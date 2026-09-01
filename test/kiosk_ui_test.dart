import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:xsight_app/core/theme/xs_colors.dart';
import 'package:xsight_app/core/theme/xs_theme.dart';
import 'package:xsight_app/state/kiosk_patient_state.dart';
import 'package:xsight_app/ui/components/xs_chip.dart';
import 'package:xsight_app/ui/components/xs_dial_gauge.dart';
import 'package:xsight_app/ui/components/xs_liquid_reveal.dart';
import 'package:xsight_app/core/api/upload_client.dart';
import 'package:xsight_app/core/sensor/esp32_serial_client.dart';
import 'package:xsight_app/ui/components/xs_pin_pad.dart';
import 'package:xsight_app/ui/components/xs_radial_menu.dart';
import 'package:xsight_app/ui/components/xs_remote_session_dialog.dart';
import 'package:xsight_app/ui/components/xs_sensor_scan_panel.dart';
import 'package:xsight_app/ui/components/xs_staff_dialogs.dart';
import 'package:xsight_app/ui/components/xs_stepper.dart';
import 'package:xsight_app/ui/components/xs_handwritten_word.dart';
import 'package:xsight_app/ui/screens/kiosk_chat_screen.dart';
import 'package:xsight_app/ui/screens/kiosk_checkin_screen.dart';
import 'package:xsight_app/ui/screens/kiosk_guest_dashboard.dart';
import 'package:xsight_app/ui/screens/kiosk_modules.dart';
import 'package:xsight_app/ui/screens/kiosk_patient_picker_screen.dart';
import 'package:xsight_app/ui/screens/kiosk_temp_screen.dart';
import 'package:xsight_app/ui/components/xs_button.dart';
import 'package:xsight_app/ui/screens/kiosk_vitals_screen.dart';
import 'package:xsight_app/ui/screens/voice_mode_screen.dart';

void _noop() {}

Widget _host(Widget child) => MaterialApp(
  theme: XSTheme.light(),
  home: Scaffold(body: child),
);

Widget _noGuide(double size) => SizedBox(width: size, height: size);

void main() {
  group('XSModuleAccent', () {
    testWidgets('overrides palette accent for its subtree', (tester) async {
      Color? inner;
      Color? outer;

      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) {
              outer = XSPalette.of(context).accent;
              return XSModuleAccent(
                color: XSColors.moduleVitals,
                child: Builder(
                  builder: (context) {
                    inner = XSPalette.of(context).accent;
                    return const SizedBox();
                  },
                ),
              );
            },
          ),
        ),
      );

      expect(outer, XSColors.teal, reason: 'default light accent');
      expect(
        inner,
        XSColors.moduleVitals,
        reason: 'module wrapper must recolor accent for descendants',
      );
    });
  });

  group('XSStepper', () {
    testWidgets('names the first incomplete station as next', (tester) async {
      await tester.pumpWidget(
        _host(
          const XSStepper(
            steps: [
              XSStep(
                label: 'Pulse',
                icon: Icons.favorite,
                color: XSColors.moduleVitals,
                done: true,
              ),
              XSStep(
                label: 'Temp',
                icon: Icons.thermostat,
                color: XSColors.moduleTemp,
                done: false,
              ),
              XSStep(
                label: 'Lungs',
                icon: Icons.graphic_eq,
                color: XSColors.moduleSteth,
                done: false,
              ),
            ],
          ),
        ),
      );

      expect(find.textContaining('Step 2 of 3'), findsOneWidget);
      expect(find.textContaining('next: Temp'), findsOneWidget);
    });

    testWidgets('reports completion when every station is done', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const XSStepper(
            steps: [
              XSStep(
                label: 'Pulse',
                icon: Icons.favorite,
                color: XSColors.moduleVitals,
                done: true,
              ),
              XSStep(
                label: 'Temp',
                icon: Icons.thermostat,
                color: XSColors.moduleTemp,
                done: true,
              ),
            ],
          ),
        ),
      );

      expect(find.textContaining('All stations complete'), findsOneWidget);
      expect(find.textContaining('next:'), findsNothing);
    });

    testWidgets('taps report the station index', (tester) async {
      final taps = <int>[];
      await tester.pumpWidget(
        _host(
          XSStepper(
            onStepTap: taps.add,
            steps: const [
              XSStep(
                label: 'Pulse',
                icon: Icons.favorite,
                color: XSColors.moduleVitals,
                done: false,
              ),
              XSStep(
                label: 'Temp',
                icon: Icons.thermostat,
                color: XSColors.moduleTemp,
                done: false,
              ),
            ],
          ),
        ),
      );

      await tester.tap(find.text('Temp'));
      expect(taps, [1]);
    });
  });

  group('XSDialGauge', () {
    testWidgets('renders label, unit and status without overflow', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const Center(
            child: XSDialGauge(
              value: 37.4,
              min: 34,
              max: 42,
              label: '37.4',
              unit: '°C',
              status: '99.3 °F',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('37.4'), findsOneWidget);
      expect(find.text('°C'), findsOneWidget);
      expect(find.text('99.3 °F'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('survives an out-of-range value and a zero range', (
      tester,
    ) async {
      // Sensors do emit garbage; the gauge must clamp rather than throw.
      await tester.pumpWidget(
        _host(
          const Center(
            child: XSDialGauge(
              value: 900,
              min: 0,
              max: 0,
              label: '900',
              unit: 'bpm',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('XSChip', () {
    testWidgets('is only a button when tappable', (tester) async {
      await tester.pumpWidget(
        _host(const Center(child: XSChip(label: 'GUEST'))),
      );
      expect(find.text('GUEST'), findsOneWidget);

      var tapped = false;
      await tester.pumpWidget(
        _host(
          Center(
            child: XSChip(label: 'Ask', onTap: () => tapped = true),
          ),
        ),
      );
      await tester.tap(find.text('Ask'));
      expect(tapped, isTrue);
    });
  });

  group('KioskGuestDashboardScreen', () {
    setUp(() => KioskPatientSession.I.setGuestMode());
    tearDown(() => KioskPatientSession.I.setGuestMode());

    testWidgets('start disc is touchable so a walk-up user can begin '
        'without the hardware module', (tester) async {
      var began = false;
      await tester.pumpWidget(
        _host(KioskGuestDashboardScreen(onBegin: () => began = true)),
      );

      await tester.tap(find.text('START'));
      expect(
        began,
        isTrue,
        reason: 'touch must be a first-class path to start a session',
      );
    });

    testWidgets('journey taps open the matching guest orbit slot', (
      tester,
    ) async {
      final opened = <int>[];
      await tester.pumpWidget(
        _host(KioskGuestDashboardScreen(onOpenStation: opened.add)),
      );

      await tester.tap(find.text('Pulse'));
      await tester.tap(find.text('X-Ray'));
      expect(opened, [0, 3]);

      // The numbers above are only correct while the guest orbit is ordered to
      // match this rail. Pin that, so reordering XSModules.guest fails here
      // rather than silently opening the wrong station.
      expect(
        XSModules.guest.take(4),
        [XSModule.vitals, XSModule.temp, XSModule.steth, XSModule.xray],
        reason: 'guest orbit must follow the journey rail order',
      );
    });

    testWidgets('the station names itself unauthenticated', (tester) async {
      await tester.pumpWidget(_host(const KioskGuestDashboardScreen()));

      // The reframe's whole point: whoever walks up, and whoever reviews the
      // session afterwards, must be able to tell this is the pre-login station.
      expect(find.text('TRIAGE INTAKE'), findsOneWidget);
      expect(find.text('Not saved to records'), findsOneWidget);
    });

    testWidgets('an empty session invites one instead of reporting on it', (
      tester,
    ) async {
      await tester.pumpWidget(_host(const KioskGuestDashboardScreen()));

      expect(find.text('Start your\nscreening'), findsOneWidget);
      expect(find.text('IN SESSION'), findsNothing);
    });

    testWidgets('simulated readings are labelled on the dashboard', (
      tester,
    ) async {
      KioskPatientSession.I.recordVitals(88, 97, simulated: true);

      await tester.pumpWidget(_host(const KioskGuestDashboardScreen()));

      expect(find.text('DEMO DATA — no sensor'), findsOneWidget);
      expect(find.text('88'), findsOneWidget);
    });

    testWidgets('measured readings carry no demo label', (tester) async {
      KioskPatientSession.I.recordVitals(88, 97);

      await tester.pumpWidget(_host(const KioskGuestDashboardScreen()));

      expect(find.text('DEMO DATA — no sensor'), findsNothing);
      expect(find.text('88'), findsOneWidget);
    });

    testWidgets('an intake in progress reports who it is and how far it got', (
      tester,
    ) async {
      KioskPatientSession.I
        ..setIntakeName('Juan Dela Cruz')
        ..recordVitals(88, 97)
        ..recordTemp(37.4);

      await tester.pumpWidget(_host(const KioskGuestDashboardScreen()));

      expect(find.text('IN SESSION'), findsOneWidget);
      expect(find.textContaining('Juan Dela Cruz'), findsOneWidget);
      expect(find.textContaining('2 of 4 stations'), findsOneWidget);
      // Held values are shown, and the stations that have not run are shown as
      // absent rather than omitted.
      expect(find.text('88'), findsOneWidget);
      expect(find.text('97'), findsOneWidget);
      expect(find.text('37.4'), findsOneWidget);
      expect(find.text('—'), findsOneWidget, reason: 'lungs has not run yet');
      expect(find.text('Start your\nscreening'), findsNothing);
    });

    testWidgets('a skipped check-in still reads as a session in progress', (
      tester,
    ) async {
      // Skipping leaves no name and no readings, so the old conditions saw an
      // empty kiosk and showed the invitation — while the session was open and
      // START would not ask again. The two halves have to agree.
      KioskPatientSession.I.openIntakeSession();

      await tester.pumpWidget(_host(const KioskGuestDashboardScreen()));

      expect(find.text('IN SESSION'), findsOneWidget);
      expect(find.textContaining('0 of 4 stations'), findsOneWidget);
      expect(find.text('Start your\nscreening'), findsNothing);
    });

    testWidgets('END SESSION is offered for a session with nothing recorded', (
      tester,
    ) async {
      KioskPatientSession.I.openIntakeSession(name: 'Juan Dela Cruz');

      // Wrapped the way the shell mounts it: the screen reads the session in
      // `build` and does not subscribe itself, so the shell owns the rebuild.
      // Mounting it bare here would test a configuration the kiosk never shows
      // and the panel would never react to the tap below.
      //
      // Not `const`: a const widget is canonicalised, so the builder would hand
      // the element the identical instance and Flutter would skip the rebuild
      // entirely. The shell passes callbacks, so its instance is never const.
      await tester.pumpWidget(
        _host(
          ListenableBuilder(
            listenable: KioskPatientSession.I,
            builder: (_, _) => KioskGuestDashboardScreen(onBegin: () {}),
          ),
        ),
      );

      // Previously keyed on readings existing, which hid the only way out of
      // exactly the session that had produced nothing to look at.
      expect(find.text('END SESSION'), findsOneWidget);

      await tester.tap(find.text('END SESSION'));
      await tester.pump();

      expect(KioskPatientSession.I.isIntakeOpen, isFalse);
      expect(find.text('Start your\nscreening'), findsOneWidget);
      expect(find.text('END SESSION'), findsNothing);
    });

    testWidgets('END SESSION delegates to the shell stop flow when provided', (
      tester,
    ) async {
      KioskPatientSession.I.openIntakeSession(name: 'Juan Dela Cruz');
      var stopped = false;

      await tester.pumpWidget(
        _host(
          ListenableBuilder(
            listenable: KioskPatientSession.I,
            builder: (_, _) => KioskGuestDashboardScreen(
              onStopSession: () {
                stopped = true;
                KioskPatientSession.I.resetGuestSession();
              },
            ),
          ),
        ),
      );

      await tester.tap(find.text('END SESSION'));
      await tester.pump();

      expect(stopped, isTrue);
      expect(KioskPatientSession.I.isIntakeOpen, isFalse);
    });

    testWidgets('an untouched kiosk offers no way to end a session', (
      tester,
    ) async {
      await tester.pumpWidget(_host(const KioskGuestDashboardScreen()));

      expect(find.text('END SESSION'), findsNothing);
    });
  });

  group('KioskVitalsScreen persistence', () {
    setUp(() => KioskPatientSession.I.resetGuestSession());
    tearDown(() => KioskPatientSession.I.resetGuestSession());

    testWidgets('a reading taken with the keyboard emulator still reaches the '
        'session, so it survives BACK', (tester) async {
      // The original bug: only the ESP32 path wrote to the session, so on a kiosk
      // with no module the screen showed a live SpO2 and the dashboard showed
      // nothing at all once you went back.
      //
      // The free-running fallback is gone — with no module the station now
      // waits for contact — so P stands in for the finger.
      expect(KioskPatientSession.I.hasGuestVitals, isFalse);

      await tester.pumpWidget(_host(const KioskVitalsScreen()));
      await tester.pump(const Duration(seconds: 3));
      expect(
        KioskPatientSession.I.hasGuestVitals,
        isFalse,
        reason: 'nothing may reach the session before contact',
      );

      Esp32SerialClient.shared.simulateVitalsScan();
      await tester.pump(const Duration(seconds: 6));

      final session = KioskPatientSession.I;
      expect(
        session.hasGuestVitals,
        isTrue,
        reason: 'the reading must outlive the screen that took it',
      );
      expect(session.guestSpo2, greaterThan(0));
      expect(
        session.guestVitalsSimulated,
        isTrue,
        reason: 'no sensor was attached, so it must not pass as measured',
      );

      // Let the screen's periodic timer go quiet before the test ends.
      await tester.pumpWidget(_host(const SizedBox()));
    });

    testWidgets('hardware vitals reach the session only after PULSE_DONE', (
      tester,
    ) async {
      final esp32 = Esp32SerialClient.shared;
      esp32.clearReadings();
      await tester.pumpWidget(_host(const KioskVitalsScreen()));
      await tester.pump(const Duration(milliseconds: 100));

      esp32.debugHandleLine('VITALS:84,97');
      await tester.pump();
      expect(KioskPatientSession.I.hasGuestVitals, isFalse);

      esp32.debugHandleLine('PULSE_DONE:1');
      await tester.pump();
      expect(KioskPatientSession.I.guestHr, 84);
      expect(KioskPatientSession.I.guestSpo2, 97);
      expect(KioskPatientSession.I.guestVitalsSimulated, isFalse);

      await tester.pumpWidget(_host(const SizedBox()));
    });

    testWidgets(
      'hardware temperature reaches the session only after TEMP_DONE',
      (tester) async {
        final esp32 = Esp32SerialClient.shared;
        esp32.clearReadings();
        await tester.pumpWidget(_host(const KioskTempScreen()));
        await tester.pump(const Duration(milliseconds: 100));

        esp32.debugHandleLine('TEMP:34.10');
        await tester.pump();
        expect(KioskPatientSession.I.hasGuestTemp, isFalse);

        esp32.debugHandleLine('TEMP_DONE:1');
        await tester.pump();
        expect(KioskPatientSession.I.guestTemp, closeTo(34.1, 0.001));
        expect(KioskPatientSession.I.guestTempSimulated, isFalse);

        await tester.pumpWidget(_host(const SizedBox()));
      },
    );

    testWidgets(
      'the keyboard emulator delivers a temperature tagged simulated',
      (tester) async {
        final esp32 = Esp32SerialClient.shared;
        esp32.clearReadings();
        await tester.pumpWidget(_host(const KioskTempScreen()));
        await tester.pump(const Duration(milliseconds: 100));

        expect(KioskPatientSession.I.hasGuestTemp, isFalse);

        esp32.simulateTempScan();
        await tester.pump(const Duration(seconds: 6));

        expect(KioskPatientSession.I.hasGuestTemp, isTrue);
        expect(KioskPatientSession.I.guestTemp, greaterThan(0));
        expect(
          KioskPatientSession.I.guestTempSimulated,
          isTrue,
          reason: 'no sensor was attached, so it must not pass as measured',
        );

        await tester.pumpWidget(_host(const SizedBox()));
      },
    );
  });

  group('KioskPatientSession intake identity', () {
    setUp(() => KioskPatientSession.I.setGuestMode());
    tearDown(() => KioskPatientSession.I.setGuestMode());

    test('a name given at check-in replaces the generated walk-in label', () {
      final session = KioskPatientSession.I;
      expect(session.hasIntakeName, isFalse);
      expect(session.patientDisplayName, startsWith('Walk-In Guest'));

      session.setIntakeName('  Juan Dela Cruz  ');

      expect(session.hasIntakeName, isTrue);
      expect(session.patientDisplayName, startsWith('Juan Dela Cruz ('));
      // The intake id survives, so a report still traces back to the session.
      expect(session.patientDisplayName, contains('GST-'));
    });

    test('a blank check-in leaves the generated label alone', () {
      final session = KioskPatientSession.I..setIntakeName('   ');

      expect(session.hasIntakeName, isFalse);
      expect(session.patientDisplayName, startsWith('Walk-In Guest'));
    });

    test('check-in opens the session exactly once, skip included', () {
      final session = KioskPatientSession.I;
      expect(
        session.isIntakeOpen,
        isFalse,
        reason: 'a fresh kiosk has no session to resume',
      );

      // Skipped check-in: no name, no readings, but the question was answered.
      session.openIntakeSession();
      expect(
        session.isIntakeOpen,
        isTrue,
        reason: 'START must not re-ask someone who already skipped',
      );
      expect(session.hasIntakeName, isFalse);
      expect(session.sessionStartedAt, isNotNull);

      final startedAt = session.sessionStartedAt;
      session.openIntakeSession(name: 'Juan Dela Cruz');
      expect(
        session.sessionStartedAt,
        startedAt,
        reason: 'a second call must not restart the clock mid-session',
      );
      expect(session.hasIntakeName, isTrue);
    });

    test('a reading opens a session that check-in never did', () {
      // A station reached without passing through check-in — the dashboard's
      // direct station jump — must not leave readings in a closed session, or the
      // check-in dialog would ambush someone already measured.
      final session = KioskPatientSession.I..recordVitals(88, 97);

      expect(session.isIntakeOpen, isTrue);
    });

    test(
      'reset closes the session, so the next person is checked in again',
      () {
        final session = KioskPatientSession.I
          ..openIntakeSession(name: 'Juan Dela Cruz')
          ..recordVitals(88, 97);
        expect(session.isIntakeOpen, isTrue);

        session.resetGuestSession();

        expect(
          session.isIntakeOpen,
          isFalse,
          reason: 'one exit has to clear the lifecycle flag with the data',
        );
      },
    );

    test('RESET clears the name and the clock, not just the readings', () {
      final session = KioskPatientSession.I
        ..setIntakeName('Juan Dela Cruz')
        ..recordVitals(88, 97);
      expect(session.sessionStartedAt, isNotNull);

      session.resetGuestSession();

      expect(
        session.hasIntakeName,
        isFalse,
        reason: 'a cleared session must not keep the last person\'s name',
      );
      expect(session.patientDisplayName, startsWith('Walk-In Guest'));
      expect(session.measuredStationCount, 0);
      expect(session.sessionStartedAt, isNull);
    });

    test('linking a record discards held readings unless attach is confirmed', () {
      final session = KioskPatientSession.I..recordVitals(88, 97);
      expect(session.hasHeldIntakeReadings, isTrue);

      session.selectPatient({'id': 7, 'name': 'Real Patient', 'mrn': 'MRN-7'});

      // Pins the safety property: the kiosk cannot know the linked record belongs
      // to whoever just used the station, so the default must lose the readings
      // rather than write a stranger's into a real chart.
      expect(session.measuredStationCount, 0);
      expect(session.patientDisplayName, startsWith('Real Patient'));
    });

    test('a value no sensor produced is marked, and the AI is told', () {
      final session = KioskPatientSession.I
        ..recordVitals(88, 97, simulated: true);

      expect(session.hasSimulatedReadings, isTrue);
      expect(session.guestVitalsSimulated, isTrue);
      // The assistant reasons about these numbers, so it must not be handed a
      // random walk as though a finger had been on the sensor.
      expect(session.clinicalContextPrompt, contains('SIMULATED'));
    });

    test('a measured value carries no demo marker', () {
      final session = KioskPatientSession.I..recordVitals(88, 97);

      expect(session.hasSimulatedReadings, isFalse);
      expect(session.clinicalContextPrompt, isNot(contains('SIMULATED')));
    });

    test('a real reading replacing a simulated one clears the marker', () {
      final session = KioskPatientSession.I
        ..recordVitals(88, 97, simulated: true);
      expect(session.hasSimulatedReadings, isTrue);

      // What happens when the module is plugged in mid-session: the hardware
      // path records over the stand-in and the demo marker must not persist.
      session.recordVitals(90, 98);

      expect(session.hasSimulatedReadings, isFalse);
    });

    test('RESET clears provenance along with the readings', () {
      final session = KioskPatientSession.I
        ..recordVitals(88, 97, simulated: true)
        ..recordTemp(37.1, simulated: true);
      expect(session.hasSimulatedReadings, isTrue);

      session.resetGuestSession();

      expect(session.hasSimulatedReadings, isFalse);
      expect(session.guestVitalsSimulated, isFalse);
      expect(session.guestTempSimulated, isFalse);
    });

    test('confirmed attach carries the held readings onto the record', () {
      final session = KioskPatientSession.I..recordVitals(88, 97);

      session.selectPatient({
        'id': 8,
        'name': 'Real Patient',
        'mrn': 'MRN-8',
      }, attachHeldReadings: true);

      expect(session.guestHr, 88);
      expect(session.measuredStationCount, 1);
    });
  });

  group('XSModules orbit', () {
    test('guest orbit hides Settings but keeps the assistant', () {
      expect(
        XSModules.guest,
        isNot(contains(XSModule.settings)),
        reason: 'backend URL and telemetry are staff-only',
      );
      expect(XSModules.guest, contains(XSModule.assistant));
    });

    test('staff orbit exposes every module in the catalogue', () {
      expect(XSModules.staff.toSet(), XSModules.catalogue.keys.toSet());
    });

    test('mode switch changes which module a slot means', () {
      // The bug this guards: slot index was used as module identity, so staff
      // slot 3 (temp) and guest slot 3 (x-ray) collided.
      expect(XSModules.forMode(isGuest: true)[3], XSModule.xray);
      expect(XSModules.forMode(isGuest: false)[3], XSModule.temp);
    });

    test('every module has a title, nav token, and esp state', () {
      for (final m in XSModule.values) {
        expect(XSModules.catalogue[m], isNotNull, reason: '$m missing copy');
        expect(XSModules.titles[m], isNotNull, reason: '$m missing title');
        expect(XSModules.navNames[m], isNotNull, reason: '$m missing nav');
        expect(XSModules.espStates[m], isNotNull, reason: '$m missing state');
      }
    });

    test('nav tokens and esp states round-trip to the same module', () {
      for (final m in XSModule.values) {
        expect(XSModules.forNav(XSModules.navNames[m]!), m);
        expect(XSModules.forEspState(XSModules.espStates[m]!), m);
      }
      expect(XSModules.forNav('NOPE'), isNull);
      expect(
        XSModules.forEspState(0),
        isNull,
        reason: '0 is the dashboard, not a module',
      );
    });
  });

  group('KioskPatientSession clinical context', () {
    setUp(() => KioskPatientSession.I.resetGuestSession());
    tearDown(() => KioskPatientSession.I.resetGuestSession());

    test('unmeasured stations are reported, never invented', () {
      final ctx = KioskPatientSession.I.clinicalContextPrompt;

      expect(ctx, contains('Heart Rate: not measured'));
      expect(ctx, contains('Chest Radiograph Finding: not measured'));
      expect(KioskPatientSession.I.measuredStationCount, 0);
    });

    test('recorded readings appear with units', () {
      KioskPatientSession.I
        ..recordVitals(88, 97)
        ..recordTemp(37.4)
        ..recordStethoscope('', 'wheeze');

      final ctx = KioskPatientSession.I.clinicalContextPrompt;

      expect(ctx, contains('88 bpm'));
      expect(ctx, contains('97%'));
      expect(ctx, contains('37.4 °C'));
      expect(ctx, contains('wheeze'));
      expect(KioskPatientSession.I.measuredStationCount, 3);
    });
  });

  group('KioskPatientPickerScreen', () {
    setUp(() => KioskPatientSession.I.resetGuestSession());
    tearDown(() => KioskPatientSession.I.resetGuestSession());

    testWidgets('picking a patient links the session before reporting it', (
      tester,
    ) async {
      // Offline is the state a demo kiosk boots into: the picker falls back to
      // its fictional roster, so this exercises the real widget without HTTP.
      Map<String, dynamic>? picked;
      await tester.pumpWidget(
        _host(
          KioskPatientPickerScreen(onSelect: (p) => picked = p, onSkip: () {}),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Eleanor Vance'));
      await tester.pump();

      expect(picked?['name'], 'Eleanor Vance');
      expect(
        KioskPatientSession.I.isGuest,
        isFalse,
        reason: 'session must be linked by the time the shell is told',
      );
      expect(KioskPatientSession.I.selectedPatient?['name'], 'Eleanor Vance');
    });

    testWidgets('demo records are labelled so staff cannot mistake them', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(KioskPatientPickerScreen(onSelect: (_) {}, onSkip: () {})),
      );
      await tester.pumpAndSettle();

      expect(find.text('DEMO RECORDS'), findsOneWidget);
    });

    testWidgets('skipping returns a real guest session, not a null patient', (
      tester,
    ) async {
      var skipped = false;
      await tester.pumpWidget(
        _host(
          KioskPatientPickerScreen(
            onSelect: (_) {},
            onSkip: () => skipped = true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('CONTINUE WITHOUT PATIENT'));
      await tester.pump();

      expect(skipped, isTrue);
    });
  });

  group('KioskChatScreen', () {
    testWidgets('opens on an empty state, not a fake assistant message', (
      tester,
    ) async {
      // The greeting used to be pushed into `_messages` as role=assistant,
      // which was then replayed to the model as real conversation history.
      await tester.pumpWidget(_host(const KioskChatScreen()));

      expect(find.text('Ask about this session'), findsOneWidget);
      expect(find.text('XSIGHT AI'), findsNothing);
      expect(find.textContaining('Not a diagnosis'), findsOneWidget);
    });

    testWidgets('starter cards are tappable entry points', (tester) async {
      await tester.pumpWidget(_host(const KioskChatScreen()));

      expect(find.text('Summarize this session'), findsOneWidget);
      expect(find.text('Recommend next steps'), findsOneWidget);
    });
  });
  group('XSLiquidReveal', () {
    testWidgets('draws nothing at all while closed', (tester) async {
      await tester.pumpWidget(
        _host(
          XSLiquidReveal(
            isOpen: false,
            accent: XSColors.moduleXray,
            onClose: () {},
            child: const Text('cockpit'),
          ),
        ),
      );

      // The dashboard's START disc is the only affordance, so a closed reveal
      // must contribute no visuals, no hit targets, and must not mount `child`
      // (whose controllers would otherwise tick unseen).
      expect(find.text('cockpit'), findsNothing);
      expect(find.byType(GestureDetector), findsNothing);
    });

    testWidgets('reveals its child and a close button once opened', (
      tester,
    ) async {
      Widget host(bool isOpen) => _host(
        XSLiquidReveal(
          isOpen: isOpen,
          accent: XSColors.moduleXray,
          onClose: () {},
          child: const Text('cockpit'),
        ),
      );

      await tester.pumpWidget(host(false));
      await tester.pumpWidget(host(true));
      await tester.pumpAndSettle();

      expect(find.text('cockpit'), findsOneWidget);
      expect(find.byIcon(Icons.close_rounded), findsOneWidget);
    });

    testWidgets('close button dismisses, and so does a tap beside the panel', (
      tester,
    ) async {
      var closed = 0;

      Widget host(bool isOpen) => _host(
        XSLiquidReveal(
          isOpen: isOpen,
          accent: XSColors.moduleXray,
          onClose: () => closed++,
          child: const SizedBox(),
        ),
      );

      await tester.pumpWidget(host(false));
      await tester.pumpWidget(host(true));

      // Mid-morph the panel has not yet covered the surface, so the barrier
      // behind it is reachable — this is the window where an outside tap has
      // any meaning at all. Once open the panel is the whole surface.
      await tester.pump(const Duration(milliseconds: 120));
      await tester.tapAt(const Offset(4, 4));
      expect(closed, 1, reason: 'tap beside the growing panel must dismiss');

      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.close_rounded));
      expect(closed, 2);
    });

    testWidgets('expands from the anchor it is given', (tester) async {
      final anchorKey = GlobalKey();
      const anchorSize = 120.0;

      // Deliberately off-centre: an anchor at the surface's centre would let
      // the assertions below pass even with no anchoring at all.
      Widget host(bool isOpen) => _host(
        Stack(
          children: [
            Positioned(
              left: 40,
              top: 60,
              child: Container(
                key: anchorKey,
                width: anchorSize,
                height: anchorSize,
                color: XSColors.teal,
              ),
            ),
            XSLiquidReveal(
              isOpen: isOpen,
              accent: XSColors.moduleXray,
              anchorKey: anchorKey,
              onClose: () {},
              child: const SizedBox(),
            ),
          ],
        ),
      );

      await tester.pumpWidget(host(false));
      final anchor = tester.getRect(find.byKey(anchorKey));

      await tester.pumpWidget(host(true));
      // A bare pump() advances no time, so the controller would still read 0
      // and the panel would correctly not exist yet.
      await tester.pump(const Duration(milliseconds: 1));

      // The panel itself always fills the surface — the *clip* is what grows —
      // so assert on the clipper it was handed. Its origin must be the anchor's
      // rect in the reveal's coordinates, which is what ties the animation to
      // the START disc.
      final clipper =
          tester.widget<ClipPath>(find.byType(ClipPath).first).clipper
              as RevealClipper;
      expect((clipper.origin.center - anchor.center).distance, lessThan(1));
      expect(clipper.origin.width, closeTo(anchorSize, 1));
    });

    testWidgets('grows gradually rather than snapping to full size', (
      tester,
    ) async {
      final anchorKey = GlobalKey();

      Widget host(bool isOpen) => _host(
        Stack(
          children: [
            Positioned(
              left: 40,
              top: 500,
              child: Container(
                key: anchorKey,
                width: 120,
                height: 120,
                color: XSColors.teal,
              ),
            ),
            XSLiquidReveal(
              isOpen: isOpen,
              accent: XSColors.moduleXray,
              anchorKey: anchorKey,
              onClose: () {},
              child: const SizedBox(),
            ),
          ],
        ),
      );

      await tester.pumpWidget(host(false));
      await tester.pumpWidget(host(true));

      double coveredFraction() {
        final clipper =
            tester.widget<ClipPath>(find.byType(ClipPath).first).clipper
                as RevealClipper;
        final path = clipper.getClip(clipper.full.size);
        var hits = 0;
        var total = 0;
        for (var x = 4.0; x < clipper.full.width; x += 12) {
          for (var y = 4.0; y < clipper.full.height; y += 12) {
            total++;
            if (path.contains(Offset(x, y))) hits++;
          }
        }
        return hits / total;
      }

      // Guards both ways the timing can go wrong. Front-loaded easing (the old
      // cubic-bezier(0.22, 1, 0.36, 1)) is over 80% travelled a fifth of the way
      // in, so the disc appears to jump straight to full screen — that is what
      // the upper bounds catch. The opposite failure is a long decelerating tail
      // that spends most of the wall clock creeping through the last few percent
      // where there is nothing left to see, which reads as sluggish — the lower
      // bound at the two-thirds mark catches that.
      const total = XSLiquidReveal.openDuration;
      Duration frac(double f) =>
          Duration(microseconds: (total.inMicroseconds * f).round());

      await tester.pump(frac(0.25));
      final quarter = coveredFraction();
      expect(
        quarter,
        lessThan(0.5),
        reason: 'a quarter in, most of the surface must still be unrevealed',
      );

      await tester.pump(frac(0.25));
      final half = coveredFraction();
      expect(half, greaterThan(quarter), reason: 'must keep growing');
      expect(
        half,
        lessThan(0.95),
        reason: 'halfway in, the reveal must not already be complete',
      );

      await tester.pump(frac(1 / 6));
      expect(
        coveredFraction(),
        greaterThan(0.9),
        reason:
            'two-thirds in, the growth must be nearly done — a long '
            'tail past this point is dead time that reads as sluggish',
      );

      await tester.pumpAndSettle();
      expect(
        coveredFraction(),
        greaterThan(0.99),
        reason: 'must end up covering the surface',
      );

      // The bounds above are all proportional, so they say nothing about how
      // long the reveal actually takes — a 2s version would satisfy every one of
      // them. This is the wall-clock budget: the panel must be essentially there
      // within half a second of the tap, or it feels slow no matter how well
      // shaped the curve is.
      expect(
        XSLiquidReveal.openDuration.inMilliseconds,
        lessThanOrEqualTo(750),
      );
    });

    testWidgets('reverses cleanly back to nothing', (tester) async {
      Widget host(bool isOpen) => _host(
        XSLiquidReveal(
          isOpen: isOpen,
          accent: XSColors.moduleXray,
          onClose: () {},
          child: const Text('cockpit'),
        ),
      );

      await tester.pumpWidget(host(false));
      await tester.pumpWidget(host(true));
      await tester.pumpAndSettle();
      expect(find.text('cockpit'), findsOneWidget);

      // Closing must run to completion and tear the panel down. An early
      // `if (value == 0)` bail on a *forward-only* curve used to leave the last
      // frames playing at full speed; the reverse curve is checked here by
      // requiring the tree to be empty again once settled.
      await tester.pumpWidget(host(false));
      await tester.pumpAndSettle();
      expect(find.text('cockpit'), findsNothing);
      expect(find.byType(ClipPath), findsNothing);
    });

    testWidgets('fadeOutOnClose fades in place instead of collapsing', (
      tester,
    ) async {
      final anchorKey = GlobalKey();

      Widget host(bool isOpen) => _host(
        Stack(
          children: [
            Positioned(
              left: 40,
              top: 500,
              child: Container(
                key: anchorKey,
                width: 120,
                height: 120,
                color: XSColors.teal,
              ),
            ),
            XSLiquidReveal(
              isOpen: isOpen,
              accent: XSColors.moduleXray,
              anchorKey: anchorKey,
              fadeOutOnClose: true,
              onClose: () {},
              child: const Text('cockpit'),
            ),
          ],
        ),
      );

      await tester.pumpWidget(host(false));
      await tester.pumpWidget(host(true));
      await tester.pumpAndSettle();

      await tester.pumpWidget(host(false));
      await tester.pump(const Duration(milliseconds: 110));

      // Mid-exit the clip must still cover the whole surface: the panel is
      // handing over to the module screen, so shrinking it back towards the
      // START disc would animate towards something about to be replaced.
      final clipper =
          tester.widget<ClipPath>(find.byType(ClipPath).first).clipper
              as RevealClipper;
      final path = clipper.getClip(clipper.full.size);
      for (final corner in [clipper.full.topRight, clipper.full.bottomLeft]) {
        final probe = Offset(
          corner.dx == 0 ? 1 : corner.dx - 1,
          corner.dy == 0 ? 1 : corner.dy - 1,
        );
        expect(
          path.contains(probe),
          isTrue,
          reason: 'geometry must stay full-size while fading',
        );
      }

      // Opacity, not geometry, is what carries the exit.
      final fade = tester.widget<Opacity>(
        find
            .ancestor(of: find.byType(ClipPath), matching: find.byType(Opacity))
            .last,
      );
      expect(fade.opacity, greaterThan(0.0));
      expect(fade.opacity, lessThan(1.0));

      // And it still tears down completely.
      await tester.pumpAndSettle();
      expect(find.text('cockpit'), findsNothing);
      expect(find.byType(ClipPath), findsNothing);
    });
  });

  group('RevealClipper', () {
    const full = Rect.fromLTWH(0, 0, 400, 300);
    // Off-centre and low, like the START disc on a wide kiosk panel.
    final origin = Rect.fromCircle(center: const Offset(80, 220), radius: 60);

    Path clipAt(double t) =>
        RevealClipper(origin: origin, full: full, t: t).getClip(full.size);

    test('starts as a circle matching the anchor', () {
      final bounds = clipAt(0).getBounds();

      // Not merely "small": the START disc is round, so the first frame has to
      // be the disc's own circle, or the reveal reads as a rectangle appearing.
      expect(bounds.width, closeTo(origin.width, 1));
      expect(bounds.height, closeTo(origin.height, 1));
      expect((bounds.center - origin.center).distance, lessThan(1));
      expect(bounds.width, closeTo(bounds.height, 1), reason: 'must be round');
    });

    test('ends covering every corner of the surface', () {
      final path = clipAt(1);

      for (final corner in [
        full.topLeft,
        full.topRight,
        full.bottomLeft,
        full.bottomRight,
      ]) {
        // Nudge inward: a path does not reliably contain its own boundary.
        final probe = Offset(
          corner.dx == 0 ? 1 : corner.dx - 1,
          corner.dy == 0 ? 1 : corner.dy - 1,
        );
        expect(
          path.contains(probe),
          isTrue,
          reason: 'corner $corner uncovered',
        );
      }
    });

    test('the visible region only ever grows', () {
      int covered(double t) {
        final path = clipAt(t);
        var hits = 0;
        for (var x = 2.0; x < full.width; x += 8) {
          for (var y = 2.0; y < full.height; y += 8) {
            if (path.contains(Offset(x, y))) hits++;
          }
        }
        return hits;
      }

      var last = 0;
      for (var t = 0.0; t <= 1.0; t += 0.05) {
        final now = covered(t);
        expect(
          now,
          greaterThanOrEqualTo(last),
          reason: 'visible region shrank at t=${t.toStringAsFixed(2)}',
        );
        last = now;
      }
      // Sanity: a clip stuck at zero would satisfy monotonicity trivially.
      expect(last, greaterThan(0));
    });
  });

  group('XSRadialMenu', () {
    const items = <XSRadialMenuItem>[
      (
        icon: Icons.medical_services_outlined,
        label: 'Upload X-Ray',
        sub: 'Chest radiograph AI analysis',
        tag: 'RADIOLOGY',
        sensor: 'DICOM pipeline',
        details: ['Multi-pathology detection'],
        color: XSColors.moduleXray,
      ),
      (
        icon: Icons.monitor_heart_outlined,
        label: 'Heart Rate',
        sub: 'Pulse oximetry reading',
        tag: 'BIOMETRIC',
        sensor: 'MAX30102',
        details: ['Pulse waveform'],
        color: XSColors.moduleVitals,
      ),
    ];

    testWidgets('focuses an unfocused card and launches the focused one', (
      tester,
    ) async {
      var launches = 0;
      final selections = <int>[];

      await tester.pumpWidget(
        _host(
          XSRadialMenu(
            items: items,
            selectedIndex: 0,
            onSelectIndex: selections.add,
            onLaunch: () => launches++,
          ),
        ),
      );

      // Tapping a card that is not focused must preview it, never launch: the
      // HUD is the only place a walk-up user sees what a module will do.
      await tester.tap(find.text('Heart Rate'));
      expect(selections, [1]);
      expect(launches, 0);

      // The focused card is at the top of the arc; its label also appears in
      // the HUD, so target the orbital card by its ordinal badge.
      await tester.tap(find.text('01'));
      expect(launches, 1);
    });

    testWidgets('HUD describes the focused module', (tester) async {
      await tester.pumpWidget(
        _host(
          XSRadialMenu(
            items: items,
            selectedIndex: 1,
            onSelectIndex: (_) {},
            onLaunch: () {},
          ),
        ),
      );

      expect(find.text('BIOMETRIC'), findsOneWidget);
      expect(find.text('MAX30102'), findsOneWidget);
      expect(find.text('Pulse oximetry reading'), findsOneWidget);
      expect(find.text('LAUNCH MODULE'), findsOneWidget);
    });
  });

  group('XSPinPad', () {
    testWidgets('submits on its own once the last slot fills', (tester) async {
      final entered = <String>[];
      await tester.pumpWidget(
        _host(Center(child: XSPinPad(onCompleted: entered.add))),
      );

      for (final d in ['1', '2', '3']) {
        await tester.tap(find.text(d));
        await tester.pump();
      }
      expect(entered, isEmpty, reason: 'an incomplete PIN must not submit');

      await tester.tap(find.text('4'));
      await tester.pump();
      // The pad hands the PIN over one frame late so the fourth slot is painted
      // before the host closes; pump again to let that callback run.
      await tester.pump();
      expect(entered, ['1234']);
    });

    testWidgets('backspace and CLR are dead until something is entered', (
      tester,
    ) async {
      final entered = <String>[];
      await tester.pumpWidget(
        _host(Center(child: XSPinPad(onCompleted: entered.add))),
      );

      final pad = tester.state<XSPinPadState>(find.byType(XSPinPad));
      await tester.tap(find.text('CLR'));
      await tester.tap(find.byIcon(Icons.backspace_outlined));
      await tester.pump();
      expect(pad.filled, 0);

      await tester.tap(find.text('7'));
      await tester.tap(find.text('8'));
      await tester.pump();
      expect(pad.filled, 2);

      await tester.tap(find.byIcon(Icons.backspace_outlined));
      await tester.pump();
      expect(pad.filled, 1);

      await tester.tap(find.text('CLR'));
      await tester.pump();
      expect(pad.filled, 0);
      expect(entered, isEmpty);
    });

    testWidgets('an error empties the pad, so the retry starts clean', (
      tester,
    ) async {
      Widget build(String? error) => _host(
        Center(
          child: XSPinPad(onCompleted: (_) {}, errorText: error),
        ),
      );

      await tester.pumpWidget(build(null));
      await tester.tap(find.text('1'));
      await tester.tap(find.text('2'));
      await tester.pump();
      expect(tester.state<XSPinPadState>(find.byType(XSPinPad)).filled, 2);

      await tester.pumpWidget(build('PIN not recognised. Try again.'));
      await tester.pump();
      expect(find.text('PIN not recognised. Try again.'), findsOneWidget);
      expect(tester.state<XSPinPadState>(find.byType(XSPinPad)).filled, 0);
    });

    testWidgets('scales down rather than overflowing a narrow panel', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          Center(
            child: SizedBox(width: 160, child: XSPinPad(onCompleted: (_) {})),
          ),
        ),
      );
      await tester.pump();

      // The pad's natural width is wider than 160, so without the FittedBox the
      // key row would push past its parent and the layout phase would report an
      // overflow here. Keys must stay tappable after the scale-down.
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('5'));
      await tester.pump();
      expect(tester.state<XSPinPadState>(find.byType(XSPinPad)).filled, 1);
    });
  });

  group('XSStaffLoginDialog', () {
    setUp(() => KioskPatientSession.I.setGuestMode());
    tearDown(() => KioskPatientSession.I.setGuestMode());

    Future<bool?> openAndEnter(WidgetTester tester, List<String> digits) async {
      bool? result;
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  result = await XSStaffLoginDialog.show(context),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      for (final d in digits) {
        await tester.tap(find.text(d));
        await tester.pump();
      }
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets('a complete PIN unlocks staff mode with no confirm button', (
      tester,
    ) async {
      expect(KioskPatientSession.I.isStaffMode, isFalse);

      final result = await openAndEnter(tester, ['1', '2', '3', '4']);

      expect(result, isTrue);
      expect(
        KioskPatientSession.I.isStaffMode,
        isTrue,
        reason: 'the pad must submit without a separate action button',
      );
      expect(find.byType(XSStaffLoginDialog), findsNothing);
    });

    testWidgets('cancel leaves the session unauthenticated', (tester) async {
      bool? result;
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  result = await XSStaffLoginDialog.show(context),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(result, isFalse);
      expect(KioskPatientSession.I.isStaffMode, isFalse);
    });

    testWidgets('a typed staff name is used verbatim', (tester) async {
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => XSStaffLoginDialog.show(context),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'Nurse Reyes');
      // Focusing the field scrolls the dialog content; settle before tapping so
      // the keys are where the finder thinks they are.
      await tester.pumpAndSettle();

      for (final d in ['8', '8', '8', '8']) {
        await tester.tap(find.text(d));
        await tester.pump();
      }
      await tester.pumpAndSettle();

      // Not "Dr. Nurse Reyes": the old screen prefixed a title onto whatever was
      // typed, which turned the staff-ID placeholder into "Dr. DR-4091".
      expect(KioskPatientSession.I.staffName, 'Nurse Reyes');
    });

    testWidgets(
      'an untouched name field leaves the existing staff name alone',
      (tester) async {
        final before = KioskPatientSession.I.staffName;

        await openAndEnter(tester, ['0', '0', '0', '0']);

        expect(KioskPatientSession.I.staffName, before);
      },
    );
  });

  group('LungSoundResult', () {
    test('reports which classifier answered, and how loud the capture was', () {
      final r = LungSoundResult.fromJson({
        'label': 'crackle',
        'confidence': 0.72,
        'bytes_received': 80044,
        'model': 'torch',
        'features': {'signal_rms_counts': 37.7, 'duration_s': 20.0},
      });

      expect(r.label, 'crackle');
      expect(r.model, 'torch');
      expect(r.isHeuristic, isFalse);
      expect(r.signalRmsCounts, 37.7);
    });

    test('a heuristic answer is distinguishable from a trained one', () {
      // The fallback returns the same shape as the model, so this flag is the only
      // thing that separates a trained reading from hand-picked thresholds.
      final r = LungSoundResult.fromJson({
        'label': 'normal',
        'confidence': 0.5,
        'bytes_received': 4000,
        'model': 'heuristic',
      });

      expect(r.isHeuristic, isTrue);
      expect(r.signalRmsCounts, 0, reason: 'absent features must not throw');
    });

    test('a response with no model or features still parses', () {
      // An older backend, or one that errored before the classifier ran.
      final r = LungSoundResult.fromJson({'label': 'wheeze'});

      expect(r.label, 'wheeze');
      expect(r.model, isEmpty);
      expect(
        r.isHeuristic,
        isFalse,
        reason: 'unknown is not the same claim as heuristic',
      );
    });
  });

  group('KioskPatientSession phone check-in', () {
    setUp(() => KioskPatientSession.I.setGuestMode());
    tearDown(() => KioskPatientSession.I.setGuestMode());

    test('a submission fills in name, age, sex and reported symptoms', () {
      final session = KioskPatientSession.I;

      session.applyIntakeDetails({
        'name': '  Maria Santos ',
        'age': 41,
        'sex': 'Female',
        'symptoms': ['dry cough', 'shortness of breath'],
      });

      expect(session.patientDisplayName, contains('Maria Santos'));
      expect(session.selectedPatient?['age'], 41);
      expect(session.selectedPatient?['gender'], 'Female');
      expect(session.intakeSymptoms, ['dry cough', 'shortness of breath']);
      expect(
        session.isIntakeOpen,
        isTrue,
        reason: 'somebody filled the form in, so the session has started',
      );
    });

    test('age arrives as a string from a form field and still lands', () {
      final session = KioskPatientSession.I..applyIntakeDetails({'age': '58'});
      expect(session.selectedPatient?['age'], 58);
    });

    test('an implausible age is refused rather than stored', () {
      final session = KioskPatientSession.I;
      final before = session.selectedPatient?['age'];

      session.applyIntakeDetails({'age': 0});
      expect(session.selectedPatient?['age'], before);

      session.applyIntakeDetails({'age': 900});
      expect(
        session.selectedPatient?['age'],
        before,
        reason: 'browser input is untrusted; a bad age must not reach the CDSS',
      );
    });

    test('a flooded symptom list is capped and its entries trimmed', () {
      final session = KioskPatientSession.I;

      session.applyIntakeDetails({
        'symptoms': ['  fever  ', ...List.generate(40, (i) => 'symptom $i')],
      });

      expect(session.intakeSymptoms.length, 12);
      expect(session.intakeSymptoms.first, 'fever');
    });

    test('non-string symptom entries are dropped, not stringified', () {
      final session = KioskPatientSession.I
        ..applyIntakeDetails({
          'symptoms': [
            'cough',
            42,
            null,
            {'a': 'b'},
            'wheeze',
          ],
        });

      expect(session.intakeSymptoms, ['cough', 'wheeze']);
    });

    test('a submission cannot rewrite a linked record', () {
      final session = KioskPatientSession.I;
      session.authenticateStaff('1234');
      session.selectPatient({
        'id': 7,
        'name': 'Real Patient',
        'mrn': 'MRN-7',
        'age': 60,
        'gender': 'Male',
      });

      session.applyIntakeDetails({
        'name': 'Someone Else',
        'age': 22,
        'sex': 'Female',
      });

      expect(session.selectedPatient?['name'], 'Real Patient');
      expect(session.selectedPatient?['age'], 60);
      expect(
        session.selectedPatient?['gender'],
        'Male',
        reason: 'a browser form must never edit a chart',
      );
    });

    test('resetting the session clears the reported symptoms', () {
      final session = KioskPatientSession.I
        ..applyIntakeDetails({
          'symptoms': ['fever'],
        });
      expect(session.intakeSymptoms, isNotEmpty);

      session.resetGuestSession();
      expect(
        session.intakeSymptoms,
        isEmpty,
        reason: 'nothing may carry over to the next person',
      );
    });
  });

  group('XSHandwrittenWord', () {
    // The reveal builds its gradient stops from the animation value, and equal
    // stops at the extremes are the case that would assert.
    for (final v in [0.0, 0.5, 1.0]) {
      testWidgets('renders at progress $v', (tester) async {
        await tester.pumpWidget(
          _host(
            XSHandwrittenWord(
              text: 'Hello',
              progress: AlwaysStoppedAnimation<double>(v),
              color: XSColors.slate,
            ),
          ),
        );
        expect(tester.takeException(), isNull);
        expect(find.text('Hello'), findsOneWidget);
      });
    }
  });

  group('KioskCheckInScreen', () {
    setUp(() => KioskPatientSession.I.setGuestMode());
    tearDown(() => KioskPatientSession.I.setGuestMode());

    /// Push check-in and let the greeting finish writing.
    ///
    /// Explicit pumps rather than `pumpAndSettle`: the ambient background runs a
    /// continuous animation, so settling never returns.
    Future<KioskCheckInResult?> pushAndSettle(WidgetTester tester) async {
      KioskCheckInResult? result;
      var pushed = false;
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) {
              if (!pushed) {
                pushed = true;
                WidgetsBinding.instance.addPostFrameCallback((_) async {
                  result = await Navigator.of(context).push<KioskCheckInResult>(
                    PageRouteBuilder<KioskCheckInResult>(
                      pageBuilder: (context, animation, secondaryAnimation) =>
                          const KioskCheckInScreen(autoStartHandoff: false),
                    ),
                  );
                });
              }
              return const SizedBox.expand();
            },
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(seconds: 2));
      return result;
    }

    testWidgets('greets, then offers a way past the QR', (tester) async {
      tester.view
        ..physicalSize = const Size(1280, 800)
        ..devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await pushAndSettle(tester);

      expect(find.text('Hello'), findsOneWidget);
      expect(find.text('Welcome to XSIGHT'), findsOneWidget);
      expect(find.text('ENTER DETAILS ON THE KIOSK'), findsOneWidget);
      expect(find.text('Start without giving details'), findsOneWidget);
    });

    testWidgets('starting without details resolves to a skip', (tester) async {
      tester.view
        ..physicalSize = const Size(1280, 800)
        ..devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      KioskCheckInResult? result;
      var pushed = false;
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) {
              if (!pushed) {
                pushed = true;
                WidgetsBinding.instance.addPostFrameCallback((_) async {
                  result = await Navigator.of(context).push<KioskCheckInResult>(
                    PageRouteBuilder<KioskCheckInResult>(
                      pageBuilder: (context, animation, secondaryAnimation) =>
                          const KioskCheckInScreen(autoStartHandoff: false),
                    ),
                  );
                });
              }
              return const SizedBox.expand();
            },
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(seconds: 2));

      await tester.tap(find.text('Start without giving details'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(result, isNotNull);
      expect(result!.name, isNull);
      expect(result!.details, isNull);
    });

    testWidgets('the shell can close it and keep the session', (tester) async {
      tester.view
        ..physicalSize = const Size(1280, 800)
        ..devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await pushAndSettle(tester);
      // The path `_dismissCheckIn` takes when hardware opens the module's own
      // menu while check-in is still up.
      expect(KioskCheckInScreen.activeState, isNotNull);
      KioskCheckInScreen.activeState!.submitAndClose();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Welcome to XSIGHT'), findsNothing);
      expect(
        KioskCheckInScreen.activeState,
        isNull,
        reason: 'a closed screen must not stay addressable',
      );
    });
  });

  group('guided sensor stations', () {
    setUp(() => KioskPatientSession.I.setGuestMode());
    tearDown(() => KioskPatientSession.I.setGuestMode());

    /// Explicit pumps: both screens hold a repeating fallback timer, so settling
    /// never returns.
    Future<void> mount(WidgetTester tester, Widget screen) async {
      tester.view
        ..physicalSize = const Size(1280, 800)
        ..devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_host(screen));
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('vitals opens on coaching, not on charts', (tester) async {
      await mount(tester, const KioskVitalsScreen());

      expect(find.text('Place your fingertip on the sensor'), findsOneWidget);
      // The trend charts belong to the settled reading. Showing them during the
      // scan invited someone to read a number that was still moving.
      expect(find.text('Heart Rate'), findsNothing);
      expect(find.text('ALERT THRESHOLDS'), findsNothing);
    });

    testWidgets('vitals says the station starts itself', (tester) async {
      await mount(tester, const KioskVitalsScreen());
      expect(
        find.textContaining('no button to press'),
        findsOneWidget,
        reason: 'the reading is automatic; the copy has to say so',
      );
    });

    testWidgets('temperature opens on coaching with no take-reading button', (
      tester,
    ) async {
      await mount(tester, const KioskTempScreen());

      // The IR sensor reads the same fingertip as the pulse sensor, so the
      // placement a walk-in has to learn is identical at both stations.
      expect(find.textContaining('fingertip'), findsWidgets);
      expect(find.textContaining('forehead'), findsNothing);
      // The old manual trigger is what made "press OK to keep this" a step.
      expect(find.text('TAKE TEMPERATURE'), findsNothing);
      expect(find.text('MEASURING...'), findsNothing);
    });
  });

  group('XSSensorScanPanel', () {
    testWidgets('counts down and shows both live values while scanning', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const XSSensorScanPanel(
            phase: XSScanPhase.scanning,
            guide: _noGuide,
            guideMessage: 'place finger',
            acquiringMessage: 'finding pulse',
            secondsLeft: 12,
            totalSeconds: 20,
            accent: XSColors.moduleVitals,
            live: [
              (label: 'HEART RATE', value: '72', unit: 'bpm'),
              (label: 'SpO2', value: '98', unit: '%'),
            ],
          ),
        ),
      );

      expect(find.text('12'), findsOneWidget);
      expect(find.text('72'), findsOneWidget);
      expect(find.text('98'), findsOneWidget);
      expect(find.text('Reading — hold still'), findsOneWidget);
      // Coaching copy belongs to the earlier phases only.
      expect(find.text('place finger'), findsNothing);
    });

    testWidgets('the ring stops claiming progress once the window is up', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const XSSensorScanPanel(
            phase: XSScanPhase.finishing,
            guide: _noGuide,
            guideMessage: 'place finger',
            acquiringMessage: 'finding pulse',
            secondsLeft: 0,
            totalSeconds: 20,
            accent: XSColors.moduleVitals,
          ),
        ),
      );

      final ring = tester.widget<CircularProgressIndicator>(
        find.byType(CircularProgressIndicator),
      );
      expect(
        ring.value,
        isNull,
        reason:
            'the module has not confirmed yet, and a full still ring '
            'would read as finished',
      );
      expect(find.text('Finishing up'), findsOneWidget);
    });

    testWidgets('coaching phases show the guide, not a countdown', (
      tester,
    ) async {
      for (final phase in [XSScanPhase.guide, XSScanPhase.acquiring]) {
        await tester.pumpWidget(
          _host(
            XSSensorScanPanel(
              phase: phase,
              guide: _noGuide,
              guideMessage: 'place finger',
              acquiringMessage: 'finding pulse',
              secondsLeft: 20,
              totalSeconds: 20,
              accent: XSColors.moduleVitals,
              live: const [(label: 'HEART RATE', value: '72', unit: 'bpm')],
            ),
          ),
        );
        expect(
          find.byType(CircularProgressIndicator),
          findsNothing,
          reason: '$phase has nothing to count down yet',
        );
        expect(
          find.text('72'),
          findsNothing,
          reason: '$phase has no reading to show',
        );
      }
    });
  });

  group('remote session prompt', () {
    /// Opens the dialog over a bare host and hands back the pending result.
    Future<Future<bool?>> open(
      WidgetTester tester,
      Map<String, dynamic> patient,
    ) async {
      late Future<bool?> result;
      await tester.pumpWidget(
        MaterialApp(
          theme: XSTheme.light(),
          home: Builder(
            builder: (context) {
              return Scaffold(
                body: Center(
                  child: ElevatedButton(
                    onPressed: () => result = XSRemoteSessionDialog.show(
                      context,
                      patient: patient,
                    ),
                    child: const Text('open'),
                  ),
                ),
              );
            },
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets('a record with no details invents none', (tester) async {
      // This shipped as "Profile: Unknown · Adult" — two facts about a patient
      // that nobody supplied, on the screen that asks them to consent.
      await open(tester, {'name': 'Arjay'});
      expect(find.text('Arjay'), findsOneWidget);
      expect(find.textContaining('Unknown'), findsNothing);
      expect(find.textContaining('Adult'), findsNothing);
    });

    testWidgets('a date of birth is never relabelled as an age', (
      tester,
    ) async {
      await open(tester, {'name': 'Ana', 'sex': 'Female', 'dob': '1981-04-12'});
      expect(find.textContaining('DOB 1981-04-12'), findsOneWidget);
      expect(find.textContaining('1981-04-12 yrs'), findsNothing);
    });

    testWidgets('an age is shown as an age', (tester) async {
      await open(tester, {'name': 'Ana', 'sex': 'Female', 'age': 45});
      expect(find.textContaining('45 yrs'), findsOneWidget);
    });

    testWidgets('an unnamed record still says who it is not', (tester) async {
      await open(tester, {'id': 7});
      expect(find.text('Unnamed record'), findsOneWidget);
      expect(find.textContaining('MRN-10007'), findsOneWidget);
    });

    testWidgets('accept resolves true and decline resolves false', (
      tester,
    ) async {
      var result = await open(tester, {'name': 'Ana'});
      await tester.tap(find.textContaining('ACCEPT'));
      await tester.pumpAndSettle();
      expect(await result, isTrue);

      result = await open(tester, {'name': 'Ana'});
      await tester.tap(find.text('DECLINE'));
      await tester.pumpAndSettle();
      expect(await result, isFalse);
    });

    testWidgets('the two actions do not overlap', (tester) async {
      // The old AlertDialog actions row overflowed and stacked "Decline" on top
      // of the accept button, so a decline tap could start the session instead.
      await open(tester, {'name': 'Ana', 'sex': 'Female', 'age': 45});
      final accept = tester.getRect(find.textContaining('ACCEPT'));
      final decline = tester.getRect(find.text('DECLINE'));
      expect(accept.overlaps(decline), isFalse);
      expect(decline.top, greaterThan(accept.bottom));
    });
  });


group('guided scan panel on a landscape phone', () {
  // The panel's FittedBox used to scale the whole column — CANCEL included —
  // down to ~0.55 on an 800x360 phone, leaving a ~30 px button that could not
  // be hit with a fingertip. The button now lives outside the scaling box.
  testWidgets('CANCEL keeps a real touch target at 800x360 mid-scan',
      (tester) async {
    tester.view
      ..physicalSize = const Size(800, 360)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _host(XSSensorScanPanel(
        phase: XSScanPhase.scanning,
        guide: (size) => SizedBox(width: size, height: size),
        guideMessage: 'Place your fingertip on the sensor',
        acquiringMessage: 'Finding your pulse',
        secondsLeft: 20,
        totalSeconds: 20,
        accent: XSColors.moduleVitals,
        live: const [
          (label: 'HEART RATE', value: '72', unit: 'bpm'),
        ],
        onCancel: () {},
      )),
    );
    await tester.pump(const Duration(milliseconds: 300));

    final button = find.widgetWithText(XSButton, 'CANCEL');
    expect(button, findsOneWidget,
        reason: 'mid-scan there IS something to cancel');
    final size = tester.getSize(button);
    expect(
      size.height >= 48,
      isTrue,
      reason: 'CANCEL rendered at ${size.height}px tall — below the 48px '
          'minimum touch target',
    );
  });

  testWidgets('guide phase shows no CANCEL — nothing to abandon yet',
      (tester) async {
    // In guide a CANCEL resets to the state the user is already in: a dead
    // button, which is exactly what it read as on module-less setups where
    // the panel never leaves guide. Leaving the station is BACK.
    await tester.pumpWidget(
      _host(XSSensorScanPanel(
        phase: XSScanPhase.guide,
        guide: (size) => SizedBox(width: size, height: size),
        guideMessage: 'Place your fingertip on the sensor',
        acquiringMessage: 'Finding your pulse',
        secondsLeft: 20,
        totalSeconds: 20,
        accent: XSColors.moduleVitals,
        onCancel: () {},
      )),
    );
    expect(find.widgetWithText(XSButton, 'CANCEL'), findsNothing);
  });

  // Regression: the voice screen's visualizer ticker mutated a fixed-length
  // list every frame — "Unsupported operation: Cannot remove from a
  // fixed-length list" — which only shows up once the ticker actually runs
  // (a single pump() in the layout tests never ticks it). Pump with elapsed
  // time so the ticker fires, and expect a clean build.
  testWidgets('voice mode visualizer ticker does not throw', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: XSTheme.light(),
        home: const VoiceModeScreen(onExit: _noop),
      ),
    );
    // Let several level ticks run at ~16ms each.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(tester.takeException(), isNull);
  });
});

}
