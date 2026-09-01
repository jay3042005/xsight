import os
import sys
from reportlab.lib.pagesizes import letter
from reportlab.lib import colors
from reportlab.platypus import (
    SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle, PageBreak, KeepTogether, HRFlowable
)
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.lib.units import inch
from reportlab.pdfgen import canvas

class NumberedCanvas(canvas.Canvas):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._saved_page_states = []

    def showPage(self):
        self._saved_page_states.append(dict(self.__dict__))
        self._startPage()

    def save(self):
        num_pages = len(self._saved_page_states)
        for state in self._saved_page_states:
            self.__dict__.update(state)
            self.draw_header_footer(num_pages)
            super().showPage()
        super().save()

    def draw_header_footer(self, page_count):
        self.saveState()
        self.setFont("Helvetica-Bold", 8)
        self.setFillColor(colors.HexColor("#5C6BC0"))
        
        # Header (pages > 1)
        if self._pageNumber > 1:
            self.drawString(54, 11 * inch - 36, "XSIGHT THORACIC AI SYSTEM — STATISTICAL TREATMENT GUIDE")
            self.setStrokeColor(colors.HexColor("#E0E0E0"))
            self.setLineWidth(0.5)
            self.line(54, 11 * inch - 42, 8.5 * inch - 54, 11 * inch - 42)
            
        # Footer (all pages)
        self.setFont("Helvetica", 8)
        self.setFillColor(colors.HexColor("#757575"))
        self.drawString(54, 36, "Confidential — XSIGHT Medical AI Research & Evaluation Framework")
        
        page_str = f"Page {self._pageNumber} of {page_count}"
        self.drawRightString(8.5 * inch - 54, 36, page_str)
        self.setStrokeColor(colors.HexColor("#E0E0E0"))
        self.setLineWidth(0.5)
        self.line(54, 48, 8.5 * inch - 54, 48)
        
        self.restoreState()

def build_pdf(filename):
    doc = SimpleDocTemplate(
        filename,
        pagesize=letter,
        leftMargin=54,
        rightMargin=54,
        topMargin=54,
        bottomMargin=60
    )
    
    styles = getSampleStyleSheet()
    
    # Custom Palette
    PRIMARY = colors.HexColor("#1A237E")    # Deep Indigo
    SECONDARY = colors.HexColor("#283593")  # Navy Accent
    TEAL = colors.HexColor("#00838F")       # Medical Teal Accent
    DARK_TEXT = colors.HexColor("#212121")  # Charcoal Body Text
    LIGHT_BG = colors.HexColor("#F4F6F9")   # Soft Grey Card Background
    ACCENT_BORDER = colors.HexColor("#C5CAE9")

    # Typography Styles
    title_style = ParagraphStyle(
        'DocTitle',
        parent=styles['Heading1'],
        fontName='Helvetica-Bold',
        fontSize=22,
        leading=26,
        textColor=PRIMARY,
        spaceAfter=4
    )
    
    subtitle_style = ParagraphStyle(
        'DocSubtitle',
        parent=styles['Normal'],
        fontName='Helvetica',
        fontSize=11,
        leading=15,
        textColor=TEAL,
        spaceAfter=15
    )

    h1_style = ParagraphStyle(
        'H1',
        parent=styles['Heading2'],
        fontName='Helvetica-Bold',
        fontSize=13,
        leading=17,
        textColor=PRIMARY,
        spaceBefore=14,
        spaceAfter=6,
        keepWithNext=True
    )
    
    h2_style = ParagraphStyle(
        'H2',
        parent=styles['Heading3'],
        fontName='Helvetica-Bold',
        fontSize=10.5,
        leading=14,
        textColor=SECONDARY,
        spaceBefore=8,
        spaceAfter=4,
        keepWithNext=True
    )

    body_style = ParagraphStyle(
        'Body',
        parent=styles['Normal'],
        fontName='Helvetica',
        fontSize=9,
        leading=13,
        textColor=DARK_TEXT,
        spaceAfter=5
    )

    formula_title_style = ParagraphStyle(
        'FormulaTitle',
        fontName='Helvetica-Bold',
        fontSize=10,
        leading=13,
        textColor=PRIMARY
    )

    formula_expr_style = ParagraphStyle(
        'FormulaExpr',
        fontName='Courier-Bold',
        fontSize=10.5,
        leading=14,
        textColor=TEAL
    )

    table_header_style = ParagraphStyle(
        'TableHeader',
        fontName='Helvetica-Bold',
        fontSize=8.5,
        leading=11,
        textColor=colors.white
    )

    table_cell_style = ParagraphStyle(
        'TableCell',
        fontName='Helvetica',
        fontSize=8,
        leading=11,
        textColor=DARK_TEXT
    )

    story = []

    # Title Block / Header Banner
    story.append(Paragraph("XSIGHT THORACIC AI SYSTEM", title_style))
    story.append(Paragraph("Statistical Treatment of Data & Evaluation Metrics Guide", subtitle_style))
    story.append(HRFlowable(width="100%", thickness=2, color=PRIMARY, spaceBefore=0, spaceAfter=10))

    # Metadata Box
    meta_data = [
        [
            Paragraph("<b>Target System:</b> XSIGHT AI Kiosk & Mobile", body_style),
            Paragraph("<b>Application:</b> Chapter 3 Thesis / Capstone", body_style),
            Paragraph("<b>Document Version:</b> 1.0 (2026)", body_style)
        ]
    ]
    meta_table = Table(meta_data, colWidths=[2.3*inch, 2.7*inch, 2.0*inch])
    meta_table.setStyle(TableStyle([
        ('BACKGROUND', (0,0), (-1,-1), LIGHT_BG),
        ('BOX', (0,0), (-1,-1), 0.5, ACCENT_BORDER),
        ('PADDING', (0,0), (-1,-1), 5),
        ('VALIGN', (0,0), (-1,-1), 'MIDDLE'),
    ]))
    story.append(meta_table)
    story.append(Spacer(1, 10))

    # Introduction
    intro_p = Paragraph(
        "This document specifies the standard <b>Statistical Treatment of Data</b> formulas used to evaluate the XSIGHT "
        "medical AI thoracic screening application. It provides formulas for quantitative user evaluation (SUS), "
        "AI diagnostic classification accuracy (X-ray & vision models), latency performance, and clinical concordance.",
        body_style
    )
    story.append(intro_p)
    story.append(Spacer(1, 8))

    # Helper function for Formula Cards
    def make_formula_card(title, math_expr, desc_text, variables_list):
        content = []
        content.append(Paragraph(title, formula_title_style))
        content.append(Spacer(1, 2))
        content.append(Paragraph(f"<b>Formula: &nbsp;&nbsp; {math_expr}</b>", formula_expr_style))
        content.append(Spacer(1, 3))
        content.append(Paragraph(desc_text, body_style))
        
        vars_formatted = "<br/>".join([f"• <b>{v[0]}</b> = {v[1]}" for v in variables_list])
        content.append(Paragraph(f"<b>Where:</b><br/>{vars_formatted}", body_style))
        
        card_table = Table([[content]], colWidths=[7.0 * inch])
        card_table.setStyle(TableStyle([
            ('BACKGROUND', (0,0), (-1,-1), LIGHT_BG),
            ('BOX', (0,0), (-1,-1), 1, ACCENT_BORDER),
            ('LINELEFT', (0,0), (-1,-1), 4, TEAL),
            ('PADDING', (0,0), (-1,-1), 7),
        ]))
        return KeepTogether([card_table, Spacer(1, 8)])

    # SECTION 1: DESCRIPTIVE STATISTICS
    story.append(Paragraph("1. Descriptive Statistics Formulas", h1_style))
    story.append(HRFlowable(width="100%", thickness=0.5, color=SECONDARY, spaceBefore=0, spaceAfter=6))

    # Formula 1: Frequency & Percentage
    story.append(make_formula_card(
        "1.1 Frequency & Percentage (P)",
        "P = ( f / N ) * 100%",
        "Quantifies respondent distribution across demographics, symptom severity, and XSIGHT risk scoring categories (Low, Moderate, High).",
        [
            ("P", "Percentage (%)"),
            ("f", "Frequency or count of cases in a category"),
            ("N", "Total sample size / total respondents")
        ]
    ))

    # Formula 2: Weighted Mean
    story.append(make_formula_card(
        "1.2 Weighted Mean (X̄)",
        "X̄ = Σ(f * x) / N",
        "Calculates average evaluation scores from Likert scale survey responses (usability, interface quality, clinical utility).",
        [
            ("X̄", "Weighted Mean score"),
            ("f", "Frequency of responses for a specific scale rating"),
            ("x", "Assigned numeric weight (e.g., 1 to 5)"),
            ("N", "Total number of respondents")
        ]
    ))

    # Likert Table
    story.append(Paragraph("<b>Likert Scale Verbal Interpretation Reference Table:</b>", h2_style))
    likert_data = [
        [Paragraph("Scale Weight", table_header_style), Paragraph("Mean Range", table_header_style), Paragraph("Qualitative Rating", table_header_style), Paragraph("Clinical / Usability Interpretation", table_header_style)],
        [Paragraph("5", table_cell_style), Paragraph("4.21 – 5.00", table_cell_style), Paragraph("Strongly Agree", table_cell_style), Paragraph("Outstanding usability & strong clinical agreement", table_cell_style)],
        [Paragraph("4", table_cell_style), Paragraph("3.41 – 4.20", table_cell_style), Paragraph("Agree", table_cell_style), Paragraph("High satisfaction; acceptable performance", table_cell_style)],
        [Paragraph("3", table_cell_style), Paragraph("2.61 – 3.40", table_cell_style), Paragraph("Neutral", table_cell_style), Paragraph("Moderate quality; minor usability refinements needed", table_cell_style)],
        [Paragraph("2", table_cell_style), Paragraph("1.81 – 2.60", table_cell_style), Paragraph("Disagree", table_cell_style), Paragraph("Low usability / frequent clinical discrepancy", table_cell_style)],
        [Paragraph("1", table_cell_style), Paragraph("1.00 – 1.80", table_cell_style), Paragraph("Strongly Disagree", table_cell_style), Paragraph("Unacceptable system performance", table_cell_style)],
    ]
    likert_table = Table(likert_data, colWidths=[0.9*inch, 1.1*inch, 1.3*inch, 3.7*inch])
    likert_table.setStyle(TableStyle([
        ('BACKGROUND', (0,0), (-1,0), PRIMARY),
        ('ALIGN', (0,0), (-1,-1), 'LEFT'),
        ('VALIGN', (0,0), (-1,-1), 'MIDDLE'),
        ('GRID', (0,0), (-1,-1), 0.5, colors.HexColor("#D1D5DB")),
        ('ROWBACKGROUNDS', (0,1), (-1,-1), [colors.white, LIGHT_BG]),
        ('PADDING', (0,0), (-1,-1), 4),
    ]))
    story.append(likert_table)
    story.append(Spacer(1, 8))

    # Formula 3: Standard Deviation
    story.append(make_formula_card(
        "1.3 Standard Deviation (SD)",
        "SD = sqrt[ Σ(x - X̄)² / (n - 1) ]",
        "Measures the dispersion and stability of system response latency (STT/TTS delays in seconds) and vital sign telemetry readings.",
        [
            ("SD", "Sample Standard Deviation"),
            ("x", "Observed value in a single trial"),
            ("X̄", "Mean value across trials"),
            ("n", "Total number of trial iterations")
        ]
    ))

    # SECTION 2: AI DIAGNOSTIC METRICS
    story.append(Paragraph("2. AI Diagnostic & Machine Learning Evaluation Metrics", h1_style))
    story.append(HRFlowable(width="100%", thickness=0.5, color=SECONDARY, spaceBefore=0, spaceAfter=6))

    story.append(Paragraph(
        "Evaluates the performance of XSIGHT's X-ray classifier, multimodal vision provider, and vitals risk scoring against medical ground truth.",
        body_style
    ))
    story.append(Spacer(1, 4))

    # Metrics Summary Table
    ai_metrics_data = [
        [Paragraph("Diagnostic Metric", table_header_style), Paragraph("Mathematical Formula", table_header_style), Paragraph("Clinical Purpose in XSIGHT", table_header_style)],
        [
            Paragraph("<b>Overall Accuracy (ACC)</b>", table_cell_style),
            Paragraph("ACC = (TP + TN) / (TP + TN + FP + FN)", table_cell_style),
            Paragraph("Measures overall percentage of correct predictions across all cases.", table_cell_style)
        ],
        [
            Paragraph("<b>Sensitivity / Recall (SEN)</b>", table_cell_style),
            Paragraph("SEN = TP / (TP + FN)", table_cell_style),
            Paragraph("<b>Critical for Screening:</b> Ability to correctly detect actual disease (minimizes False Negatives).", table_cell_style)
        ],
        [
            Paragraph("<b>Specificity (SPE)</b>", table_cell_style),
            Paragraph("SPE = TN / (TN + FP)", table_cell_style),
            Paragraph("Ability to correctly identify normal/healthy patients (minimizes false alarms).", table_cell_style)
        ],
        [
            Paragraph("<b>Precision / PPV</b>", table_cell_style),
            Paragraph("PREC = TP / (TP + FP)", table_cell_style),
            Paragraph("Proportion of positive AI flags confirmed true by clinical diagnosis.", table_cell_style)
        ],
        [
            Paragraph("<b>F1-Score</b>", table_cell_style),
            Paragraph("F1 = 2 * (PREC * SEN) / (PREC + SEN)", table_cell_style),
            Paragraph("Harmonic balance between Precision & Sensitivity for imbalanced medical data.", table_cell_style)
        ],
    ]
    ai_table = Table(ai_metrics_data, colWidths=[1.5*inch, 2.5*inch, 3.0*inch])
    ai_table.setStyle(TableStyle([
        ('BACKGROUND', (0,0), (-1,0), SECONDARY),
        ('GRID', (0,0), (-1,-1), 0.5, colors.HexColor("#D1D5DB")),
        ('ROWBACKGROUNDS', (0,1), (-1,-1), [colors.white, LIGHT_BG]),
        ('PADDING', (0,0), (-1,-1), 4),
        ('VALIGN', (0,0), (-1,-1), 'MIDDLE'),
    ]))
    story.append(ai_table)
    story.append(Spacer(1, 6))

    # Confusion Matrix Legend Box
    cm_text = (
        "<b>Confusion Matrix Legend:</b><br/>"
        "• <b>TP (True Positive):</b> XSIGHT correctly flagged a thoracic abnormality.<br/>"
        "• <b>TN (True Negative):</b> XSIGHT correctly classified a healthy patient as normal.<br/>"
        "• <b>FP (False Positive):</b> XSIGHT incorrectly flagged a normal patient as sick.<br/>"
        "• <b>FN (False Negative):</b> XSIGHT missed an actual thoracic pathology (High Risk)."
    )
    cm_card = Table([[Paragraph(cm_text, body_style)]], colWidths=[7.0*inch])
    cm_card.setStyle(TableStyle([
        ('BACKGROUND', (0,0), (-1,-1), colors.HexColor("#FFF8E1")),
        ('BOX', (0,0), (-1,-1), 1, colors.HexColor("#FFE082")),
        ('PADDING', (0,0), (-1,-1), 5),
    ]))
    story.append(cm_card)
    story.append(Spacer(1, 8))

    # SECTION 3: SYSTEM USABILITY SCALE
    story.append(Paragraph("3. System Usability Scale (SUS) Formula", h1_style))
    story.append(HRFlowable(width="100%", thickness=0.5, color=SECONDARY, spaceBefore=0, spaceAfter=6))

    story.append(make_formula_card(
        "3.1 Standard SUS Score Calculation",
        "SUS Score = 2.5 * [ Σ(Q_odd - 1) + Σ(5 - Q_even) ]",
        "Standardized usability calculation across 10 post-interaction questionnaire items.",
        [
            ("Q_odd", "Scores from odd items (1, 3, 5, 7, 9) — positive statements"),
            ("Q_even", "Scores from even items (2, 4, 6, 8, 10) — negative statements"),
            ("Multiplier 2.5", "Converts the raw score sum (0–40 range) to a standardized 0–100 scale")
        ]
    ))

    # SECTION 4: INFERENTIAL STATISTICS
    story.append(Paragraph("4. Inferential Statistics & Clinical Concordance", h1_style))
    story.append(HRFlowable(width="100%", thickness=0.5, color=SECONDARY, spaceBefore=0, spaceAfter=6))

    # Cohen's Kappa
    story.append(make_formula_card(
        "4.1 Cohen's Kappa Coefficient (κ)",
        "κ = ( P_o - P_e ) / ( 1 - P_e )",
        "Evaluates inter-rater agreement between XSIGHT AI risk score and licensed clinician evaluation.",
        [
            ("κ", "Cohen's Kappa agreement statistic"),
            ("P_o", "Observed relative agreement ratio between AI and clinician"),
            ("P_e", "Expected probability of agreement occurring by pure chance alone"),
            ("Interpretation", "κ > 0.80 = Almost Perfect Agreement; 0.61–0.80 = Substantial Agreement")
        ]
    ))

    # Paired t-Test
    story.append(make_formula_card(
        "4.2 Paired t-Test (t)",
        "t = d̄ / ( s_d / sqrt[n] )",
        "Tests for significant differences between XSIGHT telemetry readings (Heart Rate, SpO2) and standard clinical monitoring devices.",
        [
            ("t", "Calculated t-statistic"),
            ("d̄", "Mean of differences between paired XSIGHT and reference device readings"),
            ("s_d", "Standard deviation of difference scores"),
            ("n", "Number of paired sample measurements")
        ]
    ))

    # Document Footer Note
    story.append(Spacer(1, 6))
    story.append(HRFlowable(width="100%", thickness=1, color=PRIMARY, spaceBefore=0, spaceAfter=6))
    story.append(Paragraph(
        "<i>Note: Medical AI systems like XSIGHT are intended for screening assistance and clinical decision support. "
        "All statistical validation protocols should be reviewed alongside institutional ethics board standards.</i>",
        ParagraphStyle('FooterNote', parent=styles['Normal'], fontName='Helvetica-Oblique', fontSize=7.5, textColor=colors.HexColor("#616161"))
    ))

    doc.build(story, canvasmaker=NumberedCanvas)

if __name__ == "__main__":
    out_dir = "/home/jay/.gemini/antigravity-cli/brain/e447c38c-2778-4b1b-924d-13092080d13d"
    os.makedirs(out_dir, exist_ok=True)
    
    target_path = os.path.join(out_dir, "xsight_statistical_treatment_guide.pdf")
    build_pdf(target_path)
    
    # Copy to workspace as well
    ws_path = "/home/jay/Documents/project/tupi/xsight/xsight_statistical_treatment_guide.pdf"
    import shutil
    shutil.copyfile(target_path, ws_path)
    
    print(f"PDF generated successfully at:\n - {target_path}\n - {ws_path}")
