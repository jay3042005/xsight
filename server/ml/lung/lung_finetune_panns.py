"""XSIGHT lung-sound classifier — PANNs CNN14 fine-tuning (laptop GPU).

The frozen-CNN14 head (lung_train_panns.py) reached ~0.35 test accuracy —
weakly informative embeddings, but below the majority baseline. The standard
next step in the ICBHI literature, and the one that reaches ~0.55-0.70 on
patient-aware 4-class evaluation, is fine-tuning the pretrained network's
upper layers on the target dataset:

  - frozen: spectrogram/logmel extractors, conv_block1-5, bn0, fc_audioset
  - trained: conv_block6, fc1, and a new 4-class linear head on the embedding
  - discriminative LRs (3e-5 body / 1e-3 head), batch 16 on a 6 GB GPU

Run:
    cd server
    .venv/bin/python ml/lung/lung_finetune_panns.py -v

Outputs (to ml/lung/output/):
    lung_cnn14_finetuned.pt   {"cnn14": Cnn14 state_dict, "head": 4-class head}
    lung_config_finetune.json runtime config for lung_classifier.py
    metrics_finetune.json     eval report

Expectation: 0.50-0.65 patient-aware accuracy. Above ~0.85 = leakage.
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
from torch.utils.data import DataLoader, Dataset

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lung_train_local as lt
from lung_train_panns import PANNS_SR, _resample_to_32k

log = logging.getLogger("lung-ft")


class _CycleWindows(Dataset):
    """Preprocessed, resampled 4 s windows — rebuilt each epoch is too slow,
    so windows are materialised once and augmented on the fly."""

    def __init__(self, cycles: list[lt.Cycle], indices: list[int],
                 augment: bool):
        self.augment = augment
        per_file: dict[str, bytes] = {}
        self.x = np.zeros((len(indices), lt._WINDOW), dtype=np.float32)
        self.y = np.zeros(len(indices), dtype=np.int64)
        for j, i in enumerate(indices):
            c = cycles[i]
            if c.wav_path not in per_file:
                with open(c.wav_path, "rb") as f:
                    per_file = {c.wav_path: f.read()}
            full = lt.wav_to_pcm16(per_file[c.wav_path])
            chunk = lt.preprocess_cycle(
                full[int(c.start * lt._SAMPLE_RATE):int(c.end * lt._SAMPLE_RATE)]
            )
            if len(chunk) < lt._WINDOW:
                chunk = np.pad(chunk, (0, lt._WINDOW - len(chunk)))
            self.x[j] = chunk[:lt._WINDOW]
            self.y[j] = lt._LABELS.index(c.label)

    def __len__(self):
        return len(self.y)

    def __getitem__(self, i):
        w = self.x[i]
        if self.augment:
            # gentle gain jitter only: the classes are defined by fine
            # temporal structure, which heavier augmentation can destroy
            w = w * np.random.uniform(0.85, 1.15)
        # resample on the fly: keeps RAM at 16 kHz instead of 32 kHz
        return (_resample_to_32k(w), int(self.y[i]))


def main() -> int:
    ap = argparse.ArgumentParser(description="Fine-tune PANNs CNN14 on ICBHI")
    ap.add_argument("--data-dir", type=Path, default=None)
    ap.add_argument("--out", type=Path,
                    default=Path(__file__).resolve().parent / "output")
    ap.add_argument("--epochs", type=int, default=12)
    ap.add_argument("--batch-size", type=int, default=16)
    ap.add_argument("--body-lr", type=float, default=3e-5)
    ap.add_argument("--head-lr", type=float, default=1e-3)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)-7s %(message)s", datefmt="%H:%M:%S")
    torch.manual_seed(args.seed)
    np.random.seed(args.seed)

    device = "cuda" if torch.cuda.is_available() else "cpu"
    log.info("device=%s", device)

    # ---- dataset ----
    audio_dir = args.data_dir
    if audio_dir is None:
        import kagglehub
        src = Path(kagglehub.dataset_download(lt._KAGGLE_DATASET))
        audio_dir = lt.find_audio_dir(src)
    elif not any(audio_dir.glob("*.wav")):
        audio_dir = lt.find_audio_dir(audio_dir)
    cycles = lt.build_manifest(audio_dir)
    if not cycles:
        log.error("no cycles found")
        return 1
    tr_i, va_i, te_i = lt.patient_aware_split(cycles, args.seed)

    log.info("materialising windows (one-off)…")
    t0 = time.time()
    tr_ds = _CycleWindows(cycles, tr_i, augment=True)
    va_ds = _CycleWindows(cycles, va_i, augment=False)
    te_ds = _CycleWindows(cycles, te_i, augment=False)
    log.info("windows ready in %.0fs (train=%d val=%d test=%d)",
             time.time() - t0, len(tr_ds), len(va_ds), len(te_ds))

    tr_ld = DataLoader(tr_ds, batch_size=args.batch_size, shuffle=True,
                       num_workers=2, pin_memory=True, drop_last=True)
    va_ld = DataLoader(va_ds, batch_size=args.batch_size, num_workers=2)
    te_ld = DataLoader(te_ds, batch_size=args.batch_size, num_workers=2)

    # ---- model: Cnn14 with a 4-class head ----
    from panns_inference import AudioTagging
    at = AudioTagging(device=device)
    model = at.model.module if hasattr(at.model, "module") else at.model
    model.to(device)

    # Cnn14.forward returns a dict with a *sigmoid* clipwise_output
    # (AudioSet multi-label style) — useless for CE loss. So fc_audioset
    # stays frozen and unused, and this explicit head takes its embedding.
    head = nn.Linear(model.fc_audioset.in_features, len(lt._LABELS)).to(device)

    # Freeze the perception stack; train conv_block6 + fc1 + new head.
    frozen = [model.spectrogram_extractor, model.logmel_extractor,
              model.spec_augmenter, model.bn0,
              model.conv_block1, model.conv_block2, model.conv_block3,
              model.conv_block4, model.conv_block5]
    for m in frozen:
        for p in m.parameters():
            p.requires_grad = False
    body_params = [p for p in model.conv_block6.parameters()] + \
                  [p for p in model.fc1.parameters()]
    head_params = list(head.parameters())
    trainable = body_params + head_params
    log.info("trainable tensors: %d | frozen tensors: %d",
             len(trainable),
             sum(1 for p in model.parameters() if not p.requires_grad))

    optimizer = optim.AdamW([
        {"params": body_params, "lr": args.body_lr},
        {"params": head_params, "lr": args.head_lr},
    ], weight_decay=1e-4)
    scheduler = optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=args.epochs)
    # Mild class weights: full inverse-frequency weighting made the frozen
    # head over-predict the rare classes and sink accuracy below baseline.
    counts = np.bincount(tr_ds.y, minlength=len(lt._LABELS)).clip(min=1)
    weights = torch.tensor(
        np.sqrt(counts.max() / counts), dtype=torch.float32).to(device)
    criterion = nn.CrossEntropyLoss(weight=weights, label_smoothing=0.05)
    log.info("class weights: %s", weights.cpu().numpy().round(2))

    def evaluate(loader) -> tuple[float, float, np.ndarray, np.ndarray]:
        """Returns (accuracy, macro_f1, probs, ys)."""
        model.eval()
        probs, ys_all = [], []
        with torch.no_grad():
            for x, y in loader:
                logits = head(model(x.to(device), None)["embedding"])
                probs.append(torch.softmax(logits, dim=1).cpu().numpy())
                ys_all.append(y.numpy())
        probs = np.concatenate(probs)
        ys_all = np.concatenate(ys_all)
        rep, _ = lt.classification_report_manual(ys_all, probs.argmax(1), probs)
        return (rep["accuracy"], rep["macro avg"]["f1-score"], probs, ys_all)

    args.out.mkdir(parents=True, exist_ok=True)
    ckpt_path = args.out / "lung_cnn14_finetuned.pt"
    best_val_f1 = 0.0
    for epoch in range(1, args.epochs + 1):
        model.train()
        # keep frozen modules honest under .train()
        for m in frozen:
            m.eval()
        t0 = time.time()
        running_loss, running_correct, running_total = 0.0, 0, 0
        for bi, (x, y) in enumerate(tr_ld, 1):
            x, y = x.to(device), y.to(device)
            logits = head(model(x, None)["embedding"])
            loss = criterion(logits, y)
            optimizer.zero_grad()
            loss.backward()
            nn.utils.clip_grad_norm_(trainable, max_norm=5.0)
            optimizer.step()
            running_loss += loss.item() * len(y)
            running_correct += (logits.argmax(1) == y).sum().item()
            running_total += len(y)
            if args.verbose or bi % 20 == 0 or bi == len(tr_ld):
                log.info("  ep%d %d/%d loss=%.3f acc=%.3f",
                         epoch, bi, len(tr_ld),
                         running_loss / running_total,
                         running_correct / running_total)
        scheduler.step()
        val_acc, val_f1, _, _ = evaluate(va_ld)
        # Selection on macro-F1, NOT accuracy: the val split is ~60% normal,
        # so accuracy-based selection keeps picking majority-shaped
        # checkpoints that predict wheeze/both never.
        log.info("epoch %d/%d done in %.0fs — train_loss=%.3f train_acc=%.3f "
                 "val_acc=%.3f val_macro_f1=%.3f%s", epoch, args.epochs,
                 time.time() - t0, running_loss / running_total,
                 running_correct / running_total, val_acc, val_f1,
                 "  * best" if val_f1 > best_val_f1 else "")
        if val_f1 > best_val_f1:
            best_val_f1 = val_f1
            torch.save({"cnn14": model.state_dict(), "head": head.state_dict()},
                        ckpt_path)
    log.info("best val macro_f1=%.3f", best_val_f1)

    # ---- final test evaluation on the best checkpoint ----
    ckpt = torch.load(ckpt_path, map_location=device, weights_only=True)
    model.load_state_dict(ckpt["cnn14"])
    head.load_state_dict(ckpt["head"])
    test_acc, test_f1, probs, ys_te = evaluate(te_ld)

    # temperature calibration on val
    model.eval()
    logits_all, ys_va = [], []
    with torch.no_grad():
        for x, y in va_ld:
            logits_all.append(head(model(x.to(device), None)["embedding"]).cpu())
            ys_va.append(y)
    logits_all, ys_va = torch.cat(logits_all), torch.cat(ys_va)
    temperature = nn.Parameter(torch.ones(1) * 1.5)
    opt_t = optim.LBFGS([temperature], lr=0.01, max_iter=50)
    nll = nn.CrossEntropyLoss()

    def closure():
        opt_t.zero_grad()
        loss = nll(logits_all / temperature, ys_va)
        loss.backward()
        return loss

    opt_t.step(closure)
    temperature = max(float(temperature.detach().item()), 1e-2)

    report, cm = lt.classification_report_manual(
        ys_te, probs.argmax(1), probs)
    log.info("TEST (patient-aware): accuracy=%.3f macro_f1=%.3f temperature=%.3f",
             test_acc, report["macro avg"]["f1-score"], temperature)
    for name in lt._LABELS:
        r = report[name]
        log.info("  %-8s P=%.3f R=%.3f F1=%.3f (n=%d)",
                 name, r["precision"], r["recall"], r["f1-score"], r["support"])
    log.info("confusion matrix (rows=true, cols=pred):")
    log.info("          " + "".join(f"{l:>9s}" for l in lt._LABELS))
    for i, l in enumerate(lt._LABELS):
        log.info("  %-7s " % l +
                 "".join(f"{cm[i, j]:>9d}" for j in range(len(lt._LABELS))))
    if test_acc > 0.85:
        log.warning("accuracy %.3f is suspiciously high for a patient-aware "
                    "ICBHI split — suspect leakage before trusting it",
                    test_acc)

    (args.out / "lung_config_finetune.json").write_text(json.dumps({
        "backend": "panns-ft",
        "num_classes": len(lt._LABELS),
        "temperature": temperature,
        "labels": lt._LABELS,
        "sample_rate": lt._SAMPLE_RATE,
        "panns_sr": PANNS_SR,
        "window_sec": lt._WINDOW_SEC,
        "hop_sec": 2.0,
        "bandpass": [lt._BANDPASS[0], lt._BANDPASS[1]],
    }, indent=2))
    (args.out / "metrics_finetune.json").write_text(json.dumps({
        "classification_report": report,
        "confusion_matrix": cm.tolist(),
        "temperature": temperature,
        "best_val_macro_f1": round(best_val_f1, 4),
        "backend": "panns-cnn14-finetuned",
        "train_samples": len(tr_ds), "val_samples": len(va_ds),
        "test_samples": len(te_ds),
        "train_patients": len({cycles[i].patient_id for i in tr_i}),
        "val_patients": len({cycles[i].patient_id for i in va_i}),
        "test_patients": len({cycles[i].patient_id for i in te_i}),
        "dataset": f"ICBHI 2017 (Kaggle: {lt._KAGGLE_DATASET})",
    }, indent=2))
    log.info("artifacts: lung_cnn14_finetuned.pt, lung_config_finetune.json, "
             "metrics_finetune.json -> %s", args.out.resolve())
    return 0


if __name__ == "__main__":
    sys.exit(main())
