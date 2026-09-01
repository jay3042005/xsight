"""Signal gating for the ESP32 stethoscope path.

The kiosk sends whatever the bell picked up, including nothing at all — a user
pressing OK before placing it, or a module streaming a flat line. Every label the
classifier can return is a clinical finding, so "no signal" has to be its own
answer rather than the nearest one.
"""

from __future__ import annotations

import struct

import numpy as np
import pytest

from app import lung_classifier as lc


# The ESP32 samples a 12-bit ADC at 2 kHz and high-passes at ~20 Hz, so what
# reaches the WAV is an AC swing measured in ADC counts. Amplitudes here are in
# those counts, which is what the hardware can be read in.
_SR = 2000


def _esp32_wav(signal: np.ndarray, peak_counts: float) -> bytes:
    """Byte-for-byte the header `kiosk_lung_sound_screen._wav()` writes."""
    pcm = np.clip(signal * peak_counts, -32768, 32767).astype("<i2").tobytes()
    header = (
        b"RIFF"
        + struct.pack("<I", 36 + len(pcm))
        + b"WAVEfmt "
        + struct.pack("<IHHIIHH", 16, 1, 1, _SR, _SR * 2, 2, 16)
        + b"data"
        + struct.pack("<I", len(pcm))
    )
    return header + pcm


def _breath(seconds: float = 20.0) -> np.ndarray:
    """Band-limited noise, standing in for breath sounds. Peak-normalised."""
    rng = np.random.default_rng(0)
    n = int(_SR * seconds)
    sig = np.convolve(rng.normal(0, 1, n), np.ones(9) / 9, "same")
    return sig / max(abs(sig).max(), 1e-9)


@pytest.fixture(autouse=True)
def _loaded():
    lc.load()


def test_a_capture_off_the_chest_is_refused_not_labelled() -> None:
    # 8 counts is the bell held in air. Peak-normalisation would otherwise scale
    # it to full range and hand the model something that looks like a patient.
    with pytest.raises(lc.LungSignalTooWeak):
        lc.classify(_esp32_wav(_breath(), 8))


def test_a_flat_line_is_refused_rather_than_called_normal() -> None:
    # The case that made this necessary: silence used to classify, and it came
    # back "crackle" at 0.85 — higher confidence than any real recording.
    with pytest.raises(lc.LungSignalTooWeak):
        lc.classify(_esp32_wav(np.zeros(int(_SR * 20)), 0))


def test_too_short_to_hold_a_breath_is_refused() -> None:
    # Formerly returned ("normal", 0.3): brushing the bell across the chest
    # reported clear lungs at a confidence the UI renders as a real reading.
    with pytest.raises(lc.LungSignalTooWeak):
        lc.classify(_esp32_wav(_breath(0.4), 200))


def test_the_reported_working_amplitude_classifies() -> None:
    # A raw span of 1000-1400 counts on the ADC is roughly a +/-200 count swing
    # once the DC bias is high-passed away. That must never be gated out.
    label, confidence, features = lc.classify(_esp32_wav(_breath(), 200))

    # "inconclusive" is a legitimate assessed answer (the confidence gate),
    # distinct from rejection: what matters here is the capture was assessed
    # at all, and its level reported in the units the hardware is read in.
    assert label in [*lc._LABELS, "inconclusive"]
    assert 0.0 <= confidence <= 1.0
    assert features["signal_rms_counts"] > 10


def test_a_quiet_but_real_capture_still_classifies() -> None:
    # The gate belongs in the gap between the noise floor and a weak patient, not
    # near a working signal: at 30 counts peak this is already six times quieter
    # than the reported amplitude and must still be assessed.
    label, _, features = lc.classify(_esp32_wav(_breath(), 30))

    assert label in [*lc._LABELS, "inconclusive"]
    assert 2 < features["signal_rms_counts"] < 10


def test_duration_is_read_from_the_header_not_assumed() -> None:
    # The EMR used to derive this as `bytes / (16000 * 2)`, which is the 16 kHz the
    # classifier resamples *to* rather than the 2 kHz the ESP32 sends — filing
    # every auscultation at an eighth of its real length.
    _, _, features = lc.classify(_esp32_wav(_breath(20.0), 200))

    assert features["duration_s"] == pytest.approx(20.0, abs=0.05)


def test_the_threshold_is_configurable_for_calibration() -> None:
    original = lc._config.get("min_rms")
    try:
        # A site with a hotter preamp raises it; the response's rms figure is what
        # a real recording is calibrated against.
        lc._config["min_rms"] = 1.0
        with pytest.raises(lc.LungSignalTooWeak):
            lc.classify(_esp32_wav(_breath(), 200))
    finally:
        if original is None:
            lc._config.pop("min_rms", None)
        else:
            lc._config["min_rms"] = original


def test_low_confidence_answers_inconclusive_not_a_finding() -> None:
    # Every model trained for this kiosk is wrong more often than right at low
    # confidence, so below the gate the answer must be "inconclusive" — never
    # a finding the CDSS would then act on. Works on any backend: the gate
    # applies after classification, whatever produced the confidence.
    original = lc._config.get("min_confidence")
    try:
        lc._config["min_confidence"] = 1.1  # nothing can clear this
        label, confidence, features = lc.classify(_esp32_wav(_breath(), 200))
        assert label == "inconclusive"
        assert features.get("gated") is True
        assert 0.0 <= confidence < 1.1
    finally:
        if original is None:
            lc._config.pop("min_confidence", None)
        else:
            lc._config["min_confidence"] = original


def test_high_gate_off_returns_a_real_label() -> None:
    # Gate at zero (off) preserves the ungated behaviour, so a deployment can
    # always fall back to showing the raw classifier output.
    original = lc._config.get("min_confidence")
    try:
        lc._config["min_confidence"] = 0.0
        label, _, _ = lc.classify(_esp32_wav(_breath(), 200))
        assert label in lc._LABELS
    finally:
        if original is None:
            lc._config.pop("min_confidence", None)
        else:
            lc._config["min_confidence"] = original
