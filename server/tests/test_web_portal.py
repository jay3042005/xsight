from __future__ import annotations

import io
import os
import pytest
from fastapi.testclient import TestClient

os.environ.setdefault("CHAT_PROVIDER", "local")
os.environ.setdefault("VISION_PROVIDER", "mock")

from app import emr_db
from app.main import app

client = TestClient(app)


def test_serve_web_dashboard_html() -> None:
    """The portal renders with its three views wired.

    Asserts structural landmarks rather than headline copy, which is free to be
    reworded without breaking the suite.
    """
    res = client.get("/web")
    assert res.status_code == 200
    assert "XSIGHT" in res.text
    for node in ('id="authView"', 'id="sessionView"', 'id="recordsView"',
                 'id="xrayModal"', 'id="captureView"'):
        assert node in res.text, f"portal is missing {node}"


def test_portal_shares_the_kiosk_design_tokens() -> None:
    """The portal, the kiosk app and the phone pages are one visual system.

    Pins the brand palette from lib/core/theme/xs_colors.dart, and the absence of
    a webfont CDN — the portal has to render correctly on a clinic LAN with no
    route to the internet.
    """
    html = client.get("/web").text
    for token in ("#1B6B6F", "#6C9A8B", "#2F3E46", "#DCEDEA"):
        assert token in html, f"brand colour {token} missing from the portal"
    assert "fonts.googleapis" not in html
    assert "prefers-color-scheme: dark" in html


def test_portal_never_ships_placeholder_vitals() -> None:
    """No measurement may have a plausible default.

    The portal used to render `data.vitals.hr || 74` and ship 74/98.5/36.6/16 as
    static text, so an empty record displayed a complete, invented set of
    observations. Every tile must start as an em dash instead.
    """
    html = client.get("/web").text
    for fabricated in ("|| 74", "|| 98.5", "|| 36.6", "|| 0.94",
                       "Normothermic", "Eupneic", "No focal consolidation"):
        assert fabricated not in html, f"portal still fabricates: {fabricated}"
    assert "realNum" in html, "the positive-finite reading guard is gone"


def test_xray_qr_is_reachable_from_another_device() -> None:
    """A capture URL is scanned by a *different* device, so it can never encode a
    host that means "this machine".

    The kiosk app reaches the backend as localhost on desktop and 10.0.2.2 on the
    Android emulator; echoing either into the QR produced a code that scanned
    cleanly and then failed to load.
    """
    for unreachable in ("localhost:8000", "127.0.0.1:8000", "10.0.2.2:8000"):
        res = client.post("/handoff/xray", headers={"host": unreachable})
        assert res.status_code == 200
        url = res.json()["capture_url"]
        host = url.split("//", 1)[1].split("/", 1)[0]
        assert host != unreachable, f"QR still points at {host}"
        assert "/web/#/xray-upload?sid=" in url

    # An address a phone can already reach is left alone.
    res = client.post("/handoff/xray", headers={"host": "192.168.1.44:8000"})
    assert "192.168.1.44:8000" in res.json()["capture_url"]


def test_kiosk_hub_drives_the_portal_upload_prompt() -> None:
    """The kiosk hub socket is what makes the portal's X-ray popup and Stop
    Session work; both were dead while it was torn down with the guest screen.
    """
    with client.websocket_connect("/ws/kiosk/events") as ws:
        assert ws.receive_json()["event"] == "connected"

        ws.send_json({"event": "station_change", "station": "xray"})
        ws.send_json({"event": "ping"})
        ws.receive_json()

        state = client.get("/handoff/status").json()
        assert state["kiosks_online"] == 1
        assert state["kiosk_state"]["station"] == "xray"
        assert state["kiosk_state"]["active"] is True

        # An explicit ask bumps a counter, because re-announcing the same station
        # cannot tell the polling portal to reopen a prompt someone closed.
        before = state["kiosk_state"]["xray_prompt_seq"]
        ws.send_json({"event": "request_xray_upload"})
        ws.send_json({"event": "ping"})
        ws.receive_json()
        after = client.get("/handoff/status").json()["kiosk_state"]["xray_prompt_seq"]
        assert after == before + 1

        # Stop must actually reach the kiosk, which is what returns it to guest.
        stop = client.post("/api/web/kiosk/stop-session")
        assert stop.json()["kiosks_notified"] == 1
        assert ws.receive_json()["event"] == "session_stopped"


def test_portal_upload_reaches_the_kiosk_without_an_announcement() -> None:
    """The portal's X-ray upload must land on the kiosk, not just in the record.

    The kiosk publishes its capture session over the event hub, but the server
    minted that session and can resolve it alone — so a dropped announcement, or a
    kiosk build that predates the announcement, must not silently divert the film
    to a server-side path whose result never reaches the station screen.
    """
    import io

    sid = client.post("/handoff/xray").json()["sid"]

    with client.websocket_connect("/ws/kiosk/events") as hub:
        assert hub.receive_json()["event"] == "connected"
        hub.send_json({"event": "station_change", "station": "xray"})
        hub.send_json({"event": "ping"})
        hub.receive_json()

        # No `xray_session` was ever sent, yet the portal can still find it.
        state = client.get("/handoff/status").json()["kiosk_state"]
        assert state["xray_sid"] == sid, "portal would fall back to the record"

        with client.websocket_connect(f"/ws/handoff/{sid}") as capture:
            assert capture.receive_json()["event"] == "waiting"
            film = b"\xff\xd8\xff\xe0" + b"\x00" * 512
            up = client.post(
                f"/handoff/session/{sid}/film",
                files={"file": ("film.jpg", io.BytesIO(film), "image/jpeg")},
            )
            assert up.status_code == 200
            # The kiosk receives it and runs its own analysis and display.
            delivered = capture.receive_json()
            assert delivered["event"] == "film"
            assert delivered.get("image_b64")

    # A session that has been filled is never offered again. Asserted against
    # this sid specifically rather than expecting None: other tests in this module
    # leave their own unfilled sessions open, and inference legitimately finds the
    # newest of those.
    assert client.get("/handoff/status").json()["kiosk_state"]["xray_sid"] != sid


def test_announced_session_wins_over_the_inferred_one() -> None:
    """An explicit announcement is authoritative; inference is only the fallback."""
    announced = client.post("/handoff/xray").json()["sid"]
    client.post("/handoff/xray")          # newer, would win by inference alone

    with client.websocket_connect("/ws/kiosk/events") as hub:
        hub.receive_json()
        hub.send_json({"event": "station_change", "station": "xray"})
        hub.send_json({"event": "xray_session", "sid": announced})
        hub.send_json({"event": "ping"})
        hub.receive_json()
        state = client.get("/handoff/status").json()["kiosk_state"]
        assert state["xray_sid"] == announced


def test_stopping_a_session_leaves_a_readable_visit_in_the_history() -> None:
    """A portal-dispatched visit must land on the record, grouped and clickable.

    The kiosk used to adopt a dispatched patient as an anonymous intake session,
    so `selectedPatientId` stayed null and every station's EMR write was skipped —
    a whole visit measured, and the patient's history still empty. Linking the
    record is what makes this pass; the consultation filed on stop is what gives
    the grouped visit its headline and risk level.
    """
    import io

    patient_id = client.post("/api/web/auth/demo").json()["patient"]["id"]
    before = client.get(
        f"/api/web/patient/history?patient_id={patient_id}"
    ).json()["total"]

    client.post(
        "/api/web/kiosk/trigger-session",
        json={"patient": {"id": patient_id, "name": "Arjay", "sex": "Male"}},
    )

    # What each station writes once the record is linked.
    emr_db.record_vitals(
        patient_id=patient_id, hr=112, spo2=90, temp=34.1, source="kiosk"
    )
    emr_db.save_lung_sound(patient_id=patient_id, label="Crackles", confidence=0.71)
    # A real JPEG, so the stored preview the visit page renders is exercised too;
    # a stub byte string is rejected for a preview and would make has_image false.
    Image = pytest.importorskip("PIL.Image", reason="Pillow builds the test film")
    buf = io.BytesIO()
    Image.new("L", (600, 600), 96).save(buf, format="JPEG")
    client.post(
        f"/api/web/patient/xray?patient_id={patient_id}",
        files={"file": ("film.jpg", io.BytesIO(buf.getvalue()), "image/jpeg")},
    )

    # Stop: the kiosk files the visit summary before clearing its state.
    assert client.post("/api/web/kiosk/stop-session").status_code == 200
    client.post(
        f"/emr/patients/{patient_id}/consultations",
        json={
            "physician": "XSIGHT kiosk screening",
            "summary": "Kiosk session measured pulse and SpO2, breath sounds.",
            "diagnosis": "Findings in heart rate, oxygen saturation, breath sounds",
            "risk_level": "High",
            "vitals_snapshot": "HR 112 bpm",
        },
    )

    history = client.get(
        f"/api/web/patient/history?patient_id={patient_id}"
    ).json()
    assert history["total"] >= before

    visit = history["visits"][0]
    # The list entry: enough to recognise the visit without opening it.
    assert visit["risk_level"] == "High"
    assert visit["headline"] == (
        "Findings in heart rate, oxygen saturation, breath sounds"
    )
    for tag in ("hr", "spo2", "temp", "lung", "xray"):
        assert tag in visit["measured"], f"{tag} missing from the visit chips"

    # The click-through: every reading, from the same payload.
    vitals = visit["vitals"][0]
    assert round(vitals["hr"]) == 112
    assert round(vitals["spo2"]) == 90
    assert visit["lung_sounds"][0]["label"] == "Crackles"
    assert visit["xrays"] and visit["xrays"][0]["has_image"]
    assert visit["consultations"][0]["risk_level"] == "High"


def test_demo_auth_flow() -> None:
    res = client.post("/api/web/auth/demo")
    assert res.status_code == 200
    data = res.json()
    assert data["status"] == "ok"
    patient = data["patient"]
    assert patient["name"] == "John Doe"
    assert "token" in data

    # Test dashboard data retrieval
    dash_res = client.get(f"/api/web/patient/dashboard?patient_id={patient['id']}")
    assert dash_res.status_code == 200
    dash_data = dash_res.json()
    assert "vitals" in dash_data
    assert "xray" in dash_data
    assert "lung_sound" in dash_data


def test_custom_register_and_login() -> None:
    email = f"tester_{os.getpid()}@example.com"
    # Register
    reg_res = client.post(
        "/api/web/auth/register",
        json={
            "name": "Sarah Connor",
            "email": email,
            "password": "secretpassword",
            "sex": "Female",
            "dob": "1985-05-12",
        },
    )
    assert reg_res.status_code == 200
    reg_data = reg_res.json()
    patient_id = reg_data["patient"]["id"]

    # Login
    login_res = client.post(
        "/api/web/auth/login",
        json={"email": email, "password": "secretpassword"},
    )
    assert login_res.status_code == 200
    login_data = login_res.json()
    assert login_data["patient"]["id"] == patient_id


def test_local_handoff_and_kiosk_remote_triggers() -> None:
    # 1. Status
    status_res = client.get("/handoff/status")
    assert status_res.status_code == 200
    assert status_res.json()["available"] is True

    # 2. Mint local X-Ray session
    xray_sess = client.post("/handoff/xray")
    assert xray_sess.status_code == 200
    sid = xray_sess.json()["sid"]
    assert "capture_url" in xray_sess.json()

    # 3. Local phone uploads film
    fake_img = io.BytesIO(b"\xff\xd8\xff\xe0" + b"\x00" * 200)
    upload_res = client.post(
        f"/handoff/session/{sid}/film",
        files={"file": ("test.jpg", fake_img, "image/jpeg")},
    )
    assert upload_res.status_code == 200
    assert upload_res.json()["status"] == "ok"

    # 4. Kiosk triggers
    trig_res = client.post(
        "/api/web/kiosk/trigger-session",
        json={"patient": {"name": "Alice", "age": 30, "sex": "Female"}},
    )
    assert trig_res.status_code == 200
    assert trig_res.json()["status"] == "ok"

    stop_res = client.post("/api/web/kiosk/stop-session")
    assert stop_res.status_code == 200
    assert stop_res.json()["status"] == "ok"
