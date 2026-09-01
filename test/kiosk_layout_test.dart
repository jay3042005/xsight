import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xsight_app/core/theme/xs_colors.dart';
import 'package:xsight_app/core/theme/xs_scale.dart';
import 'package:xsight_app/core/theme/xs_theme.dart';
import 'package:xsight_app/state/kiosk_patient_state.dart';
import 'package:xsight_app/ui/components/xs_liquid_reveal.dart';
import 'package:xsight_app/ui/components/xs_radial_menu.dart';
import 'package:xsight_app/ui/components/xs_remote_session_dialog.dart';
import 'package:xsight_app/ui/components/xs_sensor_scan_panel.dart';
import 'package:xsight_app/ui/components/xs_staff_dialogs.dart';
import 'package:xsight_app/ui/screens/kiosk_cdss_screen.dart';
import 'package:xsight_app/ui/screens/kiosk_chat_screen.dart';
import 'package:xsight_app/ui/screens/kiosk_checkin_screen.dart';
import 'package:xsight_app/ui/screens/kiosk_dashboard.dart';
import 'package:xsight_app/ui/screens/kiosk_guest_dashboard.dart';
import 'package:xsight_app/ui/screens/kiosk_guest_entry_screen.dart';
import 'package:xsight_app/ui/screens/kiosk_modules.dart';
import 'package:xsight_app/ui/screens/kiosk_patient_picker_screen.dart';
import 'package:xsight_app/ui/screens/kiosk_settings_screen.dart';
import 'package:xsight_app/ui/screens/kiosk_temp_screen.dart';
import 'package:xsight_app/ui/screens/kiosk_vitals_screen.dart';
import 'package:xsight_app/ui/screens/mode_selection_screen.dart';
import 'package:xsight_app/ui/screens/voice_mode_screen.dart';

/// The shipped app is landscape-only. Portrait geometries remain here as a
/// defensive fallback for desktop resizing and platform transition frames.
/// Overflow is silent in release builds, so pump every screen at each geometry
/// and fail on layout errors.
const _sizes = <String, Size>{
  'landscape 1280x800': Size(1280, 800),
  'portrait 800x1280': Size(800, 1280),
  'small tablet 1024x768': Size(1024, 768),
  // Xiaomi Pad 6 kiosk: 2880x1800 at DPR 2.75 -> 1047x655 logical. The
  // 655px shortest side lands in the 1.15 scale bucket, which none of the
  // geometries above exercise, so overflows shipped to the Pad unseen.
  'xiaomi pad 6 landscape': Size(1047, 655),
  'xiaomi pad 6 portrait': Size(655, 1047),
  // Landscape phone (20:9, e.g. 800x360 logical). The kiosk app on a phone
  // is a real deployment surface now — the guided scan panels and module
  // screens must not overflow or shrink their buttons to untappable sizes.
  'landscape phone 800x360': Size(800, 360),
};

/// Layout faults only. Missing plugins (libserialport, SoLoud), failed HTTP,
/// and pending timers are expected in a unit-test host and are not what this
/// suite guards.
bool _isLayoutFault(Object error) {
  final text = error.toString();
  return text.contains('overflowed') ||
      text.contains('RenderBox was not laid out') ||
      text.contains('was given unbounded') ||
      // An Expanded inside a scroll view. This one is worse than an overflow:
      // it throws during performLayout, so the subtree gets no size and the
      // screen renders blank rather than merely wrong. The old filter matched
      // only 'was given unbounded' and missed this wording entirely.
      text.contains('non-zero flex but incoming') ||
      text.contains('unbounded constraints');
}

/// The staff orbit, straight from the shell's own catalogue.
///
/// Built rather than hand-copied: a duplicate list drifts, and the whole point
/// of this case is that the *real* module set fits. Seven orbiting cards plus
/// the central HUD is the densest thing the kiosk draws.
List<XSRadialMenuItem> get _navigatorItems => [
  for (final id in XSModules.staff)
    if (XSModules.catalogue[id] case final m?)
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

Future<List<String>> _layoutFaults(
  WidgetTester tester,
  Size size,
  Widget child,
) async {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final faults = <String>[];
  final previousErrorHandler = FlutterError.onError;
  FlutterError.onError = (details) {
    if (_isLayoutFault(details.exception)) {
      faults.add(details.exceptionAsString().split('\n').first);
      return;
    }
    previousErrorHandler?.call(details);
  };
  addTearDown(() => FlutterError.onError = previousErrorHandler);

  try {
    await tester.pumpWidget(
      MaterialApp(
        theme: XSTheme.light(),
        // Mirror main.dart: the kiosk factor is applied to text app-wide, which is
        // what actually pushes these layouts to their limits.
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(XSScale.factor)),
          child: child!,
        ),
        home: Scaffold(body: child),
      ),
    );

    // Let intro/idle animations settle, then tear the tree down so screens
    // with periodic timers dispose cleanly. The FlutterError hook above keeps
    // every render exception; tester.takeException only retains one when a
    // frame emits several related layout failures.
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  } finally {
    FlutterError.onError = previousErrorHandler;
    while (true) {
      final error = tester.takeException();
      if (error == null) break;
      if (_isLayoutFault(error)) {
        faults.add(error.toString().split('\n').first);
      }
    }
  }

  return faults;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  // Network-backed screens are included deliberately: with no backend
  // configured they must still lay out, which is the state a freshly imaged
  // kiosk boots into.
  final screens = <String, Widget Function()>{
    'guest dashboard': () => KioskGuestDashboardScreen(onStaffLogin: () {}),
    // Both staff-only callbacks supplied, because both add chrome the shell
    // always asks for: the patient chip in the header and the exit from staff
    // mode in the tools row. Constructing it bare tested a configuration the
    // kiosk never shows.
    'staff dashboard': () =>
        KioskDashboardScreen(onChangePatient: () {}, onEndSession: () {}),
    // Reached right after staff login, before any sensor runs, so it has to
    // survive the same geometries as the dashboards.
    'patient picker': () =>
        KioskPatientPickerScreen(onSelect: (_) {}, onSkip: () {}),
    // The first thing a walk-in sees. Two halves side by side on a landscape
    // panel and stacked in portrait, so it is exactly the kind of screen this
    // sweep exists for. Handoff off: there is no backend here, and the relay's
    // countdown would outlive the test.
    'check-in': () => const KioskCheckInScreen(autoStartHandoff: false),
    'vitals': () => const KioskVitalsScreen(),
    // Every phase of the guided panel, because each renders different content in
    // the same box: the guide art, then a countdown ring with live values beside
    // it. The scan phase is the tallest, and it is the one a walk-in actually
    // stands in front of.
    for (final phase in XSScanPhase.values)
      'scan panel (${phase.name})': () => XSSensorScanPanel(
        phase: phase,
        guide: (size) => SizedBox(width: size, height: size),
        guideMessage: 'Place your fingertip on the sensor',
        acquiringMessage: 'Finding your pulse',
        secondsLeft: 12,
        totalSeconds: 20,
        accent: XSColors.moduleVitals,
        live: const [
          (label: 'HEART RATE', value: '72', unit: 'bpm'),
          (label: 'SpO2', value: '98', unit: '%'),
        ],
        onCancel: () {},
      ),
    'temperature': () => const KioskTempScreen(),
    'summary/CDSS': () => const KioskCDSSScreen(),
    // Same screen in its densest legal state: all four stations measured,
    // triage factors listing, long finding strings. This is the state that
    // overflowed on the Xiaomi Pad 6, not the empty one above.
    'summary/CDSS (all stations measured)': () {
      final session = KioskPatientSession.I;
      session
        ..setGuestMode()
        ..recordVitals(118, 96)
        ..recordTemp(38.2)
        ..recordStethoscope('/tmp/session.wav', 'crackle')
        ..recordXray(
          '/tmp/film.jpg',
          'Possible right lower-lobe consolidation',
          0.82,
        );
      return const KioskCDSSScreen();
    },
    // The assistant module now opens on the voice stage (text chat is a
    // button on it), so this is the screen the module actually mounts. Hosted
    // like the shell hosts it — onExit supplied — so the exit path is the one
    // production uses. The chat screen is covered by its own entry below.
    'assistant': () => VoiceModeScreen(onExit: () {}),
    'assistant chat': () => const KioskChatScreen(),
    'settings': () => const KioskSettingsScreen(),
    'guest entry': () => KioskGuestEntryScreen(
      onEnterGuestMode: () {},
      onEnterRemoteSession: (_) {},
      autoConnectHub: false,
      // Same reasoning as the hub: a real sensor connect would start the
      // 2s retry timer and probe serial/BT plugins, which hang or outlive
      // the fake-async zone. The badge states are covered by unit tests.
      autoConnectSensor: false,
      autoDiscoverServer: false,
    ),
    'mode selection': () => ModeSelectionScreen(onProceed: () {}),
    // The module navigator now lives inside the liquid reveal, so it is laid
    // out at the panel's size rather than the screen's. Pump it already open:
    // on a 768px-tall panel the full staff orbit is the first thing to overflow.
    'module navigator': () => XSLiquidReveal(
      isOpen: true,
      accent: XSColors.moduleXray,
      onClose: () {},
      child: XSRadialMenu(
        items: _navigatorItems,
        selectedIndex: 0,
        onSelectIndex: (_) {},
        onLaunch: () {},
      ),
    ),
  };

  for (final entry in screens.entries) {
    for (final size in _sizes.entries) {
      testWidgets('${entry.key} lays out at ${size.key}', (tester) async {
        final faults = await _layoutFaults(tester, size.value, entry.value());
        expect(
          faults,
          isEmpty,
          reason: '${entry.key} has layout faults at ${size.key}',
        );
      });
    }
  }

  // The staff PIN pad is the densest thing the kiosk puts in a dialog and the
  // only one laid out as a fixed grid, so it gets the same geometry sweep as the
  // screens. A key pushed outside the dialog is a key nobody can press, and the
  // overflow that causes it is silent in a release build.
  for (final size in _sizes.entries) {
    testWidgets('staff login lays out at ${size.key}', (tester) async {
      var opened = false;
      final faults = await _layoutFaults(
        tester,
        size.value,
        Builder(
          builder: (context) {
            if (!opened) {
              opened = true;
              WidgetsBinding.instance.addPostFrameCallback(
                (_) => XSStaffLoginDialog.show(context),
              );
            }
            return const SizedBox.expand();
          },
        ),
      );
      expect(
        faults,
        isEmpty,
        reason: 'staff login has layout faults at ${size.key}',
      );
    });
  }

  // The remote-session consent prompt shipped as an AlertDialog whose actions
  // row silently overflowed, wrapping "Decline" on top of the accept button so
  // the two targets overlapped. Same geometry sweep, and with the longest field
  // values a portal record can send.
  for (final size in _sizes.entries) {
    testWidgets('remote session prompt lays out at ${size.key}', (
      tester,
    ) async {
      var opened = false;
      final faults = await _layoutFaults(
        tester,
        size.value,
        Builder(
          builder: (context) {
            if (!opened) {
              opened = true;
              WidgetsBinding.instance.addPostFrameCallback(
                (_) => XSRemoteSessionDialog.show(
                  context,
                  patient: {
                    'id': 4,
                    'name': 'Maria Consuelo Dela Cruz-Villanueva',
                    'sex': 'Female',
                    'dob': '1981-04-12',
                  },
                ),
              );
            }
            return const SizedBox.expand();
          },
        ),
      );
      expect(
        faults,
        isEmpty,
        reason: 'remote session prompt has layout faults at ${size.key}',
      );
    });
  }
}
