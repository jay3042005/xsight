"""XSIGHT lung sound classifier.

Mel-spectrogram CNN classification with test-time augmentation and
temperature-calibrated confidence. Falls back to improved spectral
heuristics when torch is unavailable.

Labels: normal, crackle, wheeze, both  (ICBHI 2017 4-class scheme)
"""

from __future__ import annotations

import io
import logging
import os
import struct
from pathlib import Path
from typing import Optional

import numpy as np

log = logging.getLogger("xsight.lung")

_MODEL_DIR = Path(__file__).resolve().parent
_WEIGHTS = _MODEL_DIR / "lung_model.pt"
_CONFIG = _MODEL_DIR / "lung_config.json"
# PANNs CNN14 (AudioSet-pretrained) + a small trained head. Preferred backend
# when both files exist; produced by server/ml/lung/lung_train_panns.py.
_HEAD_PANNS = _MODEL_DIR / "lung_head_panns.pt"
_CONFIG_PANNS = _MODEL_DIR / "lung_config_panns.json"
_SAMPLE_RATE = 16000
_LABELS = ["normal", "crackle", "wheeze", "both"]

# Full-scale amplitude of one ESP32 ADC count, used only to report levels in the
# units the hardware is measured in. The sketch samples a 12-bit ADC and sends the
# high-passed value as int16, so a count is 1/32768 of full scale.
_ADC_COUNT = 1.0 / 32768.0

# Below this RMS the recording carries no auscultation to classify.
#
# The firmware high-passes at ~20 Hz, so the DC bias is gone and what reaches the
# WAV is the AC swing in ADC counts. Measured through this exact filter chain, for
# a 20 s capture at 2 kHz:
#
#     bell on the chest   +/-200 counts peak  ->  37.7 counts RMS
#     a quiet patient     +/-100              ->  18.7
#     very quiet          +/- 30              ->   5.4
#     bell held in air    +/-  8              ->   1.9
#     converter noise     +/-  2              ->   0.3
#
# So the boundary is not near a real signal at all — it sits in the gap between
# roughly 2 and 5 counts. 0.0001 full-scale is 3.3 counts: twelve times below the
# reported working amplitude, and above anything the bell picks up off the chest.
# It exists to catch a dead line, not to judge technique.
#
# Override with "min_rms" in lung_config.json, in full-scale units.
# `signal_rms_counts` is returned on every classification, including rejections in
# the server log, so this can be calibrated against real recordings rather than
# these synthetic ones.
_MIN_RMS = 0.0001


class LungSignalTooWeak(ValueError):
    """The audio carries no lung sound loud enough to classify.

    Raised instead of returning a label because every entry in [_LABELS] is a
    clinical finding, and "normal" is the most harmful of the four to invent: a
    stethoscope resting on a table would otherwise be reported as clear lungs.
    Peak-normalisation is what makes this necessary rather than merely tidy — it
    scales whatever it is given to full range, so converter noise arrives at the
    model looking exactly like a quiet patient.
    """

_model = None
_loaded = False
_backend: Optional[str] = None
_config: dict = {}
_temperature: float = 1.0
# {"tagger": AudioTagging, "head": nn.Module, "mean": np, "std": np} — only
# for the panns backend.
_panns: Optional[dict] = None


def is_available() -> bool:
    return _loaded and _model is not None


def status() -> dict:
    return {
        "available": is_available(),
        "backend": _backend,
        "weights": str(_WEIGHTS) if _WEIGHTS.exists() else None,
        "config": str(_CONFIG) if _CONFIG.exists() else None,
        "panns_head": str(_HEAD_PANNS) if _HEAD_PANNS.exists() else None,
        "labels": _LABELS,
        "temperature": _temperature,
        "min_confidence": float(_config.get("min_confidence", 0.0)),
    }


def load() -> None:
    """Load classifier weights. Safe to call repeatedly."""
    global _model, _loaded, _backend, _config, _temperature, _panns
    if _loaded:
        return

    import json

    if _CONFIG.exists():
        try:
            _config = json.loads(_CONFIG.read_text())
            _temperature = float(_config.get("temperature", 1.0))
        except Exception:
            _config = {}

    # Preferred backend: frozen PANNs CNN14 embeddings + trained head. The
    # from-scratch CNN could not learn ICBHI (majority-class collapse in every
    # configuration); transfer learning from AudioSet is the approach that
    # does — see LUNG_TRAINING.md and ml/lung/lung_train_panns.py.
    if _HEAD_PANNS.exists() and _CONFIG_PANNS.exists():
        try:
            import torch
            import torch.nn as nn
            from panns_inference import AudioTagging

            cfg = json.loads(_CONFIG_PANNS.read_text())
            emb_dim = int(cfg.get("emb_dim", 2048))
            hidden = int(cfg.get("hidden", 256))
            num_classes = int(cfg.get("num_classes", len(_LABELS)))

            # Mirror of Head in lung_train_panns.py — the state_dict keys
            # (net.*) must match or the load silently fails.
            head = nn.Sequential(
                nn.Linear(emb_dim, hidden),
                nn.ReLU(),
                nn.Dropout(0.3),
                nn.Linear(hidden, num_classes),
            )
            ckpt = torch.load(_HEAD_PANNS, map_location="cpu", weights_only=True)
            # The trainer saves its Head wrapper (keys "net.0.*"); this side
            # builds the bare Sequential — strip the prefix so keys match.
            state = ckpt["head"]
            if any(k.startswith("net.") for k in state):
                state = {k.removeprefix("net."): v for k, v in state.items()}
            head.load_state_dict(state)

            device = "cuda" if torch.cuda.is_available() else "cpu"
            _panns = {
                "tagger": AudioTagging(device=device),
                "head": head.eval(),
                "mean": ckpt["emb_mean"].numpy(),
                "std": ckpt["emb_std"].numpy(),
                "sr": int(cfg.get("panns_sr", 32000)),
            }
            _config = cfg
            _temperature = float(cfg.get("temperature", 1.0))
            _model = "panns"
            _backend = "panns"
            _loaded = True
            log.info("[lung] loaded PANNs CNN14 + head (device=%s temp=%.2f)",
                     device, _temperature)
            return
        except Exception as e:
            log.warning("[lung] panns load failed: %s — falling back", e)

    if not _WEIGHTS.exists():
        log.info("[lung] no weights at %s — using spectral heuristics", _WEIGHTS)
        _model = "heuristic"
        _loaded = True
        _backend = "heuristic"
        return

    try:
        import torch
        import torch.nn as nn

        n_mels = int(_config.get("n_mels", 64))
        n_time = int(_config.get("n_time", 128))
        num_classes = int(_config.get("num_classes", len(_LABELS)))

        class LungNet2D(nn.Module):
            """2D CNN for log-mel spectrogram classification.

            Input:  (batch, 1, n_mels, n_time)
            Output: (batch, num_classes)

            Head pools each feature map with BOTH mean and max, concatenated.
            Pure global average pooling could not fit the training data at all
            (crackle bursts last a few ms and average away across a 4 s window);
            the max path preserves them. Must stay identical to LungNet2D in
            server/ml/lung/lung_train_local.py — classifier.0 is Linear(256, 64),
            so an old avg-only checkpoint's head silently fails to load.
            """
            def __init__(self):
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

        model = LungNet2D()
        state = torch.load(_WEIGHTS, map_location="cpu", weights_only=True)
        model.load_state_dict(state, strict=False)
        model.eval()
        _model = model
        _backend = "torch"
        _loaded = True
        log.info("[lung] loaded mel-spectrogram CNN (temp=%.2f)", _temperature)
    except Exception as e:
        log.warning("[lung] torch load failed: %s — using heuristics", e)
        _model = "heuristic"
        _loaded = True
        _backend = "heuristic"


# ---------------------------------------------------------------------------
# Audio preprocessing
# ---------------------------------------------------------------------------

def _wav_to_pcm16(raw: bytes) -> np.ndarray:
    """Extract PCM samples from WAV bytes, return float32 in [-1, 1]."""
    try:
        if raw[:4] != b"RIFF":
            return np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0

        channels = struct.unpack_from("<H", raw, 22)[0]
        sr = struct.unpack_from("<I", raw, 24)[0]
        bits = struct.unpack_from("<H", raw, 34)[0]
        data_offset = raw.find(b"data") + 8
        pcm = raw[data_offset:]

        if bits == 16:
            samples = np.frombuffer(pcm, dtype=np.int16).astype(np.float32) / 32768.0
        elif bits == 32:
            samples = np.frombuffer(pcm, dtype=np.int32).astype(np.float32) / 2147483648.0
        else:
            samples = np.frombuffer(pcm, dtype=np.int16).astype(np.float32) / 32768.0

        if channels > 1:
            samples = samples[::channels]

        if sr != _SAMPLE_RATE:
            samples = _resample(samples, sr, _SAMPLE_RATE)

        return samples
    except Exception:
        return np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0


def _resample(samples: np.ndarray, src_sr: int, dst_sr: int) -> np.ndarray:
    """Resample using scipy.signal.resample_poly for quality, fallback to linear interp."""
    try:
        from scipy.signal import resample_poly
        from math import gcd
        g = gcd(src_sr, dst_sr)
        up = dst_sr // g
        down = src_sr // g
        return resample_poly(samples, up, down).astype(np.float32)
    except ImportError:
        ratio = dst_sr / src_sr
        n_out = int(len(samples) * ratio)
        x_old = np.linspace(0, 1, len(samples), endpoint=False)
        x_new = np.linspace(0, 1, n_out, endpoint=False)
        return np.interp(x_new, x_old, samples).astype(np.float32)


def _bandpass(samples: np.ndarray, low: float = 50.0, high: float = 2000.0,
              sr: int = _SAMPLE_RATE, order: int = 4) -> np.ndarray:
    """Butterworth bandpass filter using scipy, fallback to simple HP+LP."""
    try:
        from scipy.signal import butter, sosfilt
        nyq = sr / 2.0
        lo = max(low / nyq, 1e-5)
        hi = min(high / nyq, 0.999)
        sos = butter(order, [lo, hi], btype="band", output="sos")
        return sosfilt(sos, samples).astype(np.float32)
    except ImportError:
        # Fallback: simple IIR HP + LP (same as firmware)
        dt = 1.0 / sr
        hp_rc = 1.0 / (2 * np.pi * low)
        hp_alpha = hp_rc / (hp_rc + dt)
        lp_rc = 1.0 / (2 * np.pi * high)
        lp_alpha = dt / (lp_rc + dt)

        hp_prev_in = 0.0
        hp_prev_out = 0.0
        lp_prev_out = 0.0
        out = np.empty_like(samples)
        for i, raw in enumerate(samples):
            hp_out = hp_alpha * (hp_prev_out + raw - hp_prev_in)
            hp_prev_in = raw
            hp_prev_out = hp_out
            lp_out = lp_prev_out + lp_alpha * (hp_out - lp_prev_out)
            lp_prev_out = lp_out
            out[i] = lp_out
        return out


# ---------------------------------------------------------------------------
# Mel-spectrogram computation (numpy-only, no torchaudio dependency)
# ---------------------------------------------------------------------------

def _mel_filterbank(n_fft: int, n_mels: int, sr: int = _SAMPLE_RATE,
                    fmin: float = 50.0, fmax: float = 2000.0) -> np.ndarray:
    """Create a mel-scale triangular filterbank matrix (n_mels, n_fft//2+1)."""
    def hz_to_mel(f):
        return 2595.0 * np.log10(1.0 + f / 700.0)

    def mel_to_hz(m):
        return 700.0 * (10.0 ** (m / 2595.0) - 1.0)

    mel_low = hz_to_mel(fmin)
    mel_high = hz_to_mel(fmax)
    mel_points = np.linspace(mel_low, mel_high, n_mels + 2)
    hz_points = mel_to_hz(mel_points)
    bin_points = np.floor((n_fft + 1) * hz_points / sr).astype(int)

    n_freqs = n_fft // 2 + 1
    fb = np.zeros((n_mels, n_freqs), dtype=np.float32)
    for m in range(n_mels):
        left = bin_points[m]
        center = bin_points[m + 1]
        right = bin_points[m + 2]
        for k in range(left, center):
            if center != left:
                fb[m, k] = (k - left) / (center - left)
        for k in range(center, right):
            if right != center:
                fb[m, k] = (right - k) / (right - center)
    return fb


def _stft(samples: np.ndarray, n_fft: int = 512, hop_length: int = 256) -> np.ndarray:
    """Compute magnitude STFT. Returns (n_freqs, n_frames)."""
    n = len(samples)
    window = np.hanning(n_fft).astype(np.float32)
    n_frames = 1 + (n - n_fft) // hop_length
    if n_frames < 1:
        n_frames = 1
        samples = np.pad(samples, (0, n_fft - len(samples)))
    frames = np.zeros((n_fft, n_frames), dtype=np.float32)
    for t in range(n_frames):
        start = t * hop_length
        frame = samples[start:start + n_fft]
        if len(frame) < n_fft:
            frame = np.pad(frame, (0, n_fft - len(frame)))
        frames[:, t] = frame * window
    fft_out = np.fft.rfft(frames, axis=0)
    return np.abs(fft_out).astype(np.float32)


def _log_mel_spectrogram(samples: np.ndarray, n_mels: int = 64,
                         n_fft: int = 512, hop_length: int = 256,
                         n_time: int = 128) -> np.ndarray:
    """Compute log-mel spectrogram. Returns (n_mels, n_time) float32."""
    mag = _stft(samples, n_fft, hop_length)
    fb = _mel_filterbank(n_fft, n_mels)
    mel = fb @ mag  # (n_mels, n_frames)
    mel = np.log10(mel + 1e-10).astype(np.float32)

    # Pad or truncate time axis to fixed length
    if mel.shape[1] < n_time:
        mel = np.pad(mel, ((0, 0), (0, n_time - mel.shape[1])))
    else:
        mel = mel[:, :n_time]

    # Normalize to [0, 1] per-spectrogram
    mn, mx = mel.min(), mel.max()
    if mx - mn > 1e-8:
        mel = (mel - mn) / (mx - mn)
    return mel


# ---------------------------------------------------------------------------
# Spectral features (shared by heuristic path)
# ---------------------------------------------------------------------------

def _spectral_features(samples: np.ndarray) -> dict:
    """Extract spectral features for heuristic classification."""
    n = len(samples)
    if n == 0:
        return {"energy": 0, "spectral_centroid": 0, "zero_crossings": 0,
                "band_energy_ratio": 0, "peak_freq": 0}

    energy = float(np.mean(samples ** 2))
    zcr = float(np.mean(np.abs(np.diff(np.sign(samples))) > 0))

    fft = np.abs(np.fft.rfft(samples))
    freqs = np.fft.rfftfreq(n, d=1.0 / _SAMPLE_RATE)
    total = fft.sum()
    centroid = float(np.sum(freqs * fft) / total) if total > 0 else 0

    low_mask = freqs < 500
    high_mask = freqs >= 500
    low_energy = float(fft[low_mask].sum())
    high_energy = float(fft[high_mask].sum())
    ber = low_energy / (low_energy + high_energy + 1e-10)

    peak_freq = float(freqs[np.argmax(fft)]) if len(fft) > 0 else 0

    return {
        "energy": energy,
        "spectral_centroid": centroid,
        "zero_crossings": zcr,
        "band_energy_ratio": ber,
        "peak_freq": peak_freq,
    }


# ---------------------------------------------------------------------------
# Heuristic classifier (fallback when no torch model)
# ---------------------------------------------------------------------------

def _heuristic_classify(samples: np.ndarray) -> tuple[str, float, dict]:
    """Spectral heuristic classification using research-based thresholds.

    Thresholds derived from respiratory sound characteristics:
    - Wheeze: continuous, musical, 100-1000 Hz, dominant >400 Hz
    - Crackle: discontinuous, explosive, broadband, high ZCR
    - Both: mixed features of wheeze + crackle
    - Normal: vesicular, 100-500 Hz, low ZCR, moderate energy
    """
    feat = _spectral_features(samples)
    scores = {label: 0.0 for label in _LABELS}

    sc = feat["spectral_centroid"]
    zcr = feat["zero_crossings"]
    ber = feat["band_energy_ratio"]
    energy = feat["energy"]
    pf = feat["peak_freq"]

    # Wheeze: high-frequency continuous sound, centroid > 400 Hz
    if sc > 400:
        scores["wheeze"] += 0.4
    if pf > 600:
        scores["wheeze"] += 0.3
    if sc > 300 and ber < 0.6:
        scores["wheeze"] += 0.2

    # Crackle: short explosive bursts, high ZCR, moderate centroid
    if zcr > 0.12:
        scores["crackle"] += 0.4
    if 200 < sc < 600:
        scores["crackle"] += 0.2
    if zcr > 0.08 and sc > 200:
        scores["crackle"] += 0.1

    # Both: has both wheeze and crackle characteristics
    if sc > 350 and zcr > 0.10:
        scores["both"] += 0.3
    if sc > 300 and zcr > 0.08 and ber < 0.7:
        scores["both"] += 0.2

    # Normal: moderate centroid, low ZCR, balanced energy
    if 100 < sc < 500 and 0.02 < zcr < 0.12:
        scores["normal"] += 0.5
    if 0.3 < ber < 0.8 and energy > 0.001:
        scores["normal"] += 0.3
    if sc < 300 and zcr < 0.08:
        scores["normal"] += 0.2

    # Diminished breath (very low energy) — map to normal with low confidence
    if energy < 0.001 and sc < 200:
        scores["normal"] += 0.3

    best = max(scores, key=scores.get)  # type: ignore
    total = sum(scores.values()) or 1
    confidence = scores[best] / total

    return best, confidence, feat


# ---------------------------------------------------------------------------
# Torch classifier with TTA
# ---------------------------------------------------------------------------

def _classify_panns(samples: np.ndarray) -> tuple[str, float, dict]:
    """Embed 4 s windows with frozen CNN14, average head probs across them.

    Mirrors the torch path's sliding-window TTA so a long recording is
    assessed over its whole length, not just its first window.
    """
    import torch

    window = int(float(_config.get("window_sec", 4.0)) * _SAMPLE_RATE)
    hop = int(float(_config.get("hop_sec", 2.0)) * _SAMPLE_RATE)
    panns_sr = int(_panns["sr"])

    windows: list[np.ndarray] = []
    if len(samples) <= window:
        windows.append(samples)
    else:
        start = 0
        while start + window <= len(samples):
            windows.append(samples[start:start + window])
            start += hop
        if start < len(samples) - window // 2:
            windows.append(samples[-window:])

    # CNN14 was trained at 32 kHz; resample each 16 kHz window up.
    resampled = [_resample_to(w, panns_sr) for w in windows]
    clip = torch.tensor(np.stack(resampled), dtype=torch.float32)
    with torch.no_grad():
        _, emb = _panns["tagger"].inference(clip)
        e = (torch.tensor(np.asarray(emb), dtype=torch.float32)
             - torch.tensor(_panns["mean"])) / torch.tensor(_panns["std"])
        logits = _panns["head"](e)
        probs = torch.softmax(logits / _temperature, dim=1)
    mean_probs = probs.mean(dim=0).numpy()

    idx = int(np.argmax(mean_probs))
    feat = _spectral_features(samples)
    return _LABELS[idx], float(mean_probs[idx]), feat


def _resample_to(samples: np.ndarray, dst_sr: int) -> np.ndarray:
    """Resample to CNN14's rate. scipy when available, linear interp else."""
    try:
        from scipy.signal import resample_poly
        from math import gcd
        g = gcd(_SAMPLE_RATE, dst_sr)
        return resample_poly(samples, dst_sr // g, _SAMPLE_RATE // g).astype(np.float32)
    except ImportError:
        ratio = dst_sr / _SAMPLE_RATE
        n_out = int(len(samples) * ratio)
        x_old = np.linspace(0, 1, len(samples), endpoint=False)
        x_new = np.linspace(0, 1, n_out, endpoint=False)
        return np.interp(x_new, x_old, samples).astype(np.float32)


def _classify_torch(samples: np.ndarray) -> tuple[str, float, dict]:
    """Classify using mel-spectrogram CNN with test-time augmentation."""
    import torch

    n_mels = int(_config.get("n_mels", 64))
    n_time = int(_config.get("n_time", 128))
    window_sec = float(_config.get("window_sec", 4.0))
    hop_sec = float(_config.get("hop_sec", 2.0))

    window_samples = int(window_sec * _SAMPLE_RATE)
    hop_samples = int(hop_sec * _SAMPLE_RATE)

    feat = _spectral_features(samples)

    # TTA: collect predictions from overlapping windows
    all_probs = []
    if len(samples) <= window_samples:
        # Short audio: single window
        spec = _log_mel_spectrogram(samples, n_mels=n_mels, n_time=n_time)
        probs = _infer_mel(spec)
        all_probs.append(probs)
    else:
        # Slide window across the recording
        start = 0
        while start + window_samples <= len(samples):
            chunk = samples[start:start + window_samples]
            spec = _log_mel_spectrogram(chunk, n_mels=n_mels, n_time=n_time)
            probs = _infer_mel(spec)
            all_probs.append(probs)
            start += hop_samples
        # Also include the tail if not already covered
        if start < len(samples) - window_samples // 2:
            chunk = samples[-window_samples:]
            spec = _log_mel_spectrogram(chunk, n_mels=n_mels, n_time=n_time)
            probs = _infer_mel(spec)
            all_probs.append(probs)

    # Average probabilities across all windows
    mean_probs = np.mean(all_probs, axis=0)

    # Apply temperature calibration
    if _temperature > 0 and abs(_temperature - 1.0) > 0.01:
        logits = np.log(mean_probs + 1e-10)
        calibrated = logits / _temperature
        exp_cal = np.exp(calibrated - calibrated.max())
        mean_probs = exp_cal / exp_cal.sum()

    idx = int(np.argmax(mean_probs))
    return _LABELS[idx], float(mean_probs[idx]), feat


def _infer_mel(spec: np.ndarray) -> np.ndarray:
    """Run a single mel-spectrogram through the CNN. Returns softmax probs."""
    import torch

    tensor = torch.from_numpy(spec).unsqueeze(0).unsqueeze(0)  # (1, 1, M, T)
    with torch.no_grad():
        logits = _model(tensor)  # type: ignore
        probs = torch.softmax(logits, dim=1)[0].cpu().numpy()
    return probs


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def classify(audio_bytes: bytes) -> tuple[str, float, dict]:
    """Classify lung sounds from WAV/PCM bytes.

    Returns (label, confidence, features_dict).
    """
    if not is_available():
        raise RuntimeError("lung sound classifier not available")

    samples = _wav_to_pcm16(audio_bytes)
    duration_s = len(samples) / _SAMPLE_RATE

    # Bandpass filter: 50-2000 Hz (lung sound frequency range)
    samples = _bandpass(samples, low=50.0, high=2000.0)

    # Remove DC offset
    samples = samples - np.mean(samples)

    # Measured on the filtered signal but *before* normalisation, the only point
    # where amplitude still means anything: one step further down every recording
    # has the same peak by construction.
    peak = float(np.abs(samples).max()) if len(samples) else 0.0
    rms = float(np.sqrt(np.mean(samples ** 2))) if len(samples) else 0.0
    level = {
        "duration_s": round(duration_s, 2),
        "signal_rms_counts": round(rms / _ADC_COUNT, 1),
        "signal_peak_counts": round(peak / _ADC_COUNT, 1),
    }

    # Under a second cannot hold a breath cycle. This used to return
    # ("normal", 0.3), so brushing the bell across the chest reported clear lungs
    # at a confidence the UI renders as a real reading.
    if duration_s < 1.0:
        raise LungSignalTooWeak(
            "Recording too short to assess — hold the stethoscope still for a "
            "few breaths."
        )

    min_rms = float(_config.get("min_rms", _MIN_RMS))
    if rms < min_rms:
        raise LungSignalTooWeak(
            "No lung sound detected — place the stethoscope firmly on the chest "
            "and hold still."
        )

    # Peak normalize
    if peak > 1e-8:
        samples = samples / peak

    label, confidence, feat = (
        _classify_panns(samples) if _backend == "panns"
        else _classify_torch(samples) if _backend == "torch"
        else _heuristic_classify(samples)
    )

    # Confidence gate ("min_confidence" in the backend config, 0 = off).
    # Patient-aware evaluation of every model trained for this kiosk showed
    # no confidence band where findings are right more often than not — a
    # confident-looking "crackle" at these confidences is wrong ~2 of 3
    # times. Rather than present a coin flip as a clinical finding, the
    # answer below the gate is "inconclusive": cdss ignores it (no risk
    # contribution) and the kiosk shows a neutral tile instead of a finding.
    gate = float(_config.get("min_confidence", 0.0))
    if gate > 0 and confidence < gate:
        return "inconclusive", confidence, {**feat, **level, "gated": True}
    return label, confidence, {**feat, **level}
