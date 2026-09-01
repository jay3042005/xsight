"""Phone → kiosk film & intake handoff (Local LAN + Cloud Relay).

Supports two modes:
1. **Local LAN Mode** (Default, no Vercel/cloud dependency):
   The server generates QR URLs pointing to `http://<LAN_IP>:8000/web/#/...`.
   Mobile phones on the same Wi-Fi upload films/intake directly to this server,
   and the server pushes the data to the kiosk app in real time via WebSockets.
2. **Cloud Relay Mode** (Optional, when `XSIGHT_RELAY_URL` and `XSIGHT_RELAY_KEY` are configured):
   Uses external Vercel store-and-forward relay.

Also provides the **Kiosk Event Hub** (`/ws/kiosk/events`), allowing patients on the
Web App to remotely start and stop sessions on the local Kiosk and see live station updates.
"""

from __future__ import annotations

import asyncio
import base64
import logging
import os
import secrets
import socket
import time
from dataclasses import dataclass, field
from typing import Any, Literal, Optional

import httpx
from fastapi import (
    APIRouter,
    Body,
    File,
    HTTPException,
    Request,
    UploadFile,
    WebSocket,
    WebSocketDisconnect,
)
from fastapi.responses import Response
from starlette.websockets import WebSocketState

from app.qr_svg import qr_svg

log = logging.getLogger("xsight.handoff")

router = APIRouter(tags=["Handoff"])

RELAY_URL = os.getenv("XSIGHT_RELAY_URL", "").rstrip("/")
RELAY_KEY = os.getenv("XSIGHT_RELAY_KEY", "")

SESSION_TTL_S = int(os.getenv("XSIGHT_HANDOFF_TTL_S", "600"))
POLL_INTERVAL_S = float(os.getenv("XSIGHT_HANDOFF_POLL_S", "1.5"))
MAX_FILM_BYTES = int(os.getenv("XSIGHT_HANDOFF_MAX_BYTES", "10485760"))

Kind = Literal["xray", "report", "intake"]


def get_local_lan_ip() -> str:
    """Find the best local network IP address."""
    override = os.getenv("XSIGHT_LAN_IP", "").strip()
    if override:
        return override
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "127.0.0.1"


# Hosts that resolve to "this device" and are therefore useless in a QR code:
# the phone scanning it would dial its own loopback. 10.0.2.2 / 10.0.3.2 are the
# Android emulator and Genymotion aliases for the developer's host machine.
_UNREACHABLE_HOSTS = frozenset({
    "localhost",
    "127.0.0.1",
    "0.0.0.0",
    "::1",
    "[::1]",
    "10.0.2.2",
    "10.0.3.2",
})


def _split_host_port(host_header: str) -> tuple[str, Optional[str]]:
    """Split a Host header into (host, port), tolerating IPv6 brackets."""
    if host_header.startswith("["):  # [::1]:8000
        closing = host_header.find("]")
        if closing != -1:
            host = host_header[: closing + 1]
            rest = host_header[closing + 1 :]
            return host, rest[1:] if rest.startswith(":") else None
    if ":" in host_header:
        host, _, port = host_header.rpartition(":")
        return host, port or None
    return host_header, None


def get_server_base_url(req: Optional[Request] = None) -> str:
    """Build a base URL a *phone on the same Wi-Fi* can actually reach.

    Every caller of this feeds a QR code or a link handed to a separate device,
    so the request's own Host header can only be trusted when it is already a
    routable LAN address. The kiosk app reaches this server as `localhost:8000`
    on desktop and `10.0.2.2:8000` on the Android emulator — echoing either into
    a QR produces a code that scans fine and then fails to load, which is
    indistinguishable from a broken handoff. Fall back to the interface address
    in those cases, keeping the port the client actually connected on.
    """
    scheme = "http"
    port: Optional[str] = None

    if req and req.headers.get("host"):
        host, port = _split_host_port(req.headers["host"].strip())
        scheme = req.url.scheme or "http"
        if host.lower() not in _UNREACHABLE_HOSTS:
            return f"{scheme}://{req.headers['host'].strip()}"

    ip = get_local_lan_ip()
    port = port or os.getenv("PORT", "8000")
    return f"{scheme}://{ip}:{port}"


@dataclass
class HandoffSession:
    sid: str
    kind: Kind
    created_at: float = field(default_factory=time.monotonic)
    delivered: bool = False
    film_bytes: Optional[bytes] = None
    intake_data: Optional[dict[str, Any]] = None
    report_pdf: Optional[bytes] = None
    notify_event: asyncio.Event = field(default_factory=asyncio.Event)

    @property
    def expired(self) -> bool:
        return (time.monotonic() - self.created_at) > SESSION_TTL_S


_sessions: dict[str, HandoffSession] = {}

# Active Kiosk WebSockets for remote session linking
_kiosk_websockets: set[WebSocket] = set()
_kiosk_state: dict[str, Any] = {
    "active": False,
    "station": "idle",
    "patient_name": None,
    "last_updated": time.time(),
    # Bumped whenever the kiosk asks the web portal to show its X-ray upload
    # prompt. The portal polls rather than holding a socket, so a counter is
    # what lets it distinguish a fresh request from the station simply still
    # being open — re-sending `station_change` could not.
    "xray_prompt_seq": 0,
    # Live capture session at the X-ray station, so the web portal can post a
    # film into it and have the kiosk analyse and display the result.
    "xray_sid": None,
}


def relay_configured() -> bool:
    return bool(RELAY_URL and RELAY_KEY)


def _new_sid() -> str:
    return secrets.token_urlsafe(24)


def _prune() -> None:
    for sid in [s for s, sess in _sessions.items() if sess.expired]:
        _sessions.pop(sid, None)


def _relay_headers() -> dict[str, str]:
    return {"x-xsight-key": RELAY_KEY}


async def _relay_register(sid: str, kind: Kind) -> None:
    async with httpx.AsyncClient(timeout=10) as client:
        r = await client.post(
            f"{RELAY_URL}/api/session",
            json={"sid": sid, "kind": kind, "ttl": SESSION_TTL_S},
            headers=_relay_headers(),
        )
        if r.status_code >= 400:
            raise HTTPException(
                status_code=502,
                detail=f"relay rejected session: {r.status_code} {r.text[:200]}",
            )


async def _relay_fetch_film(sid: str) -> bytes | None:
    async with httpx.AsyncClient(timeout=30) as client:
        r = await client.get(
            f"{RELAY_URL}/api/session/{sid}/film", headers=_relay_headers()
        )
        if r.status_code == 404:
            return None
        if r.status_code >= 400:
            log.warning("[handoff] relay poll %s -> %s", sid[:8], r.status_code)
            return None
        data = r.content
        if not data:
            return None
        if len(data) > MAX_FILM_BYTES:
            raise HTTPException(status_code=413, detail="film exceeds size limit")
        return data


async def _relay_fetch_intake(sid: str) -> dict[str, Any] | None:
    async with httpx.AsyncClient(timeout=30) as client:
        r = await client.get(
            f"{RELAY_URL}/api/session/{sid}/intake", headers=_relay_headers()
        )
        if r.status_code == 404:
            return None
        if r.status_code >= 400:
            log.warning("[handoff] intake poll %s -> %s", sid[:8], r.status_code)
            return None
        try:
            data = r.json()
        except ValueError:
            log.warning("[handoff] intake poll %s returned non-JSON", sid[:8])
            return None
        return data if isinstance(data, dict) else None


async def _relay_delete(sid: str) -> None:
    if not relay_configured():
        return
    try:
        async with httpx.AsyncClient(timeout=10) as client:
            await client.delete(
                f"{RELAY_URL}/api/session/{sid}", headers=_relay_headers()
            )
    except Exception as e:
        log.warning("[handoff] relay delete failed for %s: %s", sid[:8], e)


async def _relay_put_report(sid: str, pdf: bytes) -> None:
    async with httpx.AsyncClient(timeout=30) as client:
        r = await client.put(
            f"{RELAY_URL}/api/session/{sid}/report",
            content=pdf,
            headers={**_relay_headers(), "content-type": "application/pdf"},
        )
        if r.status_code >= 400:
            raise HTTPException(
                status_code=502,
                detail=f"relay rejected report: {r.status_code} {r.text[:200]}",
            )


# ---------------------------------------------------------------------------
# Status & Creation Routes
# ---------------------------------------------------------------------------

def _newest_open_xray_sid() -> Optional[str]:
    """Newest live X-ray capture session that has not been filled yet.

    A fallback for `kiosk_state["xray_sid"]`. The kiosk announces its session over
    the event hub, but *this server minted it* and already knows about it, so
    making the portal's upload route depend on that one announcement surviving was
    a needless single point of failure — a socket blip, or an older kiosk build
    that does not announce at all, and the film silently went to the record
    instead of to the station.
    """
    best: Optional[tuple[str, HandoffSession]] = None
    for sid, session in _sessions.items():
        if session.kind != "xray" or session.expired or session.film_bytes is not None:
            continue
        if best is None or session.created_at > best[1].created_at:
            best = (sid, session)
    return best[0] if best else None


def _kiosk_state_view() -> dict[str, Any]:
    """`_kiosk_state` with `xray_sid` resolved, without mutating the shared dict.

    Kept a copy so an inferred session never gets mistaken for an announced one.
    """
    view = dict(_kiosk_state)
    if not view.get("xray_sid"):
        view["xray_sid"] = _newest_open_xray_sid()
    return view


@router.get("/handoff/status")
async def handoff_status(req: Request) -> dict[str, Any]:
    _prune()
    lan_ip = get_local_lan_ip()
    base_url = get_server_base_url(req)
    mode = "relay" if relay_configured() else "local"
    return {
        "available": True,
        "mode": mode,
        "lan_ip": lan_ip,
        "base_url": base_url,
        "relay": RELAY_URL or None,
        "ttl_s": SESSION_TTL_S,
        "active_sessions": len(_sessions),
        "kiosks_online": len(_kiosk_websockets),
        "kiosk_state": _kiosk_state_view(),
        "reason": None,
    }


@router.get("/handoff/qr.svg")
async def handoff_qr_svg(data: str) -> Response:
    """Render [data] as a QR code, locally.

    The web portal used to source its QR from `api.qrserver.com`, which both
    failed closed on an offline clinic LAN and handed every capture URL — session
    token included — to a third party. [data] is only ever emitted as path
    coordinates, never as markup or text, so there is nothing to escape.
    """
    if not data or len(data) > 512:
        raise HTTPException(status_code=400, detail="data must be 1-512 characters")
    try:
        svg = qr_svg(data)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return Response(
        content=svg,
        media_type="image/svg+xml",
        # A given URL always encodes to the same image, and capture sessions are
        # short-lived anyway.
        headers={"Cache-Control": "public, max-age=600"},
    )


@router.post("/handoff/xray")
async def create_xray_handoff(req: Request) -> dict[str, Any]:
    _prune()
    sid = _new_sid()
    session = HandoffSession(sid=sid, kind="xray")
    _sessions[sid] = session

    if relay_configured():
        await _relay_register(sid, "xray")
        capture_url = f"{RELAY_URL}/s/{sid}"
    else:
        base_url = get_server_base_url(req)
        capture_url = f"{base_url}/web/#/xray-upload?sid={sid}"

    log.info("[handoff] xray session %s… created (url: %s)", sid[:8], capture_url)
    return {
        "sid": sid,
        "capture_url": capture_url,
        "expires_in": SESSION_TTL_S,
        "local": not relay_configured(),
    }


@router.post("/handoff/intake")
async def create_intake_handoff(req: Request) -> dict[str, Any]:
    _prune()
    sid = _new_sid()
    session = HandoffSession(sid=sid, kind="intake")
    _sessions[sid] = session

    if relay_configured():
        await _relay_register(sid, "intake")
        form_url = f"{RELAY_URL}/i/{sid}"
    else:
        base_url = get_server_base_url(req)
        form_url = f"{base_url}/web/#/intake?sid={sid}"

    log.info("[handoff] intake session %s… created (url: %s)", sid[:8], form_url)
    return {
        "sid": sid,
        "form_url": form_url,
        "expires_in": SESSION_TTL_S,
        "local": not relay_configured(),
    }


@router.post("/handoff/report/{consultation_id}")
async def create_report_handoff(consultation_id: int, req: Request) -> dict[str, Any]:
    from app.report_routes import build_report_pdf

    try:
        pdf = build_report_pdf(consultation_id)
    except FileNotFoundError:
        raise HTTPException(status_code=404, detail="Consultation not found")

    _prune()
    sid = _new_sid()
    session = HandoffSession(sid=sid, kind="report", report_pdf=pdf)
    _sessions[sid] = session

    if relay_configured():
        await _relay_register(sid, "report")
        await _relay_put_report(sid, pdf)
        download_url = f"{RELAY_URL}/s/{sid}"
    else:
        base_url = get_server_base_url(req)
        download_url = f"{base_url}/reports/{consultation_id}.pdf"

    log.info("[handoff] report session %s… created (%d bytes)", sid[:8], len(pdf))
    return {
        "sid": sid,
        "download_url": download_url,
        "expires_in": SESSION_TTL_S,
        "local": not relay_configured(),
    }


# ---------------------------------------------------------------------------
# Local Upload Endpoints for Mobile Phones
# ---------------------------------------------------------------------------

@router.post("/handoff/session/{sid}/film")
async def local_upload_film(sid: str, file: UploadFile = File(...)) -> dict[str, Any]:
    session = _sessions.get(sid)
    if not session or session.expired:
        raise HTTPException(status_code=404, detail="Session expired or not found")
    data = await file.read()
    if not data:
        raise HTTPException(status_code=400, detail="Empty file")
    if len(data) > MAX_FILM_BYTES:
        raise HTTPException(status_code=413, detail="File too large")

    session.film_bytes = data
    session.notify_event.set()
    log.info("[handoff] local film uploaded for session %s (%d bytes)", sid[:8], len(data))
    return {"status": "ok", "bytes": len(data)}


@router.post("/handoff/session/{sid}/intake")
async def local_upload_intake(sid: str, payload: dict[str, Any] = Body(...)) -> dict[str, Any]:
    session = _sessions.get(sid)
    if not session or session.expired:
        raise HTTPException(status_code=404, detail="Session expired or not found")

    session.intake_data = payload
    session.notify_event.set()
    log.info("[handoff] local intake uploaded for session %s", sid[:8])
    return {"status": "ok"}


@router.get("/handoff/session/{sid}/report")
async def local_get_report(sid: str) -> Response:
    session = _sessions.get(sid)
    if not session or session.expired or not session.report_pdf:
        raise HTTPException(status_code=404, detail="Report expired or not found")
    return Response(content=session.report_pdf, media_type="application/pdf")


# ---------------------------------------------------------------------------
# WebSocket Handoff for Kiosk Tablet
# ---------------------------------------------------------------------------

def _local_payload(session: HandoffSession) -> Any:
    """Whatever has been delivered straight to this server, or None.

    The counterpart to the relay fetch: `/handoff/session/{sid}/film` and
    `/handoff/session/{sid}/intake` write here.
    """
    if session.kind == "intake":
        return session.intake_data
    return session.film_bytes


@router.websocket("/ws/handoff/{sid}")
async def ws_handoff(ws: WebSocket, sid: str) -> None:
    await ws.accept()
    session = _sessions.get(sid)
    if session is None:
        await ws.send_json({"event": "error", "detail": "unknown session"})
        await ws.close()
        return

    async def send(event: str, **fields: Any) -> None:
        try:
            await ws.send_json({"event": event, **fields})
        except Exception:
            pass

    remaining = max(0, SESSION_TTL_S - int(time.monotonic() - session.created_at))
    await send("waiting", expires_in=remaining)
    log.info("[handoff] app waiting on %s…", sid[:8])

    try:
        while True:
            # A closed socket is only surfaced as WebSocketDisconnect on *receive*,
            # and this loop never receives — so a kiosk that walked away left the
            # relay being polled for the session's full ten-minute TTL. Visible in
            # the logs as 404s continuing long after "connection closed".
            if ws.client_state != WebSocketState.CONNECTED:
                log.info("[handoff] app left %s… — stopping poll", sid[:8])
                await _relay_delete(sid)
                _sessions.pop(sid, None)
                return

            if session.expired:
                await send("expired")
                break

            # A payload can arrive by *either* door, in either mode:
            #
            #   * the relay, for a phone that scanned the QR over mobile data;
            #   * a direct POST to /handoff/session/{sid}/film, which is what the
            #     web portal's upload prompt and a phone on the LAN both use.
            #
            # This used to poll only the relay whenever one was configured, so a
            # locally delivered film was accepted with a 200, stored, and then
            # ignored forever while the kiosk sat on 404s from the relay. Check
            # the local payload first — it is already in memory — then the relay.
            payload = _local_payload(session)

            if payload is None and relay_configured():
                try:
                    if session.kind == "intake":
                        payload = await _relay_fetch_intake(sid)
                    else:
                        payload = await _relay_fetch_film(sid)
                except Exception as e:
                    log.warning("[handoff] poll error on %s: %s", sid[:8], e)
                    payload = None

            if payload is None:
                # Sleeping on the event rather than a bare timer means a direct
                # POST wakes this immediately instead of on the next poll tick,
                # and it paces the relay polling at the same time.
                try:
                    await asyncio.wait_for(
                        session.notify_event.wait(), timeout=POLL_INTERVAL_S
                    )
                    payload = _local_payload(session)
                except asyncio.TimeoutError:
                    payload = None

            if payload is not None and not session.delivered:
                session.delivered = True
                _sessions.pop(sid, None)
                teardown = asyncio.ensure_future(_relay_delete(sid))

                if session.kind == "intake":
                    await send("intake", details=payload)
                else:
                    await send(
                        "film",
                        image_b64=base64.b64encode(payload).decode("ascii"),
                        bytes=len(payload),
                    )
                try:
                    await asyncio.shield(teardown)
                except asyncio.CancelledError:
                    raise
                break
    except WebSocketDisconnect:
        log.info("[handoff] app left %s… before %s arrived", sid[:8], session.kind)
        await _relay_delete(sid)
        _sessions.pop(sid, None)
        return

    try:
        await ws.close()
    except Exception:
        pass


# ---------------------------------------------------------------------------
# Kiosk Real-Time Event Hub (Remote Web Session Triggering & Stop Session)
# ---------------------------------------------------------------------------

@router.websocket("/ws/kiosk/events")
async def ws_kiosk_events(ws: WebSocket) -> None:
    """WebSocket held by the Kiosk app to listen for incoming web sessions & report state."""
    await ws.accept()
    _kiosk_websockets.add(ws)
    log.info("[kiosk_hub] Kiosk connected to event hub. Total online: %d", len(_kiosk_websockets))
    try:
        await ws.send_json({"event": "connected", "kiosks_online": len(_kiosk_websockets)})
        while True:
            data = await ws.receive_json()
            event_type = data.get("event")
            if event_type == "ping":
                await ws.send_json({"event": "pong"})
            elif event_type == "station_change":
                _kiosk_state["station"] = data.get("station", "unknown")
                _kiosk_state["active"] = True
                if _kiosk_state["station"] != "xray":
                    _kiosk_state["xray_sid"] = None
                _kiosk_state["last_updated"] = time.time()
                log.info("[kiosk_hub] Kiosk changed station: %s", _kiosk_state["station"])
            elif event_type == "kiosk_session_active":
                _kiosk_state["active"] = True
                _kiosk_state["patient_name"] = data.get("patient_name")
                _kiosk_state["last_updated"] = time.time()
            elif event_type == "xray_session":
                _kiosk_state["xray_sid"] = data.get("sid") or None
                _kiosk_state["last_updated"] = time.time()
                log.info(
                    "[kiosk_hub] X-ray capture session %s",
                    (_kiosk_state["xray_sid"] or "cleared")[:8],
                )
            elif event_type == "request_xray_upload":
                _kiosk_state["station"] = "xray"
                _kiosk_state["active"] = True
                _kiosk_state["xray_prompt_seq"] = _kiosk_state.get("xray_prompt_seq", 0) + 1
                _kiosk_state["last_updated"] = time.time()
                log.info(
                    "[kiosk_hub] Kiosk requested web X-ray upload prompt (seq %d)",
                    _kiosk_state["xray_prompt_seq"],
                )
            elif event_type == "kiosk_session_idle":
                _kiosk_state["active"] = False
                _kiosk_state["station"] = "idle"
                _kiosk_state["patient_name"] = None
                _kiosk_state["xray_sid"] = None
                _kiosk_state["last_updated"] = time.time()
    except WebSocketDisconnect:
        _kiosk_websockets.discard(ws)
        if not _kiosk_websockets:
            _kiosk_state["xray_sid"] = None
        log.info("[kiosk_hub] Kiosk disconnected from event hub. Total online: %d", len(_kiosk_websockets))
    except Exception as e:
        _kiosk_websockets.discard(ws)
        log.warning("[kiosk_hub] WebSocket error: %s", e)


async def broadcast_to_kiosks(message: dict[str, Any]) -> int:
    """Broadcast a message to all connected Kiosks."""
    sent = 0
    dead = set()
    for ws in _kiosk_websockets:
        try:
            await ws.send_json(message)
            sent += 1
        except Exception:
            dead.add(ws)
    for ws in dead:
        _kiosk_websockets.discard(ws)
    return sent


@router.get("/api/web/kiosk/status")
async def get_kiosk_status() -> dict[str, Any]:
    """Check live status of the Kiosk station."""
    return {
        "online": len(_kiosk_websockets) > 0,
        "kiosks_online": len(_kiosk_websockets),
        "state": _kiosk_state_view(),
    }


@router.post("/api/web/kiosk/trigger-session")
async def trigger_kiosk_session(payload: dict[str, Any] = Body(...)) -> dict[str, Any]:
    """Patient on Web clicks 'Start Session on Kiosk'. Broadcasts to Kiosk."""
    patient = payload.get("patient") or payload
    msg = {
        "event": "remote_session_request",
        "patient": patient,
        "timestamp": time.time(),
    }
    _kiosk_state["active"] = True
    _kiosk_state["patient_name"] = patient.get("name")
    _kiosk_state["last_updated"] = time.time()

    count = await broadcast_to_kiosks(msg)
    log.info("[kiosk_hub] Remote session triggered for %s. Sent to %d kiosk(s)", patient.get("name", "Unknown"), count)
    return {
        "status": "ok",
        "broadcasted": count > 0,
        "kiosks_online": len(_kiosk_websockets),
        "message": "Session dispatched to kiosk tablet" if count > 0 else "Kiosk currently offline. It will receive when connected.",
    }


@router.post("/api/web/kiosk/stop-session")
async def stop_kiosk_session() -> dict[str, Any]:
    """Reset / Stop active Kiosk session from web or kiosk and return to guest screen."""
    _kiosk_state["active"] = False
    _kiosk_state["station"] = "idle"
    _kiosk_state["patient_name"] = None
    _kiosk_state["last_updated"] = time.time()

    msg = {"event": "session_stopped", "timestamp": time.time()}
    count = await broadcast_to_kiosks(msg)
    log.info("[kiosk_hub] Stop session broadcasted to %d kiosk(s)", count)
    return {"status": "ok", "kiosks_notified": count, "message": "Kiosk session terminated and reset to Guest Mode."}
