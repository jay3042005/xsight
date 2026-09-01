"""XSIGHT lung-sound classifier — PANNs embedding training (laptop GPU).

The from-scratch CNN could not learn ICBHI (it collapsed to the majority
class in every configuration; see lung_train_local.py history). The approach
that actually works on this dataset — per LUNG_TRAINING.md §3 and the ICBHI
literature — is transfer learning from AudioSet-pretrained models:

  1. PANNs CNN14 (80M params, pretrained on AudioSet) as a frozen feature
     extractor: one 2048-dim embedding per respiratory cycle.
  2. A tiny trainable head (2048 -> 256 -> 4) on top, patient-aware split.

Embeddings are cached to panns_embeddings.npz next to this script, so
retraining the head is instant. Preprocessing is identical to the server's
runtime path (bandpass 50-2000 Hz, DC removal, peak normalisation, 4 s
window at 16 kHz), then resampled to 32 kHz for CNN14.

Run:
    cd server
    .venv/bin/python ml/lung/lung_train_panns.py -v
    .venv/bin/python ml/lung/lung_train_panns.py --smoke   # pipeline check

Outputs (to ml/lung/output/):
    lung_head_panns.pt      head state_dict + embedding scaler
    lung_config_panns.json  runtime config for lung_classifier.py
    metrics_panns.json      eval report (same shape as metrics.json)

Expectation: 55-65% patient-aware accuracy — the honest ICBHI ceiling.
Above ~85% means the split leaked; this script prints a loud warning.
"""

from __future__ import annotations

import argparse
import json
import logging
import sys
import time
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn
import torch.optim as optim
from torch.utils.data import DataLoader, TensorDataset

# Shared dataset/manifest/split/report code with the from-scratch trainer.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import lung_train_local as lt

log = logging.getLogger("lung-panns")

EMB_DIM = 2048
PANNS_SR = 32000  # CNN14 was trained at 32 kHz; panns_inference expects it.
_CACHE = Path(__file__).resolve().parent / "panns_embeddings.npz"


class Head(nn.Module):
    """Tiny classifier on top of frozen CNN14 embeddings."""

    def __init__(self, in_dim: int = EMB_DIM, hidden: int = 256, n: int = 4):
        super().__init__()
        self.net = nn.Sequential(
            nn.Linear(in_dim, hidden),
            nn.ReLU(),
            nn.Dropout(0.3),
            nn.Linear(hidden, n),
        )

    def forward(self, x):
        return self.net(x)


def _cycle_window(raw: bytes, start: float, end: float) -> np.ndarray:
    """One cycle through the exact preprocessing the server does at runtime."""
    full = lt.wav_to_pcm16(raw)
    chunk = lt.preprocess_cycle(
        full[int(start * lt._SAMPLE_RATE):int(end * lt._SAMPLE_RATE)]
    )
    if len(chunk) < lt._WINDOW:
        chunk = np.pad(chunk, (0, lt._WINDOW - len(chunk)))
    return chunk[:lt._WINDOW]


def _resample_to_32k(x: np.ndarray) -> np.ndarray:
    from scipy.signal import resample_poly
    return resample_poly(x, 2, 1).astype(np.float32)


def extract_embeddings(cycles: list[lt.Cycle], device: str) -> np.ndarray:
    """CNN14 embedding per cycle, cached. Loads each wav once."""
    if _CACHE.exists():
        cached = np.load(_CACHE)
        if len(cached["emb"]) == len(cycles):
            log.info("using cached embeddings (%d x %d)", *cached["emb"].shape)
            return cached["emb"]
        log.info("embedding cache stale (cycles changed) — re-extracting")

    from panns_inference import AudioTagging

    log.info("loading PANNs CNN14 (first run downloads ~300 MB checkpoint)")
    at = AudioTagging(device=device)

    out = np.zeros((len(cycles), EMB_DIM), dtype=np.float32)
    per_file: dict[str, bytes] = {}
    batch_idx: list[int] = []
    batch_audio: list[np.ndarray] = []
    t0 = time.time()
    done = 0

    def flush() -> None:
        nonlocal done
        if not batch_audio:
            return
        clip = torch.tensor(np.stack(batch_audio), dtype=torch.float32)
        # inference() -> (clipwise_output 527-d AudioSet scores, embedding 2048-d)
        _, emb = at.inference(clip)
        for i, e in zip(batch_idx, emb):
            out[i] = e
        done += len(batch_idx)
        rate = done / max(time.time() - t0, 1e-9)
        log.info("  embedded %d/%d cycles (%.1f/s, ETA %.0fs)",
                 done, len(cycles), rate, (len(cycles) - done) / max(rate, 1))
        batch_idx.clear()
        batch_audio.clear()

    for i, cyc in enumerate(cycles):
        if cyc.wav_path not in per_file:
            # keep one decoded file at a time; manifest is file-grouped
            with open(cyc.wav_path, "rb") as f:
                per_file = {cyc.wav_path: f.read()}
        window = _cycle_window(per_file[cyc.wav_path], cyc.start, cyc.end)
        batch_idx.append(i)
        batch_audio.append(_resample_to_32k(window))
        if len(batch_audio) == 32:
            flush()
    flush()

    np.savez_compressed(_CACHE, emb=out)
    log.info("embeddings cached to %s", _CACHE)
    return out


def run_epoch(model, loader, criterion, optimizer=None):
    training = optimizer is not None
    model.train() if training else model.eval()
    loss_sum, correct, total = 0.0, 0, 0
    with torch.set_grad_enabled(training):
        for x, y in loader:
            logits = model(x)
            loss = criterion(logits, y)
            if training:
                optimizer.zero_grad()
                loss.backward()
                optimizer.step()
            loss_sum += loss.item() * len(y)
            correct += (logits.argmax(1) == y).sum().item()
            total += len(y)
    return loss_sum / max(total, 1), correct / max(total, 1)


def main() -> int:
    ap = argparse.ArgumentParser(description="PANNs-based lung model training")
    ap.add_argument("--data-dir", type=Path, default=None,
                    help="extracted ICBHI dataset root (default: kagglehub cache)")
    ap.add_argument("--out", type=Path,
                    default=Path(__file__).resolve().parent / "output")
    ap.add_argument("--epochs", type=int, default=120)
    ap.add_argument("--batch-size", type=int, default=256)
    ap.add_argument("--lr", type=float, default=1e-3)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--smoke", action="store_true",
                    help="embed 200 cycles and exit — pipeline check only")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)-7s %(message)s", datefmt="%H:%M:%S")
    torch.manual_seed(args.seed)
    np.random.seed(args.seed)

    device = "cuda" if torch.cuda.is_available() else "cpu"
    log.info("device=%s torch=%s", device, torch.__version__)

    # ---- dataset ----
    audio_dir = args.data_dir
    if audio_dir is None:
        import kagglehub
        src = Path(kagglehub.dataset_download(lt._KAGGLE_DATASET))
        audio_dir = lt.find_audio_dir(src)
    elif not any(audio_dir.glob("*.wav")):
        audio_dir = lt.find_audio_dir(audio_dir)
    log.info("audio dir: %s", audio_dir)
    cycles = lt.build_manifest(audio_dir)
    if args.smoke:
        cycles = cycles[:200]
        log.info("SMOKE MODE: %d cycles, embedding only", len(cycles))
        extract_embeddings(cycles, device)
        log.info("SMOKE OK — pipeline works")
        return 0
    if not cycles:
        log.error("no cycles found")
        return 1

    tr_i, va_i, te_i = lt.patient_aware_split(cycles, args.seed)
    ys = np.array([lt._LABELS.index(c.label) for c in cycles], dtype=np.int64)

    # ---- embeddings (frozen CNN14) ----
    emb = extract_embeddings(cycles, device)

    # ---- standardise on TRAIN only; the scaler ships with the head ----
    mean = emb[tr_i].mean(axis=0)
    std = emb[tr_i].std(axis=0) + 1e-8
    emb_n = (emb - mean) / std

    def tensor_ds(indices):
        return TensorDataset(
            torch.tensor(emb_n[indices], dtype=torch.float32),
            torch.tensor(ys[indices], dtype=torch.long),
        )

    tr_ld = DataLoader(tensor_ds(tr_i), batch_size=args.batch_size, shuffle=True)
    va_ld = DataLoader(tensor_ds(va_i), batch_size=args.batch_size)
    te_ld = DataLoader(tensor_ds(te_i), batch_size=args.batch_size)

    # ---- head training ----
    model = Head()
    counts = np.bincount(ys[tr_i], minlength=len(lt._LABELS)).clip(min=1)
    weights = torch.tensor(len(tr_i) / (len(lt._LABELS) * counts),
                           dtype=torch.float32)
    log.info("head: %s | class weights: %s",
             sum(p.numel() for p in model.parameters()), weights.numpy().round(2))
    criterion = nn.CrossEntropyLoss(weight=weights, label_smoothing=0.05)
    optimizer = optim.AdamW(model.parameters(), lr=args.lr, weight_decay=1e-4)
    scheduler = optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=args.epochs)

    best_val = 0.0
    args.out.mkdir(parents=True, exist_ok=True)
    head_path = args.out / "lung_head_panns.pt"
    for epoch in range(1, args.epochs + 1):
        tr_loss, tr_acc = run_epoch(model, tr_ld, criterion, optimizer)
        scheduler.step()
        va_loss, va_acc = run_epoch(model, va_ld, criterion)
        if epoch % 10 == 0 or epoch == 1 or va_acc > best_val:
            log.info("epoch %3d/%d  train_loss=%.3f train_acc=%.3f "
                     "val_loss=%.3f val_acc=%.3f%s",
                     epoch, args.epochs, tr_loss, tr_acc, va_loss, va_acc,
                     "  * best" if va_acc > best_val else "")
        if va_acc > best_val:
            best_val = va_acc
            torch.save({"head": model.state_dict(),
                        "emb_mean": torch.tensor(mean),
                        "emb_std": torch.tensor(std)}, head_path)
    log.info("best val_acc=%.3f", best_val)

    # ---- temperature calibration on val ----
    ckpt = torch.load(head_path, map_location="cpu", weights_only=True)
    model.load_state_dict(ckpt["head"])
    model.eval()
    va_logits, va_ys = [], []
    with torch.no_grad():
        for x, y in va_ld:
            va_logits.append(model(x))
            va_ys.append(y)
    va_logits, va_ys = torch.cat(va_logits), torch.cat(va_ys)
    temperature = nn.Parameter(torch.ones(1) * 1.5)
    opt_t = optim.LBFGS([temperature], lr=0.01, max_iter=50)
    nll = nn.CrossEntropyLoss()

    def closure():
        opt_t.zero_grad()
        loss = nll(va_logits / temperature, va_ys)
        loss.backward()
        return loss

    opt_t.step(closure)
    temperature = max(float(temperature.detach().item()), 1e-2)
    log.info("fitted temperature = %.3f", temperature)

    # ---- test evaluation (patient-aware, untouched split) ----
    probs, ys_te = [], []
    with torch.no_grad():
        for x, y in te_ld:
            p = torch.softmax(model(x) / temperature, dim=1)
            probs.append(p.numpy())
            ys_te.append(y.numpy())
    probs = np.concatenate(probs)
    ys_te = np.concatenate(ys_te)
    report, cm = lt.classification_report_manual(ys_te, probs.argmax(1), probs)
    acc = report["accuracy"]
    log.info("TEST (patient-aware): accuracy=%.3f macro_f1=%.3f",
             acc, report["macro avg"]["f1-score"])
    for name in lt._LABELS:
        r = report[name]
        log.info("  %-8s P=%.3f R=%.3f F1=%.3f (n=%d)",
                 name, r["precision"], r["recall"], r["f1-score"], r["support"])
    log.info("confusion matrix (rows=true, cols=pred):")
    log.info("          " + "".join(f"{l:>9s}" for l in lt._LABELS))
    for i, l in enumerate(lt._LABELS):
        log.info("  %-7s " % l +
                 "".join(f"{cm[i, j]:>9d}" for j in range(len(lt._LABELS))))
    if acc > 0.85:
        log.warning("accuracy %.3f is suspiciously high for a patient-aware "
                    "ICBHI split — suspect leakage before trusting it", acc)

    # ---- export ----
    (args.out / "lung_config_panns.json").write_text(json.dumps({
        "backend": "panns",
        "emb_dim": EMB_DIM,
        "hidden": 256,
        "num_classes": len(lt._LABELS),
        "temperature": temperature,
        "labels": lt._LABELS,
        "sample_rate": lt._SAMPLE_RATE,
        "panns_sr": PANNS_SR,
        "window_sec": lt._WINDOW_SEC,
        "bandpass": [lt._BANDPASS[0], lt._BANDPASS[1]],
        # Confidence gate consumed by lung_classifier.classify(): below this
        # the API answers "inconclusive" instead of a finding. Calibrate
        # against the precision/coverage table this run prints above — there
        # is no band where findings are reliably right, so this trades
        # coverage for trustworthiness.
        "min_confidence": 0.65,
    }, indent=2))
    (args.out / "metrics_panns.json").write_text(json.dumps({
        "classification_report": report,
        "confusion_matrix": cm.tolist(),
        "temperature": temperature,
        "best_val_acc": round(best_val, 4),
        "backend": "panns-cnn14-frozen",
        "train_samples": len(tr_i), "val_samples": len(va_i),
        "test_samples": len(te_i),
        "train_patients": len({cycles[i].patient_id for i in tr_i}),
        "val_patients": len({cycles[i].patient_id for i in va_i}),
        "test_patients": len({cycles[i].patient_id for i in te_i}),
        "dataset": f"ICBHI 2017 (Kaggle: {lt._KAGGLE_DATASET})",
    }, indent=2))
    log.info("artifacts: %s (lung_head_panns.pt, lung_config_panns.json, "
             "metrics_panns.json)", args.out.resolve())
    log.info("deploy: copy lung_head_panns.pt + lung_config_panns.json to "
             "server/app/ and restart the backend")
    return 0


if __name__ == "__main__":
    sys.exit(main())
