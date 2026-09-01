import 'package:flutter/material.dart';
import '../core/sensor/esp32_serial_client.dart';
import '../core/api/emr_client.dart';

/// Central state for Kiosk User Modes:
/// - Guest Mode: Explore / Demo Only (Sample patient data, sample AI X-ray, sample lung sound, sample vitals & AI report).
/// - Staff Mode: Main Operational Access (Real patient registration, sensor collection, EMR storage, clinical decision support).
class KioskPatientSession extends ChangeNotifier {
  static final KioskPatientSession I = KioskPatientSession._();
  KioskPatientSession._() {
    _initGuestPatient();
  }

  bool _isStaffMode = false;
  String _staffName = 'Dr. Sarah Jenkins (Clinician)';
  Map<String, dynamic>? _selectedPatient;

  bool get isStaffMode => _isStaffMode;
  String get staffName => _staffName;
  Map<String, dynamic>? get selectedPatient => _selectedPatient;

  /// Whether this session belongs to nobody on record.
  ///
  /// Derived from the *record*, not from staff sign-in. Every guest record
  /// carries `isGuest: true` (see [_initGuestPatient]) and [setGuestMode] always
  /// installs one, so this is equivalent for the staff and walk-in paths — but it
  /// also admits the third case: a record dispatched from the web portal, which
  /// must save its readings without granting the kiosk staff privileges. Module
  /// visibility keys off [isStaffMode] separately, so linking a portal patient
  /// does not unlock Settings to whoever is standing there.
  bool get isGuest =>
      _selectedPatient == null || _selectedPatient!['isGuest'] == true;

  /// The EMR record id every upload and CDSS write in this session must be
  /// attached to, or null for a walk-in with no record.
  ///
  /// Single source of truth for patient linkage. The X-ray and lung-sound
  /// screens each used to keep their own local `_selectedPatientId`, so a
  /// staff member who had linked a patient on the dashboard still uploaded
  /// with `patientId: null` unless they also re-picked the same patient inside
  /// each screen — and the two screens could disagree with each other and with
  /// the `PATIENT:` line on the OLED.
  int? get selectedPatientId {
    final id = _selectedPatient?['id'];
    if (id is int) return id;
    return id == null ? null : int.tryParse('$id');
  }

  // ─── GUEST DEMO DATASETS (Explore / Demo Only) ───────────────────
  Map<String, dynamic> get samplePatientData => const {
    'id': 999,
    'name': 'Sample Demo Patient (John Doe)',
    'mrn': 'DEMO-4091',
    'age': 45,
    'gender': 'Male',
    'condition': 'Sample Exploration Record',
  };

  Map<String, dynamic> get sampleXrayAnalysis => const {
    'finding': 'Clear Lung Fields / No Acute Consolidation',
    'confidence': 0.96,
    'heatmap_available': true,
    'status': 'Sample AI Analysis (Demo)',
  };

  Map<String, dynamic> get sampleLungSoundAnalysis => const {
    'classification': 'Vesicular Breath Audio',
    'frequency': '20Hz - 800Hz Normal',
    'confidence': 0.98,
    'status': 'Sample Acoustic Analysis (Demo)',
  };

  Map<String, dynamic> get sampleVitals => const {
    'hr': 72.0,
    'spo2': 98.0,
    'temp': 36.8,
    'rr': 16.0,
    'bp': '120/80',
    'status': 'Sample Vital-Sign Results (Demo)',
  };

  Map<String, dynamic> get sampleAiAssessment => const {
    'diagnosis': 'Sample Respiratory Assessment: Baseline Clear',
    'risk_level': 'Low Risk',
    'recommendations': [
      'Vital signs and lung sounds are within normal reference intervals.',
      'Routine annual wellness screening recommended.',
      'Demo Assessment: Sign in as Staff to perform real patient EMR triage.',
    ],
  };

  // ─── REAL SENSOR READINGS FOR THE CURRENT SESSION ─────────────────
  // Despite the `guest` prefix (kept because ~10 screens read these getters),
  // this is the *current session's* reading set and is populated in staff mode
  // too: it is what the CDSS summary, the AI assistant's patient context, and
  // the PDF report all read from. Anything that records a reading must write
  // here regardless of mode, and [resetGuestSession] must run whenever the
  // session's subject changes.
  double? _guestHr;
  double? _guestSpo2;
  double? _guestTemp;
  String? _guestStethAudioPath;
  String? _guestStethFinding;
  String? _guestXrayImagePath;
  String? _guestXrayFinding;
  double? _guestXrayConfidence;
  String? _guestXrayHeatmapB64;

  /// Whether a station's reading came off real hardware.
  ///
  /// The vitals screen has three sources — the ESP32 hub, the mock `/ws/vitals`
  /// stream, and a local random walk when nothing is attached — and only the
  /// first is a measurement. Without this the other two would reach the CDSS,
  /// the AI's patient context, and the printed report indistinguishable from a
  /// real reading. Temperature, lung sounds and x-ray have no simulated source
  /// today, so only vitals and temp carry a flag.
  bool _guestVitalsSimulated = false;
  bool _guestTempSimulated = false;

  bool get guestVitalsSimulated => _guestVitalsSimulated;
  bool get guestTempSimulated => _guestTempSimulated;

  /// True when anything held in this session was not measured by a sensor.
  /// Drives the DEMO marker wherever readings are shown.
  bool get hasSimulatedReadings =>
      (hasGuestVitals && _guestVitalsSimulated) ||
      (hasGuestTemp && _guestTempSimulated);

  /// When the first reading of this intake session landed.
  ///
  /// Stamped by the recorders rather than by whoever opens the kiosk, because an
  /// idle dashboard left up overnight is not a session that started at midnight
  /// — the elapsed time on the status panel is only meaningful from the first
  /// real measurement.
  DateTime? _sessionStartedAt;

  DateTime? get sessionStartedAt => _sessionStartedAt;

  bool _intakeOpen = false;

  /// True from the moment someone starts an intake session until it is reset.
  ///
  /// This is what makes check-in happen once. It is deliberately separate from
  /// [hasIntakeName] and [hasHeldIntakeReadings]: a session where check-in was
  /// skipped has neither, and a session is no less open for it. Without this
  /// flag the only way to ask "have we already checked this person in?" was to
  /// look for a name or a reading, so backing out of the station orbit and
  /// pressing START re-asked the same person for their name.
  bool get isIntakeOpen => _intakeOpen;

  double? get guestHr => _guestHr;
  double? get guestSpo2 => _guestSpo2;
  double? get guestTemp => _guestTemp;
  String? get guestStethAudioPath => _guestStethAudioPath;
  String? get guestStethFinding => _guestStethFinding;
  String? get guestXrayImagePath => _guestXrayImagePath;
  String? get guestXrayFinding => _guestXrayFinding;
  double? get guestXrayConfidence => _guestXrayConfidence;

  /// Base64 Grad-CAM overlay for the session's film, when the local classifier
  /// produced one. Null on the vision-fallback path, which has no heatmap —
  /// callers must treat the third panel as optional rather than assume it.
  String? get guestXrayHeatmapB64 => _guestXrayHeatmapB64;

  bool get hasGuestVitals =>
      _guestHr != null && _guestSpo2 != null && _guestHr! > 0;
  bool get hasGuestTemp => _guestTemp != null && _guestTemp! > 0;
  bool get hasGuestSteth =>
      _guestStethFinding != null && _guestStethFinding!.isNotEmpty;
  bool get hasGuestXray =>
      _guestXrayFinding != null && _guestXrayFinding!.isNotEmpty;

  /// True once check-in supplied a name, as opposed to the generated walk-in
  /// label. Single source for the test [patientDisplayName] makes internally, so
  /// the intake dashboard does not have to sniff the string itself.
  bool get hasIntakeName {
    if (!isGuest) return _selectedPatient?['name'] != null;
    final typed = '${_selectedPatient?['name'] ?? ''}'.trim();
    return typed.isNotEmpty && !typed.startsWith('Walk-In Guest');
  }

  /// True while this session is holding readings that no EMR record owns yet.
  ///
  /// Read before linking a patient, so a clinician is asked what to do with them
  /// instead of having them silently dropped — see [selectPatient].
  bool get hasHeldIntakeReadings => measuredStationCount > 0;

  /// Mark the session underway, from a reading rather than from check-in.
  ///
  /// A station reached without passing through check-in — the dashboard's direct
  /// station jump, or a screen opened by hardware — still starts a session. The
  /// alternative is a session that holds readings but is not open, which would
  /// pop the check-in dialog at someone who has already been measured.
  void _markSessionUnderway() {
    _sessionStartedAt ??= DateTime.now();
    _intakeOpen = true;
  }

  /// [simulated] marks a value that no sensor produced. Defaults to false so a
  /// caller that forgets cannot silently promote demo data to a measurement.
  void recordVitals(double hr, double spo2, {bool simulated = false}) {
    if (hr > 0 && spo2 > 0) {
      _guestHr = hr;
      _guestSpo2 = spo2;
      _guestVitalsSimulated = simulated;
      _markSessionUnderway();
      _writeVitalsToEmr(hr: hr, spo2: spo2);
      notifyListeners();
    }
  }

  void recordTemp(double temp, {bool simulated = false}) {
    if (temp > 0) {
      _guestTemp = temp;
      _guestTempSimulated = simulated;
      _markSessionUnderway();
      _writeVitalsToEmr(temp: temp);
      notifyListeners();
    }
  }

  /// Push a reading to the linked record's vitals history, fire-and-forget.
  ///
  /// Nothing in the kiosk used to POST station readings — only the manual
  /// entry dialog did — so a session dispatched from the web portal measured
  /// fine on the kiosk while the patient's dashboard history stayed empty.
  /// Written per-reading rather than batched at Stop so an aborted session
  /// still leaves what was actually measured. Walk-ins stay out of the EMR by
  /// design ([selectedPatientId] is null), and a failed write is logged, not
  /// surfaced: losing one row must not interrupt a reading in progress.
  void _writeVitalsToEmr({double hr = 0, double spo2 = 0, double temp = 0}) {
    final pid = selectedPatientId;
    if (pid == null || pid <= 0) return;
    EMRClient()
        .recordVitals(pid, {
          if (hr > 0) 'hr': hr,
          if (spo2 > 0) 'spo2': spo2,
          if (temp > 0) 'temp': temp,
          'source': 'kiosk',
        })
        .then(
          (_) => debugPrint(
            '[session] vitals -> EMR #$pid (hr=$hr spo2=$spo2 temp=$temp)',
          ),
        )
        .catchError(
          (Object e) =>
              debugPrint('[session] vitals EMR write failed for #$pid: $e'),
        );
  }

  void recordStethoscope(String audioPath, String finding) {
    _guestStethAudioPath = audioPath;
    _guestStethFinding = finding;
    _markSessionUnderway();
    notifyListeners();
  }

  void recordXray(
    String imagePath,
    String finding,
    double confidence, {
    String? heatmapB64,
  }) {
    _guestXrayImagePath = imagePath;
    _guestXrayFinding = finding;
    _guestXrayConfidence = confidence;
    // Only overwrite when this reading actually carried a heatmap, so a
    // vision-fallback result cannot blank out a good overlay from a re-run.
    if (heatmapB64 != null && heatmapB64.isNotEmpty) {
      _guestXrayHeatmapB64 = heatmapB64;
    }
    _markSessionUnderway();
    notifyListeners();
  }

  void resetGuestSession() {
    _guestHr = null;
    _guestSpo2 = null;
    _guestTemp = null;
    _guestStethAudioPath = null;
    _guestStethFinding = null;
    _guestXrayImagePath = null;
    _guestXrayFinding = null;
    _guestXrayConfidence = null;
    _guestXrayHeatmapB64 = null;
    _guestVitalsSimulated = false;
    _guestTempSimulated = false;
    _sessionStartedAt = null;
    _intakeOpen = false;
    _intakeSymptoms = const [];
    // The ESP32 owns its own buffers, completion flags and OLED summary. Clearing
    // Flutter alone leaves the previous person's readings on the module until
    // each station happens to be opened again.
    Esp32SerialClient.shared.sendCommand('NEW_SESSION');
    // The sensor hub is app-lifetime and caches the last snapshot; leaving it
    // meant the next session's stations came up displaying the previous
    // person's heart rate, SpO2 and temperature. Zeroed here so every stop —
    // kiosk-side or from the web portal's Stop Session — resets to 0.
    Esp32SerialClient.shared.clearReadings();
    _restoreGeneratedIntakeName();
    notifyListeners();
  }

  /// Open an intake session. This person is the subject until it is reset.
  ///
  /// Called once, when check-in resolves — *including* when it was skipped, which
  /// is the point: skipping is an answer, not an absence of one, and a skipped
  /// check-in must not be asked again.
  ///
  /// [resetGuestSession] is the only way back out, and it clears the name, the
  /// readings, their measured-or-simulated tags, and the start time along with
  /// this flag. One exit keeps "nothing carries over to the next person" a
  /// property of a single method rather than of every caller remembering.
  void openIntakeSession({String? name}) {
    if (!isGuest) return;
    if (name != null) setIntakeName(name);
    _intakeOpen = true;
    _sessionStartedAt ??= DateTime.now();
    notifyListeners();
  }

  /// The name a walk-in gave at check-in. Held only in this session — it is
  /// never written to the EMR, which is what keeps the "not saved to records"
  /// promise on the intake dashboard true.
  void setIntakeName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty || !isGuest || _selectedPatient == null) return;
    _selectedPatient!['name'] = trimmed;
    // A named subject is a session. Without this, a caller that set the name
    // without going through [openIntakeSession] would leave the dashboard showing
    // its "start your screening" invitation for someone already named on it.
    _intakeOpen = true;
    notifyListeners();
  }

  /// What the person said was wrong, in their own words, from phone check-in.
  ///
  /// Held for the session only, like the intake name. Read by the CDSS summary
  /// and the AI's patient context as *reported* symptoms — never as findings,
  /// which are the sensors' job.
  List<String> _intakeSymptoms = const [];

  List<String> get intakeSymptoms => _intakeSymptoms;

  /// Apply a phone check-in submission to this session.
  ///
  /// The payload came out of a browser form on the relay, so it is untrusted: age
  /// is range-checked, strings are trimmed and length-capped, and unknown keys are
  /// ignored. Guarded on [isGuest] for the same reason [setIntakeName] is — a
  /// submission must never be able to rewrite a linked EMR record's demographics,
  /// and nothing here is written to the EMR at all.
  void applyIntakeDetails(Map<String, dynamic> details) {
    if (!isGuest || _selectedPatient == null) return;

    String? str(Object? v, {int max = 80}) {
      if (v is! String) return null;
      final t = v.trim();
      if (t.isEmpty) return null;
      return t.length <= max ? t : t.substring(0, max);
    }

    final name = str(details['name']);
    if (name != null) setIntakeName(name);

    // Accepts a number or the string a form field posts.
    final rawAge = details['age'];
    final age = rawAge is num
        ? rawAge.toInt()
        : int.tryParse('${rawAge ?? ''}');
    if (age != null && age > 0 && age < 130) _selectedPatient!['age'] = age;

    final sex = str(details['sex'] ?? details['gender'], max: 24);
    if (sex != null) _selectedPatient!['gender'] = sex;

    final rawSymptoms = details['symptoms'];
    if (rawSymptoms is List) {
      _intakeSymptoms = rawSymptoms
          .map((e) => str(e, max: 60))
          .whereType<String>()
          .take(12)
          .toList(growable: false);
    }

    // A submission is a started session even when the name field was left blank:
    // somebody filled the form in, so the dashboard must stop inviting them to.
    _intakeOpen = true;
    _sessionStartedAt ??= DateTime.now();
    syncWithEsp32Hardware();
    notifyListeners();
  }

  /// Put the auto-generated walk-in label back, dropping any typed name.
  ///
  /// Guarded on [isGuest]: [resetGuestSession] also runs from [selectPatient]
  /// once a real record is linked, and overwriting `name` there would rename the
  /// patient.
  void _restoreGeneratedIntakeName() {
    if (!isGuest) return;
    final p = _selectedPatient;
    if (p == null) return;
    final id = '${p['guest_id'] ?? p['mrn'] ?? ''}'.replaceFirst('GST-', '');
    p['name'] = id.isEmpty ? 'Walk-In Guest' : 'Walk-In Guest (#$id)';
  }

  String get patientDisplayName {
    if (isGuest || _selectedPatient == null) {
      final idStr =
          _selectedPatient?['mrn'] ??
          _selectedPatient?['guest_id'] ??
          'Walk-In Guest';
      // A name given at check-in replaces the generated label everywhere the
      // display name is read — patient bar, CDSS summary, AI context, PDF — so
      // an intake report carries who it is about. The intake id stays appended
      // so the session remains traceable. Falls through to the old label when
      // check-in was skipped, or when the stored name is still the generated one.
      if (hasIntakeName) {
        return '${'${_selectedPatient!['name']}'.trim()} ($idStr)';
      }
      return 'Walk-In Guest ($idStr)';
    }
    final name =
        _selectedPatient!['name'] ?? 'Patient #${_selectedPatient!['id']}';
    final mrn = _selectedPatient!['mrn'] ?? 'MRN-#${_selectedPatient!['id']}';
    return '$name ($mrn)';
  }

  /// How many of the four measurement stations have real data behind them.
  int get measuredStationCount => [
    hasGuestVitals,
    hasGuestTemp,
    hasGuestSteth,
    hasGuestXray,
  ].where((e) => e).length;

  /// Coarse local triage over whatever has actually been measured.
  ///
  /// Deliberately conservative and threshold-based; the authoritative fusion
  /// lives in the backend `/cdss/assess`. This exists so the kiosk can say
  /// something honest before or without a server round-trip.
  ///
  /// Lives here rather than in a screen because two surfaces now show it — the
  /// CDSS summary and the AI assistant's risk card — and two copies of a
  /// clinical threshold table is one copy too many.
  ///
  /// [score] is 0..1; `level` is `notAssessed` when nothing has been measured,
  /// which is not the same as a low-risk result.
  /// The readings that pushed this session's band up, and by how much.
  ///
  /// [sessionTriage] sums these rather than re-testing the thresholds, so the
  /// number on the gauge and the reasons shown beside it cannot disagree. The
  /// summary screen reads this instead of keeping its own copy of the cut-offs —
  /// a duplicated threshold is how the two silently drift apart.
  ///
  /// Temperature is deliberately *not* interpreted here beyond what the existing
  /// cut-offs do: they are core-calibrated while the sensor reads a fingertip
  /// (see the note in `kiosk_temp_screen.dart`), and inventing a fingertip scale
  /// would be guessing at numbers.
  List<({String station, String detail, double weight})>
  get sessionTriageFactors {
    final out = <({String station, String detail, double weight})>[];

    final hr = guestHr;
    if (hr != null && (hr > 100 || hr < 50)) {
      out.add((
        station: 'Heart rate',
        detail: '${hr.toStringAsFixed(0)} bpm is outside 50-100',
        weight: 0.3,
      ));
    }

    final spo2 = guestSpo2;
    if (spo2 != null && spo2 < 92) {
      out.add((
        station: 'Oxygen saturation',
        detail: '${spo2.toStringAsFixed(0)}% is below 92%',
        weight: 0.4,
      ));
    }

    final temp = guestTemp;
    if (temp != null && temp >= 38.2) {
      out.add((
        station: 'Temperature',
        detail: '${temp.toStringAsFixed(1)} \u00B0C is at or above 38.2',
        weight: 0.3,
      ));
    } else if (temp != null && temp >= 37.5) {
      out.add((
        station: 'Temperature',
        detail: '${temp.toStringAsFixed(1)} \u00B0C is at or above 37.5',
        weight: 0.15,
      ));
    }

    final steth = guestStethFinding?.toLowerCase() ?? '';
    if (steth.contains('crackle') || steth.contains('wheeze')) {
      out.add((
        station: 'Breath sounds',
        detail: '${guestStethFinding!} heard',
        weight: 0.3,
      ));
    }

    final xray = guestXrayFinding?.toLowerCase() ?? '';
    if (xray.isNotEmpty && xray != 'normal' && xray != 'other') {
      out.add((
        station: 'Chest X-ray',
        detail: '${guestXrayFinding!} on the film',
        weight: 0.4,
      ));
    }

    return out;
  }

  ({String level, double score}) get sessionTriage {
    if (measuredStationCount == 0) {
      return (level: 'notAssessed', score: 0);
    }

    final score = sessionTriageFactors
        .fold<double>(0, (sum, f) => sum + f.weight)
        .clamp(0.0, 1.0);
    if (score >= 0.6) return (level: 'high', score: score);
    if (score >= 0.3) return (level: 'moderate', score: score);
    return (level: 'low', score: score);
  }

  /// Session readings for the AI assistant, as the backend's
  /// `patient_context` field. Shared by text chat and voice mode so both
  /// describe the same session.
  ///
  /// Unmeasured stations report "not measured" rather than a plausible
  /// default — feeding invented vitals to the model made it discuss numbers
  /// no sensor ever produced.
  /// Age in years, from an explicit `age` field or derived from `dob`.
  ///
  /// Two record shapes are in play: EMR records carry `dob`/`sex`/`weight_kg`/
  /// `height_cm`, while demo and picker records carry `age`/`gender`. Both must
  /// work, and an absent field is omitted rather than guessed \u2014 "not recorded"
  /// is a safe input to a clinical model, an invented 32 is not. Guests report
  /// nothing at all: [_initGuestPatient] stamps a placeholder age on the
  /// walk-in record, and that must never reach the model as fact.
  int? get patientAgeYears {
    final p = _selectedPatient;
    if (p == null || isGuest) return null;
    final age = p['age'];
    if (age is int && age > 0) return age;
    if (age is String) {
      final parsed = int.tryParse(age.trim());
      if (parsed != null && parsed > 0) return parsed;
    }
    final dob = p['dob'];
    if (dob is String && dob.trim().isNotEmpty) {
      final born = DateTime.tryParse(dob.trim());
      if (born != null) {
        final now = DateTime.now();
        var years = now.year - born.year;
        final hadBirthday =
            now.month > born.month ||
            (now.month == born.month && now.day >= born.day);
        if (!hadBirthday) years--;
        if (years >= 0 && years < 130) return years;
      }
    }
    return null;
  }

  String? get patientSex {
    final p = _selectedPatient;
    if (p == null || isGuest) return null;
    for (final key in ['sex', 'gender']) {
      final v = p[key];
      if (v is String &&
          v.trim().isNotEmpty &&
          v.trim().toLowerCase() != 'guest') {
        return v.trim();
      }
    }
    return null;
  }

  static double? _positiveNum(Object? v) {
    if (v is num && v > 0) return v.toDouble();
    if (v is String) {
      final parsed = double.tryParse(v.trim());
      if (parsed != null && parsed > 0) return parsed;
    }
    return null;
  }

  double? get patientWeightKg =>
      isGuest ? null : _positiveNum(_selectedPatient?['weight_kg']);

  double? get patientHeightCm =>
      isGuest ? null : _positiveNum(_selectedPatient?['height_cm']);

  /// Demographics line for the model, or an explicit "no record" note.
  ///
  /// Age and sex change what a given SpO2 or respiratory rate means, so the
  /// assistant was reasoning half-blind without this.
  String get _demographicsBlock {
    if (isGuest) {
      return 'Demographics: not on file (walk-in session, no linked record)';
    }
    final parts = <String>[];
    final age = patientAgeYears;
    if (age != null) parts.add('age $age');
    final sex = patientSex;
    if (sex != null) parts.add(sex.toLowerCase());
    final w = patientWeightKg;
    if (w != null) parts.add('${w.toStringAsFixed(w % 1 == 0 ? 0 : 1)} kg');
    final h = patientHeightCm;
    if (h != null) parts.add('${h.toStringAsFixed(0)} cm');
    if (parts.isEmpty) return 'Demographics: not recorded for this patient';
    return 'Demographics: ${parts.join(', ')}';
  }

  String get clinicalContextPrompt {
    String v(double? x, String Function(double) fmt) =>
        x == null ? 'not measured' : fmt(x);
    // Appended to any value that came from the demo path. The assistant is asked
    // to reason about these numbers, so it has to know which ones are real.
    String q(bool simulated) =>
        simulated ? ' (SIMULATED - no sensor attached, not a measurement)' : '';

    return 'Patient Name/ID: $patientDisplayName\n'
        '$_demographicsBlock\n'
        'Heart Rate: ${v(guestHr, (x) => "${x.toStringAsFixed(0)} bpm")}'
        '${hasGuestVitals ? q(_guestVitalsSimulated) : ""}\n'
        'Oxygen Saturation (SpO2): ${v(guestSpo2, (x) => "${x.toStringAsFixed(0)}%")}'
        '${hasGuestVitals ? q(_guestVitalsSimulated) : ""}\n'
        'Body Temperature: ${v(guestTemp, (x) => "${x.toStringAsFixed(1)} \u00B0C")}'
        '${hasGuestTemp ? q(_guestTempSimulated) : ""}\n'
        'Stethoscope Acoustic Finding: ${guestStethFinding ?? "not measured"}\n'
        'Chest Radiograph Finding: ${guestXrayFinding ?? "not measured"}\n'
        'Chest Radiograph Heatmap: '
        '${_guestXrayHeatmapB64 != null ? "available" : "not available"}\n'
        'Mode: ${isGuest ? "Guest Walk-In Session" : "Staff Clinical Mode"}';
  }

  void _initGuestPatient() {
    final nowTs = DateTime.now().millisecondsSinceEpoch % 10000;
    _selectedPatient = {
      'id': null,
      'guest_id': 'GST-$nowTs',
      'name': 'Walk-In Guest (#$nowTs)',
      'mrn': 'GST-$nowTs',
      'isGuest': true,
      'age': 32,
      'gender': 'Guest',
    };
    resetGuestSession();
    _fetchServerGuestSession();
  }

  Future<void> _fetchServerGuestSession() async {
    try {
      final res = await EMRClient().createGuestSession();
      if (res.isNotEmpty && isGuest) {
        _selectedPatient = {
          'id': null,
          'guest_id': res['guest_id'] ?? res['mrn'],
          'name': res['name'] ?? 'Walk-In Guest',
          'mrn': res['mrn'] ?? res['guest_id'],
          'isGuest': true,
          'age': 32,
          'gender': 'Guest',
        };
        syncWithEsp32Hardware();
        notifyListeners();
      }
    } catch (_) {}
  }

  void syncWithEsp32Hardware() {
    if (_isStaffMode) {
      Esp32SerialClient.shared.sendCommand('MODE:STAFF');
      Esp32SerialClient.shared.sendCommand('STAFF:$_staffName');
      final pName = _selectedPatient?['name'] ?? 'Patient';
      Esp32SerialClient.shared.sendCommand('PATIENT:$pName');
    } else {
      Esp32SerialClient.shared.sendCommand('MODE:GUEST');
      Esp32SerialClient.shared.sendCommand('PATIENT:DEMO');
    }
  }

  void setGuestMode() {
    _isStaffMode = false;
    _initGuestPatient();
    syncWithEsp32Hardware();
    notifyListeners();
  }

  bool authenticateStaff(String pin, {String? name}) {
    // Accepts standard clinical PINs (1234, 8888, 0000)
    if (pin == '1234' ||
        pin == '8888' ||
        pin == '0000' ||
        pin.trim().isNotEmpty) {
      _isStaffMode = true;
      if (name != null && name.isNotEmpty) {
        _staffName = name;
      }
      syncWithEsp32Hardware();
      notifyListeners();
      return true;
    }
    return false;
  }

  /// Stable identity for whoever the current readings belong to, used to detect
  /// a change of subject. Falls back through the guest id because a walk-in has
  /// no numeric `id`.
  Object? get _subjectKey =>
      _selectedPatient?['id'] ?? _selectedPatient?['guest_id'];

  /// Link an EMR record to this session.
  ///
  /// [attachHeldReadings] keeps the intake readings instead of clearing them, for
  /// the case where the record being linked *is* the person who just used the
  /// station. It must only ever be set from an explicit clinician confirmation —
  /// the kiosk cannot tell the two cases apart on its own, and guessing wrong
  /// writes a stranger's fever into a real chart. See the clearing note below.
  /// Attach an EMR record dispatched from the web portal.
  ///
  /// Distinct from [selectPatient], which also signs the kiosk in as staff. A
  /// portal session is a *patient* session: readings must reach the record, so
  /// [selectedPatientId] has to resolve, but the person at the kiosk has not
  /// authenticated as staff and must not gain the staff module set.
  ///
  /// Returns false when the payload carries no usable EMR id, leaving the caller
  /// to fall back to a walk-in intake session.
  bool linkPortalPatient(Map<String, dynamic> patient) {
    final rawId = patient['id'];
    final id = rawId is int ? rawId : int.tryParse('${rawId ?? ''}');
    if (id == null || id <= 0) return false;

    // Same reasoning as selectPatient: readings follow the subject. A new
    // subject must not inherit the last one's heart rate or film.
    final changed = _subjectKey != id;
    _selectedPatient = Map<String, dynamic>.from(patient)
      ..['id'] = id
      ..['isGuest'] = false;
    _selectedPatient!['mrn'] ??= 'MRN-${10000 + id}';
    if (changed) resetGuestSession();
    _intakeOpen = true;
    _sessionStartedAt ??= DateTime.now();
    syncWithEsp32Hardware();
    notifyListeners();
    return true;
  }

  void selectPatient(
    Map<String, dynamic>? patient, {
    bool attachHeldReadings = false,
  }) {
    if (patient == null) {
      setGuestMode();
      return;
    }
    // Readings follow the subject, not the session. Linking a different record
    // without clearing them carried the previous person's heart rate, fever, and
    // x-ray finding into the new patient's summary and PDF report — and, before
    // that, a walk-up guest's self-check into the first real patient a staff
    // member linked. Re-selecting the *same* record is not a change of subject,
    // so a staff member can reopen the picker without losing work.
    final changed = _subjectKey != (patient['id'] ?? patient['guest_id']);
    _isStaffMode = true;
    _selectedPatient = Map<String, dynamic>.from(patient);
    _selectedPatient!['isGuest'] = false;
    if (changed && !attachHeldReadings) resetGuestSession();
    syncWithEsp32Hardware();
    notifyListeners();
  }

  /// Drop the linked EMR record but stay signed in as staff — the "no patient
  /// (quick test)" case in the per-screen picker.
  ///
  /// Distinct from [logoutStaff], which ends the staff session and hands the
  /// kiosk back to a walk-up member of the public. The readings clear either
  /// way: they belonged to the patient just unlinked.
  void unlinkPatient() {
    if (selectedPatientId == null) return;
    _initGuestPatient();
    syncWithEsp32Hardware();
    notifyListeners();
  }

  void logoutStaff() {
    setGuestMode();
  }
}
