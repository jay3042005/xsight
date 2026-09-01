"""Relay mode must not blind the kiosk to a locally delivered film.

A film can arrive two ways: through the cloud relay (a phone that scanned the QR
over mobile data) or by a direct POST to `/handoff/session/{sid}/film` (the web
portal's upload prompt, or a phone on the LAN). Whenever a relay was configured
the capture socket polled *only* the relay, so a local upload was accepted with a
200, stored, and then ignored while the kiosk sat on relay 404s until the session
expired.
"""

from __future__ import annotations

import io
import time

import pytest
from fastapi.testclient import TestClient

from app import handoff
from app.main import app

FILM = b"\xff\xd8\xff\xe0" + b"\x00" * 4096


@pytest.fixture
def relay_mode(monkeypatch: pytest.MonkeyPatch) -> dict[str, int]:
    """Configure a relay that registers fine and never has the film.

    Mirrors the real situation: the QR was minted against the relay but nobody
    used it, and the film came in locally instead.
    """
    polls = {"count": 0}

    async def register(sid: str, kind: str) -> None:
        return None

    async def fetch_film(sid: str):
        polls["count"] += 1
        return None

    async def fetch_intake(sid: str):
        return None

    async def delete(sid: str) -> None:
        return None

    monkeypatch.setattr(handoff, "RELAY_URL", "https://relay.example")
    monkeypatch.setattr(handoff, "RELAY_KEY", "test-key")
    monkeypatch.setattr(handoff, "_relay_register", register)
    monkeypatch.setattr(handoff, "_relay_fetch_film", fetch_film)
    monkeypatch.setattr(handoff, "_relay_fetch_intake", fetch_intake)
    monkeypatch.setattr(handoff, "_relay_delete", delete)
    assert handoff.relay_configured()
    return polls


def test_local_film_reaches_the_kiosk_in_relay_mode(relay_mode: dict[str, int]) -> None:
    client = TestClient(app)
    sid = client.post("/handoff/xray").json()["sid"]

    with client.websocket_connect(f"/ws/handoff/{sid}") as capture:
        assert capture.receive_json()["event"] == "waiting"

        posted = client.post(
            f"/handoff/session/{sid}/film",
            files={"file": ("film.jpg", io.BytesIO(FILM), "image/jpeg")},
        )
        assert posted.status_code == 200

        delivered = capture.receive_json()
        assert delivered["event"] == "film", "kiosk never saw the local upload"
        assert delivered["bytes"] == len(FILM)


def test_capture_socket_stops_polling_the_relay_once_the_kiosk_leaves(
    relay_mode: dict[str, int],
) -> None:
    """A closed socket surfaces as WebSocketDisconnect only on *receive*, and this
    loop never receives — so a kiosk that walked away used to leave the relay
    being polled for the session's full TTL.
    """
    client = TestClient(app)
    sid = client.post("/handoff/xray").json()["sid"]

    with client.websocket_connect(f"/ws/handoff/{sid}") as capture:
        assert capture.receive_json()["event"] == "waiting"

    relay_mode["count"] = 0
    time.sleep(handoff.POLL_INTERVAL_S * 2 + 0.5)
    assert relay_mode["count"] <= 1, (
        f"still polling the relay after disconnect ({relay_mode['count']} times)"
    )


def test_local_intake_also_reaches_the_kiosk_in_relay_mode(
    relay_mode: dict[str, int],
) -> None:
    """Same door, same bug — the intake payload had the identical blind spot."""
    client = TestClient(app)
    sid = client.post("/handoff/intake").json()["sid"]

    with client.websocket_connect(f"/ws/handoff/{sid}") as capture:
        assert capture.receive_json()["event"] == "waiting"

        posted = client.post(
            f"/handoff/session/{sid}/intake",
            json={"name": "Arjay", "age": "34"},
        )
        assert posted.status_code == 200

        delivered = capture.receive_json()
        assert delivered["event"] == "intake"
        assert delivered["details"]["name"] == "Arjay"
