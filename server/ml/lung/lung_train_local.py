"""XSIGHT lung-sound classifier — local training script (laptop GPU).

Trains the same LungNet2D mel-spectrogram CNN the server serves, on the
ICBHI 2017 Respiratory Sound Database, entirely on the local machine:

    cd server
    .venv/bin/python ml/lung/lung_train_local.py -v

Why this exists: the shipped lung_model.pt came from a 5-epoch Colab run
that plateaued at val_acc=0.39 — near chance. This script trains longer,
caches spectrograms in RAM so each epoch takes seconds, and writes the
same artifact set the Colab notebook produced.

Dependencies: torch, numpy, scipy — all already in server/.venv.
kagglehub is optional (only for the automatic download); without it,
point --data-dir at a manually downloaded copy.

Data: ICBHI 2017 (920 wavs, 126 patients, 6898 annotated cycles).
Automatic download (needs kagglehub + Kaggle account):
    pip install kagglehub
    export KAGGLE_CONFIG_DIR=/path/to/dir/containing/kaggle.json
The repo root has a kaggle.json. Manual alternative: download
https://www.kaggle.com/datasets/nimalanparameshwaran/icbhi-2017-challenge-respiratory-sound-database
and pass --data-dir pointing at the extracted folder (the one whose
subdirectory holds the 920 .wav files, typically ICBHI_final_database).

Realistic expectation: patient-aware splits land at 55-72% accuracy on
this 4-class problem. Anything above ~85% means the split leaked patient
identity, and this script prints a loud warning rather than celebrating.

Outputs (to --out, default ml/lung/output/):
    lung_model.pt      state_dict, drop-in for server/app/lung_model.pt
    lung_config.json   preprocessing/architecture config (copy alongside)
    labels.json        index -> label order
    metrics.json       per-class P/R/F1, confusion matrix, calibration
"""

from __future__ import annotations

import argparse
import json
import logging
import random
import struct
import sys
import time
from dataclasses import dataclass
from math import gcd
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn
import torch.optim as optim
from torch.utils.data import DataLoader, Dataset, WeightedRandomSampler

log = logging.getLogger("lung-train")

# --- constants shared with server/app/lung_classifier.py (keep in sync) ---
_SAMPLE_RATE = 16000
_LABELS = ["normal", "crackle", "wheeze", "both"]
_N_MELS = 64
_N_FFT = 512
_HOP = 256
_N_TIME = 128
_WINDOW = _SAMPLE_RATE * 4  # 4 s / 64000 samples
_WINDOW_SEC = 4.0
_HOP_SEC = 2.0
_BANDPASS = (50.0, 2000.0)

_KAGGLE_DATASET = "nimalanparameshwaran/icbhi-2017-challenge-respiratory-sound-database"


# ---------------------------------------------------------------------------
# Audio preprocessing — mirrors lung_classifier.py / the Colab notebook
# ---------------------------------------------------------------------------

def wav_to_pcm16(raw: bytes) -> np.ndarray:
    """Extract mono float32 [-1, 1] PCM from WAV bytes. Verbatim semantics
    of lung_classifier.py::_wav_to_pcm16 (including its fallbacks)."""
    try:
        if raw[:4] != b"RIFF":
            return np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
        channels = struct.unpack_from("<H", raw, 22)[0]
        sr = struct.unpack_from("<I", raw, 24)[0]
        bits = struct.unpack_from("<H", raw, 34)[0]
        pcm = raw[raw.find(b"data") + 8:]
        if bits == 32:
            samples = np.frombuffer(pcm, dtype=np.int32).astype(np.float32) / 2147483648.0
        else:
            samples = np.frombuffer(pcm, dtype=np.int16).astype(np.float32) / 32768.0
        if channels > 1:
            samples = samples[::channels]
        if sr != _SAMPLE_RATE:
            from scipy.signal import resample_poly
            g = gcd(sr, _SAMPLE_RATE)
            samples = resample_poly(samples, _SAMPLE_RATE // g, sr // g).astype(np.float32)
        return samples
    except Exception:
        return np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0


def bandpass(samples: np.ndarray) -> np.ndarray:
    from scipy.signal import butter, sosfilt
    nyq = _SAMPLE_RATE / 2.0
    sos = butter(4, [_BANDPASS[0] / nyq, min(_BANDPASS[1] / nyq, 0.999)],
                 btype="band", output="sos")
    return sosfilt(sos, samples).astype(np.float32)


def preprocess_cycle(samples: np.ndarray) -> np.ndarray:
    """Bandpass -> DC removal -> peak normalise, as the server does."""
    samples = bandpass(samples)
    samples = samples - np.mean(samples)
    peak = float(np.abs(samples).max()) if len(samples) else 0.0
    if peak > 1e-8:
        samples = samples / peak
    return samples


def _mel_filterbank() -> np.ndarray:
    n_fft, n_mels = _N_FFT, _N_MELS
    hz_to_mel = lambda f: 2595.0 * np.log10(1.0 + f / 700.0)
    mel_to_hz = lambda m: 700.0 * (10.0 ** (m / 2595.0) - 1.0)
    mel_points = np.linspace(hz_to_mel(_BANDPASS[0]), hz_to_mel(_BANDPASS[1]), n_mels + 2)
    bin_points = np.floor((n_fft + 1) * mel_to_hz(mel_points) / _SAMPLE_RATE).astype(int)
    fb = np.zeros((n_mels, n_fft // 2 + 1), dtype=np.float32)
    for m in range(n_mels):
        left, center, right = bin_points[m], bin_points[m + 1], bin_points[m + 2]
        for k in range(left, center):
            if center != left:
                fb[m, k] = (k - left) / (center - left)
        for k in range(center, right):
            if right != center:
                fb[m, k] = (right - k) / (right - center)
    return fb


_MEL_FB = _mel_filterbank()
_HANN = np.hanning(_N_FFT).astype(np.float32)


def log_mel_spectrogram(samples: np.ndarray) -> np.ndarray:
    """Vectorised log-mel spectrogram -> (n_mels, n_time), normalised [0, 1].
    Same math as lung_classifier.py::_log_mel_spectrogram."""
    n_frames = max(1, 1 + (len(samples) - _N_FFT) // _HOP)
    shape = (n_frames, _N_FFT)
    strides = (samples.strides[0] * _HOP, samples.strides[0])
    frames = np.lib.stride_tricks.as_strided(samples, shape=shape, strides=strides)
    frames = (frames * _HANN).copy()
    mag = np.abs(np.fft.rfft(frames, axis=1))
    mel = (mag @ _MEL_FB.T).astype(np.float32).T  # (n_mels, n_frames)
    mel = np.log10(mel + 1e-10)
    if mel.shape[1] < _N_TIME:
        mel = np.pad(mel, ((0, 0), (0, _N_TIME - mel.shape[1])))
    else:
        mel = mel[:, :_N_TIME]
    mn, mx = mel.min(), mel.max()
    if mx - mn > 1e-8:
        mel = (mel - mn) / (mx - mn)
    return mel


# ---------------------------------------------------------------------------
# Dataset discovery + manifest
# ---------------------------------------------------------------------------

@dataclass
class Cycle:
    wav_path: str
    start: float
    end: float
    label: str
    patient_id: str


def find_audio_dir(root: Path) -> Path | None:
    """Locate the directory holding the 920 wavs under a downloaded copy."""
    dirs = [p for p in root.rglob("*") if p.is_dir() and any(p.glob("*.wav"))]
    return max(dirs, key=lambda p: len(list(p.glob("*.wav"))), default=None)


def download_icbhi(data_root: Path) -> Path | None:
    """Try kagglehub; return the dataset root or None (manual fallback)."""
    try:
        import kagglehub
    except ImportError:
        return None
    log.info("downloading ICBHI via kagglehub (first run: ~2 GB)…")
    src = Path(kagglehub.dataset_download(_KAGGLE_DATASET))
    return src


def build_manifest(audio_dir: Path) -> list[Cycle]:
    def label_for(c: int, w: int) -> str:
        if c and w:
            return "both"
        if c:
            return "crackle"
        if w:
            return "wheeze"
        return "normal"

    cycles: list[Cycle] = []
    wav_files = sorted(audio_dir.glob("*.wav"))
    log.info("found %d recordings in %s", len(wav_files), audio_dir)
    for wav_path in wav_files:
        txt_path = wav_path.with_suffix(".txt")
        if not txt_path.exists():
            continue
        patient_id = wav_path.stem.split("_")[0]
        with open(txt_path) as f:
            for line in f:
                parts = line.strip().split("\t")
                if len(parts) != 4:
                    continue
                s, e, c, w = parts
                cycles.append(Cycle(str(wav_path), float(s), float(e),
                                    label_for(int(c), int(w)), patient_id))
    return cycles


def cache_spectrograms(cycles: list[Cycle]) -> np.ndarray:
    """Preprocess every cycle once; hold all spectrograms in RAM (~230 MB).
    Afterwards an epoch is pure GPU work, so long runs are cheap."""
    specs = np.zeros((len(cycles), _N_MELS, _N_TIME), dtype=np.float32)
    t0 = time.time()
    per_file_cache: dict[str, np.ndarray] = {}
    for i, cyc in enumerate(cycles):
        if cyc.wav_path not in per_file_cache:
            with open(cyc.wav_path, "rb") as f:
                per_file_cache = {cyc.wav_path: wav_to_pcm16(f.read())}  # keep 1 file
        full = per_file_cache[cyc.wav_path]
        s, e = int(cyc.start * _SAMPLE_RATE), int(cyc.end * _SAMPLE_RATE)
        chunk = preprocess_cycle(full[s:e])
        if len(chunk) < _WINDOW:
            chunk = np.pad(chunk, (0, _WINDOW - len(chunk)))
        else:
            chunk = chunk[:_WINDOW]
        specs[i] = log_mel_spectrogram(chunk)
        if (i + 1) % 500 == 0 or i + 1 == len(cycles):
            rate = (i + 1) / (time.time() - t0)
            log.info("  preprocessed %d/%d cycles (%.0f/s, ETA %.0fs)",
                     i + 1, len(cycles), rate, (len(cycles) - i - 1) / max(rate, 1))
    return specs


# ---------------------------------------------------------------------------
# Patient-aware split (numpy-only GroupShuffleSplit equivalent)
# ---------------------------------------------------------------------------

def patient_aware_split(cycles: list[Cycle], seed: int):
    rng = random.Random(seed)
    patients = sorted({c.patient_id for c in cycles})
    rng.shuffle(patients)
    n_test = max(1, int(len(patients) * 0.20))
    n_val = max(1, int(len(patients) * 0.15))
    test_p = set(patients[:n_test])
    val_p = set(patients[n_test:n_test + n_val])
    train_p = set(patients[n_test + n_val:])

    tr = [i for i, c in enumerate(cycles) if c.patient_id in train_p]
    va = [i for i, c in enumerate(cycles) if c.patient_id in val_p]
    te = [i for i, c in enumerate(cycles) if c.patient_id in test_p]

    assert not (train_p & val_p) and not (train_p & test_p) and not (val_p & test_p)
    log.info("split: train=%d cycles/%d patients  val=%d/%d  test=%d/%d "
             "(no patient overlap — verified)",
             len(tr), len(train_p), len(va), len(val_p), len(te), len(test_p))
    return tr, va, te


# ---------------------------------------------------------------------------
# Model — verbatim LungNet2D from lung_classifier.py::load()
# ---------------------------------------------------------------------------

class LungNet2D(nn.Module):
    """2D CNN for log-mel spectrogram classification.
    Input:  (batch, 1, n_mels, n_time)
    Output: (batch, num_classes)

    Head pools each feature map with BOTH mean and max, concatenated. The
    original pure AdaptiveAvgPool2d(1) head could not even memorise 256
    samples (0.69 overfit accuracy vs 1.00 for this head): averaging over
    the whole 4 s window dilutes crackle bursts — transient events lasting
    a few ms — into the background, while max-pooling preserves them.

    NOTE: this must stay byte-identical to the LungNet2D in
    server/app/lung_classifier.py, or load_state_dict silently skips the
    mismatched classifier.0 (Linear(256, 64) here, Linear(128, 64) there).
    """

    def __init__(self, num_classes=4):
        super().__init__()
        self.features = nn.Sequential(
            nn.Conv2d(1, 32, kernel_size=3, padding=1),
            nn.BatchNorm2d(32),
            nn.ReLU(),
            nn.MaxPool2d(2),
            nn.Conv2d(32, 64, kernel_size=3, padding=1),
            nn.BatchNorm2d(64),
            nn.ReLU(),
            nn.MaxPool2d(2),
            nn.Conv2d(64, 128, kernel_size=3, padding=1),
            nn.BatchNorm2d(128),
            nn.ReLU(),
        )
        self.classifier = nn.Sequential(
            nn.Linear(256, 64),
            nn.ReLU(),
            nn.Dropout(0.3),
            nn.Linear(64, num_classes),
        )

    def forward(self, x):
        x = self.features(x)
        avg = x.mean(dim=(2, 3))
        mx = x.amax(dim=(2, 3))
        return self.classifier(torch.cat([avg, mx], dim=1))


class FocalLoss(nn.Module):
    """Focal loss (Lin et al. 2017) — down-weights easy examples; helps with
    ICBHI's imbalance (~53% normal / ~7% both)."""

    def __init__(self, gamma: float = 2.0):
        super().__init__()
        self.gamma = gamma

    def forward(self, logits, targets):
        ce = nn.functional.cross_entropy(logits, targets, reduction="none")
        return (((1 - torch.exp(-ce)) ** self.gamma) * ce).mean()


class SpecDS(Dataset):
    """Serves cached spectrograms; applies SpecAugment on the train split."""

    MASK_FRAC = 0.10  # max fraction of time/freq bins masked — mild on purpose

    def __init__(self, specs: np.ndarray, ys: np.ndarray, indices: list[int],
                 augment: bool):
        self.specs = specs[indices]
        self.ys = ys[indices]
        self.augment = augment

    def __len__(self):
        return len(self.ys)

    def __getitem__(self, i):
        spec = self.specs[i]
        if self.augment:
            spec = spec.copy()
            t_max = max(1, int(_N_TIME * self.MASK_FRAC))
            tw = np.random.randint(0, t_max)
            t0 = np.random.randint(0, max(1, _N_TIME - tw))
            spec[:, t0:t0 + tw] = 0
            f_max = max(1, int(_N_MELS * self.MASK_FRAC))
            fw = np.random.randint(0, f_max)
            f0 = np.random.randint(0, max(1, _N_MELS - fw))
            spec[f0:f0 + fw, :] = 0
        return torch.from_numpy(spec).unsqueeze(0), int(self.ys[i])


# ---------------------------------------------------------------------------
# Train / calibrate / evaluate
# ---------------------------------------------------------------------------

def run_epoch(model, loader, device, criterion, optimizer=None, mixup=True):
    training = optimizer is not None
    model.train() if training else model.eval()
    total_loss, correct, total = 0.0, 0, 0
    with torch.set_grad_enabled(training):
        for x, y in loader:
            x, y = x.to(device, non_blocking=True), y.to(device, non_blocking=True)
            if training and mixup and np.random.random() < 0.5:
                lam = float(np.random.beta(0.2, 0.2))
                idx = torch.randperm(x.size(0), device=x.device)
                x = lam * x + (1 - lam) * x[idx]
                logits = model(x)
                loss = lam * criterion(logits, y) + (1 - lam) * criterion(logits, y[idx])
            else:
                logits = model(x)
                loss = criterion(logits, y)
            if training:
                optimizer.zero_grad()
                loss.backward()
                nn.utils.clip_grad_norm_(model.parameters(), max_norm=5.0)
                optimizer.step()
            total_loss += loss.item() * len(y)
            correct += (logits.argmax(1) == y).sum().item()
            total += len(y)
    return total_loss / max(total, 1), correct / max(total, 1)


def fit_temperature(model, loader, device) -> float:
    """Guo et al. 2017 post-hoc calibration on validation logits."""
    model.eval()
    logits_all, ys_all = [], []
    with torch.no_grad():
        for x, y in loader:
            logits_all.append(model(x.to(device)).cpu())
            ys_all.append(y)
    logits_all, ys_all = torch.cat(logits_all), torch.cat(ys_all)

    temperature = nn.Parameter(torch.ones(1) * 1.5)
    opt = optim.LBFGS([temperature], lr=0.01, max_iter=50)
    nll = nn.CrossEntropyLoss()

    def closure():
        opt.zero_grad()
        loss = nll(logits_all / temperature, ys_all)
        loss.backward()
        return loss

    opt.step(closure)
    return max(float(temperature.detach().item()), 1e-2)


def classification_report_manual(ys, preds, probs) -> tuple[dict, np.ndarray]:
    """Per-class precision/recall/F1 + confusion matrix, no sklearn."""
    n = len(_LABELS)
    cm = np.zeros((n, n), dtype=int)
    for t, p in zip(ys, preds):
        cm[t, p] += 1
    report = {}
    for i, name in enumerate(_LABELS):
        tp = cm[i, i]
        fp = cm[:, i].sum() - tp
        fn = cm[i, :].sum() - tp
        precision = tp / (tp + fp) if tp + fp else 0.0
        recall = tp / (tp + fn) if tp + fn else 0.0
        f1 = 2 * precision * recall / (precision + recall) if precision + recall else 0.0
        support = int(cm[i, :].sum())
        report[name] = {"precision": round(precision, 4), "recall": round(recall, 4),
                        "f1-score": round(f1, 4), "support": support}
    acc = float(np.trace(cm) / cm.sum()) if cm.sum() else 0.0
    macro_f1 = float(np.mean([report[l]["f1-score"] for l in _LABELS]))
    report["accuracy"] = round(acc, 4)
    report["macro avg"] = {"f1-score": round(macro_f1, 4)}
    return report, cm


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--data-dir", type=Path, default=None,
                    help="extracted ICBHI dataset root (or its audio dir)")
    ap.add_argument("--out", type=Path, default=Path(__file__).resolve().parent / "output",
                    help="artifact output directory (default: ml/lung/output)")
    ap.add_argument("--epochs", type=int, default=60,
                    help="training epochs (default 60; epochs take ~2s on GPU)")
    ap.add_argument("--loss", choices=["ce", "focal"], default="ce",
                    help="loss function. 'ce' = cross-entropy + label smoothing "
                         "(default; the focal run collapsed to predicting crackle)")
    ap.add_argument("--mixup-prob", type=float, default=0.0,
                    help="mixup probability (default 0 = off; with focal loss it "
                         "prevented the model from fitting at all)")
    ap.add_argument("--no-spec-augment", action="store_true",
                    help="disable SpecAugment time/freq masking")
    ap.add_argument("--batch-size", type=int, default=128)
    ap.add_argument("--lr", type=float, default=1e-3)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("-v", "--verbose", action="store_true",
                    help="per-batch logging (default logs every 10 batches)")
    args = ap.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)-7s %(message)s", datefmt="%H:%M:%S")
    torch.manual_seed(args.seed)
    np.random.seed(args.seed)
    random.seed(args.seed)

    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    log.info("device=%s torch=%s", device, torch.__version__)
    if device.type == "cuda":
        log.info("gpu=%s", torch.cuda.get_device_name(0))
    args.out.mkdir(parents=True, exist_ok=True)

    # ---- data ----
    audio_dir = None
    if args.data_dir:
        audio_dir = (args.data_dir if args.data_dir.glob("*.wav")
                     else find_audio_dir(args.data_dir))
    if audio_dir is None:
        src = download_icbhi(args.out)
        if src is not None:
            audio_dir = find_audio_dir(src)
    if audio_dir is None:
        log.error(
            "ICBHI not found. Either:\n"
            "  1. pip install kagglehub  (then rerun — downloads ~2 GB), or\n"
            "  2. download the dataset from Kaggle manually and rerun with\n"
            "     --data-dir /path/to/icbhi-2017-challenge-respiratory-sound-database")
        return 1
    log.info("audio dir: %s", audio_dir)

    cycles = build_manifest(audio_dir)
    if not cycles:
        log.error("no annotated cycles found under %s", audio_dir)
        return 1
    counts = {l: sum(1 for c in cycles if c.label == l) for l in _LABELS}
    patients = {c.patient_id for c in cycles}
    log.info("manifest: %d cycles, %d patients, labels=%s", len(cycles), len(patients), counts)

    log.info("preprocessing all cycles (one-off, cached in RAM)…")
    specs = cache_spectrograms(cycles)
    ys = np.array([_LABELS.index(c.label) for c in cycles], dtype=np.int64)

    tr_i, va_i, te_i = patient_aware_split(cycles, args.seed)

    tr_ds = SpecDS(specs, ys, tr_i, augment=not args.no_spec_augment)
    va_ds = SpecDS(specs, ys, va_i, augment=False)
    te_ds = SpecDS(specs, ys, te_i, augment=False)

    # Inverse-sqrt class weights: oversamples the rare classes (both, wheeze)
    # without flattening the prior to uniform — full balancing plus focal loss
    # collapsed the previous run into predicting "crackle" for everything.
    class_counts = np.bincount(ys[tr_i], minlength=len(_LABELS)).clip(min=1)
    sample_weights = (1.0 / np.sqrt(class_counts))[ys[tr_i]]
    sampler = WeightedRandomSampler(sample_weights, num_samples=len(tr_i), replacement=True)

    tr_ld = DataLoader(tr_ds, batch_size=args.batch_size, sampler=sampler)
    va_ld = DataLoader(va_ds, batch_size=args.batch_size)
    te_ld = DataLoader(te_ds, batch_size=args.batch_size)

    # ---- model ----
    model = LungNet2D(num_classes=len(_LABELS)).to(device)
    log.info("model: LungNet2D, %.2fM params",
             sum(p.numel() for p in model.parameters()) / 1e6)

    if args.loss == "focal":
        criterion = FocalLoss(gamma=2.0)
    else:
        criterion = nn.CrossEntropyLoss(label_smoothing=0.1)
    log.info("loss=%s", type(criterion).__name__)
    optimizer = optim.AdamW(model.parameters(), lr=args.lr, weight_decay=1e-4)
    scheduler = optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=args.epochs)

    best_val = 0.0
    log.info("training %d epochs (batch=%d, %s, mixup=%.2f, specaugment=%s)…",
             args.epochs, args.batch_size, type(criterion).__name__, args.mixup_prob,
             not args.no_spec_augment)
    for epoch in range(1, args.epochs + 1):
        t0 = time.time()
        model.train()
        running_loss, running_correct, running_total = 0.0, 0, 0
        for bi, (x, y) in enumerate(tr_ld, 1):
            x, y = x.to(device), y.to(device)
            if np.random.random() < args.mixup_prob:
                lam = float(np.random.beta(0.2, 0.2))
                idx = torch.randperm(x.size(0), device=x.device)
                x = lam * x + (1 - lam) * x[idx]
                logits = model(x)
                loss = lam * criterion(logits, y) + (1 - lam) * criterion(logits, y[idx])
            else:
                logits = model(x)
                loss = criterion(logits, y)
            optimizer.zero_grad()
            loss.backward()
            nn.utils.clip_grad_norm_(model.parameters(), max_norm=5.0)
            optimizer.step()
            running_loss += loss.item() * len(y)
            running_correct += (logits.argmax(1) == y).sum().item()
            running_total += len(y)
            if (args.verbose or bi % 10 == 0 or bi == len(tr_ld)):
                log.info("  epoch %d batch %d/%d  loss=%.4f  acc=%.3f",
                         epoch, bi, len(tr_ld), running_loss / running_total,
                         running_correct / running_total)
        scheduler.step()

        va_loss, va_acc = run_epoch(model, va_ld, device, criterion, optimizer=None)
        log.info("epoch %d/%d done in %.0fs — train_loss=%.4f val_loss=%.4f val_acc=%.3f%s",
                 epoch, args.epochs, time.time() - t0,
                 running_loss / running_total, va_loss, va_acc,
                 "  ★ saved (new best)" if va_acc > best_val else "")
        if va_acc > best_val:
            best_val = va_acc
            torch.save(model.state_dict(), args.out / "lung_model.pt")
    log.info("best val_acc=%.3f", best_val)

    # ---- calibrate + final eval on the untouched test split ----
    model.load_state_dict(torch.load(args.out / "lung_model.pt", map_location=device))
    temperature = fit_temperature(model, va_ld, device)
    log.info("fitted temperature = %.3f", temperature)

    model.eval()
    probs_all, ys_all = [], []
    with torch.no_grad():
        for x, y in te_ld:
            logits = model(x.to(device)).cpu() / temperature
            probs_all.append(torch.softmax(logits, dim=1).numpy())
            ys_all.append(y.numpy())
    probs = np.concatenate(probs_all)
    ys_te = np.concatenate(ys_all)
    preds = probs.argmax(1)

    report, cm = classification_report_manual(ys_te, preds, probs)
    acc = report["accuracy"]
    log.info("TEST (patient-aware): accuracy=%.3f macro_f1=%.3f",
             acc, report["macro avg"]["f1-score"])
    for name in _LABELS:
        r = report[name]
        log.info("  %-8s P=%.3f R=%.3f F1=%.3f (n=%d)",
                 name, r["precision"], r["recall"], r["f1-score"], r["support"])
    log.info("confusion matrix (rows=true, cols=pred):")
    log.info("          " + "".join(f"{l:>9s}" for l in _LABELS))
    for i, l in enumerate(_LABELS):
        log.info("  %-7s " % l + "".join(f"{cm[i, j]:>9d}" for j in range(len(_LABELS))))
    if acc > 0.85:
        log.warning("accuracy %.3f is suspiciously high for a patient-aware ICBHI "
                    "split — suspect leakage before trusting it", acc)

    # ---- export ----
    metrics = {
        "classification_report": report,
        "confusion_matrix": cm.tolist(),
        "temperature": temperature,
        "train_samples": len(tr_i), "val_samples": len(va_i), "test_samples": len(te_i),
        "train_patients": len({cycles[i].patient_id for i in tr_i}),
        "val_patients": len({cycles[i].patient_id for i in va_i}),
        "test_patients": len({cycles[i].patient_id for i in te_i}),
        "best_val_acc": round(best_val, 4),
        "epochs": args.epochs,
        "dataset": f"ICBHI 2017 (Kaggle: {_KAGGLE_DATASET})",
    }
    (args.out / "metrics.json").write_text(json.dumps(metrics, indent=2))
    (args.out / "labels.json").write_text(json.dumps(_LABELS, indent=2))
    (args.out / "lung_config.json").write_text(json.dumps({
        "n_mels": _N_MELS, "n_time": _N_TIME, "n_fft": _N_FFT, "hop_length": _HOP,
        "window_sec": _WINDOW_SEC, "hop_sec": _HOP_SEC, "num_classes": len(_LABELS),
        "temperature": temperature, "sample_rate": _SAMPLE_RATE,
        "bandpass_low": _BANDPASS[0], "bandpass_high": _BANDPASS[1],
    }, indent=2))
    log.info("artifacts written to %s: lung_model.pt, lung_config.json, "
             "labels.json, metrics.json", args.out.resolve())
    log.info("deploy: cp %s/lung_model.pt %s/lung_config.json server/app/ "
             "and restart the backend", args.out, args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
