"""XSIGHT Local Web Dashboard & Clinical Patient Portal.

Clean, professional medical single-page web app with:
- Dedicated Kiosk Session Control View (Start / Stop Session)
- Automatic X-Ray QR Code & Upload Popup ONLY when Kiosk is actively on the X-Ray Station
- Separate Patient Clinical Records & Telemetry Dashboard
- Clean typography and SVG iconography matching XSIGHT Design System (Zero Emojis).
"""

from __future__ import annotations

import base64
import json
import logging
import os
import time
from datetime import datetime, timezone
from typing import Any, Optional

from fastapi import APIRouter, Body, Depends, File, Header, HTTPException, Request, UploadFile
from fastapi.responses import HTMLResponse, JSONResponse
from pydantic import BaseModel, Field

from app import emr_db as db
from app.handoff import broadcast_to_kiosks, get_local_lan_ip, get_server_base_url, _sessions, HandoffSession

# Same env var app.main uses; read directly rather than imported from there,
# which would be a circular import (main.py includes this router).
MAX_UPLOAD_BYTES = int(os.getenv("MAX_UPLOAD_BYTES", "10485760"))

log = logging.getLogger("xsight.web")

router = APIRouter(tags=["Web Portal"])


# ---------------------------------------------------------------------------
# Pydantic Schemas
# ---------------------------------------------------------------------------

class RegisterRequest(BaseModel):
    name: str = Field(..., min_length=1, max_length=200)
    email: str = Field(..., min_length=3, max_length=200)
    password: str = Field(..., min_length=3)
    dob: str = ""
    sex: str = ""
    phone: str = ""
    notes: str = ""


class LoginRequest(BaseModel):
    email: str
    password: str


# ---------------------------------------------------------------------------
# Auth Endpoints
# ---------------------------------------------------------------------------

@router.post("/api/web/auth/register")
async def web_register(payload: RegisterRequest) -> dict[str, Any]:
    existing = db.get_patient_by_email(payload.email)
    if existing:
        raise HTTPException(status_code=400, detail="Email is already registered.")
    patient = db.register_patient_auth(
        name=payload.name,
        email=payload.email,
        password=payload.password,
        dob=payload.dob,
        sex=payload.sex,
        phone=payload.phone,
        notes=payload.notes,
    )
    return {"status": "ok", "patient": patient, "token": f"pat_{patient['id']}_{int(time.time())}"}


@router.post("/api/web/auth/login")
async def web_login(payload: LoginRequest) -> dict[str, Any]:
    patient = db.verify_patient_login(payload.email, payload.password)
    if not patient:
        raise HTTPException(status_code=401, detail="Invalid email or password.")
    return {"status": "ok", "patient": patient, "token": f"pat_{patient['id']}_{int(time.time())}"}


@router.post("/api/web/auth/demo")
async def web_demo_login() -> dict[str, Any]:
    """1-Click instant login for Demo Patient John Doe."""
    patient = db.seed_demo_patient_if_needed()
    return {"status": "ok", "patient": patient, "token": f"pat_{patient['id']}_{int(time.time())}"}


# ---------------------------------------------------------------------------
# Patient Dashboard Data
# ---------------------------------------------------------------------------

@router.get("/api/web/patient/dashboard")
async def get_patient_dashboard(patient_id: int) -> dict[str, Any]:
    data = db.get_patient_portal_dashboard(patient_id)
    if not data:
        raise HTTPException(status_code=404, detail="Patient record not found.")
    return data


# ---------------------------------------------------------------------------
# Visit History
# ---------------------------------------------------------------------------

# Records taken within this window of each other are treated as one visit. The
# schema has no encounter table — vitals, lung sounds, films and consultations
# are each stamped independently — so a visit is inferred from proximity in time.
# Wide enough to hold a full kiosk run across four stations, narrow enough that
# two appointments on the same day stay separate.
VISIT_WINDOW_S = int(os.getenv("XSIGHT_VISIT_WINDOW_S", "10800"))  # 3 hours


def _parse_stamp(raw: Any) -> float:
    """SQLite `datetime('now')` text to an epoch float; 0.0 when unparseable."""
    if not raw:
        return 0.0
    text = str(raw).strip().replace("T", " ").rstrip("Z")
    for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M:%S.%f", "%Y-%m-%d"):
        try:
            return datetime.strptime(text, fmt).replace(tzinfo=timezone.utc).timestamp()
        except ValueError:
            continue
    return 0.0


def _measured_in(visit: dict[str, Any]) -> list[str]:
    """Which readings this visit actually contains.

    Only genuine values count: a vitals row stores 0 for anything the kiosk did
    not measure (there is no respiration sensor, for one), and reporting those as
    present would put a chip on the card for a reading nobody took.
    """
    tags: list[str] = []
    for row in visit["vitals"]:
        for field, tag in (("hr", "hr"), ("spo2", "spo2"), ("temp", "temp"),
                           ("rr", "rr")):
            value = row.get(field)
            if tag not in tags and isinstance(value, (int, float)) and value > 0:
                tags.append(tag)
    if visit["lung_sounds"]:
        tags.append("lung")
    if visit["xrays"]:
        tags.append("xray")
    return tags


@router.get("/api/web/patient/history")
async def get_patient_history(patient_id: int, limit: int = 25) -> dict[str, Any]:
    """Reverse-chronological visit history, without the image blobs.

    Films can be hundreds of kilobytes of base64 each; the list carries only
    metadata plus `has_image` / `has_heatmap`, and the detail view fetches one
    film at a time from `/api/web/patient/xray-image`.
    """
    patient = db.get_patient(patient_id)
    if not patient:
        raise HTTPException(status_code=404, detail="Patient record not found.")
    patient.pop("password_hash", None)

    limit = max(1, min(int(limit), 100))

    def stamped(rows: list[dict], key: str) -> list[tuple[float, dict]]:
        return [(_parse_stamp(r.get(key)), r) for r in rows]

    events: list[tuple[float, str, dict]] = []
    for ts, row in stamped(db.get_vitals_history(patient_id, 200), "recorded_at"):
        events.append((ts, "vitals", row))
    for ts, row in stamped(db.get_lung_sound_history(patient_id, 100), "created_at"):
        events.append((ts, "lung_sounds", row))
    for ts, row in stamped(db.get_xray_history(patient_id, 100), "created_at"):
        # Strip the blobs, keep a flag so the card can say a film exists.
        row = dict(row)
        row["has_image"] = bool(str(row.pop("image_path", "") or "").startswith("data:image"))
        row["has_heatmap"] = bool(row.pop("heatmap_b64", "") or "")
        events.append((ts, "xrays", row))
    for ts, row in stamped(db.get_consultations(patient_id, 100), "created_at"):
        events.append((ts, "consultations", row))

    events.sort(key=lambda e: e[0], reverse=True)

    visits: list[dict[str, Any]] = []
    for ts, kind, row in events:
        current = visits[-1] if visits else None
        # events are newest-first, so a visit's own start time keeps decreasing.
        if current is None or (current["_start_ts"] - ts) > VISIT_WINDOW_S:
            current = {
                "id": f"v{len(visits) + 1}",
                "_start_ts": ts,
                "started_at": row.get("recorded_at") or row.get("created_at"),
                "ended_at": row.get("recorded_at") or row.get("created_at"),
                "vitals": [], "lung_sounds": [], "xrays": [], "consultations": [],
            }
            visits.append(current)
        current[kind].append(row)
        current["_start_ts"] = min(current["_start_ts"], ts) if ts else current["_start_ts"]
        current["started_at"] = row.get("recorded_at") or row.get("created_at")

    for visit in visits:
        visit.pop("_start_ts", None)
        visit["measured"] = _measured_in(visit)
        consult = visit["consultations"][0] if visit["consultations"] else None
        visit["risk_level"] = (consult or {}).get("risk_level") or None
        visit["headline"] = (
            (consult or {}).get("diagnosis")
            or (consult or {}).get("summary")
            or ("Chest radiograph" if visit["xrays"] else None)
            or ("Breath sounds" if visit["lung_sounds"] else None)
            or ("Vital signs" if visit["vitals"] else "Kiosk visit")
        )

    return {"patient": patient, "visits": visits[:limit], "total": len(visits)}


@router.get("/api/web/patient/xray-image")
async def get_patient_xray_image(patient_id: int, xray_id: int) -> dict[str, Any]:
    """One film's stored preview and heatmap, fetched only when it is displayed.

    Scoped to the patient so an id from another record cannot be read by guessing.
    """
    for row in db.get_xray_history(patient_id, 200):
        if int(row.get("id", -1)) == xray_id:
            return {
                "xray_id": xray_id,
                "image_path": row.get("image_path") or "",
                "heatmap_b64": row.get("heatmap_b64") or "",
            }
    raise HTTPException(status_code=404, detail="Film not found for this record.")


# ---------------------------------------------------------------------------
# Chest X-Ray Direct Upload with AI & Heatmap
# ---------------------------------------------------------------------------

def preview_data_uri(data: bytes, max_px: int = 1024) -> str:
    """A bounded JPEG preview of the film, as a data URI, or "" if undecodable.

    The full film is deliberately not stored. The previous code wrote
    `img_b64[:100] + "..."` — a truncated data URI that the portal happily fed to
    an <img> tag, so the radiograph panel showed a broken image for every upload.
    Keeping the whole base64 instead would put multiple megabytes in a SQLite row
    to render something a few hundred pixels wide.
    """
    try:
        from PIL import Image
        import io

        img = Image.open(io.BytesIO(data))
        img.load()
        if img.mode not in ("L", "RGB"):
            img = img.convert("RGB")
        img.thumbnail((max_px, max_px))
        buf = io.BytesIO()
        img.save(buf, format="JPEG", quality=80)
        return "data:image/jpeg;base64," + base64.b64encode(buf.getvalue()).decode("ascii")
    except Exception as exc:
        log.warning("[web_xray] preview generation failed: %s", exc)
        return ""


@router.post("/api/web/patient/xray")
async def upload_patient_xray(
    patient_id: int,
    file: UploadFile = File(...),
) -> dict[str, Any]:
    """Screen a film uploaded from the portal and file it against a record."""
    data = await file.read()
    if not data:
        raise HTTPException(status_code=400, detail="Empty image upload.")
    if len(data) > MAX_UPLOAD_BYTES:
        raise HTTPException(
            status_code=413,
            detail=f"Film exceeds the {MAX_UPLOAD_BYTES // 1048576} MB limit.",
        )
    if not db.get_patient(patient_id):
        raise HTTPException(status_code=404, detail="Patient record not found.")

    # No local model means no classification. It must NOT mean a default one:
    # this used to fall back to prediction="Normal", confidence=0.94 and write
    # that invented result into the patient's record.
    prediction = "Unclassified"
    confidence: Optional[float] = None
    heatmap_b64 = None
    details: dict[str, Any] = {
        "note": "No local screening model was available; the film was stored "
                "without a classification."
    }

    try:
        # `app.main`, not `main`: the latter only resolves when the process was
        # started as `python main.py` from server/, so under uvicorn this import
        # always failed and silently took the fabricated-result path above.
        from app.main import xray_local

        if xray_local.is_available():
            pred, conf, probs, h_b64 = xray_local.classify_with_heatmap(data)
            prediction = pred
            confidence = float(conf)
            heatmap_b64 = h_b64
            details = {"probabilities": probs, "model": "local_efficientnet_b0"}
        else:
            status = xray_local.status()
            details["model_status"] = status.get("error") or "model not loaded"
    except Exception as exc:
        log.warning("[web_xray] local model unavailable: %s", exc)
        details["model_status"] = str(exc)

    saved = db.save_xray_result(
        patient_id=patient_id,
        prediction=prediction,
        confidence=confidence if confidence is not None else 0.0,
        image_path=preview_data_uri(data),
        heatmap_b64=heatmap_b64 or "",
        details=json.dumps(details),
    )

    # The film itself is not echoed back: the browser already holds the file it
    # just posted, and base64ing a phone photo into the response added megabytes
    # for nothing.
    return {
        "status": "ok",
        "xray_id": saved.get("id"),
        "prediction": prediction,
        "confidence": confidence,
        "has_heatmap": bool(heatmap_b64),
        "details": details,
    }


# ---------------------------------------------------------------------------
# Single-Page Web Application (Clean, Focused, Zero Emoji)
# ---------------------------------------------------------------------------

WEB_APP_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="robots" content="noindex, nofollow">
<title>XSIGHT - Clinical Portal</title>
<style>
  /* XSIGHT palette, matching lib/core/theme/xs_colors.dart and web/public/*.html
     so the local portal reads as part of the same system as the kiosk and the
     phone check-in pages. System font stack on purpose: this dashboard runs on a
     clinic LAN that may have no route to a font CDN. */
  :root {
    --teal: #1B6B6F;
    --teal-dark: #0F3D3E;
    --sage: #6C9A8B;
    --slate: #2F3E46;
    --mint: #DCEDEA;
    --surface: #DCEDEA;
    --highlight: #FFFFFF;
    --text-primary: #2F3E46;
    --text-secondary: #1B6B6F;
    --text-muted: #6C9A8B;
    --divider: #C9E0DA;
    /* Inner blocks that carry body text. Deliberately NOT --highlight: in dark
       mode that is teal, and secondary text on teal is unreadable. */
    --panel: #FFFFFF;
    --xray: #1565C0;
    --green: #2E7D32;
    --orange: #E65100;
    --red: #C62828;
    --shadow-dark: rgba(47, 62, 70, .16);
    --shadow-light: rgba(255, 255, 255, .9);
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --surface: #2F3E46;
      --highlight: #1B6B6F;
      --panel: #3A4A52;
      --text-primary: #DCEDEA;
      --text-secondary: #6C9A8B;
      --text-muted: #6C9A8B;
      --divider: #1B6B6F;
      --shadow-dark: rgba(0, 0, 0, .45);
      --shadow-light: rgba(255, 255, 255, .06);
    }
  }

  * { margin: 0; padding: 0; box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
  body {
    background: var(--surface); color: var(--text-primary);
    font: 400 16px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    -webkit-font-smoothing: antialiased;
    min-height: 100dvh; display: flex; flex-direction: column;
  }

  /* Neumorphism: one raised recipe and one inset recipe, scaled by depth. Every
     surface in here is the same colour as the page - elevation is carried by the
     shadow pair alone, never by a border. */
  .raised { box-shadow: 6px 6px 14px var(--shadow-dark), -6px -6px 14px var(--shadow-light); }
  .inset  { box-shadow: inset 4px 4px 9px var(--shadow-dark), inset -4px -4px 9px var(--shadow-light); }

  /* -- Top bar ------------------------------------------------------------ */
  .topbar {
    position: sticky; top: 0; z-index: 100;
    background: var(--surface); padding: 14px 22px;
    display: flex; align-items: center; justify-content: space-between; gap: 16px;
    flex-wrap: wrap;
    box-shadow: 0 6px 16px var(--shadow-dark);
  }
  .nav-brand { display: flex; align-items: center; gap: 12px; text-decoration: none; color: inherit; cursor: pointer; }
  .mark {
    width: 42px; height: 42px; flex: 0 0 42px; border-radius: 13px;
    background: var(--surface); display: grid; place-items: center;
    box-shadow: 4px 4px 10px var(--shadow-dark), -4px -4px 10px var(--shadow-light);
  }
  .mark svg { width: 22px; height: 22px; }
  .brand-text { font-size: 19px; font-weight: 800; letter-spacing: -.3px; line-height: 1.1; }
  .brand-subtext {
    display: block; font-size: 12px; font-weight: 700; letter-spacing: .5px;
    color: var(--text-secondary); text-transform: uppercase;
  }

  /* Segmented control: inset track, raised active pill. */
  .nav-tabs {
    display: flex; gap: 6px; padding: 5px; border-radius: 15px;
    background: var(--surface);
    box-shadow: inset 3px 3px 7px var(--shadow-dark), inset -3px -3px 7px var(--shadow-light);
  }
  .nav-tab-btn {
    padding: 10px 18px; border-radius: 11px; border: 0; background: transparent;
    font: 800 13px/1 inherit; letter-spacing: .3px; color: var(--text-secondary);
    cursor: pointer; transition: box-shadow .15s ease, color .15s ease;
  }
  .nav-tab-btn.active {
    color: var(--text-primary); background: var(--surface);
    box-shadow: 3px 3px 8px var(--shadow-dark), -3px -3px 8px var(--shadow-light);
  }

  .nav-right { display: flex; align-items: center; gap: 10px; }
  .beacon-pill {
    display: flex; align-items: center; gap: 8px; padding: 9px 15px; border-radius: 999px;
    background: var(--surface); font-size: 12.5px; font-weight: 700; color: var(--text-secondary);
    box-shadow: inset 3px 3px 7px var(--shadow-dark), inset -3px -3px 7px var(--shadow-light);
  }
  .beacon-dot { width: 9px; height: 9px; border-radius: 50%; flex: 0 0 9px; background: var(--text-muted); }
  .beacon-dot.online { background: var(--green); box-shadow: 0 0 0 3px rgba(46,125,50,.18); }
  .beacon-dot.active { background: var(--xray); box-shadow: 0 0 0 3px rgba(21,101,192,.20); }

  .container { max-width: 1120px; margin: 0 auto; padding: 26px 20px 40px; width: 100%; flex: 1; }

  /* -- Typography --------------------------------------------------------- */
  .eyebrow {
    font-size: 13px; font-weight: 800; letter-spacing: .9px; text-transform: uppercase;
    color: var(--text-secondary); margin-bottom: 10px;
  }
  h1 { font-size: 26px; font-weight: 800; letter-spacing: -.5px; }
  h2 { font-size: 22px; font-weight: 800; letter-spacing: -.4px; }
  h3 { font-size: 17px; font-weight: 800; letter-spacing: -.2px; }
  .muted { color: var(--text-secondary); font-size: 15px; }
  .mono { font-variant-numeric: tabular-nums; letter-spacing: .2px; }

  /* -- Cards -------------------------------------------------------------- */
  .card {
    background: var(--surface); border-radius: 20px; padding: 22px; margin-bottom: 18px;
    box-shadow: 6px 6px 14px var(--shadow-dark), -6px -6px 14px var(--shadow-light);
  }
  .sunken {
    background: var(--surface); border-radius: 14px; padding: 14px;
    box-shadow: inset 4px 4px 9px var(--shadow-dark), inset -4px -4px 9px var(--shadow-light);
  }

  /* -- Buttons ------------------------------------------------------------ */
  .btn {
    -webkit-appearance: none; appearance: none; border: 0;
    display: inline-flex; align-items: center; justify-content: center; gap: 9px;
    min-height: 52px; padding: 0 24px; border-radius: 16px;
    font: 800 14px/1 inherit; letter-spacing: .5px; text-transform: uppercase;
    background: var(--surface); color: var(--text-primary); cursor: pointer;
    text-decoration: none; transition: box-shadow .12s ease, transform .12s ease;
    box-shadow: 5px 5px 12px var(--shadow-dark), -5px -5px 12px var(--shadow-light);
  }
  .btn:active {
    box-shadow: inset 4px 4px 9px var(--shadow-dark), inset -4px -4px 9px var(--shadow-light);
    transform: scale(.99);
  }
  .btn:focus-visible { outline: 2px solid var(--teal); outline-offset: 3px; }
  .btn.primary { background: var(--teal); color: #fff; box-shadow: 5px 5px 14px var(--shadow-dark); }
  .btn.danger  { background: var(--red);  color: #fff; box-shadow: 5px 5px 14px var(--shadow-dark); }
  .btn.block { width: 100%; }
  .btn.sm { min-height: 42px; padding: 0 16px; font-size: 12.5px; border-radius: 13px; }
  .btn.lg { min-height: 62px; padding: 0 32px; font-size: 15px; }
  .btn[disabled] { opacity: .5; pointer-events: none; }
  .btn svg { width: 18px; height: 18px; flex: 0 0 18px; }
  .icon-btn {
    width: 42px; height: 42px; min-height: 0; padding: 0; border-radius: 13px; flex: 0 0 42px;
  }

  /* -- Forms -------------------------------------------------------------- */
  .field { display: block; margin-bottom: 15px; }
  .field > .lbl {
    display: block; font-size: 13.5px; font-weight: 700; color: var(--text-primary); margin-bottom: 7px;
  }
  input, select {
    -webkit-appearance: none; appearance: none;
    width: 100%; min-height: 54px; padding: 0 16px; border: 0; border-radius: 14px;
    background: var(--surface); color: var(--text-primary); font: 600 16px/1 inherit;
    box-shadow: inset 4px 4px 9px var(--shadow-dark), inset -4px -4px 9px var(--shadow-light);
  }
  select { padding-right: 40px; cursor: pointer; }
  input:focus, select:focus { outline: 2px solid var(--teal); outline-offset: 2px; }
  .row-2 { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
  @media (max-width: 460px) { .row-2 { grid-template-columns: 1fr; } }

  .auth-box { max-width: 470px; margin: 34px auto; }
  .auth-switch {
    display: flex; gap: 6px; padding: 5px; border-radius: 15px; margin-bottom: 22px;
    box-shadow: inset 3px 3px 7px var(--shadow-dark), inset -3px -3px 7px var(--shadow-light);
  }
  .auth-switch-btn {
    flex: 1; min-height: 46px; border: 0; border-radius: 11px; background: transparent;
    font: 800 13.5px/1 inherit; color: var(--text-secondary); cursor: pointer;
  }
  .auth-switch-btn.active {
    color: var(--text-primary); background: var(--surface);
    box-shadow: 3px 3px 8px var(--shadow-dark), -3px -3px 8px var(--shadow-light);
  }
  .divider-or {
    display: flex; align-items: center; gap: 12px; margin: 20px 0 16px;
    font-size: 12.5px; font-weight: 800; letter-spacing: .8px; text-transform: uppercase;
    color: var(--text-muted);
  }
  .divider-or::before, .divider-or::after { content: ""; flex: 1; height: 1px; background: var(--divider); }

  /* -- Badges ------------------------------------------------------------- */
  .badge {
    display: inline-flex; align-items: center; gap: 8px; padding: 8px 16px; border-radius: 999px;
    font-size: 12.5px; font-weight: 800; letter-spacing: .6px; text-transform: uppercase;
  }
  .badge.standby { background: var(--panel); color: var(--text-secondary); }
  .badge.active  { background: rgba(21,101,192,.12); color: var(--xray); }
  .badge.ok      { background: rgba(46,125,50,.12);  color: var(--green); }
  .badge.warn    { background: rgba(230,81,0,.12);   color: var(--orange); }
  .badge.alert   { background: rgba(198,40,40,.12);  color: var(--red); }

  /* -- Session view ------------------------------------------------------- */
  .session-card { text-align: center; padding: 34px 26px; }
  .patient-bar {
    display: flex; flex-wrap: wrap; justify-content: center; gap: 10px 26px;
    padding: 16px 20px; border-radius: 14px; margin: 20px auto 26px; max-width: 700px;
    font-size: 14px; color: var(--text-secondary); background: var(--panel);
  }
  .patient-bar strong { color: var(--text-primary); font-weight: 800; }
  .session-actions { display: flex; justify-content: center; gap: 14px; flex-wrap: wrap; }

  .station-tracker {
    display: grid; grid-template-columns: repeat(auto-fit, minmax(170px, 1fr));
    gap: 14px; margin: 28px auto 0; max-width: 800px; text-align: left;
  }
  .station-item {
    border-radius: 16px; padding: 15px 16px; background: var(--surface);
    box-shadow: inset 4px 4px 9px var(--shadow-dark), inset -4px -4px 9px var(--shadow-light);
    transition: box-shadow .2s ease;
  }
  /* Active station reads as lifted rather than merely outlined, so it is legible
     across the room without relying on a hue difference alone. */
  .station-item.active {
    box-shadow: 4px 4px 11px var(--shadow-dark), -4px -4px 11px var(--shadow-light);
  }
  .station-item-head { display: flex; align-items: center; gap: 8px; }
  .station-dot { width: 8px; height: 8px; border-radius: 50%; flex: 0 0 8px; background: var(--text-muted); }
  .station-item.active .station-dot { background: var(--xray); box-shadow: 0 0 0 3px rgba(21,101,192,.2); }
  .station-item-title {
    font-size: 12px; font-weight: 800; letter-spacing: .7px; text-transform: uppercase;
    color: var(--text-secondary);
  }
  .station-item-val { font-size: 14px; font-weight: 700; color: var(--text-primary); margin-top: 6px; }

  /* -- Records view ------------------------------------------------------- */
  .records-header {
    display: flex; flex-wrap: wrap; justify-content: space-between; align-items: flex-end;
    gap: 14px; margin-bottom: 20px;
  }
  .vitals-grid {
    display: grid; grid-template-columns: repeat(auto-fit, minmax(210px, 1fr));
    gap: 16px; margin-bottom: 18px;
  }
  .vital-box {
    background: var(--surface); border-radius: 18px; padding: 18px 20px;
    box-shadow: 6px 6px 14px var(--shadow-dark), -6px -6px 14px var(--shadow-light);
  }
  .vital-title {
    font-size: 12px; font-weight: 800; letter-spacing: .7px; text-transform: uppercase;
    color: var(--text-secondary);
  }
  .vital-num {
    font-size: 36px; font-weight: 800; letter-spacing: -1px; color: var(--text-primary);
    margin: 8px 0 4px; font-variant-numeric: tabular-nums;
  }
  .vital-num .unit { font-size: 15px; font-weight: 700; color: var(--text-secondary); letter-spacing: 0; }
  .vital-sub { font-size: 12.5px; color: var(--text-secondary); }

  .dashboard-columns { display: grid; grid-template-columns: 1.15fr 1fr; gap: 18px; align-items: start; }
  @media (max-width: 900px) { .dashboard-columns { grid-template-columns: 1fr; } }

  .panel-title {
    display: flex; justify-content: space-between; align-items: center; gap: 12px;
    font-size: 16px; font-weight: 800; letter-spacing: -.2px; margin-bottom: 14px;
  }

  .xray-canvas-box {
    background: #000; border-radius: 14px; padding: 12px; min-height: 240px;
    display: flex; flex-direction: column; align-items: center; justify-content: center;
    box-shadow: inset 3px 3px 10px rgba(0,0,0,.5);
  }
  .xray-stack { position: relative; max-width: 100%; display: inline-block; }
  .xray-img { max-height: 250px; width: auto; max-width: 100%; display: block; border-radius: 10px; }
  .xray-heatmap {
    position: absolute; inset: 0; width: 100%; height: 100%;
    mix-blend-mode: screen; opacity: .85; pointer-events: none;
    transition: opacity .18s ease;
  }
  .empty-note { font-size: 13.5px; color: var(--text-muted); text-align: center; }

  .history-item {
    border-radius: 13px; padding: 12px 14px; margin-bottom: 9px; background: var(--panel);
  }
  .history-item:last-child { margin-bottom: 0; }
  .history-top { display: flex; justify-content: space-between; align-items: center; gap: 10px; }
  .history-top strong { font-size: 14px; font-weight: 800; color: var(--text-primary); }
  .history-sub { font-size: 12px; color: var(--text-secondary); margin-top: 3px; }

  /* -- Visit history ------------------------------------------------------ */
  .visit-card {
    display: grid; grid-template-columns: minmax(0, 1fr) auto; gap: 14px;
    align-items: center; width: 100%; text-align: left;
    background: var(--surface); border: 0; border-radius: 18px;
    padding: 18px 20px; margin-bottom: 14px; cursor: pointer;
    font: inherit; color: var(--text-primary);
    box-shadow: 6px 6px 14px var(--shadow-dark), -6px -6px 14px var(--shadow-light);
    transition: box-shadow .14s ease, transform .14s ease;
  }
  .visit-card:hover { transform: translateY(-1px); }
  .visit-card:active {
    transform: none;
    box-shadow: inset 4px 4px 9px var(--shadow-dark), inset -4px -4px 9px var(--shadow-light);
  }
  .visit-card:focus-visible { outline: 2px solid var(--teal); outline-offset: 3px; }
  .visit-when {
    font-size: 12.5px; font-weight: 800; letter-spacing: .6px; text-transform: uppercase;
    color: var(--text-secondary);
  }
  .visit-headline {
    font-size: 17px; font-weight: 800; letter-spacing: -.2px; margin: 5px 0 10px;
    overflow-wrap: anywhere;
    /* A clinician can write a long impression; the card shows the first two lines
       and the full text is on the visit page. */
    display: -webkit-box; -webkit-box-orient: vertical; -webkit-line-clamp: 2;
    overflow: hidden;
  }
  .visit-chips { display: flex; flex-wrap: wrap; gap: 7px; }
  .chip-tag {
    display: inline-flex; align-items: center; gap: 6px;
    padding: 6px 12px; border-radius: 999px; background: var(--panel);
    font-size: 12px; font-weight: 700; color: var(--text-secondary);
  }
  .chip-tag b { color: var(--text-primary); font-weight: 800; }
  .visit-right { display: flex; align-items: center; gap: 12px; }
  .visit-chevron { color: var(--text-secondary); width: 20px; height: 20px; flex: 0 0 20px; }

  /* -- Visit detail (a full page, not a dialog) --------------------------- */
  .detail-head {
    display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between;
    gap: 14px; margin-bottom: 20px;
  }
  .detail-title { font-size: 24px; font-weight: 800; letter-spacing: -.5px; }
  .detail-sub { font-size: 13.5px; color: var(--text-secondary); margin-top: 4px; }
  .kv { display: grid; grid-template-columns: minmax(0,1fr); gap: 10px; }
  .kv-row {
    display: flex; justify-content: space-between; gap: 14px;
    padding-bottom: 10px; border-bottom: 1px solid var(--divider);
    font-size: 14px;
  }
  .kv-row:last-child { border-bottom: 0; padding-bottom: 0; }
  .kv-row dt { color: var(--text-secondary); }
  .kv-row dd { font-weight: 700; text-align: right; overflow-wrap: anywhere; }

  /* -- Mobile ------------------------------------------------------------- */
  @media (max-width: 720px) {
    .topbar { padding: 12px 14px; gap: 10px; }
    .nav-tabs { order: 3; width: 100%; }
    .nav-tab-btn { flex: 1; padding: 11px 8px; }
    .brand-text { font-size: 17px; }
    .container { padding: 18px 14px 32px; }
    .card { padding: 18px; border-radius: 18px; }
    h1 { font-size: 22px; }
    h2 { font-size: 20px; }
    .session-card { padding: 24px 18px; }
    .session-actions .btn { width: 100%; }
    .patient-bar { flex-direction: column; align-items: flex-start; gap: 8px; }
    .vitals-grid { grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 12px; }
    .vital-box { padding: 15px 16px; }
    .vital-num { font-size: 30px; }
    .station-tracker { grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: 10px; }
    .visit-card { padding: 15px 16px; }
    .visit-headline { font-size: 15.5px; }
    .detail-title { font-size: 20px; }
    .modal-card { padding: 20px; border-radius: 20px; }
    .beacon-pill { padding: 8px 12px; font-size: 12px; }
  }
  @media (max-width: 400px) {
    .beacon-pill span:last-child { display: none; }
    .vitals-grid { grid-template-columns: 1fr 1fr; }
  }

  /* -- Modal -------------------------------------------------------------- */
  .modal-backdrop {
    position: fixed; inset: 0; z-index: 200; padding: 18px;
    background: rgba(47, 62, 70, .55); backdrop-filter: blur(8px);
    display: none; align-items: center; justify-content: center;
  }
  .modal-backdrop.open { display: flex; }
  .modal-card {
    background: var(--surface); border-radius: 22px; padding: 24px;
    width: 100%; max-width: 540px; max-height: 92dvh; overflow-y: auto;
    box-shadow: 10px 10px 30px rgba(0,0,0,.35), -6px -6px 16px var(--shadow-light);
  }
  .modal-head { display: flex; justify-content: space-between; align-items: flex-start; gap: 12px; }
  .upload-tabs {
    display: grid; grid-template-columns: repeat(3, 1fr); gap: 6px; margin: 18px 0 16px;
    padding: 5px; border-radius: 15px;
    box-shadow: inset 3px 3px 7px var(--shadow-dark), inset -3px -3px 7px var(--shadow-light);
  }
  .upload-tab-btn {
    border: 0; background: transparent; border-radius: 11px; min-height: 46px; padding: 0 6px;
    font: 800 12.5px/1.2 inherit; color: var(--text-secondary); cursor: pointer;
  }
  .upload-tab-btn.active {
    color: var(--text-primary); background: var(--surface);
    box-shadow: 3px 3px 8px var(--shadow-dark), -3px -3px 8px var(--shadow-light);
  }
  .dropzone {
    border-radius: 16px; padding: 34px 18px; text-align: center; cursor: pointer;
    background: var(--surface);
    box-shadow: inset 4px 4px 9px var(--shadow-dark), inset -4px -4px 9px var(--shadow-light);
  }
  .dropzone:hover { outline: 2px dashed var(--teal); outline-offset: -8px; }
  .qr-frame {
    background: #fff; padding: 12px; border-radius: 16px; display: inline-block;
    box-shadow: 5px 5px 12px var(--shadow-dark);
  }
  .qr-frame img { width: 168px; height: 168px; display: block; }
  .guide-list { padding-left: 20px; margin-top: 8px; color: var(--text-secondary); font-size: 13.5px; line-height: 1.7; }

  /* -- Toast -------------------------------------------------------------- */
  #toast {
    position: fixed; bottom: 24px; left: 50%; transform: translateX(-50%) translateY(12px);
    padding: 14px 22px; border-radius: 15px; max-width: min(90vw, 460px);
    background: var(--surface); color: var(--text-primary);
    font-size: 14px; font-weight: 700; text-align: center;
    box-shadow: 6px 6px 16px var(--shadow-dark), -6px -6px 16px var(--shadow-light);
    z-index: 300; opacity: 0; pointer-events: none;
    transition: opacity .2s ease, transform .2s ease;
  }
  #toast.show { opacity: 1; transform: translateX(-50%) translateY(0); }

  .disclaimer {
    text-align: center; font-size: 12.5px; color: var(--text-secondary);
    line-height: 1.6; padding: 6px 18px 0; max-width: 640px; margin: 0 auto;
  }
  @keyframes spin { to { transform: rotate(360deg); } }
  .hidden { display: none !important; }
</style>
</head>
<body>

<nav class="topbar">
  <a class="nav-brand" onclick="navigateTo('session')">
    <div class="mark" aria-hidden="true">
      <svg viewBox="0 0 24 24" fill="none" stroke="#1B6B6F" stroke-width="2"
           stroke-linecap="round" stroke-linejoin="round">
        <path d="M6 3v6a6 6 0 0 0 12 0V3"/><path d="M12 15v6"/><path d="M9 21h6"/>
      </svg>
    </div>
    <div>
      <span class="brand-text">XSIGHT</span>
      <span class="brand-subtext">Clinical portal</span>
    </div>
  </a>

  <div class="nav-tabs hidden" id="appNavTabs">
    <button class="nav-tab-btn active" id="tabNavSession" onclick="navigateTo('session')">Kiosk session</button>
    <button class="nav-tab-btn" id="tabNavRecords" onclick="navigateTo('records')">Health record</button>
  </div>

  <div class="nav-right">
    <div class="beacon-pill" role="status" aria-live="polite">
      <span class="beacon-dot" id="beaconDot"></span>
      <span id="beaconText">Kiosk: connecting</span>
    </div>
    <button class="btn sm hidden" id="logoutBtn" onclick="logout()">Sign out</button>
  </div>
</nav>

<div class="container">

  <!-- 1. Authentication -->
  <div id="authView" class="auth-box">
    <div class="card">
      <p class="eyebrow">Clinical access</p>
      <h2>Sign in to the portal</h2>
      <p class="muted" style="margin-top:6px;">
        Start a screening session on the kiosk, or review a patient's recorded history.
      </p>
    </div>

    <div class="card">
      <div class="auth-switch">
        <button class="auth-switch-btn active" id="authTabLogin" onclick="switchAuthMode('login')">Sign in</button>
        <button class="auth-switch-btn" id="authTabRegister" onclick="switchAuthMode('register')">Register</button>
      </div>

      <form id="loginForm" onsubmit="handleLogin(event)">
        <label class="field">
          <span class="lbl">Email address</span>
          <input type="email" id="loginEmail" autocomplete="email" required placeholder="you@example.com">
        </label>
        <label class="field">
          <span class="lbl">Password</span>
          <input type="password" id="loginPass" autocomplete="current-password" required>
        </label>
        <button type="submit" class="btn primary block">Sign in</button>
      </form>

      <form id="registerForm" class="hidden" onsubmit="handleRegister(event)">
        <label class="field">
          <span class="lbl">Full name</span>
          <input type="text" id="regName" autocomplete="name" maxlength="80" placeholder="Jane Smith" required>
        </label>
        <label class="field">
          <span class="lbl">Email address</span>
          <input type="email" id="regEmail" autocomplete="email" placeholder="jane@example.com" required>
        </label>
        <label class="field">
          <span class="lbl">Password</span>
          <input type="password" id="regPass" autocomplete="new-password" required>
        </label>
        <div class="row-2">
          <label class="field">
            <span class="lbl">Date of birth</span>
            <input type="date" id="regDob">
          </label>
          <label class="field">
            <span class="lbl">Sex</span>
            <select id="regSex">
              <option value="Female">Female</option>
              <option value="Male">Male</option>
              <option value="Other">Other</option>
            </select>
          </label>
        </div>
        <button type="submit" class="btn primary block">Create account</button>
      </form>

      <div class="divider-or">or</div>
      <button class="btn block" onclick="handleDemoLogin()">Demo record (John Doe)</button>
    </div>

    <p class="disclaimer">
      XSIGHT is an AI-assisted screening aid, not a diagnosis. Results are always
      reviewed by a licensed clinician.
    </p>
  </div>

  <!-- 2. Remote session control -->
  <div id="sessionView" class="hidden">
    <div class="card session-card">
      <div id="sessionBadgeWrap">
        <span class="badge standby" id="sessionStatusBadge">Kiosk standby &middot; ready to start</span>
      </div>

      <h1 style="margin-top:16px;" id="sessionHeading">Start a screening session</h1>
      <p class="muted" style="max-width:560px; margin:10px auto 0;" id="sessionSubtext">
        Start sends this patient profile to the kiosk tablet. The kiosk asks the
        person in front of it to accept before any reading is taken.
      </p>

      <div class="patient-bar">
        <span>Patient <strong id="sessPatName">&mdash;</strong></span>
        <span>Record <strong class="mono" id="sessPatId">&mdash;</strong></span>
        <span>Profile <strong id="sessPatMeta">&mdash;</strong></span>
      </div>

      <div class="session-actions">
        <button class="btn primary lg" id="btnStartSession" onclick="triggerStartSession()">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"
               stroke-linecap="round" stroke-linejoin="round"><path d="M5 3l14 9-14 9V3z"/></svg>
          Start session on kiosk
        </button>
        <button class="btn danger lg hidden" id="btnStopSession" onclick="triggerStopSession()">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"
               stroke-linecap="round" stroke-linejoin="round"><rect x="5" y="5" width="14" height="14" rx="2"/></svg>
          Stop &middot; return to guest mode
        </button>
      </div>

      <div class="station-tracker">
        <div class="station-item" id="stVitals">
          <div class="station-item-head">
            <span class="station-dot"></span><span class="station-item-title">Pulse &amp; SpO&#8322;</span>
          </div>
          <div class="station-item-val" id="stVitalsVal">Idle</div>
        </div>
        <div class="station-item" id="stTemp">
          <div class="station-item-head">
            <span class="station-dot"></span><span class="station-item-title">Temperature</span>
          </div>
          <div class="station-item-val" id="stTempVal">Idle</div>
        </div>
        <div class="station-item" id="stLungs">
          <div class="station-item-head">
            <span class="station-dot"></span><span class="station-item-title">Stethoscope</span>
          </div>
          <div class="station-item-val" id="stLungsVal">Idle</div>
        </div>
        <div class="station-item" id="stXray">
          <div class="station-item-head">
            <span class="station-dot"></span><span class="station-item-title">Chest radiograph</span>
          </div>
          <div class="station-item-val" id="stXrayVal">Idle</div>
        </div>
      </div>

      <!-- AI screening summary. Filed by the kiosk when the session ends; the
           poll picks it up within a tick. Until then the card stays hidden —
           an invented placeholder here would be a fabricated assessment. -->
      <div class="card hidden" id="sessionSummaryCard" style="margin-top:18px; text-align:left; max-width:800px; margin-left:auto; margin-right:auto;">
        <div class="panel-title">
          <span>AI screening summary</span>
          <span class="badge standby" id="ssRisk">No assessment</span>
        </div>
        <p class="eyebrow" style="margin-bottom:10px;" id="ssWhen">This screening</p>
        <div class="sunken">
          <strong id="ssImpression" style="font-size:15px; font-weight:800;">&mdash;</strong>
          <p style="font-size:13.5px; color:var(--text-secondary); margin-top:6px; line-height:1.55;" id="ssSummary"></p>
        </div>
        <p style="font-size:12.5px; color:var(--text-muted); margin-top:10px;">
          AI-assisted screening, not a diagnosis &middot; requires clinician review.
        </p>
      </div>
    </div>
  </div>

  <!-- 3. Health record: a history list that opens a full page, not a popup -->
  <div id="recordsView" class="hidden">

    <div id="historyPane">
      <div class="records-header">
        <div>
          <p class="eyebrow">Health record</p>
          <h2 id="recPatName">&mdash;</h2>
          <p class="muted" style="font-size:13.5px; margin-top:4px;">
            <span id="recPatMeta">&mdash;</span> &middot; <span class="mono" id="recPatMrn">&mdash;</span>
          </p>
        </div>
        <button class="btn sm" onclick="loadRecordsData()">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"
               stroke-linecap="round" stroke-linejoin="round">
            <path d="M21 12a9 9 0 1 1-3-6.7"/><path d="M21 3v6h-6"/>
          </svg>
          Refresh
        </button>
      </div>

      <!-- Most recent readings, for a glance before opening anything. Every tile
           starts as an em dash; a missing reading is never given a default. -->
      <div class="vitals-grid">
        <div class="vital-box">
          <div class="vital-title">Heart rate</div>
          <div class="vital-num"><span id="valHr">&mdash;</span> <span class="unit">bpm</span></div>
          <div class="vital-sub" id="valHrSub">No reading on record</div>
        </div>
        <div class="vital-box">
          <div class="vital-title">Oxygen saturation</div>
          <div class="vital-num"><span id="valSpo2">&mdash;</span> <span class="unit">%</span></div>
          <div class="vital-sub" id="valSpo2Sub">No reading on record</div>
        </div>
        <div class="vital-box">
          <div class="vital-title">Skin temperature</div>
          <div class="vital-num"><span id="valTemp">&mdash;</span> <span class="unit">&deg;C</span></div>
          <div class="vital-sub" id="valTempSub">No reading on record</div>
        </div>
        <div class="vital-box">
          <div class="vital-title">Films scanned</div>
          <div class="vital-num"><span id="valFilms">&mdash;</span></div>
          <div class="vital-sub" id="valFilmsSub">No radiograph on record</div>
        </div>
      </div>

      <p class="eyebrow" style="margin:26px 0 12px;">Recent visits</p>
      <div id="visitList">
        <div class="card"><p class="empty-note">Loading history&hellip;</p></div>
      </div>
    </div>

    <!-- Full-page detail for one visit -->
    <div id="visitPane" class="hidden">
      <button class="btn sm" style="margin-bottom:18px;" onclick="closeVisit()">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"
             stroke-linecap="round" stroke-linejoin="round">
          <path d="M19 12H5"/><path d="M12 19l-7-7 7-7"/>
        </svg>
        All visits
      </button>

      <div class="detail-head">
        <div>
          <p class="eyebrow" id="vdWhen">&mdash;</p>
          <div class="detail-title" id="vdHeadline">&mdash;</div>
          <div class="detail-sub" id="vdWho">&mdash;</div>
        </div>
        <span class="badge standby" id="vdRisk">No assessment</span>
      </div>

      <div class="vitals-grid" id="vdVitals"></div>

      <div class="dashboard-columns">
        <div>
          <div class="card" id="vdXrayCard">
            <div class="panel-title">
              <span>Chest radiograph</span>
              <span class="badge standby" id="vdXrayBadge">No film</span>
            </div>
            <div class="xray-canvas-box">
              <div class="xray-stack hidden" id="xrayStack">
                <img id="xrayBaseImg" class="xray-img" src="" alt="Chest radiograph">
                <img id="xrayHeatmapImg" class="xray-heatmap" src="" alt="AI attention heatmap">
              </div>
              <div class="empty-note" id="xrayEmpty">No radiograph film on record.</div>
            </div>
            <div class="hidden" style="margin-top:12px;" id="xrayControls">
              <button class="btn sm block" id="btnToggleHeat" onclick="toggleHeatmap()">Hide AI heatmap</button>
            </div>
            <div class="sunken" style="margin-top:14px;">
              <strong id="xrayDiag" style="font-size:14px; font-weight:800;">Awaiting film</strong>
              <p style="font-size:13px; color:var(--text-secondary); margin-top:5px;" id="xrayNotes">
                No film was submitted during this visit.
              </p>
            </div>
          </div>
        </div>

        <div>
          <div class="card">
            <div class="panel-title">
              <span>Breath sounds</span>
              <span class="badge standby" id="recLungBadge">No recording</span>
            </div>
            <div class="sunken">
              <div style="font-weight:800; font-size:14px;" id="recLungTitle">Not recorded</div>
              <p style="font-size:13px; color:var(--text-secondary); margin-top:5px;" id="recLungDesc">
                The stethoscope station was not used during this visit.
              </p>
            </div>
          </div>

          <div class="card" id="vdAssessCard">
            <div class="panel-title"><span>Assessment</span></div>
            <dl class="kv" id="vdAssess"></dl>
          </div>
        </div>
      </div>

      <p class="disclaimer" style="margin-top:20px;">
        Screening support only. These results are not a diagnosis - have them
        reviewed by a licensed clinician. Chest pain, severe breathlessness, blue
        lips, confusion or fainting need emergency care now.
      </p>
    </div>
  </div>

  <!-- 4. Phone capture view. Reached only by scanning the kiosk's X-ray QR,
       which encodes {lan}/web/#/xray-upload?sid=... - no sign-in, because the
       person holding the phone is whoever is standing at the kiosk. The film
       goes to /handoff/session/{sid}/film and the kiosk collects it over the
       WebSocket it already holds. -->
  <div id="captureView" class="hidden" style="max-width:560px; margin:0 auto;">
    <div class="card">
      <p class="eyebrow">Chest X-ray</p>
      <h2>Send the film to the kiosk</h2>
      <p class="muted" style="margin-top:8px;">
        Photograph the film on a lightbox, or pick an existing image. It goes
        straight to the kiosk screening station on this Wi-Fi.
      </p>
    </div>

    <div id="capStatus" class="hidden card" style="display:flex; align-items:center; gap:12px; padding:16px 18px;">
      <span id="capSpinner" class="hidden" style="width:20px;height:20px;flex:0 0 20px;border:2.5px solid var(--divider);border-top-color:var(--teal);border-radius:50%;animation:spin .8s linear infinite;"></span>
      <span id="capStatusText" style="min-width:0; overflow-wrap:anywhere; font-weight:700;"></span>
    </div>

    <div class="card" id="capPickCard">
      <button class="btn primary block" id="capBtnCamera">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"
             stroke-linecap="round" stroke-linejoin="round">
          <path d="M23 19a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4l2-3h6l2 3h4a2 2 0 0 1 2 2z"/>
          <circle cx="12" cy="13" r="4"/>
        </svg>
        Photograph the film
      </button>
      <button class="btn block" id="capBtnGallery" style="margin-bottom:0;">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"
             stroke-linecap="round" stroke-linejoin="round">
          <rect x="3" y="3" width="18" height="18" rx="2"/>
          <circle cx="8.5" cy="8.5" r="1.5"/><path d="M21 15l-5-5L5 21"/>
        </svg>
        Choose an image
      </button>
      <input type="file" id="capFileCamera" accept="image/*" capture="environment" class="hidden">
      <input type="file" id="capFileGallery" accept="image/*" class="hidden">
    </div>

    <div class="card hidden" id="capPreviewCard">
      <img id="capPreview" alt="Selected film"
           style="width:100%; max-height:46dvh; object-fit:contain; background:#000; border-radius:14px; display:block;">
      <p class="muted" style="font-size:13px; text-align:center; margin:10px 0 14px;" id="capMeta"></p>
      <button class="btn primary block" id="capBtnSend">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"
             stroke-linecap="round" stroke-linejoin="round">
          <path d="M22 2L11 13"/><path d="M22 2l-7 20-4-9-9-4z"/>
        </svg>
        Send to the kiosk
      </button>
      <button class="btn block" id="capBtnRetake" style="margin-bottom:0;">Pick a different image</button>
    </div>

    <div class="card hidden" id="capDoneCard" style="text-align:center;">
      <div style="width:76px;height:76px;margin:4px auto 16px;border-radius:50%;background:rgba(46,125,50,.12);display:grid;place-items:center;">
        <svg viewBox="0 0 24 24" fill="none" stroke="#2E7D32" stroke-width="2.5"
             stroke-linecap="round" stroke-linejoin="round" style="width:38px;height:38px;">
          <path d="M20 6L9 17l-5-5"/>
        </svg>
      </div>
      <h2>Film sent</h2>
      <p class="muted" style="margin-top:8px;">
        The kiosk is screening it now. You can put your phone away and watch the
        kiosk screen.
      </p>
    </div>

    <p class="disclaimer">
      AI-assisted screening, not a diagnosis. A licensed clinician reviews every
      result.
    </p>
  </div>
</div>

<!-- X-ray upload prompt: opens itself when the kiosk reaches the X-ray station.
     Upload only. The QR belongs on the kiosk screen, where a phone can see it -
     putting one here asked the clinician to scan their own monitor. -->
<div class="modal-backdrop" id="xrayModal" role="dialog" aria-modal="true" aria-labelledby="xrayModalHeader">
  <div class="modal-card">
    <div class="modal-head">
      <div>
        <p class="eyebrow">Station active</p>
        <h3 id="xrayModalHeader">Upload a chest film</h3>
      </div>
      <button class="btn sm icon-btn" onclick="closeXrayModal(true)" aria-label="Close">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2"
             stroke-linecap="round"><path d="M18 6L6 18M6 6l12 12"/></svg>
      </button>
    </div>
    <p class="muted" style="font-size:14px; margin:10px 0 16px;">
      The kiosk is on the X-ray station. The film is sent straight there, screened
      with the local AI model, and the result appears on the kiosk screen.
    </p>

    <div class="dropzone" id="xrayDrop">
      <svg viewBox="0 0 24 24" fill="none" stroke="var(--text-secondary)" stroke-width="1.6"
           stroke-linecap="round" stroke-linejoin="round"
           style="width:40px;height:40px;margin-bottom:10px;">
        <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/>
        <path d="M17 8l-5-5-5 5"/><path d="M12 3v13"/>
      </svg>
      <div style="font-weight:800; font-size:15px;">Choose a film, or drop one here</div>
      <div class="muted" style="font-size:13px; margin-top:6px;">PNG or JPEG, up to 10 MB</div>
      <input type="file" id="xrayFileInput" accept="image/*" class="hidden" onchange="handleXrayUpload(event)">
    </div>

    <button class="btn primary block" style="margin-top:14px;" id="xrayPickBtn">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"
           stroke-linecap="round" stroke-linejoin="round">
        <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/>
        <path d="M17 8l-5-5-5 5"/><path d="M12 3v13"/>
      </svg>
      Select film
    </button>

    <details style="margin-top:14px;">
      <summary style="cursor:pointer; font-size:13.5px; font-weight:700; color:var(--text-secondary);">
        Photographing a film
      </summary>
      <div class="sunken" style="margin-top:10px;">
        <ul class="guide-list" style="margin-top:0;">
          <li>Hold the camera parallel to the lightbox.</li>
          <li>Include both lung apices and the costophrenic angles.</li>
          <li>Turn the flash off to avoid glare on the film.</li>
        </ul>
      </div>
    </details>
  </div>
</div>

<div id="toast" role="status" aria-live="polite"></div>
<script>
const BASE = window.location.origin;
let currentPatient = null;
let currentToken = null;
let currentView = 'session';
let sessionActive = false;
let showHeatmap = true;
let uploadTab = 'qr';
let currentKioskStation = 'idle';
/* The kiosk-status poll runs every 2.5s and re-applies session state. Without
   these two guards it would (a) rewrite every node 24x/minute and (b) reopen the
   X-ray modal the moment the user closed it, making the close button useless. */
let lastSessionUiKey = null;
let xrayModalUserClosed = false;
/* Last X-ray prompt the kiosk asked for. A bump means "open it now", which
   overrides a dismissal — the clinician at the kiosk just pressed the button. */
let lastXrayPromptSeq = null;
/* Capture session live at the kiosk's X-ray station, published by the kiosk over
   the event hub. A film posted into it lands on the kiosk, which analyses it and
   shows the result on the station screen. */
let kioskXraySid = null;

const DASH = '—';

/* Read a response as JSON without assuming it is JSON.
   Error responses are not always JSON — a 500 carries an HTML page, some
   rejections carry an empty body — and calling res.json() on those throws a
   SyntaxError that masks the real failure. Returns {ok, data, error}. */
async function readJson(res) {
  const text = await res.text().catch(() => '');
  let data = null;
  if (text) {
    try { data = JSON.parse(text); } catch (e) { data = null; }
  }
  if (res.ok && data !== null) return {ok: true, data, error: null};
  const detail = data && (data.detail || data.message);
  return {
    ok: res.ok,
    data,
    error: detail
      || (res.ok ? 'The server sent a malformed reply.'
                 : `Server error ${res.status}${res.statusText ? ' - ' + res.statusText : ''}.`),
  };
}

function show(el, visible) {
  const node = typeof el === 'string' ? document.getElementById(el) : el;
  if (node) node.classList.toggle('hidden', !visible);
}

/* A reading is only real if it is a finite positive number. `|| fallback` would
   turn a missing or zero value into a plausible vital sign, which is exactly what
   a screening record must never display. */
function realNum(v) {
  const n = Number(v);
  return Number.isFinite(n) && n > 0 ? n : null;
}

function fmtStamp(raw) {
  if (!raw) return '';
  const d = new Date(String(raw).replace(' ', 'T') + (String(raw).endsWith('Z') ? '' : 'Z'));
  if (isNaN(d.getTime())) return String(raw);
  return d.toLocaleString(undefined, {
    year: 'numeric', month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit'
  });
}

// -- View navigation --------------------------------------------------------
function navigateTo(view) {
  if (!currentPatient) return;
  currentView = view;
  document.getElementById('tabNavSession').classList.toggle('active', view === 'session');
  document.getElementById('tabNavRecords').classList.toggle('active', view === 'records');
  show('sessionView', view === 'session');
  show('recordsView', view === 'records');
  if (view === 'records') loadRecordsData();
}

// -- Authentication ---------------------------------------------------------
function switchAuthMode(mode) {
  document.getElementById('authTabLogin').classList.toggle('active', mode === 'login');
  document.getElementById('authTabRegister').classList.toggle('active', mode === 'register');
  show('loginForm', mode === 'login');
  show('registerForm', mode === 'register');
}

async function handleLogin(e) {
  e.preventDefault();
  const email = document.getElementById('loginEmail').value;
  const password = document.getElementById('loginPass').value;
  try {
    const res = await fetch(BASE + '/api/web/auth/login', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({email, password})
    });
    const {ok, data, error} = await readJson(res);
    if (!ok || !data) throw new Error(error);
    onLoginSuccess(data.patient, data.token);
  } catch (err) {
    showToast(err.message);
  }
}

async function handleRegister(e) {
  e.preventDefault();
  const name = document.getElementById('regName').value;
  const email = document.getElementById('regEmail').value;
  const password = document.getElementById('regPass').value;
  const dob = document.getElementById('regDob').value;
  const sex = document.getElementById('regSex').value;
  try {
    const res = await fetch(BASE + '/api/web/auth/register', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({name, email, password, dob, sex})
    });
    const {ok, data, error} = await readJson(res);
    if (!ok || !data) throw new Error(error);
    onLoginSuccess(data.patient, data.token);
  } catch (err) {
    showToast(err.message);
  }
}

async function handleDemoLogin() {
  try {
    const res = await fetch(BASE + '/api/web/auth/demo', { method: 'POST' });
    const {ok, data, error} = await readJson(res);
    if (!ok || !data) throw new Error(error);
    onLoginSuccess(data.patient, data.token);
  } catch (err) {
    showToast('Demo login failed: ' + err.message);
  }
}

function onLoginSuccess(patient, token) {
  currentPatient = patient;
  currentToken = token;
  localStorage.setItem('xs_patient', JSON.stringify(patient));
  localStorage.setItem('xs_token', token);

  show('authView', false);
  show('appNavTabs', true);
  show('logoutBtn', true);

  populatePatientInfo();
  navigateTo('session');
  showToast('Signed in as ' + patient.name);
}

function logout() {
  currentPatient = null;
  currentToken = null;
  localStorage.removeItem('xs_patient');
  localStorage.removeItem('xs_token');

  show('authView', true);
  show('sessionView', false);
  show('recordsView', false);
  show('appNavTabs', false);
  show('logoutBtn', false);
  closeXrayModal();
  showToast('Signed out.');
}

function populatePatientInfo() {
  if (!currentPatient) return;
  const bits = [currentPatient.sex, currentPatient.dob].filter(Boolean);
  const meta = bits.length ? bits.join(' · ') : 'No profile details';
  const mrn = 'MRN-' + (10000 + currentPatient.id);

  document.getElementById('sessPatName').textContent = currentPatient.name;
  document.getElementById('sessPatId').textContent = mrn;
  document.getElementById('sessPatMeta').textContent = meta;

  document.getElementById('recPatName').textContent = currentPatient.name;
  document.getElementById('recPatMrn').textContent = mrn;
  document.getElementById('recPatMeta').textContent = meta;
}

// -- Remote session controls ------------------------------------------------
async function triggerStartSession() {
  if (!currentPatient) return;
  showToast('Sending session to the kiosk…');
  try {
    const res = await fetch(BASE + '/api/web/kiosk/trigger-session', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({
        patient: {
          id: currentPatient.id,
          name: currentPatient.name,
          dob: currentPatient.dob,
          sex: currentPatient.sex,
          phone: currentPatient.phone
        }
      })
    });
    const {ok, data, error} = await readJson(res);
    if (!ok) throw new Error(error);
    setSessionUiState(true);
    // A new session must not show the previous one's summary — hide it the
    // moment the session starts rather than waiting for the next poll tick.
    show('sessionSummaryCard', false);
    showToast((data && data.message) || 'Session sent. Waiting for the kiosk to accept.');
  } catch (e) {
    showToast('Could not start session: ' + e.message);
  }
}

async function triggerStopSession() {
  showToast('Ending session…');
  try {
    const res = await fetch(BASE + '/api/web/kiosk/stop-session', { method: 'POST' });
    const {ok, data, error} = await readJson(res);
    if (!ok) throw new Error(error);
    xrayModalUserClosed = false;
    setSessionUiState(false);
    closeXrayModal();
    if (currentView === 'records') loadRecordsData();
    /* The kiosk files the visit summary a moment AFTER it receives the stop,
       so fetch immediately and again shortly after — the "Last screening"
       card must appear on its own, not after a browser restart. The regular
       2.5 s poll keeps covering anything these two miss. */
    pollLatestVisit();
    setTimeout(pollLatestVisit, 2000);
    setTimeout(pollLatestVisit, 5000);
    showToast((data && data.message) || 'Kiosk returned to guest mode.');
  } catch (e) {
    showToast('Could not stop session: ' + e.message);
  }
}

const STATIONS = {
  vitals: ['stVitals', 'Measuring pulse and SpO₂'],
  temp:   ['stTemp',   'Reading skin temperature'],
  steth:  ['stLungs',  'Listening to breath sounds'],
  xray:   ['stXray',   'Waiting for a film'],
};

function setSessionUiState(active, station = 'idle') {
  // Reopening the modal is keyed on leaving the station, so clear the manual
  // dismissal as soon as the kiosk moves elsewhere.
  if (station !== 'xray') xrayModalUserClosed = false;

  const key = active + '|' + station;
  if (key === lastSessionUiKey) return;
  lastSessionUiKey = key;

  sessionActive = active;
  currentKioskStation = station;
  const badge = document.getElementById('sessionStatusBadge');
  const heading = document.getElementById('sessionHeading');
  const subtext = document.getElementById('sessionSubtext');

  if (active) {
    badge.className = 'badge active';
    badge.textContent = station === 'idle'
      ? 'Session active on kiosk'
      : 'Session active · ' + station.toUpperCase() + ' station';
    heading.textContent = 'Screening in progress';
    subtext.textContent = 'This patient profile is live on the kiosk. Readings attach to '
      + 'their record as each station finishes. Stop the session to return the kiosk to guest mode.';
  } else {
    badge.className = 'badge standby';
    badge.textContent = 'Kiosk standby · ready to start';
    heading.textContent = 'Start a screening session';
    subtext.textContent = 'Start sends this patient profile to the kiosk tablet. The kiosk asks '
      + 'the person in front of it to accept before any reading is taken.';
  }
  show('btnStartSession', !active);
  show('btnStopSession', active);

  Object.values(STATIONS).forEach(([id]) => {
    document.getElementById(id).classList.remove('active');
    document.getElementById(id + 'Val').textContent = 'Idle';
  });

  const hit = STATIONS[station];
  if (hit) {
    document.getElementById(hit[0]).classList.add('active');
    document.getElementById(hit[0] + 'Val').textContent = hit[1];
  }

  if (station === 'xray') {
    if (!xrayModalUserClosed) openXrayModal();
  } else {
    closeXrayModal();
  }
}

// -- Records: history list ---------------------------------------------------
let visits = [];
let openVisit = null;
let showHeatmapPref = true;

const MEASURE_LABEL = {
  hr: 'Heart rate', spo2: 'SpO₂', temp: 'Skin temp',
  rr: 'Respiration', lung: 'Breath sounds', xray: 'Radiograph',
};

function riskClass(risk) {
  const r = String(risk || '');
  if (/high|urgent|severe/i.test(r)) return 'alert';
  if (/moderate|medium/i.test(r)) return 'warn';
  if (/low|normal/i.test(r)) return 'ok';
  return 'standby';
}

/* Latest genuine value of `field` across all visits, newest first. */
function latestVital(field) {
  for (const v of visits) {
    for (const row of v.vitals) {
      const n = realNum(row[field]);
      if (n !== null) return {value: n, at: row.recorded_at};
    }
  }
  return null;
}

function renderSummaryStrip() {
  const rows = [
    ['valHr', 'hr', n => String(Math.round(n))],
    ['valSpo2', 'spo2', n => n.toFixed(1)],
    ['valTemp', 'temp', n => n.toFixed(1)],
  ];
  for (const [id, field, fmt] of rows) {
    const hit = latestVital(field);
    document.getElementById(id).textContent = hit ? fmt(hit.value) : DASH;
    const sub = document.getElementById(id + 'Sub');
    if (!sub) continue;
    if (!hit) {
      sub.textContent = 'No reading on record';
    } else if (field === 'temp') {
      sub.textContent = 'Fingertip sensor · not core temperature';
    } else {
      sub.textContent = 'Recorded ' + fmtStamp(hit.at);
    }
  }

  const films = visits.reduce((n, v) => n + v.xrays.length, 0);
  document.getElementById('valFilms').textContent = films === 0 ? DASH : String(films);
  document.getElementById('valFilmsSub').textContent = films === 0
    ? 'No radiograph on record'
    : films + (films === 1 ? ' film screened' : ' films screened');
}

function visitCard(visit, index) {
  const card = document.createElement('button');
  card.className = 'visit-card';
  card.type = 'button';
  card.onclick = () => showVisit(index);

  const left = document.createElement('div');
  const when = document.createElement('div');
  when.className = 'visit-when';
  when.textContent = fmtStamp(visit.started_at) || 'Undated';
  left.appendChild(when);

  const head = document.createElement('div');
  head.className = 'visit-headline';
  head.textContent = visit.headline || 'Kiosk visit';
  left.appendChild(head);

  const chips = document.createElement('div');
  chips.className = 'visit-chips';
  if (visit.measured.length === 0) {
    const none = document.createElement('span');
    none.className = 'chip-tag';
    none.textContent = 'No readings';
    chips.appendChild(none);
  }
  for (const tag of visit.measured) {
    const chip = document.createElement('span');
    chip.className = 'chip-tag';
    chip.textContent = MEASURE_LABEL[tag] || tag;
    chips.appendChild(chip);
  }
  left.appendChild(chips);
  card.appendChild(left);

  const right = document.createElement('div');
  right.className = 'visit-right';
  if (visit.risk_level) {
    const badge = document.createElement('span');
    badge.className = 'badge ' + riskClass(visit.risk_level);
    badge.textContent = visit.risk_level;
    right.appendChild(badge);
  }
  const chevron = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  chevron.setAttribute('viewBox', '0 0 24 24');
  chevron.setAttribute('fill', 'none');
  chevron.setAttribute('stroke', 'currentColor');
  chevron.setAttribute('stroke-width', '2.2');
  chevron.setAttribute('class', 'visit-chevron');
  const path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
  path.setAttribute('d', 'M9 18l6-6-6-6');
  chevron.appendChild(path);
  right.appendChild(chevron);
  card.appendChild(right);
  return card;
}

function renderVisitList() {
  const wrap = document.getElementById('visitList');
  wrap.textContent = '';
  if (visits.length === 0) {
    const card = document.createElement('div');
    card.className = 'card';
    const p = document.createElement('p');
    p.className = 'empty-note';
    p.textContent = 'Nothing recorded yet. Start a session on the kiosk and '
      + 'readings will appear here.';
    card.appendChild(p);
    wrap.appendChild(card);
    return;
  }
  visits.forEach((v, i) => wrap.appendChild(visitCard(v, i)));
}

async function loadRecordsData() {
  if (!currentPatient) return;
  try {
    const res = await fetch(BASE + '/api/web/patient/history?patient_id=' + currentPatient.id);
    const {ok, data, error} = await readJson(res);
    if (!ok || !data) throw new Error(error);
    visits = Array.isArray(data.visits) ? data.visits : [];
    renderSummaryStrip();
    renderVisitList();
    // Keep an open visit in sync with the refreshed data rather than closing it.
    if (openVisit !== null && visits[openVisit]) showVisit(openVisit);
  } catch (e) {
    showToast('Could not load the record: ' + e.message);
  }
}

// -- Records: one visit, as a full page --------------------------------------
function closeVisit() {
  openVisit = null;
  show('visitPane', false);
  show('historyPane', true);
  window.scrollTo({top: 0, behavior: 'smooth'});
}

function vitalTile(label, value, unit, sub) {
  const box = document.createElement('div');
  box.className = 'vital-box';
  const t = document.createElement('div');
  t.className = 'vital-title'; t.textContent = label;
  const n = document.createElement('div');
  n.className = 'vital-num'; n.textContent = value;
  if (unit) {
    const u = document.createElement('span');
    u.className = 'unit'; u.textContent = ' ' + unit;
    n.appendChild(u);
  }
  const s = document.createElement('div');
  s.className = 'vital-sub'; s.textContent = sub;
  box.append(t, n, s);
  return box;
}

function renderVisitVitals(visit) {
  const grid = document.getElementById('vdVitals');
  grid.textContent = '';
  const row = visit.vitals[0];
  const specs = [
    ['Heart rate', 'hr', 'bpm', n => String(Math.round(n)), 'Pulse oximeter'],
    ['Oxygen saturation', 'spo2', '%', n => n.toFixed(1), 'Pulse oximeter'],
    ['Skin temperature', 'temp', '°C', n => n.toFixed(1),
     'Fingertip sensor · not core temperature'],
    ['Respiration rate', 'rr', '/min', n => String(Math.round(n)),
     'Not measured at this kiosk'],
  ];
  let shown = 0;
  for (const [label, field, unit, fmt, sub] of specs) {
    const n = row ? realNum(row[field]) : null;
    if (n === null) continue;              // absent readings are simply absent
    grid.appendChild(vitalTile(label, fmt(n), unit, sub));
    shown++;
  }
  if (shown === 0) {
    const card = document.createElement('div');
    card.className = 'card';
    card.style.gridColumn = '1 / -1';
    const p = document.createElement('p');
    p.className = 'empty-note';
    p.textContent = 'No vital signs were recorded during this visit.';
    card.appendChild(p);
    grid.appendChild(card);
  }
}

function renderVisitLung(visit) {
  const l = visit.lung_sounds[0];
  const badge = document.getElementById('recLungBadge');
  const title = document.getElementById('recLungTitle');
  const desc = document.getElementById('recLungDesc');
  if (!l || !l.label) {
    badge.className = 'badge standby';
    badge.textContent = 'No recording';
    title.textContent = 'Not recorded';
    desc.textContent = 'The stethoscope station was not used during this visit.';
    return;
  }
  const label = String(l.label);
  const normal = /normal|clear|vesicular/i.test(label);
  badge.className = 'badge ' + (normal ? 'ok' : 'warn');
  badge.textContent = label;
  title.textContent = normal ? 'Normal breath sounds' : 'Finding: ' + label;
  const bits = [];
  const conf = realNum(l.confidence);
  if (conf !== null) bits.push('Model confidence ' + Math.round(conf * 100) + '%');
  if (l.created_at) bits.push('recorded ' + fmtStamp(l.created_at));
  desc.textContent = (bits.length ? bits.join(' · ') + '. ' : '')
    + 'Screening aid only — confirm by auscultation.';
}

async function renderVisitXray(visit) {
  const x = visit.xrays[0];
  const badge = document.getElementById('vdXrayBadge');
  const diag = document.getElementById('xrayDiag');
  const notes = document.getElementById('xrayNotes');
  const heat = document.getElementById('xrayHeatmapImg');

  show('xrayStack', false);
  show('xrayControls', false);
  show('xrayEmpty', true);

  if (!x) {
    badge.className = 'badge standby';
    badge.textContent = 'No film';
    diag.textContent = 'No film';
    notes.textContent = 'No film was submitted during this visit.';
    document.getElementById('xrayEmpty').textContent = 'No radiograph film on record.';
    return;
  }

  const pred = x.prediction ? String(x.prediction) : 'Unclassified';
  const conf = realNum(x.confidence);
  const normal = /normal|clear|no finding/i.test(pred);
  badge.className = 'badge ' + (conf === null ? 'standby' : normal ? 'ok' : 'warn');
  badge.textContent = conf === null ? pred : Math.round(conf * 100) + '% · ' + pred;
  diag.textContent = pred;
  const bits = [];
  if (x.created_at) bits.push('Captured ' + fmtStamp(x.created_at));
  if (conf === null) bits.push('no local screening model was available, so the film was stored unclassified');
  notes.textContent = bits.join('. ')
    + (bits.length ? '. ' : '')
    + 'AI-assisted screening, not a diagnosis — requires radiologist review.';

  if (!x.has_image) {
    document.getElementById('xrayEmpty').textContent =
      'The film was recorded but no preview is stored.';
    return;
  }

  // The list omits blobs; fetch just this film's preview.
  try {
    const res = await fetch(BASE + '/api/web/patient/xray-image?patient_id='
      + currentPatient.id + '&xray_id=' + x.id);
    const {ok, data} = await readJson(res);
    if (!ok || !data || !data.image_path) throw new Error('no preview');
    document.getElementById('xrayBaseImg').src = data.image_path;
    show('xrayStack', true);
    show('xrayEmpty', false);
    if (data.heatmap_b64) {
      heat.src = 'data:image/png;base64,' + data.heatmap_b64;
      show(heat, true);
      show('xrayControls', true);
      showHeatmapPref = true;
      heat.style.opacity = '0.85';
      document.getElementById('btnToggleHeat').textContent = 'Hide AI heatmap';
    } else {
      show(heat, false);
    }
  } catch (e) {
    document.getElementById('xrayEmpty').textContent = 'The film preview could not be loaded.';
  }
}

function renderVisitAssessment(visit) {
  const dl = document.getElementById('vdAssess');
  dl.textContent = '';
  const c = visit.consultations[0];
  const rows = [];
  if (c) {
    if (c.diagnosis) rows.push(['Impression', c.diagnosis]);
    if (c.summary) rows.push(['Summary', c.summary]);
    if (c.recommendations) rows.push(['Recommendation', c.recommendations]);
    if (c.risk_level) rows.push(['Risk level', c.risk_level]);
    if (c.physician) rows.push(['Recorded by', c.physician]);
  }
  if (rows.length === 0) {
    const p = document.createElement('p');
    p.className = 'empty-note';
    p.textContent = 'No assessment was written for this visit.';
    dl.appendChild(p);
    return;
  }
  for (const [k, v] of rows) {
    const row = document.createElement('div');
    row.className = 'kv-row';
    const dt = document.createElement('dt'); dt.textContent = k;
    const dd = document.createElement('dd'); dd.textContent = v;
    row.append(dt, dd);
    dl.appendChild(row);
  }
}

function showVisit(index) {
  const visit = visits[index];
  if (!visit) return;
  openVisit = index;

  document.getElementById('vdWhen').textContent = fmtStamp(visit.started_at) || 'Undated';
  document.getElementById('vdHeadline').textContent = visit.headline || 'Kiosk visit';
  const counts = [];
  if (visit.vitals.length) counts.push('vital signs');
  if (visit.lung_sounds.length) counts.push(visit.lung_sounds.length + ' breath recording'
    + (visit.lung_sounds.length === 1 ? '' : 's'));
  if (visit.xrays.length) counts.push(visit.xrays.length + ' film'
    + (visit.xrays.length === 1 ? '' : 's'));
  document.getElementById('vdWho').textContent = counts.length
    ? 'This visit recorded ' + counts.join(', ') + '.'
    : 'No readings were recorded during this visit.';

  const risk = document.getElementById('vdRisk');
  risk.className = 'badge ' + riskClass(visit.risk_level);
  risk.textContent = visit.risk_level || 'No assessment';

  renderVisitVitals(visit);
  renderVisitLung(visit);
  renderVisitAssessment(visit);
  renderVisitXray(visit);

  show('historyPane', false);
  show('visitPane', true);
  window.scrollTo({top: 0, behavior: 'smooth'});
}

function toggleHeatmap() {
  showHeatmapPref = !showHeatmapPref;
  const h = document.getElementById('xrayHeatmapImg');
  if (h) h.style.opacity = showHeatmapPref ? '0.85' : '0';
  document.getElementById('btnToggleHeat').textContent =
    showHeatmapPref ? 'Hide AI heatmap' : 'Show AI heatmap';
}

// -- X-ray upload prompt -----------------------------------------------------
/* The kiosk's "ask the web portal" button lands here on the next poll tick. */
function handleXrayPrompt(seq) {
  const n = Number(seq);
  if (!Number.isFinite(n)) return;
  if (lastXrayPromptSeq === null) {
    lastXrayPromptSeq = n;   // first sight: adopt without popping
    return;
  }
  if (n === lastXrayPromptSeq) return;
  lastXrayPromptSeq = n;
  xrayModalUserClosed = false;
  openXrayModal();
}

function openXrayModal() {
  document.getElementById('xrayModal').classList.add('open');
}

function closeXrayModal(byUser) {
  if (byUser) xrayModalUserClosed = true;
  document.getElementById('xrayModal').classList.remove('open');
}

async function handleXrayUpload(e) {
  const file = e.target.files[0];
  if (!file || !currentPatient) return;
  if (!String(file.type).startsWith('image/')) {
    showToast('That file is not an image.');
    e.target.value = '';
    return;
  }
  if (file.size > 10 * 1048576) {
    showToast('That film is over 10 MB. Use a smaller image.');
    e.target.value = '';
    return;
  }

  const body = new FormData();
  body.append('file', file, file.name || 'film.jpg');

  /* Into the kiosk's live capture session, the same door the phone uses. The
     kiosk holds a socket on it, so the film is analysed and displayed *at the
     station* — posting straight to the record instead would file a result the
     clinician standing at the kiosk never sees. */
  if (kioskXraySid) {
    showToast('Sending the film to the kiosk…');
    try {
      const res = await fetch(
        BASE + '/handoff/session/' + encodeURIComponent(kioskXraySid) + '/film',
        {method: 'POST', body});
      if (res.status === 404) {
        // The station moved on or the code expired. Fall through to the record.
        kioskXraySid = null;
      } else {
        const {ok, error} = await readJson(res);
        if (!ok) throw new Error(error);
        showToast('Sent. The kiosk is screening it now — watch the kiosk screen.');
        closeXrayModal();
        e.target.value = '';
        return;
      }
    } catch (err) {
      showToast('Could not reach the kiosk: ' + err.message);
      e.target.value = '';
      return;
    }
  }

  /* No station waiting for a film: attach it to the record instead, and say so,
     rather than silently doing something different from what was asked. */
  showToast('No kiosk station is waiting. Filing to the record instead…');
  try {
    const res = await fetch(BASE + '/api/web/patient/xray?patient_id=' + currentPatient.id,
      {method: 'POST', body});
    const {ok, data, error} = await readJson(res);
    if (!ok || !data) throw new Error(error);
    const conf = realNum(data.confidence);
    showToast('Filed to the record · ' + data.prediction + (conf === null
      ? ' (not classified — no local model)'
      : ' · ' + Math.round(conf * 100) + '%'));
    closeXrayModal();
    if (currentView === 'records') loadRecordsData();
  } catch (err) {
    showToast('Upload failed: ' + err.message);
  } finally {
    e.target.value = '';
  }
}

// -- Live readings during a session -------------------------------------------
/* The kiosk files each reading to the record as its station finishes, so the
   newest visit IS the live session. Polling it (limit=1 keeps the payload
   tiny) lets the station tracker show actual values instead of "Idle", and
   surfaces the AI summary the moment the kiosk files it at session end. */
let latestVisit = null;

function fillStationReadings() {
  if (!latestVisit) return;
  /* Only a genuinely active session owns the station tracker. In standby the
     same values read as "a session happened by itself" — they are the last
     recorded visit, and that belongs in the clearly-dated summary card
     below, not in what looks like a live session view. */
  if (!sessionActive) {
    document.getElementById('ssWhen').textContent =
      latestVisit.started_at ? 'Last screening · ' + fmtStamp(latestVisit.started_at)
                             : 'Last screening';
    const c0 = latestVisit.consultations[0];
    const card = document.getElementById('sessionSummaryCard');
    if (c0) {
      show(card, true);
      const risk = document.getElementById('ssRisk');
      risk.className = 'badge ' + riskClass(c0.risk_level);
      risk.textContent = c0.risk_level || 'No assessment';
      document.getElementById('ssImpression').textContent =
        c0.diagnosis || 'Screening summary';
      document.getElementById('ssSummary').textContent = c0.summary || '';
    } else {
      show(card, false);
    }
    return;
  }
  // Active: this session's own summary is written when it ENDS. The previous
  // session's summary must not sit here reading like it belongs to this one,
  // so the card is simply hidden for the duration of the session.
  show('sessionSummaryCard', false);

  // A station that already has a reading shows it even while active — the
  // kiosk sitting on the X-ray station after a film was screened used to pin
  // the tracker at "Waiting for a film" forever.
  const hit = STATIONS[currentKioskStation];
  const activeId = hit ? hit[0] : null;
  const setVal = (id, text, hasReading) => {
    if (id === activeId && !hasReading) return;  // keep the live instruction
    document.getElementById(id).textContent = text;
  };

  const withVital = (field) =>
    latestVisit.vitals.find(r => realNum(r[field]) !== null);
  const vRow = withVital('hr') || withVital('spo2');
  if (vRow) {
    const hr = realNum(vRow.hr), sp = realNum(vRow.spo2);
    const parts = [];
    if (hr !== null) parts.push('HR ' + Math.round(hr) + ' bpm');
    if (sp !== null) parts.push('SpO₂ ' + Math.round(sp) + '%');
    setVal('stVitalsVal', parts.join(' · '), true);
  }

  const tRow = withVital('temp');
  if (tRow) setVal('stTempVal', realNum(tRow.temp).toFixed(1) + ' °C', true);

  const lung = latestVisit.lung_sounds[0];
  if (lung && lung.label) setVal('stLungsVal', String(lung.label), true);

  const x = latestVisit.xrays[0];
  if (x && x.prediction) setVal('stXrayVal', String(x.prediction), true);
}

async function pollLatestVisit() {
  if (!currentPatient) return;
  try {
    const res = await fetch(BASE + '/api/web/patient/history?patient_id='
      + currentPatient.id + '&limit=1');
    const {ok, data} = await readJson(res);
    if (!ok || !data) return;
    latestVisit = (data.visits && data.visits[0]) || null;
    fillStationReadings();
  } catch (e) { /* transient LAN blip - the next tick recovers */ }
}

// -- Kiosk status poll ------------------------------------------------------
async function pollKioskStatus() {
  try {
    const res = await fetch(BASE + '/handoff/status');
    if (!res.ok) return;
    const data = await res.json();
    const online = (data.kiosks_online || 0) > 0;
    const state = data.kiosk_state || {};
    const dot = document.getElementById('beaconDot');
    const text = document.getElementById('beaconText');

    if (!online) {
      dot.className = 'beacon-dot';
      text.textContent = 'Kiosk: offline';
      kioskXraySid = null;
      // An offline kiosk cannot be mid-session. Leaving the optimistic "active"
      // state from triggerStartSession() up produced the contradiction of a
      // screen reading "Session active" beside a beacon reading "offline".
      setSessionUiState(false);
      closeXrayModal();
    } else if (state.active) {
      dot.className = 'beacon-dot active';
      text.textContent = 'Kiosk: active' + (state.station ? ' · ' + state.station : '');
      setSessionUiState(true, state.station || 'idle');
      kioskXraySid = state.xray_sid || null;
      handleXrayPrompt(state.xray_prompt_seq);
    } else {
      dot.className = 'beacon-dot online';
      text.textContent = 'Kiosk: standby';
      // Trust the server's view even when idle: it resolves the sid from the
      // capture session it minted, so a station that is armed but has not
      // announced itself is still reachable.
      kioskXraySid = state.xray_sid || null;
      setSessionUiState(false);
    }
    // Latest readings ride the same 2.5 s cadence: values fill in as stations
    // finish, and the AI summary appears when the kiosk files it.
    pollLatestVisit();
  } catch (e) { /* transient LAN blip - the next tick recovers */ }
}

function showToast(msg) {
  const t = document.getElementById('toast');
  t.textContent = msg;
  t.classList.add('show');
  clearTimeout(showToast._t);
  showToast._t = setTimeout(() => t.classList.remove('show'), 3600);
}

// -- Phone capture route (#/xray-upload?sid=…) ------------------------------
// A phone that scanned the kiosk QR lands here. It is a separate mode, not a
// tab: there is no sign-in and none of the portal chrome applies, so the router
// runs before the session restore and returns early.
let capSid = null;
let capFile = null;
let capPreviewUrl = null;

function isCaptureRoute() {
  return (location.hash || '').startsWith('#/xray-upload');
}

function capStatus(text, kind) {
  const box = document.getElementById('capStatus');
  show(box, Boolean(text));
  document.getElementById('capStatusText').textContent = text || '';
  show('capSpinner', kind === 'busy');
  box.style.color = kind === 'err' ? 'var(--red)'
    : kind === 'ok' ? 'var(--green)' : 'var(--text-secondary)';
}

function capSetFile(file) {
  if (!file) return;
  if (!String(file.type).startsWith('image/')) {
    capStatus('That file is not an image. Pick a photo of the film.', 'err');
    return;
  }
  // 10 MB is the server's MAX_FILM_BYTES; rejecting here saves a phone on clinic
  // Wi-Fi from a doomed upload.
  if (file.size > 10 * 1024 * 1024) {
    capStatus('That image is over 10 MB. Retake it at a lower resolution.', 'err');
    return;
  }
  capFile = file;
  if (capPreviewUrl) URL.revokeObjectURL(capPreviewUrl);
  capPreviewUrl = URL.createObjectURL(file);
  document.getElementById('capPreview').src = capPreviewUrl;
  document.getElementById('capMeta').textContent =
    (file.size / 1048576).toFixed(1) + ' MB · ' + (file.type.split('/')[1] || 'image').toUpperCase();
  capStatus('');
  show('capPickCard', false);
  show('capPreviewCard', true);
}

function capReset() {
  capFile = null;
  if (capPreviewUrl) { URL.revokeObjectURL(capPreviewUrl); capPreviewUrl = null; }
  document.getElementById('capFileCamera').value = '';
  document.getElementById('capFileGallery').value = '';
  show('capPreviewCard', false);
  show('capPickCard', true);
  capStatus('');
}

async function capSend() {
  if (!capFile || !capSid) return;
  const btn = document.getElementById('capBtnSend');
  btn.disabled = true;
  capStatus('Sending to the kiosk…', 'busy');

  const body = new FormData();
  body.append('file', capFile, capFile.name || 'film.jpg');
  try {
    const res = await fetch(BASE + '/handoff/session/' + encodeURIComponent(capSid) + '/film', {
      method: 'POST',
      body
    });
    const {ok, error} = await readJson(res);
    if (res.status === 404) {
      capStatus('That code has expired. Press the X-ray station button on the '
        + 'kiosk for a fresh code.', 'err');
      btn.disabled = false;
      return;
    }
    if (!ok) throw new Error(error);

    show('capPreviewCard', false);
    show('capPickCard', false);
    show('capDoneCard', true);
    capStatus('');
  } catch (e) {
    capStatus('Could not reach the kiosk: ' + e.message
      + '. Check you are on the same Wi-Fi.', 'err');
    btn.disabled = false;
  }
}

function startCaptureRoute() {
  // sid lives after the ? inside the hash, so URLSearchParams needs the slice.
  const q = (location.hash || '').split('?')[1] || '';
  capSid = new URLSearchParams(q).get('sid');

  show('appNavTabs', false);
  show('logoutBtn', false);
  show('authView', false);
  show('sessionView', false);
  show('recordsView', false);
  show('captureView', true);
  document.querySelector('.beacon-pill').classList.add('hidden');

  if (!capSid) {
    show('capPickCard', false);
    capStatus('This link is incomplete. Scan the QR on the kiosk again.', 'err');
    return;
  }

  document.getElementById('capBtnCamera').onclick =
    () => document.getElementById('capFileCamera').click();
  document.getElementById('capBtnGallery').onclick =
    () => document.getElementById('capFileGallery').click();
  document.getElementById('capFileCamera').onchange =
    (e) => capSetFile(e.target.files[0]);
  document.getElementById('capFileGallery').onchange =
    (e) => capSetFile(e.target.files[0]);
  document.getElementById('capBtnSend').onclick = capSend;
  document.getElementById('capBtnRetake').onclick = capReset;
}

// -- Bootstrap -------------------------------------------------------------
window.addEventListener('DOMContentLoaded', () => {
  if (isCaptureRoute()) {
    startCaptureRoute();
    return;   // no portal chrome, no auth, no kiosk polling on a patient's phone
  }

  const saved = localStorage.getItem('xs_patient');
  const token = localStorage.getItem('xs_token');
  if (saved && token) {
    try {
      onLoginSuccess(JSON.parse(saved), token);
    } catch (e) {
      localStorage.removeItem('xs_patient');
      localStorage.removeItem('xs_token');
    }
  }
  document.addEventListener('keydown', (ev) => {
    if (ev.key === 'Escape') {
      if (openVisit !== null && currentView === 'records') closeVisit();
      closeXrayModal(true);
    }
  });

  // Upload prompt: a click anywhere on the drop area, the button, or a dropped
  // file all reach the same input.
  const pick = () => document.getElementById('xrayFileInput').click();
  document.getElementById('xrayPickBtn').onclick = pick;
  const drop = document.getElementById('xrayDrop');
  drop.onclick = pick;
  drop.addEventListener('dragover', (ev) => {
    ev.preventDefault();
    drop.style.outline = '2px dashed var(--teal)';
    drop.style.outlineOffset = '-8px';
  });
  drop.addEventListener('dragleave', () => { drop.style.outline = ''; });
  drop.addEventListener('drop', (ev) => {
    ev.preventDefault();
    drop.style.outline = '';
    const file = ev.dataTransfer && ev.dataTransfer.files && ev.dataTransfer.files[0];
    if (file) handleXrayUpload({target: {files: [file], value: ''}});
  });
  pollKioskStatus();
  setInterval(pollKioskStatus, 2500);
});
</script>
</body>
</html>
"""


@router.get("/web", response_class=HTMLResponse)
@router.get("/web/", response_class=HTMLResponse)
@router.get("/monitor", response_class=HTMLResponse)
async def serve_web_portal():
    """Main Web Portal & Clinical Telemetry Dashboard."""
    return HTMLResponse(content=WEB_APP_HTML)
