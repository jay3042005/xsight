# XSIGHT Kiosk App — Features Guide

**For Healthcare Professionals and Clinical Staff**

---

## What is XSIGHT Kiosk?

XSIGHT Kiosk is a tablet-based clinical workstation that helps healthcare professionals assess respiratory conditions faster and more accurately. It combines multiple diagnostic tools into one easy-to-use system.

---

## Main Features

### 1. **Dashboard — At-a-Glance Overview**
Your command center showing:
- **Today's patient count** and recent assessments
- **Active alerts** requiring immediate attention
- **System health** (sensor connection status, AI engine status)
- **Quick-launch buttons** for common tasks

**What you can do:**
- See all critical information in one place
- Jump directly to any tool with one tap
- Monitor system status in real-time

---

### 2. **Patient Management**
Complete electronic medical record system built specifically for respiratory care.

**What you can do:**
- **Search patients** by name, ID, or phone number
- **Add new patients** with demographics and medical history
- **View patient timeline** — all past visits, X-rays, lung sounds, and assessments in one place
- **Track vital signs over time** — see trends and changes
- **Quick access** to recent patients from any screen

**Information stored:**
- Name, date of birth, sex, weight, height
- Contact information
- Medical history and notes
- All diagnostic results (X-rays, lung sounds, vital signs)
- Risk assessments and recommendations

---

### 3. **Chest X-Ray Analysis**
AI-powered chest X-ray screening that identifies respiratory abnormalities.

**What you can do:**
- **Upload X-ray images** from camera or file picker
- **Get instant AI analysis** identifying:
  - Pneumonia
  - Tuberculosis (TB)
  - Pleural effusion (fluid in lungs)
  - Cardiomegaly (enlarged heart)
  - Lung masses
  - Other abnormalities
- **See confidence scores** — how certain the AI is about each finding
- **View heatmap overlay** — visual highlights showing exactly where the AI detected abnormalities
- **Link results to patient records** automatically

**What the AI tells you:**
- **Disease classification** (e.g., "Pneumonia detected")
- **Confidence level** (e.g., 87% certain)
- **Visual heatmap** showing affected lung areas
- **Clinical recommendations** based on findings

**Important:** This is an AI-assisted screening tool, not a replacement for radiologist interpretation.

---

### 4. **Digital Lung Sound Analysis**
Record and analyze lung sounds (digital stethoscope function).

**What you can do:**
- **Record lung sounds** using the device microphone or external digital stethoscope
- **See recording timer** and waveform in real-time
- **Get instant classification**:
  - **Normal** — no abnormal sounds
  - **Crackle** — popping sounds (suggests fluid, pneumonia, fibrosis)
  - **Wheeze** — musical sounds (suggests asthma, COPD, bronchospasm)
  - **Both** — crackle + wheeze (suggests complex condition)
- **Link to patient record** for longitudinal tracking
- **Automatic CDSS analysis** combining lung sounds with other data

**What the AI tells you:**
- **Sound classification** (normal/crackle/wheeze/both)
- **Confidence score**
- **Clinical interpretation** — what the sounds typically indicate
- **Recommended next steps** (e.g., "Consider chest X-ray")

---

### 5. **Vital Signs Monitoring**
Real-time physiological monitoring from connected sensors.

**What you can monitor:**
- **Heart Rate (HR)** — beats per minute
- **Blood Oxygen (SpO₂)** — oxygen saturation percentage
- **Blood Pressure (BP)** — systolic/diastolic mmHg (requires an optional cuff; module shows "No cuff connected" without one)

Temperature has its own station rather than a gauge here. It reads an infrared temperature from the
**same fingertip** as the pulse sensor — not a forehead — and completes on its own timed window.
Because a fingertip is peripheral skin rather than core body temperature, treat the number as a
screening signal and not as a clinical thermometer reading.

**Visual displays:**
- **Live gauges** for heart rate and SpO₂
- **Color-coded alerts** (green = normal, orange = warning, red = critical)
- **Trend charts** showing changes over the last 30 readings

**Automatic alerts for:**
- Heart rate too high or too low
- Blood oxygen below 92%
- High or low blood pressure

**Sensor connection:**
- Automatically connects to ESP32 sensor hub via USB Type-C
- Falls back to demo mode if no sensor connected
- Shows "LIVE" badge when real sensor data is active

---

### 6. **Clinical Decision Support System (CDSS)**
AI-powered intelligent assistant that combines all diagnostic data.

**What it does:**
- **Fuses multiple data sources**:
  - Chest X-ray findings
  - Lung sound classification
  - Vital signs readings
  - Patient demographics
- **Calculates overall risk level**:
  - LOW — routine monitoring
  - MODERATE — closer attention needed
  - HIGH — priority assessment required
  - CRITICAL — immediate intervention needed
- **Generates differential diagnosis** — list of possible conditions ranked by likelihood
- **Provides evidence-based recommendations** — what tests or treatments to consider
- **Creates automatic alerts** for high-risk patients

**What you see:**
- **Risk score and level** (color-coded)
- **Likely diagnoses** with confidence percentages
- **Clinical recommendations** based on current evidence
- **Active alerts** requiring attention
- **Recent assessment history** for all patients

**How it works:**
- Runs automatically when X-ray or lung sound data is available
- Uses medical knowledge base with disease-specific rules
- Considers vital sign thresholds and alert conditions
- Saves all assessments to patient record for review

**Example CDSS output:**
```
Overall Risk: HIGH (0.72)

Differential Diagnosis:
1. Pneumonia (85% confidence) — from X-ray
2. Crackle sounds detected (72% confidence) — from lung sounds
3. Fever present (38.9°C) — from the temperature station

Recommendations:
✓ Consider chest X-ray confirmation
✓ Order CBC, CRP, procalcitonin
✓ Sputum culture if productive cough
✓ Assess need for hospitalization

Active Alerts:
⚠️ Pneumonia + SpO₂=89% — URGENT
⚠️ Temperature 38.9°C — high fever
```

---

### 7. **AI Assistant (Chatbot)**
Conversational AI that answers medical questions and helps with clinical decisions.

**What you can do:**
- **Ask medical questions** in natural language
- **Get instant evidence-based answers**
- **Discuss patient cases** for second opinion
- **Search medical knowledge** without leaving the workflow

**Example questions:**
- "What are the typical signs of bacterial pneumonia?"
- "When should I refer a TB patient to a specialist?"
- "Explain the difference between crackle and wheeze sounds"

**Important:** The AI assistant is for informational support only, not for definitive diagnosis.

---

### 8. **Reports & Documentation**
Generate professional PDF reports for patient records.

**What you can generate:**
- **Patient assessment reports** including:
  - Patient demographics
  - Vital signs summary
  - X-ray findings with images
  - Lung sound results
  - CDSS risk assessment
  - Clinical recommendations
- **Export to PDF** for printing or EMR integration
- **Professional formatting** with XSIGHT branding

---

### 9. **Analytics Dashboard**
View aggregate statistics and performance metrics.

**What you can see:**
- **Total patients assessed** this month
- **Disease distribution** — breakdown by condition
- **Average risk levels** across patient population
- **Busiest assessment times** — daily/weekly trends
- **System usage statistics**

**Useful for:**
- Quality improvement tracking
- Resource planning
- Identifying disease trends
- Performance monitoring

---

### 10. **Notifications & Alerts**
Smart notification system for time-sensitive events.

**Types of alerts:**
- **Critical patient alerts** (high/critical risk assessments)
- **System notifications** (sensor disconnected, AI unavailable)
- **CDSS alerts** (urgent conditions detected)
- **Patient updates** (new results available)

**Features:**
- Color-coded by severity (info/warning/critical)
- One-tap to jump to relevant patient or tool
- Mark as read or dismiss
- Alert history for review

---

### 11. **Settings**
Configure the system for your environment.

**What you can configure:**
- **Server connection** — enter backend IP address
- **Test connection** — verify system is working
- **View system info** — AI models, software version
- **Connection status** — see if all components are online

---

## How Sensors Connect

### ESP32 Sensor Hub (via USB Type-C)
The kiosk tablet connects to a medical sensor hub via USB cable (or Bluetooth). The sensor hub collects data from:
- Pulse oximeter — heart rate and SpO₂, from a fingertip
- Infrared thermometer — temperature, from the same fingertip
- Digital stethoscope — lung sounds

Not present on this hub: there is no blood-pressure cuff and no respiratory-rate sensor. Blood
pressure is shown as "No cuff connected" rather than a number, and respiratory rate is not
displayed at all — a gauge with nothing measuring behind it is worse than an absent one.

**Connection is automatic:**
1. Plug USB Type-C cable from sensor hub into tablet
2. Kiosk detects the sensor automatically
3. "LIVE" badge appears showing real sensor data
4. Vitals update in real-time

**If no sensor is connected:**
- System runs in demo mode with simulated data
- "SIMULATED" badge shows clearly
- All other features work normally
- Can still train and test the system

---

## Typical Workflow

### Complete Patient Assessment (5-10 minutes)

1. **Select or add patient** from Patient Management
2. **Record vital signs** — sensor reads automatically or enter manually
3. **Record lung sounds** — 30-60 second recording per lung zone
4. **Upload chest X-ray** if available
5. **Review CDSS assessment** — automatic risk calculation
6. **Consult AI assistant** if needed for clinical questions
7. **Generate PDF report** for patient record
8. **Mark high-risk patients** for follow-up via notifications

---

## What Makes XSIGHT Different?

✅ **All-in-one system** — no need to switch between 5 different apps  
✅ **AI-powered but clinician-controlled** — AI assists, you decide  
✅ **Real-time sensor integration** — automatic vital signs capture  
✅ **Comprehensive records** — everything in one patient timeline  
✅ **Evidence-based recommendations** — follows clinical guidelines  
✅ **Works offline** — all AI runs locally, no internet required  
✅ **Fast assessments** — complete evaluation in 5-10 minutes  
✅ **Clear visual feedback** — color-coded alerts, charts, heatmaps  

---

## Important Disclaimers

⚠️ **This is an AI-assisted screening tool, not a diagnostic device**  
⚠️ **Final diagnosis remains the responsibility of licensed healthcare professionals**  
⚠️ **Always follow your clinical judgment over AI recommendations**  
⚠️ **For emergency cases, activate standard emergency protocols immediately**  
⚠️ **System is designed to assist, not replace, professional medical assessment**

---

## Support & Training

For questions, training, or technical support, contact your system administrator or refer to the full technical documentation.

**Quick Help:** Press the `?` icon in any screen for context-sensitive help.

---

**XSIGHT Kiosk App** — Intelligent Thoracic Assessment for Modern Healthcare
