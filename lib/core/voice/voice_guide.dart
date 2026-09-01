import 'package:flutter/foundation.dart';
import 'package:flutter_soloud/flutter_soloud.dart';

import '../../state/kiosk_patient_state.dart';
import '../../state/xs_settings.dart';

/// Who a cue is for. Decides whether [VoiceGuide.say] actually speaks it.
enum XSCueClass {
  /// Where you are and what the buttons do. Played in every mode.
  nav,

  /// How to use a sensor. Guest only — a clinician does not need coaching, and
  /// a kiosk talking over them is noise.
  coach,

  /// A reading finished. Guest only. Never reaches a session with a patient
  /// record linked, because that names a real person in a shared room and the
  /// kiosk speaker is not a private channel.
  result,

  /// Something is broken and the user cannot fix it. Played in every mode.
  fault,

  /// Needs attention now. Played in every mode.
  alarm,
}

/// One pre-recorded line of kiosk guidance.
///
/// [file] is the asset basename, which is also the cue id used in
/// `voice-guide.md`. Clips that have not been recorded yet are simply absent
/// from `assets/voice/<lang>/`; [VoiceGuide] notices once and stays silent for
/// them, so dropping a new MP3 in is the whole job of adding one.
enum XSVoiceCue {
  // ─── Session entry ────────────────────────────────────────────
  welcome('welcome', XSCueClass.nav),
  welcomeTouch('welcome_touch', XSCueClass.nav),
  disclaimer('disclaimer', XSCueClass.nav),
  menuOpen('menu_open', XSCueClass.nav),

  // ─── Station names, spoken as the orbit highlight moves ───────
  stationVitals('station_vitals', XSCueClass.nav),
  stationTemp('station_temp', XSCueClass.nav),
  stationLungs('station_lungs', XSCueClass.nav),
  stationXray('station_xray', XSCueClass.nav),
  stationSummary('station_summary', XSCueClass.nav),
  stationAssistant('station_assistant', XSCueClass.nav),
  stationSettings('station_settings', XSCueClass.nav),

  // ─── Heart rate and oxygen ────────────────────────────────────
  vitalsIntro('vitals_intro', XSCueClass.coach),
  vitalsPlace('vitals_place', XSCueClass.coach),
  vitalsActive('vitals_active', XSCueClass.coach),
  vitalsCancelled('vitals_cancelled', XSCueClass.coach),
  vitalsDone('vitals_done', XSCueClass.result),

  // ─── Temperature ──────────────────────────────────────────────
  tempIntro('temp_intro', XSCueClass.coach),
  tempPlace('temp_place', XSCueClass.coach),
  tempActive('temp_active', XSCueClass.coach),
  tempDone('temp_done', XSCueClass.result),
  tempHigh('temp_high', XSCueClass.result),

  // ─── Lung sounds ──────────────────────────────────────────────
  lungsIntro('lungs_intro', XSCueClass.coach),
  lungsPlace('lungs_place', XSCueClass.coach),
  lungsBreathe('lungs_breathe', XSCueClass.coach),
  lungsChecking('lungs_checking', XSCueClass.coach),
  lungsRetry('lungs_retry', XSCueClass.coach),
  lungsDone('lungs_done', XSCueClass.result),

  // ─── Chest x-ray ──────────────────────────────────────────────
  xrayIntro('xray_intro', XSCueClass.coach),
  xrayScan('xray_scan', XSCueClass.coach),
  xrayReceived('xray_received', XSCueClass.coach),
  xrayReading('xray_reading', XSCueClass.coach),
  xrayDone('xray_done', XSCueClass.result),
  xrayFailed('xray_failed', XSCueClass.fault),

  // ─── Results summary ──────────────────────────────────────────
  summaryNone('summary_none', XSCueClass.result),
  summaryPartial('summary_partial', XSCueClass.result),
  summaryLow('summary_low', XSCueClass.result),
  summaryModerate('summary_moderate', XSCueClass.result),
  summaryHigh('summary_high', XSCueClass.result),
  summaryDisclaimer('summary_disclaimer', XSCueClass.result),

  // ─── Problems and help. Not recorded yet; silent until they are. ──
  errSensor('err_sensor', XSCueClass.fault),
  errTemp('err_temp', XSCueClass.fault),
  errModule('err_module', XSCueClass.fault),
  errServer('err_server', XSCueClass.fault),
  emergency('emergency', XSCueClass.alarm),

  // ─── Session end. Not recorded yet. ───────────────────────────
  sessionSaved('session_saved', XSCueClass.nav),
  sessionEnd('session_end', XSCueClass.nav),
  sessionCleared('session_cleared', XSCueClass.nav);

  const XSVoiceCue(this.file, this.cueClass);

  final String file;
  final XSCueClass cueClass;
}

/// Plays the kiosk's pre-recorded spoken guidance.
///
/// One clip at a time: [say] stops whatever is playing before starting the next,
/// so a user who walks through three stations quickly hears the current station
/// rather than a queue of stale instructions.
///
/// Every suppression rule lives inside [say] rather than at the call sites.
/// Callers fire a cue whenever the state it describes is entered and do not
/// reason about mode, privacy, or repetition — a rule enforced in forty places
/// is a rule that will be missed in one of them.
class VoiceGuide {
  VoiceGuide._();
  static final VoiceGuide I = VoiceGuide._();

  /// Language folder under `assets/voice/`. Only `en` is recorded today; a
  /// Tagalog set drops in as `assets/voice/tl/` with identical filenames.
  String lang = 'en';

  /// Decoded clips, kept for the process lifetime. The whole English set is
  /// about 2.4 MB and every clip is played repeatedly over a shift, so
  /// re-decoding one on each play would be work for nothing.
  final Map<XSVoiceCue, AudioSource> _loaded = {};

  /// Cues whose asset is absent or failed to decode. Checked before every load
  /// so a missing clip costs one log line per process, not one per trigger.
  final Set<XSVoiceCue> _unavailable = {};

  SoundHandle? _handle;
  XSVoiceCue? _lastCue;
  DateTime? _lastAt;
  int _suspendDepth = 0;
  bool _engineFailed = false;

  /// Bumped by every [say] and [sayAll]. A running sequence checks it between
  /// clips and abandons itself the moment something newer is requested, so
  /// walking briskly from one station to the next cannot leave the previous
  /// station's instructions still arriving.
  int _generation = 0;

  /// True while something else owns the speaker and the microphone.
  bool get isSuspended => _suspendDepth > 0;

  /// Silence the guide until the matching [resume].
  ///
  /// The realtime voice assistant must call this. `/ws/voice` mutes its
  /// microphone only around audio *it* is streaming, so a guide clip played
  /// through the kiosk speaker during a voice session is captured by the mic,
  /// transcribed, and answered as though the user had said it.
  ///
  /// Counted rather than boolean so two overlapping owners cannot have the
  /// first one to finish un-silence the guide underneath the second.
  void suspend() {
    _suspendDepth++;
    stop();
  }

  void resume() {
    if (_suspendDepth > 0) _suspendDepth--;
  }

  /// How long the same cue must wait before it may repeat.
  ///
  /// Sensor callbacks are not edge-triggered: `Esp32SerialClient` notifies on
  /// every frame and a screen can rebuild many times inside one state, so the
  /// same cue arrives in bursts. A different cue in between clears the guard
  /// immediately — this window only governs a genuine repeat.
  static const _repeatWindow = Duration(seconds: 10);

  /// Speak [cue] if every rule allows it.
  ///
  /// Never throws and never awaits anything the caller needs: safe to call from
  /// `setState`, a serial callback, or a build method.
  Future<void> say(XSVoiceCue cue) async {
    _generation++;
    if (!_allowed(cue)) return;
    _lastCue = cue;
    _lastAt = DateTime.now();
    await _play(cue);
  }

  /// Speak [cues] in order, each starting when the one before it has finished.
  ///
  /// For the paired lines the script is written in — "Temperature. This only
  /// takes a few seconds." followed by "Rest your fingertip on the sensor" —
  /// which arrive from the same call site microseconds apart. Passing them to
  /// [say] twice would have the second clip cut the first off after a syllable.
  ///
  /// Any later [say] or [sayAll] abandons a sequence still in flight, so this
  /// costs nothing in responsiveness.
  Future<void> sayAll(List<XSVoiceCue> cues) async {
    final gen = ++_generation;
    for (final cue in cues) {
      if (gen != _generation) return;
      if (!_allowed(cue)) continue;
      _lastCue = cue;
      _lastAt = DateTime.now();
      final length = await _play(cue);
      if (length == null) continue;
      await Future<void>.delayed(length + _clipGap);
    }
  }

  /// Breathing room between chained clips. The clips carry their own head and
  /// tail silence, but not reliably enough to butt one against the next.
  static const _clipGap = Duration(milliseconds: 120);

  /// Stop the clip that is playing, if any.
  Future<void> stop() async {
    final h = _handle;
    _handle = null;
    if (h == null) return;
    try {
      await SoLoud.instance.stop(h);
    } catch (e) {
      debugPrint('[voice-guide] stop failed: $e');
    }
  }

  /// Forget the repeat guard, so the next station starts from a clean slate.
  ///
  /// Call when the session's subject changes. Without this, a second walk-up
  /// user arriving inside [_repeatWindow] would be silently denied the cue the
  /// first one just heard.
  void resetHistory() {
    _lastCue = null;
    _lastAt = null;
  }

  // ─────────────────────────────────────────────────────────────

  bool _allowed(XSVoiceCue cue) {
    if (_engineFailed) return false;
    if (!XSSettings.I.voiceGuideEnabled) return false;
    if (_unavailable.contains(cue)) return false;

    // Reading-time narration is disabled by product decision: the kiosk only
    // speaks navigation cues (greeting, agreement line, menu and station
    // names) plus alarms. Coaching, result announcements and sensor-fault
    // lines stay bundled and callable, so re-enabling any class is a one-line
    // change here.
    switch (cue.cueClass) {
      case XSCueClass.coach:
      case XSCueClass.result:
      case XSCueClass.fault:
        return false;
      case XSCueClass.nav:
      case XSCueClass.alarm:
        break;
    }

    // An alarm outranks the speaker being busy, but not the microphone being
    // live: feeding "tell a nurse now" back through STT would have the
    // assistant answer its own alarm.
    if (isSuspended) return false;

    if (cue == _lastCue) {
      final at = _lastAt;
      if (at != null &&
          DateTime.now().difference(at) < _repeatWindow &&
          cue.cueClass != XSCueClass.alarm) {
        return false;
      }
    }

    final session = KioskPatientSession.I;
    switch (cue.cueClass) {
      case XSCueClass.coach:
      case XSCueClass.result:
        // Staff mode covers the patient-linked case too: linking a record sets
        // staff mode, so a reading can never be read aloud over a named
        // patient. Checked on its own regardless, because that coupling lives
        // in another class and should not be load-bearing here.
        if (session.isStaffMode) return false;
        if (session.selectedPatientId != null) return false;
      case XSCueClass.nav:
      case XSCueClass.fault:
      case XSCueClass.alarm:
        break;
    }
    return true;
  }

  /// Plays [cue] and returns how long it runs for, or null if it could not
  /// play at all.
  Future<Duration?> _play(XSVoiceCue cue) async {
    final SoLoud so;
    try {
      so = SoLoud.instance;
      if (!so.isInitialized) await so.init();
    } catch (e) {
      // No audio device, or the native library is not in this build — a
      // headless test host, or an audio-less kiosk image. Nothing will ever
      // play, so stop asking. Note that this arrives as a bare FFI
      // `ArgumentError` from the dynamic-library loader rather than as any
      // SoLoud exception type, which is why it is caught by shape (the init
      // step failed) rather than by class.
      _engineFailed = true;
      debugPrint('[voice-guide] audio unavailable, guidance off: $e');
      return null;
    }

    try {
      var source = _loaded[cue];
      if (source == null) {
        source = await so.loadAsset('assets/voice/$lang/${cue.file}.mp3');
        _loaded[cue] = source;
      }

      // One clip at a time. Stopping after the load, not before, keeps a cue
      // that turns out to be missing from cutting off the one still playing.
      await stop();
      _handle = await so.play(source, volume: XSSettings.I.voiceGuideVolume);
      return so.getLength(source);
    } catch (e) {
      // The engine is up, so this is about this one clip: not recorded yet, or
      // a build that did not bundle the folder. Retiring the cue rather than
      // the engine keeps every other clip working.
      _unavailable.add(cue);
      debugPrint('[voice-guide] ${cue.file} unavailable: $e');
      return null;
    }
  }
}
