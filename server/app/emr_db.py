"""XSIGHT SQLite EMR database layer.

Stores patients, vitals, X-ray results, lung sounds, and consultation records.
No ORM — raw sqlite3 via Python stdlib for zero-dependency deployment.
"""

from __future__ import annotations

import json
import os
import sqlite3
import time
from contextlib import contextmanager
from typing import Any, Optional

DB_PATH = os.getenv("XSIGHT_DB_PATH", "xsight_emr.db")

_conn: Optional[sqlite3.Connection] = None


def _get_conn() -> sqlite3.Connection:
    global _conn
    if _conn is None:
        _conn = sqlite3.connect(DB_PATH, check_same_thread=False)
        _conn.row_factory = sqlite3.Row
        _conn.execute("PRAGMA journal_mode=WAL")
        _conn.execute("PRAGMA foreign_keys=ON")
        _init_schema(_conn)
    return _conn


@contextmanager
def get_db():
    conn = _get_conn()
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise


def _init_schema(conn: sqlite3.Connection):
    conn.executescript("""
    CREATE TABLE IF NOT EXISTS patients (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        name        TEXT NOT NULL,
        dob         TEXT,
        sex         TEXT,
        weight_kg   REAL,
        height_cm   REAL,
        phone       TEXT,
        email       TEXT UNIQUE,
        password_hash TEXT,
        notes       TEXT,
        created_at  TEXT DEFAULT (datetime('now')),
        updated_at  TEXT DEFAULT (datetime('now'))
    );

    CREATE TABLE IF NOT EXISTS vitals (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        patient_id  INTEGER NOT NULL REFERENCES patients(id) ON DELETE CASCADE,
        hr          REAL,
        spo2        REAL,
        temp        REAL,
        rr          REAL,
        sbp         REAL,
        dbp         REAL,
        ecg_hr      REAL,
        ecg_data    TEXT,
        source      TEXT DEFAULT 'manual',
        recorded_at TEXT DEFAULT (datetime('now'))
    );

    CREATE TABLE IF NOT EXISTS xray_results (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        patient_id  INTEGER NOT NULL REFERENCES patients(id) ON DELETE CASCADE,
        image_path  TEXT,
        prediction  TEXT,
        confidence  REAL,
        heatmap_b64 TEXT,
        details     TEXT,
        created_at  TEXT DEFAULT (datetime('now'))
    );

    CREATE TABLE IF NOT EXISTS lung_sounds (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        patient_id  INTEGER NOT NULL REFERENCES patients(id) ON DELETE CASCADE,
        audio_path  TEXT,
        label       TEXT,
        confidence  REAL,
        duration_s  REAL,
        details     TEXT,
        created_at  TEXT DEFAULT (datetime('now'))
    );

    CREATE TABLE IF NOT EXISTS consultations (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        patient_id  INTEGER NOT NULL REFERENCES patients(id) ON DELETE CASCADE,
        physician   TEXT,
        summary     TEXT,
        diagnosis   TEXT,
        recommendations TEXT,
        risk_level  TEXT,
        vitals_snapshot TEXT,
        xray_id     INTEGER REFERENCES xray_results(id),
        lung_id     INTEGER REFERENCES lung_sounds(id),
        created_at  TEXT DEFAULT (datetime('now'))
    );

    CREATE TABLE IF NOT EXISTS notifications (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        patient_id  INTEGER REFERENCES patients(id) ON DELETE SET NULL,
        type        TEXT NOT NULL,
        title       TEXT NOT NULL,
        message     TEXT NOT NULL,
        severity    TEXT DEFAULT 'info',
        read        INTEGER DEFAULT 0,
        created_at  TEXT DEFAULT (datetime('now'))
    );

    CREATE INDEX IF NOT EXISTS idx_vitals_patient ON vitals(patient_id);
    CREATE INDEX IF NOT EXISTS idx_xray_patient ON xray_results(patient_id);
    CREATE INDEX IF NOT EXISTS idx_lung_patient ON lung_sounds(patient_id);
    CREATE INDEX IF NOT EXISTS idx_consult_patient ON consultations(patient_id);
    CREATE INDEX IF NOT EXISTS idx_notif_read ON notifications(read);
    """)
    _ensure_columns(conn)


def _ensure_columns(conn: sqlite3.Connection) -> None:
    """Add columns that were introduced after a database was first created.

    Every table above is `CREATE TABLE IF NOT EXISTS`, which is a no-op once the
    file exists — so a column added to one of those definitions never reaches a
    kiosk that has already stored data, and the matching INSERT then fails at
    runtime with "table vitals has no column named ecg_hr". That broke
    `POST /emr/patients/{id}/vitals` outright on any pre-existing database.

    SQLite has no `ADD COLUMN IF NOT EXISTS`, so diff against PRAGMA table_info
    and add what is missing. Adding a column is safe to repeat this way and keeps
    old rows readable (new column reads as NULL).
    """
    wanted = {
        "patients": (("password_hash", "TEXT"),),
        "vitals": (("ecg_hr", "REAL"), ("ecg_data", "TEXT")),
    }
    added = False
    for table, columns in wanted.items():
        have = {row[1] for row in conn.execute(f"PRAGMA table_info({table})")}
        if not have:
            continue  # Table does not exist yet; the script above owns creating it.
        for name, decl in columns:
            if name not in have:
                conn.execute(f"ALTER TABLE {table} ADD COLUMN {name} {decl}")
                added = True
    # Commit the DDL here rather than leaving it in the open transaction this
    # connection starts implicitly: without this the migration only becomes
    # durable when some later request happens to commit, so a server that starts
    # and is then read by anything else still looks unmigrated.
    if added:
        conn.commit()


# ---------------------------------------------------------------------------
# Patient CRUD
# ---------------------------------------------------------------------------

def create_patient(name: str, dob: str = "", sex: str = "",
                   weight_kg: float = 0, height_cm: float = 0,
                   phone: str = "", email: str = "", notes: str = "") -> dict:
    with get_db() as conn:
        cur = conn.execute(
            """INSERT INTO patients (name,dob,sex,weight_kg,height_cm,phone,email,notes)
               VALUES (?,?,?,?,?,?,?,?)""",
            (name, dob, sex, weight_kg, height_cm, phone, email, notes),
        )
        return {"id": cur.lastrowid, "name": name}


def get_patient(patient_id: int) -> Optional[dict]:
    with get_db() as conn:
        row = conn.execute("SELECT * FROM patients WHERE id=?", (patient_id,)).fetchone()
        return dict(row) if row else None


def list_patients(limit: int = 50, offset: int = 0) -> list[dict]:
    limit = max(1, min(int(limit), 200))
    offset = max(0, int(offset))
    with get_db() as conn:
        rows = conn.execute(
            "SELECT * FROM patients ORDER BY updated_at DESC LIMIT ? OFFSET ?",
            (limit, offset),
        ).fetchall()
        return [dict(r) for r in rows]


def search_patients(query: str) -> list[dict]:
    with get_db() as conn:
        q = f"%{query}%"
        rows = conn.execute(
            "SELECT * FROM patients WHERE name LIKE ? OR phone LIKE ? OR email LIKE ? ORDER BY name",
            (q, q, q),
        ).fetchall()
        return [dict(r) for r in rows]


def update_patient(patient_id: int, **fields) -> bool:
    if not fields:
        return False
    allowed = {"name", "dob", "sex", "weight_kg", "height_cm", "phone", "email", "notes"}
    updates = {k: v for k, v in fields.items() if k in allowed}
    if not updates:
        return False
    updates["updated_at"] = time.strftime("%Y-%m-%d %H:%M:%S")
    set_clause = ", ".join(f"{k}=?" for k in updates)
    vals = list(updates.values()) + [patient_id]
    with get_db() as conn:
        cur = conn.execute(f"UPDATE patients SET {set_clause} WHERE id=?", vals)
        return cur.rowcount > 0


def delete_patient(patient_id: int) -> bool:
    with get_db() as conn:
        cur = conn.execute("DELETE FROM patients WHERE id=?", (patient_id,))
        return cur.rowcount > 0


# ---------------------------------------------------------------------------
# Vitals
# ---------------------------------------------------------------------------

def record_vitals(patient_id: int, hr: float = 0, spo2: float = 0,
                  temp: float = 0, rr: float = 0,
                  sbp: float = 0, dbp: float = 0,
                  ecg_hr: float = 0, ecg_data: str = "",
                  source: str = "manual") -> dict:
    with get_db() as conn:
        cur = conn.execute(
            """INSERT INTO vitals (patient_id,hr,spo2,temp,rr,sbp,dbp,ecg_hr,ecg_data,source)
               VALUES (?,?,?,?,?,?,?,?,?,?)""",
            (patient_id, hr, spo2, temp, rr, sbp, dbp, ecg_hr, ecg_data, source),
        )
        return {"id": cur.lastrowid}


def get_vitals_history(patient_id: int, limit: int = 100) -> list[dict]:
    limit = max(1, min(int(limit), 200))
    with get_db() as conn:
        rows = conn.execute(
            "SELECT * FROM vitals WHERE patient_id=? ORDER BY recorded_at DESC LIMIT ?",
            (patient_id, limit),
        ).fetchall()
        return [dict(r) for r in rows]


# ---------------------------------------------------------------------------
# X-ray results
# ---------------------------------------------------------------------------

def save_xray_result(patient_id: int, prediction: str, confidence: float,
                     image_path: str = "", heatmap_b64: str = "",
                     details: str = "") -> dict:
    with get_db() as conn:
        cur = conn.execute(
            """INSERT INTO xray_results (patient_id,image_path,prediction,confidence,heatmap_b64,details)
               VALUES (?,?,?,?,?,?)""",
            (patient_id, image_path, prediction, confidence, heatmap_b64, details),
        )
        return {"id": cur.lastrowid}


def get_xray_history(patient_id: int, limit: int = 20) -> list[dict]:
    limit = max(1, min(int(limit), 200))
    with get_db() as conn:
        rows = conn.execute(
            "SELECT * FROM xray_results WHERE patient_id=? ORDER BY created_at DESC LIMIT ?",
            (patient_id, limit),
        ).fetchall()
        return [dict(r) for r in rows]


# ---------------------------------------------------------------------------
# Lung sounds
# ---------------------------------------------------------------------------

def save_lung_sound(patient_id: int, label: str, confidence: float,
                    duration_s: float = 0, audio_path: str = "",
                    details: str = "") -> dict:
    with get_db() as conn:
        cur = conn.execute(
            """INSERT INTO lung_sounds (patient_id,audio_path,label,confidence,duration_s,details)
               VALUES (?,?,?,?,?,?)""",
            (patient_id, audio_path, label, confidence, duration_s, details),
        )
        return {"id": cur.lastrowid}


def get_lung_sound_history(patient_id: int, limit: int = 20) -> list[dict]:
    limit = max(1, min(int(limit), 200))
    with get_db() as conn:
        rows = conn.execute(
            "SELECT * FROM lung_sounds WHERE patient_id=? ORDER BY created_at DESC LIMIT ?",
            (patient_id, limit),
        ).fetchall()
        return [dict(r) for r in rows]


# ---------------------------------------------------------------------------
# Consultations
# ---------------------------------------------------------------------------

def save_consultation(patient_id: int, physician: str = "",
                      summary: str = "", diagnosis: str = "",
                      recommendations: str = "", risk_level: str = "low",
                      vitals_snapshot: str = "",
                      xray_id: int = 0, lung_id: int = 0) -> dict:
    with get_db() as conn:
        cur = conn.execute(
            """INSERT INTO consultations
               (patient_id,physician,summary,diagnosis,recommendations,risk_level,vitals_snapshot,xray_id,lung_id)
               VALUES (?,?,?,?,?,?,?,?,?)""",
            (patient_id, physician, summary, diagnosis, recommendations,
             risk_level, vitals_snapshot, xray_id or None, lung_id or None),
        )
        return {"id": cur.lastrowid}


def get_consultations(patient_id: int, limit: int = 20) -> list[dict]:
    limit = max(1, min(int(limit), 200))
    with get_db() as conn:
        rows = conn.execute(
            """SELECT c.*, p.name as patient_name
               FROM consultations c JOIN patients p ON c.patient_id=p.id
               WHERE c.patient_id=? ORDER BY c.created_at DESC LIMIT ?""",
            (patient_id, limit),
        ).fetchall()
        return [dict(r) for r in rows]


def list_consultations(limit: int = 50) -> list[dict]:
    """Recent consultations across all patients (avoids N+1 client fan-out)."""
    limit = max(1, min(int(limit), 200))
    with get_db() as conn:
        rows = conn.execute(
            """SELECT c.*, p.name as patient_name
               FROM consultations c JOIN patients p ON c.patient_id=p.id
               ORDER BY c.created_at DESC LIMIT ?""",
            (limit,),
        ).fetchall()
        return [dict(r) for r in rows]


# ---------------------------------------------------------------------------
# Notifications
# ---------------------------------------------------------------------------

def create_notification(title: str, message: str, severity: str = "info",
                        patient_id: int = 0, notif_type: str = "system") -> dict:
    with get_db() as conn:
        cur = conn.execute(
            """INSERT INTO notifications (patient_id,type,title,message,severity)
               VALUES (?,?,?,?,?)""",
            (patient_id or None, notif_type, title, message, severity),
        )
        return {"id": cur.lastrowid}


def get_notifications(unread_only: bool = False, limit: int = 50) -> list[dict]:
    limit = max(1, min(int(limit), 200))
    with get_db() as conn:
        q = "SELECT * FROM notifications"
        if unread_only:
            q += " WHERE read=0"
        q += " ORDER BY created_at DESC LIMIT ?"
        rows = conn.execute(q, (limit,)).fetchall()
        return [dict(r) for r in rows]


def mark_notification_read(notif_id: int):
    with get_db() as conn:
        conn.execute("UPDATE notifications SET read=1 WHERE id=?", (notif_id,))


def mark_all_read():
    with get_db() as conn:
        conn.execute("UPDATE notifications SET read=1 WHERE read=0")


# ---------------------------------------------------------------------------
# Analytics
# ---------------------------------------------------------------------------

def get_analytics_summary() -> dict:
    with get_db() as conn:
        patients = conn.execute("SELECT COUNT(*) as c FROM patients").fetchone()["c"]
        xrays = conn.execute("SELECT COUNT(*) as c FROM xray_results").fetchone()["c"]
        consultations = conn.execute("SELECT COUNT(*) as c FROM consultations").fetchone()["c"]
        vitals_records = conn.execute("SELECT COUNT(*) as c FROM vitals").fetchone()["c"]
        unread = conn.execute("SELECT COUNT(*) as c FROM notifications WHERE read=0").fetchone()["c"]

        # Disease distribution
        diseases = conn.execute(
            """SELECT prediction, COUNT(*) as count
               FROM xray_results GROUP BY prediction ORDER BY count DESC"""
        ).fetchall()

        # Risk distribution
        risks = conn.execute(
            """SELECT risk_level, COUNT(*) as count
               FROM consultations GROUP BY risk_level"""
        ).fetchall()

        return {
            "total_patients": patients,
            "total_xrays": xrays,
            "total_consultations": consultations,
            "total_vitals": vitals_records,
            "unread_notifications": unread,
            "disease_distribution": [dict(r) for r in diseases],
            "risk_distribution": [dict(r) for r in risks],
        }


def create_guest_session() -> dict[str, Any]:
    import random
    now_ts = int(time.time())
    rand_suffix = random.randint(1000, 9999)
    guest_id = f"GST-{now_ts % 1000000}-{rand_suffix}"
    return {
        "guest_id": guest_id,
        "mrn": guest_id,
        "name": f"Walk-In Guest Session (#{rand_suffix})",
        "created_at": time.strftime("%Y-%m-%d %H:%M:%S"),
        "is_guest": True,
    }


# ---------------------------------------------------------------------------
# Patient Auth & Portal Dashboard
# ---------------------------------------------------------------------------

import hashlib

def hash_password(password: str) -> str:
    return hashlib.sha256(password.encode("utf-8")).hexdigest()


def get_patient_by_email(email: str) -> Optional[dict]:
    with get_db() as conn:
        row = conn.execute("SELECT * FROM patients WHERE email = ? COLLATE NOCASE", (email.strip(),)).fetchone()
        return dict(row) if row else None


def register_patient_auth(name: str, email: str, password: str, dob: str = "", sex: str = "", phone: str = "", notes: str = "") -> dict:
    pwd_hash = hash_password(password)
    with get_db() as conn:
        cur = conn.execute(
            """INSERT INTO patients (name, email, password_hash, dob, sex, phone, notes)
               VALUES (?, ?, ?, ?, ?, ?, ?)""",
            (name.strip(), email.strip().lower(), pwd_hash, dob, sex, phone, notes),
        )
        pid = cur.lastrowid
        return {"id": pid, "name": name, "email": email}


def verify_patient_login(email: str, password: str) -> Optional[dict]:
    p = get_patient_by_email(email)
    if not p:
        return None
    pwd_hash = hash_password(password)
    if p.get("password_hash") == pwd_hash:
        # Don't leak password hash
        safe = {k: v for k, v in p.items() if k != "password_hash"}
        return safe
    return None


def seed_demo_patient_if_needed() -> dict:
    demo_email = "demo@xsight.local"
    p = get_patient_by_email(demo_email)
    if p:
        return {k: v for k, v in p.items() if k != "password_hash"}

    # Create demo patient "John Doe"
    with get_db() as conn:
        cur = conn.execute(
            """INSERT INTO patients (name, email, password_hash, dob, sex, phone, notes)
               VALUES (?, ?, ?, ?, ?, ?, ?)""",
            ("John Doe", demo_email, hash_password("demo123"), "1981-04-12", "Male", "+1-555-0199", "Annual Thoracic Screening"),
        )
        pid = cur.lastrowid

        # Insert sample vitals
        conn.execute(
            """INSERT INTO vitals (patient_id, hr, spo2, temp, rr, sbp, dbp, source)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
            (pid, 74.0, 98.5, 36.6, 16.0, 120.0, 80.0, "kiosk_sensors"),
        )

        # Insert sample lung sound
        conn.execute(
            """INSERT INTO lung_sounds (patient_id, label, confidence, details)
               VALUES (?, ?, ?, ?)""",
            (pid, "normal", 0.94, json.dumps({"description": "Clear vesicular breath sounds throughout bilateral lung fields."})),
        )

        # Insert sample xray
        conn.execute(
            """INSERT INTO xray_results (patient_id, prediction, confidence, details)
               VALUES (?, ?, ?, ?)""",
            (pid, "Normal", 0.92, json.dumps({"findings": "No focal consolidation, pneumothorax, or pleural effusion observed.", "cardiothoracic_ratio": "Normal (<0.5)"})),
        )

        # Insert consultation
        conn.execute(
            """INSERT INTO consultations (patient_id, physician, summary, diagnosis, recommendations, risk_level)
               VALUES (?, ?, ?, ?, ?, ?)""",
            (pid, "AI Assistant", "Routine screening completed. Normal cardiopulmonary metrics.", "Normal Cardiopulmonary Assessment", "Maintain healthy lifestyle. Routine annual re-screening recommended.", "low"),
        )

        row = conn.execute("SELECT * FROM patients WHERE id = ?", (pid,)).fetchone()
        return {k: v for k, v in dict(row).items() if k != "password_hash"}


def get_patient_portal_dashboard(patient_id: int) -> dict[str, Any]:
    with get_db() as conn:
        patient_row = conn.execute("SELECT * FROM patients WHERE id = ?", (patient_id,)).fetchone()
        if not patient_row:
            return {}

        patient = {k: v for k, v in dict(patient_row).items() if k != "password_hash"}

        # Latest vitals
        v_row = conn.execute(
            "SELECT * FROM vitals WHERE patient_id = ? ORDER BY recorded_at DESC LIMIT 1",
            (patient_id,),
        ).fetchone()
        vitals = dict(v_row) if v_row else None

        # Latest lung sound
        l_row = conn.execute(
            "SELECT * FROM lung_sounds WHERE patient_id = ? ORDER BY created_at DESC LIMIT 1",
            (patient_id,),
        ).fetchone()
        lung_sound = dict(l_row) if l_row else None

        # Latest xray
        x_row = conn.execute(
            "SELECT * FROM xray_results WHERE patient_id = ? ORDER BY created_at DESC LIMIT 1",
            (patient_id,),
        ).fetchone()
        xray = dict(x_row) if x_row else None

        # Consultations history
        c_rows = conn.execute(
            "SELECT * FROM consultations WHERE patient_id = ? ORDER BY created_at DESC LIMIT 10",
            (patient_id,),
        ).fetchall()
        consultations = [dict(r) for r in c_rows]

        # Recent vitals history
        vh_rows = conn.execute(
            "SELECT * FROM vitals WHERE patient_id = ? ORDER BY recorded_at DESC LIMIT 10",
            (patient_id,),
        ).fetchall()
        vitals_history = [dict(r) for r in vh_rows]

        return {
            "patient": patient,
            "vitals": vitals,
            "lung_sound": lung_sound,
            "xray": xray,
            "consultations": consultations,
            "vitals_history": vitals_history,
        }


