"""XSIGHT EMR API routes.

Patient management, vitals history, X-ray history, consultations, notifications, analytics.
"""

from __future__ import annotations

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field
from typing import Optional

from . import emr_db as db

router = APIRouter(prefix="/emr", tags=["EMR"])


# ---------------------------------------------------------------------------
# Request/Response models
# ---------------------------------------------------------------------------

class PatientCreate(BaseModel):
    name: str = Field(..., min_length=1, max_length=200)
    dob: str = ""
    sex: str = ""
    weight_kg: float = 0
    height_cm: float = 0
    phone: str = ""
    email: str = ""
    notes: str = ""


class PatientUpdate(BaseModel):
    name: Optional[str] = None
    dob: Optional[str] = None
    sex: Optional[str] = None
    weight_kg: Optional[float] = None
    height_cm: Optional[float] = None
    phone: Optional[str] = None
    email: Optional[str] = None
    notes: Optional[str] = None


class VitalsRecord(BaseModel):
    hr: float = 0
    spo2: float = 0
    temp: float = 0
    rr: float = 0
    sbp: float = 0
    dbp: float = 0
    ecg_hr: float = 0
    ecg_data: str = ""
    source: str = "manual"


class ConsultationCreate(BaseModel):
    physician: str = ""
    summary: str = ""
    diagnosis: str = ""
    recommendations: str = ""
    risk_level: str = "low"
    vitals_snapshot: str = ""
    xray_id: int = 0
    lung_id: int = 0


class NotificationCreate(BaseModel):
    title: str
    message: str
    severity: str = "info"
    patient_id: int = 0
    notif_type: str = "system"


# ---------------------------------------------------------------------------
# Patient endpoints
# ---------------------------------------------------------------------------

@router.get("/patients")
def list_patients(limit: int = 50, offset: int = 0):
    return db.list_patients(limit, offset)


@router.get("/patients/search")
def search_patients(q: str = ""):
    if not q:
        return db.list_patients()
    return db.search_patients(q)


@router.post("/patients")
def create_patient(body: PatientCreate):
    return db.create_patient(**body.model_dump())


@router.get("/patients/{patient_id}")
def get_patient(patient_id: int):
    p = db.get_patient(patient_id)
    if not p:
        raise HTTPException(404, "Patient not found")
    return p


@router.put("/patients/{patient_id}")
def update_patient(patient_id: int, body: PatientUpdate):
    fields = {k: v for k, v in body.model_dump().items() if v is not None}
    if not db.update_patient(patient_id, **fields):
        raise HTTPException(404, "Patient not found")
    return {"ok": True}


@router.delete("/patients/{patient_id}")
def delete_patient(patient_id: int):
    if not db.delete_patient(patient_id):
        raise HTTPException(404, "Patient not found")
    return {"ok": True}


# ---------------------------------------------------------------------------
# Vitals endpoints
# ---------------------------------------------------------------------------

@router.post("/patients/{patient_id}/vitals")
def record_vitals(patient_id: int, body: VitalsRecord):
    if not db.get_patient(patient_id):
        raise HTTPException(404, "Patient not found")
    return db.record_vitals(patient_id, **body.model_dump())


@router.get("/patients/{patient_id}/vitals")
def get_vitals(patient_id: int, limit: int = 100):
    return db.get_vitals_history(patient_id, limit)


# ---------------------------------------------------------------------------
# X-ray history
# ---------------------------------------------------------------------------

@router.get("/patients/{patient_id}/xrays")
def get_xray_history(patient_id: int, limit: int = 20):
    return db.get_xray_history(patient_id, limit)


# ---------------------------------------------------------------------------
# Lung sound history
# ---------------------------------------------------------------------------

@router.get("/patients/{patient_id}/lung-sounds")
def get_lung_history(patient_id: int, limit: int = 20):
    return db.get_lung_sound_history(patient_id, limit)


# ---------------------------------------------------------------------------
# Consultations
# ---------------------------------------------------------------------------

@router.post("/patients/{patient_id}/consultations")
def create_consultation(patient_id: int, body: ConsultationCreate):
    if not db.get_patient(patient_id):
        raise HTTPException(404, "Patient not found")
    return db.save_consultation(patient_id, **body.model_dump())


@router.get("/patients/{patient_id}/consultations")
def list_patient_consultations(patient_id: int, limit: int = 20):
    return db.get_consultations(patient_id, limit)


@router.get("/consultations")
def list_consultations(limit: int = 50):
    return db.list_consultations(limit)


# ---------------------------------------------------------------------------
# Notifications
# ---------------------------------------------------------------------------

@router.get("/notifications")
def list_notifications(unread: bool = False, limit: int = 50):
    return db.get_notifications(unread, limit)


@router.post("/notifications")
def create_notification(body: NotificationCreate):
    return db.create_notification(**body.model_dump())


@router.put("/notifications/{notif_id}/read")
def mark_read(notif_id: int):
    db.mark_notification_read(notif_id)
    return {"ok": True}


@router.put("/notifications/read-all")
def mark_all_read():
    db.mark_all_read()
    return {"ok": True}


# ---------------------------------------------------------------------------
# Analytics
# ---------------------------------------------------------------------------

@router.get("/analytics")
def get_analytics():
    return db.get_analytics_summary()


@router.post("/guest-session")
def create_guest_session():
    return db.create_guest_session()

