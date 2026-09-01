"""Tests for server/ml/xray/__init__.py — focused on logic that doesn't
require actual model weights (temperature calibration loading, softmax).
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from ml.xray import _load_temperature, _softmax, _METRICS_PATH  # noqa: E402
import numpy as np


def test_load_temperature_defaults_to_one_when_metrics_missing(monkeypatch):
    monkeypatch.setattr("ml.xray._METRICS_PATH", Path("/nonexistent/metrics.json"))
    assert _load_temperature() == 1.0


def test_load_temperature_reads_value_from_metrics_json(tmp_path, monkeypatch):
    metrics_file = tmp_path / "metrics.json"
    metrics_file.write_text(json.dumps({"temperature": 1.8}))
    monkeypatch.setattr("ml.xray._METRICS_PATH", metrics_file)

    assert _load_temperature() == 1.8


def test_load_temperature_ignores_invalid_value(tmp_path, monkeypatch):
    metrics_file = tmp_path / "metrics.json"
    metrics_file.write_text(json.dumps({"temperature": -3}))
    monkeypatch.setattr("ml.xray._METRICS_PATH", metrics_file)

    assert _load_temperature() == 1.0


def test_load_temperature_handles_malformed_json(tmp_path, monkeypatch):
    metrics_file = tmp_path / "metrics.json"
    metrics_file.write_text("not json")
    monkeypatch.setattr("ml.xray._METRICS_PATH", metrics_file)

    assert _load_temperature() == 1.0


def test_softmax_higher_temperature_flattens_distribution():
    logits = np.array([5.0, 1.0, 0.0])
    sharp = _softmax(logits)
    soft = _softmax(logits / 3.0)

    # Same argmax, but the top probability should shrink under a higher
    # temperature (this is exactly the de-overconfidence effect we want).
    assert int(np.argmax(sharp)) == int(np.argmax(soft))
    assert soft[0] < sharp[0]
