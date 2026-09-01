"""XSIGHT Clinical Decision Support System (CDSS).

Fuses X-ray findings, lung sounds, and vitals into a unified risk assessment
with evidence-based recommendations.
"""

from __future__ import annotations

from typing import Any

# Disease knowledge base — symptoms, risk factors, urgency
#
# Keys must match the labels the X-ray classifier can actually emit
# (`server/ml/xray/labels.json`), because `fuse_findings` gates on membership:
# a prediction that is not a key here contributes nothing to the differential,
# no recommendations, and *zero* risk. `covid-19` and `lung_opacity` were
# missing, so two of the shipped model's four abnormal classes were silently
# dropped from every assessment they appeared in.
#
# `normal` is deliberately absent: a normal film should add no differential and
# no risk, and the membership gate gives that for free.
#
# `effusion` / `pneumothorax` / `cardiomegaly` / `mass` are kept but are
# currently unreachable — they belong to the retired 7-class model
# (`legacy_labels.json`). Retained so a retrain that reintroduces them works
# without re-deriving the clinical content. Compare the same reasoning applied
# to LUNG_SOUND_FINDINGS below.
DISEASE_KB = {
    "pneumonia": {
        "risk_weight": 0.8,
        "urgent_if": {"spo2": "<92", "rr": ">28", "temp": ">39"},
        "recommendations": [
            "Consider chest X-ray confirmation",
            "Order CBC, CRP, procalcitonin",
            "Sputum culture if productive cough",
            "Assess need for hospitalization",
        ],
        "severity_factors": ["age>65", "immunocompromised", "bilateral"],
    },
    "covid-19": {
        # Comparable to pneumonia, with the extra weight coming from the
        # transmission risk rather than the radiographic severity alone.
        "risk_weight": 0.8,
        "urgent_if": {"spo2": "<94", "rr": ">24"},
        "recommendations": [
            "Confirm with RT-PCR or rapid antigen test",
            "Isolation precautions pending results",
            "Monitor SpO2 including on exertion — silent hypoxaemia is common",
            "Order CBC, CRP, D-dimer, LDH",
            "Assess need for supplemental oxygen and hospitalization",
        ],
        # A lower SpO2 trigger than pneumonia on purpose: desaturation in
        # COVID-19 often presents before dyspnoea, so waiting for 92% loses time.
        "severity_factors": ["age>65", "immunocompromised", "bilateral", "comorbidities"],
    },
    "lung_opacity": {
        # Non-specific by definition — an opacity is a finding, not a diagnosis.
        # Weighted below the named diseases so it cannot dominate the fusion,
        # and its recommendations push toward narrowing rather than treating.
        "risk_weight": 0.55,
        "urgent_if": {"spo2": "<92", "rr": ">28"},
        "recommendations": [
            "Non-specific opacity — correlate with symptoms and exposure history",
            "Compare with any prior chest imaging to date the finding",
            "Consider CBC, CRP and sputum studies to narrow infectious causes",
            "Repeat imaging or CT chest if it persists after treatment",
            "Clinician review required to characterise the opacity",
        ],
        "severity_factors": ["multilobar", "bilateral", "rapid_progression"],
    },
    "tuberculosis": {
        "risk_weight": 0.9,
        "urgent_if": {"spo2": "<90"},
        "recommendations": [
            "Sputum AFB smear and culture",
            "GeneXpert MTB/RIF test",
            "HIV testing recommended",
            "Contact tracing assessment",
            "Isolation precautions pending results",
        ],
        "severity_factors": ["HIV_positive", "drug_resistance", "cavitary"],
    },
    "effusion": {
        "risk_weight": 0.7,
        "urgent_if": {"spo2": "<92", "rr": ">26"},
        "recommendations": [
            "Thoracentesis for fluid analysis",
            "Light's criteria for exudate vs transudate",
            "CT chest if loculated",
            "Monitor respiratory status",
        ],
        "severity_factors": ["massive", "bilateral", "loculated"],
    },
    "pneumothorax": {
        "risk_weight": 0.85,
        "urgent_if": {"spo2": "<90", "rr": ">30"},
        "recommendations": [
            "Assess for tension pneumothorax",
            "Chest tube if large or symptomatic",
            "Continuous monitoring",
            "Pulmonology consult",
        ],
        "severity_factors": ["tension", "bilateral", "large"],
    },
    "cardiomegaly": {
        "risk_weight": 0.6,
        "urgent_if": {"spo2": "<91", "hr": ">120"},
        "recommendations": [
            "Echocardiogram recommended",
            "BNP/NT-proBNP levels",
            "Assess for heart failure",
            "ECG evaluation",
        ],
        "severity_factors": ["acute", "pulmonary_edema", "bilateral_infiltrates"],
    },
    "mass": {
        "risk_weight": 0.75,
        "urgent_if": {},
        "recommendations": [
            "CT chest with contrast recommended",
            "PET-CT if malignancy suspected",
            "Pulmonology/oncology referral",
            "Biopsy consideration",
        ],
        "severity_factors": ["size>3cm", "spiculated", "lymphadenopathy"],
    },
}

#     Matches the ICBHI 2017-trained classifier's 4-class label set
# (see LUNG_TRAINING.md) — normal / crackle / wheeze / both. Older
# rhonchi/diminished entries were dropped since no trained model can
# ever produce those labels; if a future classifier reintroduces them,
# add entries back here alongside the label-set change.
#
# Each sound type maps to probable respiratory diseases with risk weights
# that feed into the multimodal fusion engine.
LUNG_SOUND_FINDINGS = {
    "wheeze": {
        "associated": ["asthma", "copd", "bronchospasm"],
        "risk_weight": 0.6,
        "clinical_note": "High-pitched musical sound during expiration suggests airway narrowing. "
                         "Common in reactive airway disease (asthma), chronic obstructive conditions (COPD), "
                         "or acute bronchospasm.",
        "recommendation": "Consider bronchodilator therapy, spirometry, and chest X-ray to rule out structural obstruction",
    },
    "crackle": {
        "associated": ["pneumonia", "fibrosis", "heart_failure", "pulmonary_edema"],
        "risk_weight": 0.7,
        "clinical_note": "Discontinuous popping sounds (fine or coarse) during inspiration indicate fluid, "
                         "inflammation, or fibrosis in alveoli or small airways. Strongly associated with "
                         "pneumonia, interstitial lung disease, or congestive heart failure.",
        "recommendation": "Chest X-ray and cardiac evaluation recommended. If fever or productive cough present, "
                          "consider bacterial pneumonia workup (CBC, CRP, sputum culture)",
    },
    "both": {
        "associated": ["pneumonia", "copd", "bronchitis", "acute_exacerbation"],
        "risk_weight": 0.75,
        "clinical_note": "Combined crackle and wheeze findings suggest complex pathology: acute infectious "
                         "bronchitis with airway reactivity, COPD exacerbation, or pneumonia with bronchospasm. "
                         "Higher clinical concern warranted.",
        "recommendation": "Chest X-ray, spirometry, and cardiac evaluation — combined adventitious sounds warrant "
                          "broader diagnostic workup. Consider empiric bronchodilator + antimicrobial if infectious etiology suspected",
    },
    "normal": {
        "associated": [],
        "risk_weight": 0.0,
        "clinical_note": "No abnormal respiratory sounds detected. Normal vesicular breath sounds throughout lung fields.",
        "recommendation": "No respiratory abnormality detected on auscultation",
    },
}

def _display_label(label: str) -> str:
    """Human-readable form of a classifier label, for alert text.

    Labels are machine keys (`lung_opacity`, `covid-19`); `.title()` alone gave
    "Lung_Opacity" and "Covid-19" in clinical alerts. Known acronyms keep their
    conventional casing.
    """
    key = (label or "").strip().lower()
    special = {
        "covid-19": "COVID-19",
        "tuberculosis": "Tuberculosis",
        "lung_opacity": "Lung opacity",
    }
    if key in special:
        return special[key]
    return key.replace("_", " ").replace("-", " ").capitalize()


VITAL_THRESHOLDS = {
    "hr_low": 50,
    "hr_high": 120,
    "spo2_low": 92,
    "spo2_critical": 88,
    "temp_fever": 37.8,
    "temp_high_fever": 39.0,
    "rr_low": 10,
    "rr_high": 28,
    "rr_critical": 32,
    "sbp_low": 90,
    "sbp_high": 180,
    "dbp_low": 60,
    "dbp_high": 110,
}


def assess_vitals(vitals: dict) -> dict:
    """Evaluate vital signs and return risk level + alerts."""
    alerts = []
    risk_score = 0.0

    hr = vitals.get("hr", 0)
    spo2 = vitals.get("spo2", 0)
    temp = vitals.get("temp", 0)
    rr = vitals.get("rr", 0)
    sbp = vitals.get("sbp", 0)
    dbp = vitals.get("dbp", 0)

    t = VITAL_THRESHOLDS

    if hr and hr > t["hr_high"]:
        alerts.append({"type": "tachycardia", "severity": "warning",
                        "message": f"Heart rate {hr:.0f} bpm (>{t['hr_high']})"})
        risk_score += 0.3
    elif hr and hr < t["hr_low"]:
        alerts.append({"type": "bradycardia", "severity": "warning",
                        "message": f"Heart rate {hr:.0f} bpm (<{t['hr_low']})"})
        risk_score += 0.3

    if spo2 and spo2 < t["spo2_critical"]:
        alerts.append({"type": "critical_spo2", "severity": "critical",
                        "message": f"SpO₂ {spo2:.0f}% — CRITICAL"})
        risk_score += 0.5
    elif spo2 and spo2 < t["spo2_low"]:
        alerts.append({"type": "low_spo2", "severity": "warning",
                        "message": f"SpO₂ {spo2:.0f}% (below {t['spo2_low']}%)"})
        risk_score += 0.3

    if temp and temp >= t["temp_high_fever"]:
        alerts.append({"type": "high_fever", "severity": "warning",
                        "message": f"Temperature {temp:.1f}°C — high fever"})
        risk_score += 0.25
    elif temp and temp >= t["temp_fever"]:
        alerts.append({"type": "fever", "severity": "info",
                        "message": f"Temperature {temp:.1f}°C — fever"})
        risk_score += 0.1

    if rr and rr > t["rr_critical"]:
        alerts.append({"type": "critical_rr", "severity": "critical",
                        "message": f"Respiratory rate {rr:.0f}/min — CRITICAL"})
        risk_score += 0.5
    elif rr and rr > t["rr_high"]:
        alerts.append({"type": "tachypnea", "severity": "warning",
                        "message": f"Respiratory rate {rr:.0f}/min (>{t['rr_high']})"})
        risk_score += 0.3

    if sbp and sbp > t["sbp_high"]:
        alerts.append({"type": "hypertension", "severity": "warning",
                        "message": f"Blood pressure {sbp:.0f}/{dbp:.0f} mmHg"})
        risk_score += 0.2
    elif sbp and sbp < t["sbp_low"]:
        alerts.append({"type": "hypotension", "severity": "critical",
                        "message": f"Blood pressure {sbp:.0f}/{dbp:.0f} mmHg — LOW"})
        risk_score += 0.4

    level = "low"
    if risk_score >= 0.6:
        level = "critical"
    elif risk_score >= 0.3:
        level = "high"
    elif risk_score >= 0.1:
        level = "moderate"

    return {
        "risk_score": round(min(risk_score, 1.0), 2),
        "risk_level": level,
        "alerts": alerts,
    }


def fuse_findings(xray_prediction: str = "", xray_confidence: float = 0,
                  lung_label: str = "", lung_confidence: float = 0,
                  vitals: dict | None = None,
                  patient_age: int = 0) -> dict:
    """Fuse X-ray, lung sounds, and vitals into a unified CDSS assessment."""

    vitals_assessment = assess_vitals(vitals or {})
    all_recommendations = []
    all_alerts = list(vitals_assessment["alerts"])
    differential = []

    # X-ray findings
    if xray_prediction and xray_prediction.lower() in DISEASE_KB:
        disease = DISEASE_KB[xray_prediction.lower()]
        differential.append({
            "diagnosis": xray_prediction,
            "confidence": round(xray_confidence, 2),
            "source": "chest_xray",
        })
        all_recommendations.extend(disease["recommendations"])

        # Check urgent conditions
        for vital_name, threshold in disease.get("urgent_if", {}).items():
            val = (vitals or {}).get(vital_name, 0)
            if val and _check_threshold(val, threshold):
                all_alerts.append({
                    "type": f"urgent_{xray_prediction}_{vital_name}",
                    "severity": "critical",
                    "message": f"{_display_label(xray_prediction)} + {vital_name}={val} — URGENT",
                })

    # Lung sound findings
    if lung_label and lung_label.lower() in LUNG_SOUND_FINDINGS:
        finding = LUNG_SOUND_FINDINGS[lung_label.lower()]
        if finding["associated"]:
            for assoc in finding["associated"]:
                if assoc not in [d["diagnosis"] for d in differential]:
                    differential.append({
                        "diagnosis": assoc,
                        "confidence": round(lung_confidence * 0.7, 2),
                        "source": "lung_sound",
                        "note": finding.get("clinical_note", ""),
                    })
            all_recommendations.append(finding["recommendation"])

    # Overall risk fusion
    xray_risk = 0.0
    if xray_prediction and xray_prediction.lower() in DISEASE_KB:
        xray_risk = DISEASE_KB[xray_prediction.lower()]["risk_weight"] * xray_confidence

    lung_risk = 0.0
    if lung_label and lung_label.lower() in LUNG_SOUND_FINDINGS:
        lung_risk = LUNG_SOUND_FINDINGS[lung_label.lower()]["risk_weight"] * lung_confidence
    
    vitals_risk = vitals_assessment["risk_score"]

    combined = max(xray_risk, lung_risk, vitals_risk) * 0.6 + \
               min(xray_risk + lung_risk + vitals_risk, 1.0) * 0.4

    overall_level = "low"
    if combined >= 0.6:
        overall_level = "critical"
    elif combined >= 0.4:
        overall_level = "high"
    elif combined >= 0.2:
        overall_level = "moderate"

    # Deduplicate recommendations
    seen = set()
    unique_recs = []
    for r in all_recommendations:
        if r not in seen:
            seen.add(r)
            unique_recs.append(r)

    return {
        "overall_risk": round(min(combined, 1.0), 2),
        "overall_level": overall_level,
        "differential_diagnosis": sorted(differential, key=lambda d: -d["confidence"]),
        "recommendations": unique_recs,
        "alerts": all_alerts,
        "vitals_assessment": vitals_assessment,
    }


def _check_threshold(value: float, threshold: str) -> bool:
    """Check a value against a string threshold like '<92' or '>28'."""
    threshold = threshold.strip()
    # Longer ops first — '<=' must not match '<' branch.
    for op, n in (("<=", 2), (">=", 2), ("<", 1), (">", 1)):
        if threshold.startswith(op):
            try:
                bound = float(threshold[n:])
            except ValueError:
                return False
            if op == "<=":
                return value <= bound
            if op == ">=":
                return value >= bound
            if op == "<":
                return value < bound
            return value > bound
    return False
