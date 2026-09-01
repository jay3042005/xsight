import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/theme/xs_colors.dart';
import '../../core/theme/xs_radius.dart';
import '../../core/theme/xs_shadows.dart';
import '../../core/theme/xs_spacing.dart';
import '../../core/sensor/esp32_serial_client.dart';
import '../../core/voice/voice_guide.dart';
import 'kiosk_xray_screen.dart';
import 'kiosk_lung_sound_screen.dart';
import 'kiosk_vitals_screen.dart';
import 'kiosk_temp_screen.dart';
import 'kiosk_cdss_screen.dart';
import 'kiosk_dashboard.dart';
import 'kiosk_guest_dashboard.dart';
import 'kiosk_patient_picker_screen.dart';
import 'kiosk_chat_screen.dart';
import 'kiosk_settings_screen.dart';
import 'voice_mode_screen.dart';
import '../components/xs_ambient_background.dart';
import '../components/xs_liquid_reveal.dart';
import '../components/xs_radial_menu.dart';
import 'kiosk_checkin_screen.dart';
import 'kiosk_modules.dart';
import '../components/xs_staff_dialogs.dart';
import '../../core/api/emr_client.dart';
import '../../core/api/kiosk_hub_client.dart';
import '../../core/theme/xs_scale.dart';
import '../../state/kiosk_patient_state.dart';

/// Three-phase kiosk shell:
///   dashboard (idle) → menu (ESP32 OK / Space) → screen (ESP32 SELECT / Space)
///   CANCEL at any sub-level returns to dashboard (ESP32 BACK / Escape).
///
/// Pure hardware-driven navigation — bottom navigation bar is completely removed.
class KioskShell extends StatefulWidget {
  final VoidCallback? onStopSession;

  const KioskShell({super.key, this.onStopSession});

  @override
  State<KioskShell> createState() => _KioskShellState();
}

enum _View { dashboard, patients, menu, screen }

/// This file's short name for the shared module identity. See [XSModule].
typedef _Module = XSModule;

class _KioskShellState extends State<KioskShell> {
  _View _view = _View.dashboard;

  /// The module the `screen` view is showing. Held as an identity rather than an
  /// orbit index because the orbit is mode-dependent and this is not.
  _Module _openModule = _Module.xray;
  int _menuIndex = 0;

  /// The intake check-in dialog's own [BuildContext], or null when none is up.
  /// Held for the same reason as [_sensorPromptContext]: the module can report
  /// its menu open while check-in is still on screen, and popping blind would
  /// close whatever dialog happened to be on top.
  BuildContext? _checkinContext;

  Timer? _idleTimer;

  /// Re-sends of `MODE:` since the module last agreed with the app.
  ///
  /// Bounded because the alternative is a send loop: a module that cannot reach
  /// the requested mode would acknowledge the wrong one forever, and each ack
  /// would trigger another send.
  int _modeResyncAttempts = 0;

  /// How many times to insist before leaving the module alone.
  static const _maxModeResyncAttempts = 2;

  /// How long an open intake session may sit on the dashboard untouched before
  /// the kiosk clears it.
  ///
  /// This is the only automatic reset. It runs on the dashboard alone: a person
  /// working through a station may legitimately stand still for minutes — waiting
  /// on a film upload or a 30-second recording — and wiping their readings out
  /// from under them would be far worse than the stale session it prevents.
  static const _idleTimeout = Duration(seconds: 120);

  bool _connected = false;
  String? _pressedButton;
  Timer? _pressedResetTimer;

  /// Last session-open state announced to the hub. The announcement is a
  /// transition signal, not a heartbeat: the session notifies on every
  /// reading, and re-sending the same state each time would flood the socket.
  bool _hubAnnouncedOpen = true; // sentinel: first call always sends
  final Esp32SerialClient _esp32 = Esp32SerialClient.shared;
  final FocusNode _focusNode = FocusNode();

  /// The dashboard's primary target (guest START disc / staff CTA card). The
  /// module menu grows out of its exact bounds, so there is one thing to press.
  final GlobalKey _startKey = GlobalKey();

  // ─── Module catalogue ─────────────────────────────────────────
  // Lives in kiosk_modules.dart: the per-mode orbit and the index mapping are
  // the parts with a real failure mode, and keeping them out of this widget
  // makes them testable without serial and audio plugins.

  static const _menuData = XSModules.catalogue;

  /// The orbit for the current mode. Guest order follows the dashboard's journey
  /// rail (pulse → temp → lungs → x-ray) so the two agree; staff order follows
  /// the clinical workflow.
  ///
  /// Keyed on staff mode, not [KioskPatientSession.isGuest]: a staff member who
  /// has logged in but not yet linked a patient is still staff and must see the
  /// full seven-module orbit, even though their readings are still treated as a
  /// walk-in session until a record is linked.
  List<_Module> get _visibleModules =>
      XSModules.forMode(isGuest: !KioskPatientSession.I.isStaffMode);

  /// The module the focused orbit slot refers to.
  _Module get _focusedModule => _visibleModules[_focusedSlot];

  /// [_menuIndex], clamped into the current orbit. Read this rather than the
  /// raw field anywhere the value indexes [_visibleModules] or is handed to the
  /// radial cockpit.
  int get _focusedSlot => _menuIndex.clamp(0, _visibleModules.length - 1);

  static const _navNames = XSModules.navNames;
  static const _espStates = XSModules.espStates;

  /// Spoken station name per module, for the orbit highlight.
  static const _stationCues = {
    _Module.xray: XSVoiceCue.stationXray,
    _Module.steth: XSVoiceCue.stationLungs,
    _Module.vitals: XSVoiceCue.stationVitals,
    _Module.temp: XSVoiceCue.stationTemp,
    _Module.summary: XSVoiceCue.stationSummary,
    _Module.assistant: XSVoiceCue.stationAssistant,
    _Module.settings: XSVoiceCue.stationSettings,
  };

  // Station-opening voice lines were removed on purpose: opening a station by
  // touch or hardware select used to chain its coaching intro after the
  // navigation cue, which read as the kiosk talking over every click. Only
  // navigation cues speak now; sensor stations still coach from their own
  // state callbacks (PULSE_WAITING, temp placement, and so on).

  static _Module? _moduleForNav(String dest) => XSModules.forNav(dest);

  /// Projection of [_menuData] for the radial cockpit, which is a component and
  /// so takes a concrete record type rather than this file's private tuple.
  /// Filtered to the current mode, so the orbit only ever offers what the user
  /// is allowed to open.
  List<XSRadialMenuItem> get _radialItems => [
    for (final id in _visibleModules)
      if (_menuData[id] case final m?)
        (
          icon: m.icon,
          label: m.label,
          sub: m.sub,
          tag: m.tag,
          sensor: m.sensor,
          details: m.details,
          color: m.color,
        ),
  ];

  Widget _pageFor(_Module id) => switch (id) {
    _Module.xray => const KioskXrayScreen(),
    _Module.steth => const KioskLungSoundScreen(),
    _Module.vitals => const KioskVitalsScreen(),
    _Module.temp => const KioskTempScreen(),
    _Module.summary => const KioskCDSSScreen(),
    // The assistant module opens straight into the live voice stage; the text
    // chat is a button on it ([_openAssistantChat]). Hosted rather than pushed,
    // so exit hands navigation back to the shell instead of popping it.
    _Module.assistant => VoiceModeScreen(
      onExit: _goHome,
      onOpenChat: _openAssistantChat,
    ),
    _Module.settings => const KioskSettingsScreen(),
  };

  /// The assistant's text chat, pushed over the embedded voice stage — the
  /// same pattern as phone check-in. A route because the ESP32 state ordinals
  /// are fixed and the module identity is unchanged, so the shell's phases
  /// must not gain a fourth member; hardware BACK pops it first ([_onBack]).
  void _openAssistantChat() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const KioskChatScreen()));
  }

  // ─── Lifecycle ─────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    if (KioskPatientSession.I.isGuest) {
      _view = _View.dashboard;
    }
    _esp32.onNavigate = _onNavigate;
    _esp32.onPulseState = _onPulseState;
    _esp32.onTempState = _onTempState;
    _esp32.onDeviceState = _onDeviceState;
    _esp32.onBack = _onBack;
    _esp32.onMenuReady = _onMenuReady;
    _esp32.onVoiceOk = _onVoiceOk;
    _esp32.onVoiceDown = _onVoiceDown;
    _esp32.onVoiceUp = _onVoiceUp;
    _esp32.onModeQuery = () {
      // Readiness or a reboot: a module that has forgotten its mode is a fresh
      // negotiation, not a continuation of one that failed.
      _modeResyncAttempts = 0;
      KioskPatientSession.I.syncWithEsp32Hardware();
    };
    _esp32.onModeAck = _onModeAck;
    _esp32.onSensorError = _onSensorError;
    // Preferred: the module names the station it highlighted, so the two menus
    // can differ in order and length without a position ever being reinterpreted
    // against the wrong table.
    _esp32.onMenuSelect = (token) {
      if (!mounted) return;
      final module = _moduleForNav(token);
      if (module == null) return;
      _focusModuleFromModule(module);
    };
    _esp32.onMenuIndex = (index) {
      if (!mounted) return;
      // Legacy positional path, kept for firmware that predates `MENU_SEL:`.
      // The index is into the firmware's own menu, which is a different order
      // from the guest orbit, so translate through the module identity rather
      // than trusting the position.
      final module = XSModules.moduleForFirmwareIndex(index);
      if (module == null) return;
      _focusModuleFromModule(module);
    };
    _esp32.addListener(_onStatus);
    KioskPatientSession.I.addListener(_onSessionModeChanged);
    final hub = KioskHubClient.instance;
    hub.onRemoteStopSession = () {
      if (mounted) _stopSession();
    };
    // Idempotent: the socket is app-lifetime, but the shell can be the first
    // thing built on a restored session, and a live socket is what makes the web
    // portal's station popup and Stop Session work at all.
    hub.connect();
    // Truthful initial announcement. This used to send kiosk_session_active
    // unconditionally, so a freshly booted kiosk in guest mode read as
    // "Screening in progress" on the web portal with nobody at the screen.
    _announceSessionToHub();
    _esp32.connect();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusNode.requestFocus();
      if (_view == _View.dashboard) _greet();
    });
  }

  /// Move the orbit's focus to [module] because the hardware said so.
  ///
  /// Shared by the token and legacy-index paths so they cannot diverge, and it
  /// flashes the direction key that corresponds to the move, which is what makes
  /// the on-screen dock mirror the physical buttons.
  ///
  /// A module the current mode cannot reach leaves focus alone: the orbit has no
  /// slot for it, and snapping to slot 0 instead would move the highlight
  /// somewhere the user did not ask for.
  void _focusModuleFromModule(_Module module) {
    final next = _visibleModules.indexOf(module);
    if (next < 0) return;
    final delta = next - _focusedSlot;
    if (delta != 0) _flashButton(delta > 0 ? 'DOWN' : 'UP');
    setState(() => _menuIndex = next);
    if (delta != 0) _announceFocus();
  }

  void _flashButton(String button) {
    if (!mounted) return;
    _pressedResetTimer?.cancel();
    setState(() => _pressedButton = button);
    _pressedResetTimer = Timer(const Duration(milliseconds: 260), () {
      if (mounted) setState(() => _pressedButton = null);
    });
  }

  @override
  void dispose() {
    _pressedResetTimer?.cancel();
    _idleTimer?.cancel();
    _esp32.removeListener(_onStatus);
    KioskPatientSession.I.removeListener(_onSessionModeChanged);
    // Release the rented callback but leave the socket up — see the note in
    // KioskGuestEntryScreen.dispose.
    KioskHubClient.instance.onRemoteStopSession = null;
    _focusNode.dispose();
    super.dispose();
  }

  /// Keeps navigation legal when the orbit shrinks under it.
  ///
  /// Signing out of staff drops Settings from the orbit, so a focus index or an
  /// open screen can suddenly point at a module this mode is not allowed to
  /// reach. Left alone, OK on the orbit silently did nothing (the index was past
  /// the end) and a staff member's open Settings screen stayed on display for
  /// whoever walked up next.
  /// Publish the kiosk's real session state to the hub the web portal polls.
  ///
  /// "Active" means an open intake (check-in done or a reading taken) or a
  /// linked patient — not merely that the app is running. Called on boot and
  /// on every session change; only transitions are sent.
  void _announceSessionToHub() {
    final session = KioskPatientSession.I;
    final open = session.isIntakeOpen || session.selectedPatientId != null;
    if (open == _hubAnnouncedOpen) return;
    _hubAnnouncedOpen = open;
    if (open) {
      KioskHubClient.instance.notifySessionStarted(
        session.patientDisplayName,
      );
    } else {
      KioskHubClient.instance.notifySessionStopped();
    }
  }

  void _onSessionModeChanged() {
    if (!mounted) return;
    // A different person is using the kiosk now, so the guide must be willing to
    // repeat what it already said to the last one.
    VoiceGuide.I.resetHistory();
    // The portal's "active" light tracks the truth, not just the app running.
    _announceSessionToHub();
    final isGuest = !KioskPatientSession.I.isStaffMode;
    if (_view == _View.screen &&
        !XSModules.isAllowed(_openModule, isGuest: isGuest)) {
      _goHome();
      return;
    }
    if (_menuIndex >= _visibleModules.length) {
      setState(() => _menuIndex = _visibleModules.length - 1);
      if (_view == _View.menu) _syncWithEsp32();
    }
    // Opening or ending a session is exactly when the idle watch should start or
    // stop, and every path that does either lands here.
    _touchIdle();
    // The mode may just have changed, so give the module a fresh budget: failing
    // to push it into the previous mode says nothing about this one, and without
    // this the bound is a permanent opt-out after two bad acks. Safe to do on
    // every session notify — `syncWithEsp32Hardware` does not notify, so this
    // cannot fire between a re-send and the ack it is waiting for.
    _modeResyncAttempts = 0;
  }

  void _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return;
    _touchIdle();

    final key = event.logicalKey;
    final primary = FocusManager.instance.primaryFocus;
    final isTextField =
        primary != null && primary.context?.widget is EditableText;
    if (isTextField) return;

    if (key == LogicalKeyboardKey.space || key == LogicalKeyboardKey.enter) {
      if (_view == _View.dashboard) {
        // Same path as touching START, so the OLED opens its menu too. The old
        // inline setState left the module sitting on its intro screen.
        _onDashboardOk();
      } else if (_view == _View.menu) {
        _flashButton('OK');
        _selectMenuItem(_focusedSlot);
      }
      // On the assistant screen Space/Enter belongs to the embedded voice
      // stage, whose own focus node turns them into hold-to-talk. Acting here
      // as well would double-fire the press.
    } else if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowLeft) {
      if (_view == _View.menu) {
        _flashButton('UP');
        _moveFocus(-1);
      }
    } else if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowRight) {
      if (_view == _View.menu) {
        _flashButton('DOWN');
        _moveFocus(1);
      }
    } else if (key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.backspace) {
      if (_view != _View.dashboard) {
        _flashButton('BACK');
        _goHome();
      }
    } else if (key == LogicalKeyboardKey.keyP) {
      // Hardware-free demo: stand in for a finger on the sensor. The stations
      // wait for contact exactly as they do with a module attached, and this
      // injects the frames the firmware would have sent — so their guided
      // phases run for real. Readings land tagged SIMULATED.
      if (_view == _View.screen) {
        if (_openModule == _Module.vitals) {
          _esp32.simulateVitalsScan();
        } else if (_openModule == _Module.temp) {
          _esp32.simulateTempScan();
        }
      }
    }
  }

  // ─── ESP32 Callbacks ──────────────────────────────────────────
  void _onStatus() {
    if (!mounted) return;
    final wasUsable = _connected && _esp32.deviceReady;
    setState(() => _connected = _esp32.connected);
    // Spoken from here rather than from `_buildLinkWarning`, which is a build
    // method and runs far more often than the link actually changes. Only the
    // transition out of a working link is news.
    if (wasUsable && !(_esp32.connected && _esp32.deviceReady)) {
      VoiceGuide.I.say(XSVoiceCue.errModule);
    }
  }

  void _onBack() {
    if (!mounted) return;
    _flashButton('BACK');
    // A route pushed over the shell — the assistant's text chat — closes
    // first: navigating the shell underneath it would leave the chat stranded
    // on top of the wrong screen.
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop();
      return;
    }
    // The embedded voice stage (if any) is unmounted by the view change, and
    // its dispose stops the mic stream and socket.
    setState(() => _view = _View.dashboard);
    _greet();
  }

  void _onMenuReady() {
    if (!mounted) return;
    // The module can reach its menu while check-in is still up — on its own OK
    // button, or because someone pressed it twice. Close the dialog keeping
    // whatever was typed rather than stranding it over the orbit.
    _dismissCheckIn();
    _flashButton('OK');
    setState(() {
      _menuIndex = 0;
      _view = _View.menu;
    });
    // Push the highlight, same as _openMenu. The module keeps its own menuIndex
    // across BACK (so returning to the menu lands where the user was), so
    // without this the OLED stayed on the last-visited station while the app
    // reset to slot 0 — and the module's OK then selected the station its
    // highlight named, not the one on screen.
    _syncWithEsp32();
    _announceMenu();
  }

  void _onNavigate(String dest) {
    debugPrint('[kiosk] ESP32 nav: $dest');
    if (!mounted) return;
    final id = _moduleForNav(dest);
    if (id == null) return;
    _openModuleScreen(id);
  }

  void _onPulseState(String state) {
    if (!mounted) return;
    switch (state) {
      // The module is armed and genuinely waiting for a fingertip. A better
      // moment for the instruction than the screen appearing, which happens
      // before the sensor is ready.
      case 'WAITING':
        VoiceGuide.I.say(XSVoiceCue.vitalsPlace);
      case 'ACTIVE':
        VoiceGuide.I.say(XSVoiceCue.vitalsActive);
      case 'DONE':
        VoiceGuide.I.say(XSVoiceCue.vitalsDone);
      case 'CANCELLED':
        VoiceGuide.I.say(XSVoiceCue.vitalsCancelled);
    }
  }

  void _onTempState(String state) {
    if (!mounted) return;
    switch (state) {
      case 'ACTIVE':
        VoiceGuide.I.say(XSVoiceCue.tempActive);
      case 'DONE':
        // The reading itself arrives on a separate `TEMP:` line, so read it off
        // the client rather than the state word. Threshold matches
        // `KioskTempScreen._statusLabel`, which is what the screen shows.
        final temp = _esp32.latest?.temp ?? 0;
        VoiceGuide.I.sayAll([
          XSVoiceCue.tempDone,
          if (temp >= 37.5) XSVoiceCue.tempHigh,
        ]);
    }
  }

  /// Reports a hardware fault the firmware could not work around.
  ///
  /// `ERR:SENSOR` means the sensor never answered on the I2C bus, `ERR:TEMP`
  /// that the reading was outside the plausible body-temperature window. Both
  /// used to be invisible: the station sat on its "place your finger" coaching
  /// step forever with nothing to explain why no number ever arrived.
  void _onSensorError(String kind) {
    if (!mounted) return;
    final message = kind == 'TEMP'
        ? 'No fingertip detected on the temperature sensor. Rest your fingertip on it and hold still.'
        : 'Sensor did not respond. Check the XSIGHT module connection and try again.';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: XSColors.accentRed,
        duration: const Duration(seconds: 5),
      ),
    );
    VoiceGuide.I.say(
      kind == 'TEMP' ? XSVoiceCue.errTemp : XSVoiceCue.errSensor,
    );
  }

  void _onDeviceState(int state) {
    if (!mounted) return;
    if (state == 0) {
      setState(() => _view = _View.dashboard);
      _greet();
      return;
    }
    if (state == 1) {
      setState(() => _view = _View.menu);
      return;
    }
    // Firmware state numbers are the canonical module order + 2, matching
    // [_espStates]. Not the orbit position, which varies by mode.
    final id = XSModules.forEspState(state);
    if (id != null) _openModuleScreen(id);
  }

  void _onVoiceOk() {
    if (!mounted) return;
    // Legacy frame: the current firmware's ASSIST state sends only
    // VOICE_DOWN/VOICE_UP. The assistant module now opens straight into the
    // voice stage, so there is no separate route to launch — just make sure
    // the stage is on screen.
    if (_view != _View.screen || _openModule != _Module.assistant) {
      _openModuleScreen(_Module.assistant);
    }
  }

  void _onVoiceDown() {
    if (!mounted) return;
    // The assistant module opens straight into the voice stage, so a press
    // from anywhere else opens it; once it is up, the press drives the
    // stage's own push-to-talk.
    if (_view == _View.screen && _openModule == _Module.assistant) {
      VoiceModeScreen.activeState?.onPushToTalkDown();
    } else {
      _openModuleScreen(_Module.assistant);
    }
  }

  void _onVoiceUp() {
    if (!mounted) return;
    VoiceModeScreen.activeState?.onPushToTalkUp();
  }

  void _syncWithEsp32() {
    if (_view == _View.dashboard || _view == _View.patients) {
      _esp32.sendCommand('STATE:0');
      _esp32.sendCommand('NAV:HOME');
    } else if (_view == _View.menu) {
      _esp32.sendCommand('STATE:1');
      _esp32.sendCommand('NAV:MENU');
      // Name the station rather than its position. The firmware's menus differ
      // per mode in both order and length, so an index computed here would be
      // resolved against whichever table the module currently believes it is in
      // — and during a mode change that is not necessarily the same one.
      final token = _navNames[_focusedModule];
      if (token != null) _esp32.sendCommand('MENU_SEL:$token');
    } else if (_view == _View.screen) {
      _esp32.sendCommand('NAV:${_navNames[_openModule]}');
      _esp32.sendCommand('STATE:${_espStates[_openModule]}');
    }
  }

  /// Open a module's screen.
  ///
  /// Single entry point for touch, the orbit's OK, and every ESP32 path, so a
  /// module cannot be reached by one route without the guest-mode restriction
  /// being enforced. Sensor screens arm their own hardware after mounting, so
  /// the module's immediate acknowledgement cannot arrive before their listeners
  /// exist.
  void _openModuleScreen(_Module id) {
    // The orbit already hides staff-only modules, but the serial link is a
    // second entrance: the firmware's menu is fixed and mode-blind, so a
    // `NAV:SETTINGS` or `STATE:8` arriving while a walk-up guest is using the
    // kiosk would otherwise open the backend configuration screen for a member
    // of the public. Refuse and put the OLED back in step with the app.
    if (!XSModules.isAllowed(id, isGuest: !KioskPatientSession.I.isStaffMode)) {
      debugPrint(
        '[kiosk] refused $id: staff-only module requested in guest mode',
      );
      _syncWithEsp32();
      return;
    }
    setState(() {
      _openModule = id;
      _view = _View.screen;
      // Keep the orbit's focus on the module being opened, so returning to the
      // menu lands where the user left rather than snapping back to slot 0.
      final slot = _visibleModules.indexOf(id);
      if (slot >= 0) _menuIndex = slot;
    });
    _syncWithEsp32();
    KioskHubClient.instance.notifyStationChange(id.name);
  }

  void _selectMenuItem(int menuIdx) {
    final modules = _visibleModules;
    if (menuIdx < 0 || menuIdx >= modules.length) return;
    _openModuleScreen(modules[menuIdx]);
  }

  // ─── Build ────────────────────────────────────────────────────
  /// Accent for the current view: the focused module in the navigator, the
  /// open module on a screen, the brand teal when idle.
  Color get _viewAccent => switch (_view) {
    _View.dashboard => XSColors.teal,
    _View.patients => XSColors.moduleXray,
    _View.menu => _menuData[_focusedModule]!.color,
    _View.screen => _menuData[_openModule]!.color,
  };

  /// Enter the navigator from the idle dashboard. Same path as module OK.
  void _onDashboardOk() {
    _openMenu();
  }

  /// Stop and reset active session back to guest entry screen.
  void _stopSession() {
    _dismissCheckIn();
    // File the visit *before* clearing: setGuestMode() drops both the record and
    // the readings, so anything not written by here is lost. Fire-and-forget on
    // purpose — the kiosk must return to guest mode whether or not the write
    // lands, and a failed POST is logged rather than blocking the handover.
    _fileVisitSummary();
    KioskPatientSession.I.setGuestMode();
    KioskHubClient.instance.notifySessionStopped();
    widget.onStopSession?.call();
  }

  /// Write this session's readings up as a consultation on the linked record.
  ///
  /// What turns a pile of separate vitals/lung/film rows into one entry the
  /// portal's history can show: the visit grouping keys off timestamps, and this
  /// gives the group its headline and risk level. Skipped for a walk-in, which by
  /// design has no record to write to.
  void _fileVisitSummary() {
    final session = KioskPatientSession.I;
    final patientId = session.selectedPatientId;
    if (patientId == null) return;

    final measured = [
      if (session.hasGuestVitals) 'pulse and SpO\u2082',
      if (session.hasGuestTemp) 'skin temperature',
      if (session.hasGuestSteth) 'breath sounds',
      if (session.hasGuestXray) 'chest radiograph',
    ];
    if (measured.isEmpty) return; // nothing was measured; nothing to file

    final triage = session.sessionTriage;
    final factors = session.sessionTriageFactors;

    // Reasons come from the same list the risk score is summed from, so the
    // filed note and the on-screen band cannot describe the visit differently.
    //
    // Split deliberately: `diagnosis` becomes the history card's headline, so it
    // stays a short verdict, and the per-reading detail goes in the summary where
    // there is room for it.
    final diagnosis = factors.isEmpty
        ? 'No findings outside the screened ranges'
        : 'Findings in ${factors.map((f) => f.station.toLowerCase()).join(', ')}';
    final detail = factors.isEmpty
        ? 'Every reading taken was inside the ranges this kiosk screens for.'
        : factors.map((f) => '${f.station}: ${f.detail}').join('; ');

    final snapshot = <String>[
      if (session.guestHr != null)
        'HR ${session.guestHr!.toStringAsFixed(0)} bpm',
      if (session.guestSpo2 != null)
        'SpO\u2082 ${session.guestSpo2!.toStringAsFixed(0)}%',
      if (session.guestTemp != null)
        'Skin temp ${session.guestTemp!.toStringAsFixed(1)} \u00B0C',
      if (session.guestStethFinding != null)
        'Breath sounds: ${session.guestStethFinding}',
      if (session.guestXrayFinding != null) 'Film: ${session.guestXrayFinding}',
    ].join(' · ');

    EMRClient()
        .createConsultation(patientId, {
          'physician': 'XSIGHT kiosk screening',
          'summary': 'Kiosk session measured ${measured.join(', ')}. $detail',
          'diagnosis': diagnosis,
          'recommendations':
              'AI-assisted screening, not a diagnosis. Have these '
              'readings reviewed by a licensed clinician.',
          'risk_level': switch (triage.level) {
            'high' => 'High',
            'moderate' => 'Moderate',
            'low' => 'Low',
            _ => 'Not assessed',
          },
          'vitals_snapshot': snapshot,
        })
        .catchError((Object e) {
          debugPrint('[shell] visit summary not filed: $e');
          return <String, dynamic>{};
        });
  }

  void _dismissCheckIn() {
    final ctx = _checkinContext;
    if (ctx == null || !ctx.mounted) return;
    _checkinContext = null;
    // Prefer check-in's own submit path so anything already collected — a phone
    // submission, or a name typed into the kiosk fallback — still lands. The
    // typed dialog is checked first because it sits *above* the check-in screen
    // when the kiosk fallback is open, so popping the screen underneath it would
    // strand the dialog. Falls back to a bare pop when neither state exists yet,
    // possible if the module reports its menu open in the same event-loop turn as
    // the route is pushed.
    final dialog = XSIntakeCheckInDialog.activeState;
    final screen = KioskCheckInScreen.activeState;
    if (dialog != null) {
      dialog.submitAndClose();
    } else if (screen != null) {
      screen.submitAndClose();
    } else {
      Navigator.of(ctx).pop();
    }
  }

  void _openMenu() {
    _flashButton('OK');
    setState(() {
      _menuIndex = 0;
      _view = _View.menu;
    });
    _syncWithEsp32();
    _announceMenu();
    _touchIdle();
  }

  /// "Choose a station", then the name of the one already under the highlight.
  void _announceMenu() =>
      VoiceGuide.I.sayAll([XSVoiceCue.menuOpen, ?_stationCues[_focusedModule]]);

  /// Speak the station the highlight just landed on.
  ///
  /// Every focus change routes through here so the spoken name cannot drift
  /// from the highlight — the same reason [_moveFocus] owns the OLED sync.
  void _announceFocus() {
    final cue = _stationCues[_focusedModule];
    if (cue != null) VoiceGuide.I.say(cue);
  }

  /// Move the orbit's focus by [delta] slots, wrapping at both ends.
  ///
  /// Every focus change the *app* originates goes through here or [_focusSlot]
  /// so the OLED highlight follows. Arrow keys, the on-screen button dock, and
  /// tapping an orbit slot each used to mutate `_menuIndex` directly, which left
  /// the two displays pointing at different modules until something else
  /// happened to resync.
  void _moveFocus(int delta) {
    final count = _visibleModules.length;
    if (count == 0) return;
    setState(() => _menuIndex = (_focusedSlot + delta + count) % count);
    _syncWithEsp32();
    _announceFocus();
  }

  /// Focus an exact orbit slot, for a direct tap on a radial item.
  void _focusSlot(int slot) {
    if (slot < 0 || slot >= _visibleModules.length || slot == _focusedSlot) {
      return;
    }
    setState(() => _menuIndex = slot);
    _syncWithEsp32();
    _announceFocus();
  }

  /// "CONTINUE WITHOUT PATIENT" from the picker.
  ///
  /// Actually drops the link rather than just navigating away: staff arrive here
  /// to *change* patient as often as to pick a first one, and leaving the old
  /// record attached made the dashboard chip claim a patient the staff member had
  /// just declined — and attached the next readings to them.
  void _continueWithoutPatient() {
    KioskPatientSession.I.unlinkPatient();
    _goHome();
  }

  /// Return to the idle dashboard and tell the module to do the same.
  void _goHome() {
    setState(() => _view = _View.dashboard);
    _syncWithEsp32();
    _greet();
    _touchIdle();
  }

  /// Reconcile the module's menu table with the mode the app is in.
  ///
  /// The sketch acknowledges every `MODE:` command with `MODE_ACK:GUEST|STAFF`,
  /// and until now the app dropped it — so a `MODE:` frame lost on the wire left
  /// the OLED walking a 6-entry guest menu while the screen showed the 7-entry
  /// staff orbit, and nothing noticed. The module never asks, and its own
  /// `setMode` returns early when the mode is unchanged, so the disagreement
  /// persisted until the next mode change or a reboot.
  ///
  /// Neither side can be moved to the wrong station by this — both resolve
  /// highlights by token against their own table and decline what does not fit —
  /// but the keypress is lost, which reads to the user as a dead button.
  void _onModeAck(bool moduleIsStaff) {
    if (!mounted) return;
    if (moduleIsStaff == KioskPatientSession.I.isStaffMode) {
      _modeResyncAttempts = 0;
      return;
    }
    if (_modeResyncAttempts >= _maxModeResyncAttempts) {
      debugPrint(
        '[kiosk] module stuck in '
        '${moduleIsStaff ? "STAFF" : "GUEST"} mode; leaving it alone',
      );
      return;
    }
    _modeResyncAttempts++;
    // Re-send rather than patch the mode directly: the same call also re-sends
    // the staff and patient names, which the module drops when it switches to
    // guest, so a partial resync would leave the OLED unlabelled.
    KioskPatientSession.I.syncWithEsp32Hardware();
  }

  /// Re-arm the idle reset, or cancel it where it does not apply.
  ///
  /// Called from every place the shell changes view or handles an input, so the
  /// decision lives here rather than in each caller. Cheap enough to call
  /// unconditionally: it is a timer swap.
  void _touchIdle() {
    _idleTimer?.cancel();
    _idleTimer = null;
    final session = KioskPatientSession.I;
    if (_view != _View.dashboard) return;
    if (session.isStaffMode || !session.isIntakeOpen) return;
    _idleTimer = Timer(_idleTimeout, _endIdleSession);
  }

  /// Clear a session whose subject has walked away.
  ///
  /// The kiosk is shared and unauthenticated, so a session left on the dashboard
  /// is the next person's problem: their readings would land under someone else's
  /// name, and the previous person's name would be on screen for a stranger to
  /// read. Ending it is the same single exit the END SESSION button uses.
  void _endIdleSession() {
    _idleTimer = null;
    if (!mounted) return;
    final session = KioskPatientSession.I;
    if (session.isStaffMode || !session.isIntakeOpen) return;
    VoiceGuide.I.say(XSVoiceCue.sessionCleared);
    _stopSession();
  }

  /// Invite the next person in. Which clip depends on what they can press: with
  /// no module attached the OK button does not exist, so the copy points at the
  /// START disc instead.
  ///
  /// The repeat guard inside [VoiceGuide] keeps this from nagging when the
  /// dashboard is reached several times in quick succession.
  void _greet() => VoiceGuide.I.say(
    _esp32.deviceReady ? XSVoiceCue.welcome : XSVoiceCue.welcomeTouch,
  );

  /// Staff wants in. When the session is already staff, this is a no-op — the
  /// dashboard's patient chip is the path for changing patients, so the login
  /// dialog is never re-shown over an authenticated session.
  Future<void> _openPatientPicker() async {
    if (!KioskPatientSession.I.isStaffMode) {
      final ok = await XSStaffLoginDialog.show(context);
      if (ok != true || !mounted) return;
    }
    setState(() => _view = _View.patients);
    _syncWithEsp32();
  }

  /// Hand the kiosk back to a walk-up member of the public.
  ///
  /// The counterpart to [_openPatientPicker]. Staff mode used to last for the
  /// process lifetime: nothing reachable from a running kiosk called
  /// `logoutStaff`, so the first PIN entered turned the panel into a staff
  /// terminal until someone restarted the app — leaving Settings and the linked
  /// patient's record in reach of whoever walked up next.
  ///
  /// The dashboard confirms before calling this, so it acts immediately.
  /// [_onSessionModeChanged] fires from `logoutStaff` and does the two things the
  /// shrinking orbit requires — clamps the focus index off Settings and
  /// evacuates the screen if one is open — and [_goHome] then re-announces the
  /// idle dashboard so the OLED is not left highlighting a module the kiosk will
  /// now refuse to open.
  void _endStaffSession() {
    KioskPatientSession.I.logoutStaff();
    _goHome();
  }

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    final accent = _viewAccent;

    return PopScope(
      // Android system back on a touch-only, module-less kiosk. Every other
      // exit assumed the ESP32's BACK button or a keyboard: hardware BACK
      // sends NAV:HOME, Escape/Backspace need keys, and the left-edge swipe
      // collides with the OS gesture navigation on phones. Without this, the
      // system back gesture popped the root route and exited the app from
      // any station screen — reopening the app was the only way out.
      canPop: _view == _View.dashboard,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _flashButton('BACK');
        _goHome();
      },
      child: KeyboardListener(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: _handleKeyEvent,
        // Recolors palette.accent for the whole subtree, so each module's
        // screens, chips, and background bloom inherit its identity.
        child: XSModuleAccent(
          color: accent,
          child: Scaffold(
            backgroundColor: palette.surface,
            // No chrome at all — this is a full-bleed clinical panel.
            //
            // The app bar used to carry a back arrow, the module title, and the
            // USB chip on every screen. All three were redundant: each module
            // paints its own header, back is reachable four other ways
            // (hardware BACK, Escape, the navigator's BACK key, and a left-edge
            // swipe), and a permanently-lit USB chip says nothing on the ~99% of
            // frames where the module is simply connected. The USB indicator is
            // now an exception reporter — see [_buildLinkWarning].
            appBar: null,
            body: Stack(
              children: [
                XSAmbientBackground(
                  accent: accent,
                  // Quieter behind dense module screens than on the idle surfaces.
                  intensity: _view == _View.screen ? 0.45 : 1.0,
                  child: SafeArea(
                    // Every view now owns its own top edge, so all of them must
                    // respect the status bar rather than sliding under it.
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 280),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      transitionBuilder: (child, animation) => FadeTransition(
                        opacity: animation,
                        child: SlideTransition(
                          position: Tween<Offset>(
                            begin: const Offset(0, 0.02),
                            end: Offset.zero,
                          ).animate(animation),
                          child: child,
                        ),
                      ),
                      child: KeyedSubtree(
                        // dashboard and menu share a key: the launcher morphs
                        // over a stationary dashboard rather than swapping it
                        // out, so opening the menu is one continuous motion.
                        key: ValueKey(switch (_view) {
                          _View.screen => 'screen',
                          _View.patients => 'patients',
                          _ => 'home',
                        }),
                        child: switch (_view) {
                          _View.screen => _buildScreen(),
                          _View.patients => KioskPatientPickerScreen(
                            onSelect: (_) => _openMenu(),
                            onSkip: _continueWithoutPatient,
                          ),
                          _ => ListenableBuilder(
                            listenable: KioskPatientSession.I,
                            builder: (context, _) {
                              return KioskPatientSession.I.isStaffMode
                                  ? KioskDashboardScreen(
                                      onBegin: _openMenu,
                                      startKey: _startKey,
                                      onChangePatient: _openPatientPicker,
                                      onEndSession: _endStaffSession,
                                    )
                                  : KioskGuestDashboardScreen(
                                      onBegin: _openMenu,
                                      onOpenStation: _selectMenuItem,
                                      startKey: _startKey,
                                      onStaffLogin: _openPatientPicker,
                                      onStopSession: _stopSession,
                                    );
                            },
                          ),
                        },
                      ),
                    ),
                  ),
                ),
                // Sibling of the whole body, not of the dashboard: the reveal
                // covers the app bar and patient bar too, so the navigator is
                // genuinely full-screen. Always mounted so the controller
                // survives view changes and the circle animates rather than pops.
                _buildLauncherOverlay(palette),
                // Touch-only escape hatch. Sits above the launcher so it works
                // from the navigator too, and is a narrow left-edge strip rather
                // than a whole-body drag detector so it cannot steal the
                // horizontal scrolls that the gauge row, quick-ask chips, and
                // history lists depend on.
                if (_view != _View.dashboard) _buildEdgeSwipeBack(),
                // Only visible when the module link needs attention.
                _buildLinkWarning(palette),
              ],
            ),
            bottomNavigationBar: null,
          ),
        ),
      ),
    );
  }

  /// Narrow left-edge strip that takes a rightward drag as "back".
  ///
  /// The only way back on a touch-only tablet with no ESP32 module and no
  /// keyboard, now that the app bar's arrow is gone. Kept to 24 logical pixels
  /// and given [HitTestBehavior.translucent] so a drag that begins anywhere
  /// else — including the horizontally scrolling gauge row and chip bars —
  /// still reaches the content beneath.
  Widget _buildEdgeSwipeBack() {
    return Positioned(
      left: 0,
      top: 0,
      bottom: 0,
      width: 24,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        // Direction matters: only an inward (rightward) pull is a back
        // gesture, so a stray leftward flick near the bezel does nothing.
        onHorizontalDragEnd: (details) {
          if (details.primaryVelocity != null &&
              details.primaryVelocity! > 120) {
            _flashButton('BACK');
            setState(() {
              _view = _view == _View.screen ? _View.menu : _View.dashboard;
            });
            _syncWithEsp32();
          }
        },
      ),
    );
  }

  /// Floating link indicator, shown only when the module link needs attention.
  ///
  /// Deliberately absent while the module is connected and ready: chrome that
  /// is always lit carries no information, and this is a full-bleed clinical
  /// panel. When it does appear it is also the retry affordance, which is the
  /// only thing the old permanent chip was ever tapped for.
  /// Now covers **both transports**: USB (OTG) and Bluetooth Classic SPP
  /// ("XSIGHT").  The firmware advertises as XSIGHT over BT and mirrors the
  /// identical protocol to USB, so a tablet with no OTG cable can test the
  /// whole flow over BT (see Esp32SerialClient auto-fallback: USB → last-known
  /// bonded XSIGHT* → bonded XSIGHT* → 8 s scan).
  Widget _buildLinkWarning(XSPalette palette) {
    final ready = _connected && _esp32.deviceReady;
    final s = XSScale.factor;
    final isBt = _esp32.usingBluetooth;
    // When not ready, surface the underlying transport error which now
    // concatenates USB and BT legs (e.g. "No USB … | BT: No XSIGHT found").
    final err = _esp32.error;

    return Positioned(
      right: 12 * s,
      bottom: 12 * s,
      child: IgnorePointer(
        ignoring: ready,
        child: AnimatedOpacity(
          opacity: ready ? 0 : 1,
          duration: const Duration(milliseconds: 300),
          child: Semantics(
            button: true,
            label: _connected
                ? 'XSIGHT Module connected but not responding. Tap to retry. Long-press for Bluetooth picker.'
                : 'XSIGHT Module not detected over USB or Bluetooth. Tap to retry. Long-press for Bluetooth picker.',
            child: GestureDetector(
              onTap: () async {
                final ok = await _esp32.connect();
                if (!mounted) return;
                setState(() => _connected = ok);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      ok
                          ? 'XSIGHT Module connected (${_esp32.transportLabel}): ${_esp32.portName}'
                          : (err ??
                                'XSIGHT Module not detected over USB or Bluetooth'),
                    ),
                    duration: const Duration(seconds: 4),
                  ),
                );
              },
              onLongPress: () async {
                // Long-press opens a minimal BT picker — useful when there are
                // multiple XSIGHT modules nearby or the module has not been
                // bonded yet. Short tap already does auto USB→BT.
                final devices = await _esp32.scanForXsight(
                  timeout: const Duration(seconds: 8),
                );
                if (!mounted) return;
                if (devices.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'No XSIGHT Bluetooth devices found. Pair "XSIGHT" in system Settings, then retry.',
                      ),
                    ),
                  );
                  return;
                }
                final chosen = await showDialog<String>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Choose XSIGHT Bluetooth'),
                    content: SizedBox(
                      width: 320,
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          for (final d in devices)
                            ListTile(
                              leading: const Icon(Icons.bluetooth),
                              title: Text(d.displayName),
                              subtitle: Text(
                                '${d.address}  rssi ${d.rssi ?? "--"}  ${d.bondState.name}',
                              ),
                              onTap: () => Navigator.of(ctx).pop(d.address),
                            ),
                        ],
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(ctx).pop(),
                        child: const Text('Cancel'),
                      ),
                    ],
                  ),
                );
                if (chosen == null) return;
                final ok = await _esp32.connectBluetooth(address: chosen);
                if (!mounted) return;
                setState(() => _connected = ok);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      ok
                          ? 'Bluetooth connected: $chosen'
                          : (_esp32.error ?? 'Bluetooth connect failed'),
                    ),
                  ),
                );
              },
              child: Container(
                padding: EdgeInsets.symmetric(
                  horizontal: XSSpacing.sm * s,
                  vertical: 8 * s,
                ),
                decoration: BoxDecoration(
                  color: palette.surface,
                  borderRadius: BorderRadius.circular(XSRadius.pill),
                  border: Border.all(
                    color: _connected
                        ? XSColors.accentOrange
                        : XSColors.accentRed,
                  ),
                  boxShadow: XSShadows.soft(palette),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      isBt
                          ? Icons.bluetooth
                          : (_connected ? Icons.usb_outlined : Icons.usb_off),
                      size: 18 * s,
                      color: _connected
                          ? (isBt ? XSColors.teal : XSColors.accentOrange)
                          : XSColors.accentRed,
                    ),
                    SizedBox(width: 6 * s),
                    Text(
                      _connected
                          ? (isBt
                                ? 'BT not responding'
                                : 'Module not responding')
                          : 'No module (USB/BT)',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: palette.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildScreen() {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      child: KeyedSubtree(
        key: ValueKey(_openModule),
        child: _pageFor(_openModule),
      ),
    );
  }

  // ─── START Disc → Radial Cockpit ───────────────────────────────
  /// The navigator has no chrome of its own: it grows straight out of the
  /// dashboard's START disc. `_View.menu` means only "panel expanded", so the
  /// module's OK button, the space bar, and a finger on the disc drive one
  /// identical flow: OK opens, UP/DOWN rotate the orbit, OK again launches.
  Widget _buildLauncherOverlay(XSPalette palette) {
    return XSLiquidReveal(
      isOpen: _view == _View.menu,
      accent: _menuData[_focusedModule]!.color,
      anchorKey: _startKey,
      // The disc's own teal, so the panel's first frame is the disc.
      originColor: XSColors.teal,
      // Collapsing back onto the START disc only reads correctly when the
      // dashboard is what is behind the panel. Launching a module replaces the
      // surface entirely, so the panel cross-fades to the module screen instead
      // of shrinking towards a disc that is no longer there.
      fadeOutOnClose: _view == _View.screen,
      onClose: () {
        _flashButton('BACK');
        setState(() => _view = _View.dashboard);
        _syncWithEsp32();
      },
      child: Padding(
        padding: EdgeInsets.only(
          top: XSSpacing.md * XSScale.factor,
          bottom: XSSpacing.xs * XSScale.factor,
        ),
        child: XSRadialMenu(
          items: _radialItems,
          selectedIndex: _focusedSlot,
          onSelectIndex: _focusSlot,
          onLaunch: () => _selectMenuItem(_focusedSlot),
          footer: _buildHardwareKeyDock(palette),
        ),
      ),
    );
  }

  Widget _buildHardwareKeyDock(XSPalette palette) {
    return _SystemNavButtonGuide(
      palette: palette,
      pressedButton: _pressedButton,
      // Touch mirrors the module's buttons so the navigator is usable with no
      // hardware attached.
      onPress: (button) {
        _flashButton(button);
        switch (button) {
          case 'UP':
            _moveFocus(-1);
          case 'DOWN':
            _moveFocus(1);
          case 'OK':
            _selectMenuItem(_focusedSlot);
          case 'BACK':
            _goHome();
        }
      },
    );
  }
}

/// Horizontal ESP32 button map for the System Navigator.
///
/// Mirrors the module's four physical buttons left-to-right: UP, DOWN,
/// OK (launch), BACK (home). A button flashes when its hardware twin is
/// pressed, and each is also a touch target so the navigator works with no
/// module attached.
class _SystemNavButtonGuide extends StatelessWidget {
  final XSPalette palette;
  final String? pressedButton;
  final ValueChanged<String>? onPress;

  const _SystemNavButtonGuide({
    required this.palette,
    this.pressedButton,
    this.onPress,
  });

  @override
  Widget build(BuildContext context) {
    const buttons = [
      (label: 'UP', icon: Icons.arrow_upward_rounded, color: XSColors.sage),
      (label: 'DOWN', icon: Icons.arrow_downward_rounded, color: XSColors.sage),
      (label: 'OK', icon: Icons.check_rounded, color: XSColors.teal),
      (label: 'BACK', icon: Icons.arrow_back_rounded, color: XSColors.slate),
    ];
    final s = XSScale.factor;

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: XSSpacing.md * s,
        vertical: 10 * s,
      ),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(XSRadius.pill),
        border: Border.all(color: palette.divider),
        boxShadow: XSShadows.soft(palette),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < buttons.length; i++) ...[
            if (i > 0) SizedBox(width: XSSpacing.lg * s),
            _buttonItem(
              label: buttons[i].label,
              icon: buttons[i].icon,
              color: buttons[i].color,
              pressed: buttons[i].label == pressedButton,
              scale: s,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buttonItem({
    required String label,
    required IconData icon,
    required Color color,
    required bool pressed,
    required double scale,
  }) {
    // Pressed button uses an inset look; idle buttons stay convex.
    final bg = pressed ? color : palette.surface;
    final fg = pressed ? Colors.white : color;

    final item = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOutCubic,
          // 52 keeps the touch target clear of the 48px minimum before scale.
          width: 52 * scale,
          height: 52 * scale,
          decoration: BoxDecoration(
            color: bg,
            shape: BoxShape.circle,
            border: Border.all(
              color: pressed ? color : palette.divider,
              width: pressed ? 2 : 1,
            ),
            boxShadow: pressed
                ? XSShadows.pressed(palette)
                : XSShadows.convex(palette),
          ),
          child: Center(
            child: Icon(icon, size: 23 * scale, color: fg),
          ),
        ),
        SizedBox(height: 5 * scale),
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.8,
            color: pressed ? color : palette.textPrimary,
          ),
        ),
      ],
    );

    if (onPress == null) return item;
    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(onTap: () => onPress!(label), child: item),
    );
  }
}
