import json
from fastapi import APIRouter, HTTPException
from fastapi.responses import Response
from fpdf import FPDF
from . import emr_db as db

router = APIRouter(prefix="/reports", tags=["Reports"])

class PDFReport(FPDF):
    def header(self):
        self.set_font("Helvetica", "B", 12)
        self.cell(0, 10, "XSIGHT AI-ASSISTED THORACIC ASSESSMENT REPORT", border=0, ln=1, align="C")
        self.set_draw_color(200, 200, 200)
        self.line(10, 20, 200, 20)
        self.ln(10)

    def footer(self):
        self.set_y(-15)
        self.set_font("Helvetica", "I", 8)
        self.set_text_color(128, 128, 128)
        self.cell(0, 10, f"Page {self.page_no()} | Confidential Medical Screening Report | Powered by XSIGHT", align="C")

def build_report_pdf(consultation_id: int) -> bytes:
    """Render a consultation report and return the PDF bytes.

    Bytes rather than a file: the report is patient data, and the previous
    version wrote it to a predictable `/tmp/report_<id>.pdf` that any local
    user could read and nothing ever cleaned up. It is also needed in memory by
    the phone handoff, which pushes it to the relay rather than serving it.

    Raises [FileNotFoundError] when the consultation does not exist, so callers
    can map that to their own 404.
    """
    with db.get_db() as conn:
        c = conn.execute(
            "SELECT c.*, p.name, p.dob, p.sex, p.weight_kg, p.height_cm, p.notes as p_notes "
            "FROM consultations c JOIN patients p ON c.patient_id = p.id "
            "WHERE c.id = ?", (consultation_id,)
        ).fetchone()

    if not c:
        raise FileNotFoundError(f"consultation {consultation_id}")

    c = dict(c)

    # Generate PDF
    pdf = PDFReport()
    pdf.add_page()
    pdf.set_font("Helvetica", size=10)
    
    # Patient Info Section
    pdf.set_font("Helvetica", "B", 11)
    pdf.cell(0, 8, "1. PATIENT INFORMATION", ln=1)
    pdf.set_font("Helvetica", size=10)
    pdf.cell(95, 6, f"Name: {c['name']}", ln=0)
    pdf.cell(95, 6, f"DOB: {c['dob'] or 'N/A'}", ln=1)
    pdf.cell(95, 6, f"Sex: {c['sex'] or 'N/A'}", ln=0)
    pdf.cell(95, 6, f"Weight: {c['weight_kg'] or 0} kg / Height: {c['height_cm'] or 0} cm", ln=1)
    pdf.ln(4)
    
    # Vitals Section
    pdf.set_font("Helvetica", "B", 11)
    pdf.cell(0, 8, "2. VITAL SIGNS SNAPSHOT", ln=1)
    pdf.set_font("Helvetica", size=10)
    if c['vitals_snapshot']:
        try:
            v = json.loads(c['vitals_snapshot'])
            v_text = f"HR: {v.get('hr', 'N/A')} bpm | SpO2: {v.get('spo2', 'N/A')}% | Temp: {v.get('temp', 'N/A')} C | RR: {v.get('rr', 'N/A')}/min"
            pdf.cell(0, 6, v_text, ln=1)
        except Exception:
            pdf.cell(0, 6, "Vitals data format error", ln=1)
    else:
        pdf.cell(0, 6, "No vitals recorded for this consultation", ln=1)
    pdf.ln(4)
    
    # Assessment Section
    pdf.set_font("Helvetica", "B", 11)
    pdf.cell(0, 8, "3. AI-ASSISTED ASSESSMENT", ln=1)
    pdf.set_font("Helvetica", size=10)
    pdf.cell(95, 6, f"Primary Finding: {c['diagnosis'] or 'N/A'}", ln=0)
    pdf.cell(95, 6, f"Risk Level: {c['risk_level'].upper()}", ln=1)
    
    # Differential Diagnosis
    if c['summary']:
        try:
            diff = json.loads(c['summary'])
            if diff:
                pdf.set_font("Helvetica", "I", 9)
                pdf.cell(0, 6, "Differential Diagnosis:", ln=1)
                pdf.set_font("Helvetica", size=10)
                for d in diff:
                    pdf.cell(0, 5, f" - {d.get('diagnosis', 'N/A')} (Confidence: {int(d.get('confidence', 0)*100)}%) via {d.get('source', 'N/A')}", ln=1)
        except Exception:
            pass
    pdf.ln(4)
    
    # Recommendations Section
    pdf.set_font("Helvetica", "B", 11)
    pdf.cell(0, 8, "4. CLINICAL RECOMMENDATIONS", ln=1)
    pdf.set_font("Helvetica", size=10)
    recs = c['recommendations'] or "No specific recommendations."
    pdf.multi_cell(0, 5, recs)
    pdf.ln(4)
    
    # Disclaimer
    pdf.set_font("Helvetica", "I", 8)
    pdf.set_text_color(150, 50, 50)
    disclaimer = (
        "DISCLAIMER: This is an AI-assisted screening report, not a definitive clinical diagnosis. "
        "All findings and recommendations must be reviewed and validated by a licensed healthcare professional. "
        "In case of severe symptoms or emergency, seek immediate medical attention."
    )
    pdf.multi_cell(0, 4, disclaimer)

    # `dest="S"` renders to memory. fpdf2 returns a bytearray here.
    return bytes(pdf.output())


@router.get("/{consultation_id}/pdf")
def export_pdf_report(consultation_id: int):
    try:
        pdf = build_report_pdf(consultation_id)
    except FileNotFoundError:
        raise HTTPException(status_code=404, detail="Consultation not found")
    return Response(
        content=pdf,
        media_type="application/pdf",
        headers={
            "Content-Disposition":
                f'attachment; filename="report_{consultation_id}.pdf"',
        },
    )
