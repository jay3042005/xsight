"""Round-trip the local QR encoder through an independent decoder.

`zbarimg` is the arbiter here rather than a golden matrix: a QR is correct if a
scanner reads it back, and two encoders can produce different-but-equally-valid
matrices (they pick their own mask and encoding mode). Skips when zbarimg is not
installed, so the suite still runs on a bare machine.
"""

from __future__ import annotations

import shutil
import subprocess
import tempfile
from pathlib import Path

import pytest

from app.qr_svg import _EC_M, qr_matrix, qr_svg

pytest.importorskip("PIL", reason="Pillow renders the matrix for zbarimg")
from PIL import Image  # noqa: E402

zbar_missing = shutil.which("zbarimg") is None
requires_zbar = pytest.mark.skipif(zbar_missing, reason="zbarimg not installed")

CAPTURE_URL = (
    "http://192.168.1.11:8000/web/#/xray-upload?sid=9dAjvxyCUx4xOYKod6kzhuVfXyICRu42"
)


def _decode(modules: list[list[bool]], scale: int = 8, quiet: int = 4) -> str:
    n = len(modules)
    span = n + quiet * 2
    img = Image.new("1", (span * scale, span * scale), 1)
    px = img.load()
    for r in range(n):
        for c in range(n):
            if not modules[r][c]:
                continue
            for y in range((r + quiet) * scale, (r + quiet + 1) * scale):
                for x in range((c + quiet) * scale, (c + quiet + 1) * scale):
                    px[x, y] = 0
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "qr.png"
        img.save(path)
        out = subprocess.run(
            ["zbarimg", "-q", "--raw", str(path)], capture_output=True, text=True
        )
    return out.stdout.rstrip("\n")


def _byte_capacity(version: int) -> int:
    ec_per_block, groups = _EC_M[version - 1]
    header = 2 if version < 10 else 3
    return sum(count * size for count, size in groups) - header


@requires_zbar
def test_capture_url_round_trips() -> None:
    """The payload this actually exists to encode."""
    assert _decode(qr_matrix(CAPTURE_URL)) == CAPTURE_URL


@requires_zbar
@pytest.mark.parametrize("version", range(1, len(_EC_M) + 1))
def test_every_version_round_trips_at_full_capacity(version: int) -> None:
    """Exercises each version at its exact byte capacity, and one byte under.

    Full capacity is where the pad-byte and block-interleaving logic is most
    exposed; versions 8+ have unequal block sizes and 10+ switch to a 16-bit
    character-count field.
    """
    capacity = _byte_capacity(version)
    for length in (capacity, capacity - 1):
        text = "".join(chr(65 + (i * 7) % 58) for i in range(length))
        assert _decode(qr_matrix(text)) == text, f"v{version} at {length} bytes"


@requires_zbar
@pytest.mark.parametrize("text", ["1", "HELLO", "café ünïcode 日本 ✓"])
def test_short_and_multibyte_payloads_round_trip(text: str) -> None:
    assert _decode(qr_matrix(text)) == text


def test_version_is_the_smallest_that_fits() -> None:
    """A capture URL must not silently inflate to a denser, harder-to-scan code."""
    assert len(qr_matrix("x" * _byte_capacity(1))) == 21          # version 1
    assert len(qr_matrix("x" * (_byte_capacity(1) + 1))) == 25    # version 2


def test_oversized_payload_is_refused_not_truncated() -> None:
    with pytest.raises(ValueError):
        qr_matrix("x" * (_byte_capacity(len(_EC_M)) + 1))


def test_svg_is_self_contained_and_has_no_external_reference() -> None:
    svg = qr_svg(CAPTURE_URL)
    assert svg.startswith("<svg") and svg.endswith("</svg>")
    for forbidden in ("http://", "https://", "<script", "<image", "<text"):
        if forbidden in ("http://", "https://"):
            # The xmlns is the only permitted URL, and it is not a fetch.
            assert svg.count(forbidden) == (1 if forbidden == "http://" else 0)
        else:
            assert forbidden not in svg


def test_payload_never_reaches_the_svg_as_text() -> None:
    """The encoded string must appear only as geometry, never as markup."""
    svg = qr_svg("SENTINEL-PAYLOAD-9Z")
    assert "SENTINEL" not in svg
