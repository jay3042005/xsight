// Pins the ESP32 sketch's menu tables to the app's module contract.
//
// The kiosk has two navigation menus of different lengths — guest (6 stations)
// and staff (7, including Settings) — and both sides keep their own copy of the
// ordering. Nothing in the compiler or the analyzer connects
// `firmware/XSIGHT/XSIGHT.ino` to `XSModules`, so the two tables can drift into
// disagreement and the only symptom is the OLED highlighting one station while
// the screen focuses another. These tests read the sketch as text and assert the
// agreement directly.
//
// They fail on a firmware edit, which is the point: the sketch is the file most
// likely to be changed without running `flutter test`.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:xsight_app/core/sensor/esp32_serial_client.dart';
import 'package:xsight_app/ui/screens/kiosk_modules.dart';

/// One row of a `MenuEntry` table in the sketch.
typedef _FwEntry = ({
  String label,
  String token,
  String state,
  bool showsOnOled,
});

final _sketch = File('firmware/XSIGHT/XSIGHT.ino');

/// Rows of the `const MenuEntry <name>[]` table, in declaration order.
List<_FwEntry> _parseMenu(String source, String name) {
  final marker = 'const MenuEntry $name[] = {';
  final start = source.indexOf(marker);
  if (start < 0) fail('$name table not found in ${_sketch.path}');
  final end = source.indexOf('};', start);
  if (end < 0) fail('$name table is unterminated in ${_sketch.path}');

  final row = RegExp(
    r'\{\s*"([^"]*)"\s*,\s*"([^"]*)"\s*,\s*(STATE_\w+)\s*,\s*(true|false)\s*\}',
  );
  return [
    for (final m in row.allMatches(source.substring(start, end)))
      (
        label: m.group(1)!,
        token: m.group(2)!,
        state: m.group(3)!,
        showsOnOled: m.group(4) == 'true',
      ),
  ];
}

/// `AppState` names to their C++ enum ordinals — the numbers `STATE:<n>` carries.
Map<String, int> _parseAppStates(String source) {
  const marker = 'enum AppState {';
  final start = source.indexOf(marker);
  if (start < 0) fail('enum AppState not found in ${_sketch.path}');
  final end = source.indexOf('}', start);
  final body = source.substring(start + marker.length, end);

  final names = [
    for (final part in body.split(','))
      // Defensive against a comment being added inside the enum later.
      part.replaceAll(RegExp(r'//.*'), '').trim(),
  ]..removeWhere((s) => s.isEmpty);

  return {for (var i = 0; i < names.length; i++) names[i]: i};
}

/// The modules a firmware table names, skipping any token the app cannot
/// resolve — which the token test above reports on its own, with the label.
List<XSModule> _modulesOf(List<_FwEntry> menu) => [
  for (final e in menu) ?XSModules.forNav(e.token),
];

void main() {
  late String source;
  late List<_FwEntry> guest;
  late List<_FwEntry> staff;
  late Map<String, int> states;

  setUpAll(() {
    // Relative to the package root, which is where `flutter test` runs.
    if (!_sketch.existsSync()) {
      fail(
        '${_sketch.path} is missing — the protocol contract cannot be checked',
      );
    }
    source = _sketch.readAsStringSync();
    guest = _parseMenu(source, 'MENU_GUEST');
    staff = _parseMenu(source, 'MENU_STAFF');
    states = _parseAppStates(source);
  });

  group('firmware menu tables', () {
    test('both tables parse and are non-trivial', () {
      // Guards the parser itself: a silently-empty match list would make every
      // set comparison below pass for the wrong reason.
      expect(guest, isNotEmpty, reason: 'MENU_GUEST parsed as empty');
      expect(staff, isNotEmpty, reason: 'MENU_STAFF parsed as empty');
      expect(
        staff.length,
        greaterThan(guest.length),
        reason:
            'staff adds Settings, which is why positions cannot be '
            'used as identity across modes',
      );
    });

    test('every nav token in the sketch is one the app resolves', () {
      for (final e in [...guest, ...staff]) {
        expect(
          XSModules.forNav(e.token),
          isNotNull,
          reason:
              '"${e.label}" sends MENU_SEL:${e.token}, which '
              'XSModules.forNav does not know — the highlight would be '
              'silently dropped',
        );
      }
    });

    test('guest table is exactly the guest orbit, in the same order', () {
      // Same order matters as well as same membership: the OLED and the radial
      // orbit are read side by side, and UP/DOWN has to walk them in step.
      expect(_modulesOf(guest), XSModules.guest);
    });

    test('staff table is exactly the staff orbit, in the same order', () {
      expect(_modulesOf(staff), XSModules.staff);
      expect(
        _modulesOf(staff),
        contains(XSModule.settings),
        reason:
            'Settings on the OLED is the feature that made the menus '
            'different lengths',
      );
    });

    test('guest table cannot reach a staff-only module', () {
      for (final m in _modulesOf(guest)) {
        expect(
          XSModules.isAllowed(m, isGuest: true),
          isTrue,
          reason:
              '$m is in the guest OLED menu but the app blocks it for '
              'guests — the serial link would be a second entrance',
        );
      }
    });

    test('AppState ordinals match the STATE: numbers the app sends', () {
      for (final e in [...guest, ...staff]) {
        final module = XSModules.forNav(e.token)!;
        expect(
          states[e.state],
          XSModules.espStates[module],
          reason:
              '${e.state} is enum ordinal ${states[e.state]} in the '
              'sketch but the app sends STATE:${XSModules.espStates[module]} '
              'for $module',
        );
      }
    });

    test('only stations the OLED cannot draw are deferred to the logo screen', () {
      // The requested behaviour: X-ray (a film), the assistant (a conversation),
      // and Settings (a form) have nothing meaningful to show on 128x64, so the
      // module holds the logo and reveals navigation on OK instead of faking a
      // view. Everything else drives a real OLED screen.
      final deferred = {
        for (final e in [...guest, ...staff])
          if (!e.showsOnOled) e.token,
      };
      expect(deferred, {'XRAY', 'ASSIST', 'SETTINGS'});
    });

    test('a station is deferred consistently in both modes', () {
      final byToken = <String, bool>{};
      for (final e in [...guest, ...staff]) {
        final seen = byToken[e.token];
        if (seen != null) {
          expect(
            e.showsOnOled,
            seen,
            reason:
                '${e.token} defers on the OLED in one mode but not the '
                'other, so the same button would behave differently',
          );
        }
        byToken[e.token] = e.showsOnOled;
      }
    });
  });

  // The kiosk's guided-scan screens wait for the module to say a reading is
  // finished. Nothing in Dart can enforce that the sketch still does, so it is
  // pinned here alongside the menu tables: if the timed windows go away, or the
  // old "SELECT finalises it" branch comes back, the app would sit on a countdown
  // that never resolves — or record a partial reading as a measurement.
  group('timed reading windows', () {
    test('both stations declare a scan window', () {
      expect(
        source,
        contains('PULSE_SCAN_MS'),
        reason: 'the pulse station must own a timed window',
      );
      expect(
        source,
        contains('TEMP_SCAN_MS'),
        reason: 'the temperature station must own a timed window',
      );
    });

    test('the module finishes the reading itself', () {
      // The final VITALS: and PULSE_DONE:1 have to be reachable from the
      // measurement loop, not only from a button handler.
      final loop = source.substring(source.indexOf('void runPulseMeasurement'));
      expect(
        loop,
        contains('PULSE_DONE:1'),
        reason: 'runPulseMeasurement must be able to end the reading',
      );
      expect(
        loop,
        contains('PULSE_SCAN_MS'),
        reason: 'the window is what ends it',
      );
    });

    test('a partial window is not published as a vitals reading', () {
      final loop = source.substring(source.indexOf('void runPulseMeasurement'));
      expect(
        loop,
        contains('if (!validHeartRate || !validSPO2) return;'),
        reason:
            'a heart rate with no SpO2 behind it is not a vitals reading, '
            'and publishing one starts the kiosk countdown against half a '
            'measurement',
      );
      expect(
        loop,
        isNot(contains('validHeartRate || validSPO2')),
        reason: 'the old either-or publish gate must be gone',
      );
    });

    test('SELECT no longer locks in a reading mid-measurement', () {
      final handler = source.substring(
        source.indexOf('void handlePulse'),
        source.indexOf('void runPulseMeasurement'),
      );
      // The START/READ-AGAIN arm stays; the STOP-and-keep arm is what must not.
      expect(
        handler,
        contains('pulseSub = SUB_WAITING'),
        reason: 'SELECT must still arm the station from idle or done',
      );
      expect(
        handler,
        isNot(contains('PULSE_DONE:1')),
        reason: 'finishing is the window\'s job, not the button\'s',
      );
    });

    test('losing contact abandons the window rather than resuming it', () {
      final loop = source.substring(source.indexOf('void runPulseMeasurement'));
      // Two contact checks, and both must clear the clock: a reading spliced
      // across a break in contact is two readings.
      expect(
        RegExp(r'pulseScanStartMs = 0;').allMatches(loop).length,
        greaterThanOrEqualTo(2),
        reason:
            'both the pre-window and post-window finger checks must reset it',
      );
    });

    test('temperature finishes on its window too', () {
      final handler = source.substring(source.indexOf('void handleTemp'));
      expect(handler, contains('TEMP_SCAN_MS'));
      expect(handler, contains('TEMP_DONE:1'));
      expect(
        handler,
        contains('tempScanStartMs = 0;'),
        reason: 'losing aim must restart the window',
      );
    });
  });

  group('fresh scan cache', () {
    late Esp32SerialClient client;

    setUp(() => client = Esp32SerialClient());

    test('a new vitals scan drops only the previous HR and SpO2', () {
      client
        ..debugHandleLine('VITALS:82,97')
        ..debugHandleLine('TEMP:34.20')
        ..debugHandleLine('PULSE_DONE:1')
        ..beginVitalsScan();

      expect(client.latest?.hr, 0);
      expect(client.latest?.spo2, 0);
      expect(client.latest?.temp, closeTo(34.2, 0.001));
      expect(client.pulseState, isNull);
    });

    test('a new temperature scan drops only the previous temperature', () {
      client
        ..debugHandleLine('VITALS:76,98')
        ..debugHandleLine('TEMP:33.80')
        ..debugHandleLine('TEMP_DONE:1')
        ..beginTempScan();

      expect(client.latest?.hr, 76);
      expect(client.latest?.spo2, 98);
      expect(client.latest?.temp, 0);
      expect(client.tempState, isNull);
    });

    test(
      'session reset is sent to the firmware from the shared reset path',
      () {
        final sessionSource = File(
          'lib/state/kiosk_patient_state.dart',
        ).readAsStringSync();
        expect(sessionSource, contains("sendCommand('NEW_SESSION')"));
      },
    );

    test('STOP_TEMP cancels instead of publishing a completed reading', () {
      final commandHandler = source.substring(
        source.indexOf('} else if (line == "STOP_TEMP")'),
        source.indexOf('// ─── Session / identity'),
      );
      expect(commandHandler, isNot(contains('TEMP_DONE:1')));
      expect(commandHandler, contains('tempDone = false'));
      expect(commandHandler, contains('tempScanStartMs = 0'));
    });
  });

  group('menu highlight dialect', () {
    late Esp32SerialClient client;
    late List<String> tokens;
    late List<int> indexes;

    setUp(() {
      client = Esp32SerialClient();
      tokens = [];
      indexes = [];
      client
        ..onMenuSelect = tokens.add
        ..onMenuIndex = indexes.add;
    });

    test('the legacy index names a different station than the guest menu', () {
      // Why the suppression below is necessary rather than tidy: the pre-token
      // firmware's menu started at x-ray, the guest orbit starts at vitals, so
      // honouring both frames for one event moves the highlight twice and lands
      // on the wrong module.
      expect(XSModules.moduleForFirmwareIndex(0), XSModule.xray);
      expect(XSModules.guest.first, XSModule.vitals);
    });

    test('a token suppresses the legacy index that follows it', () {
      // The sketch prints both lines for a single highlight move.
      client
        ..debugHandleLine('MENU_SEL:VITALS')
        ..debugHandleLine('MENU_INDEX:0');

      expect(tokens, ['VITALS']);
      expect(
        indexes,
        isEmpty,
        reason: 'the index is an echo of the same event, not a second move',
      );
    });

    test('suppression persists across later highlights', () {
      client
        ..debugHandleLine('MENU_SEL:VITALS')
        ..debugHandleLine('MENU_INDEX:0')
        ..debugHandleLine('MENU_SEL:TEMP')
        ..debugHandleLine('MENU_INDEX:1');

      expect(tokens, ['VITALS', 'TEMP']);
      expect(indexes, isEmpty);
    });

    test('firmware predating MENU_SEL: still moves the highlight', () {
      client.debugHandleLine('MENU_INDEX:2');

      expect(indexes, [2]);
      expect(tokens, isEmpty);
    });

    test('a reboot re-learns which dialect the module speaks', () {
      client
        ..debugHandleLine('MENU_SEL:VITALS')
        ..debugHandleLine('READY:1')
        ..debugHandleLine('MENU_INDEX:2');

      // READY:1 means the sketch restarted, which can mean a different build,
      // so the index is trusted again until a token proves otherwise.
      expect(indexes, [2]);
    });

    test('an OK press names the station it launched', () {
      client.debugHandleLine('MENU_SELECT:SETTINGS');

      expect(tokens, ['SETTINGS']);
      expect(XSModules.forNav(tokens.single), XSModule.settings);
    });

    test('a numeric MENU_SELECT: is not mistaken for a token', () {
      client
        ..debugHandleLine('MENU_SELECT:3')
        ..debugHandleLine('MENU_INDEX:3');

      expect(tokens, isEmpty, reason: '"3" is the legacy positional payload');
      expect(indexes, [3], reason: 'a legacy build must keep working');
    });

    test('the module reports which menu table it is on', () {
      final modes = <bool>[];
      client.onModeAck = modes.add;

      client
        ..debugHandleLine('MODE_ACK:STAFF')
        ..debugHandleLine('MODE_ACK:GUEST');

      expect(modes, [true, false]);
    });

    test('a mode ack is read regardless of case or trailing space', () {
      final modes = <bool>[];
      client.onModeAck = modes.add;

      // The sketch prints these with `Serial.println`, and a line arriving over a
      // real port can carry a stray carriage return.
      client
        ..debugHandleLine('MODE_ACK:staff ')
        ..debugHandleLine('MODE_ACK:Guest');

      expect(modes, [true, false]);
    });

    test('an unreadable mode ack is treated as the lesser privilege', () {
      final modes = <bool>[];
      client.onModeAck = modes.add;

      client.debugHandleLine('MODE_ACK:');

      // Reporting staff on a payload we could not read would have the app accept
      // a mode the module may not be in; guest is the safe direction to guess.
      expect(modes, [false]);
    });

    test('the mode ack does not eat the mode query, or vice versa', () {
      final modes = <bool>[];
      var queries = 0;
      client
        ..onModeAck = modes.add
        ..onModeQuery = () => queries++;

      client
        ..debugHandleLine('MODE_ACK:STAFF')
        ..debugHandleLine('MODE:GET')
        ..debugHandleLine('MODE:QUERY');

      // Both branches match on a `MODE` prefix, so the more specific one has to
      // be tested first — this pins that ordering.
      expect(modes, [true], reason: 'MODE:GET is not an acknowledgement');
      expect(queries, 2, reason: 'the ack branch must not swallow the query');
    });

    test('the sketch still sends the ack the app now relies on', () {
      // The app reconciles its mode against MODE_ACK, so a firmware edit that
      // stopped printing it would silently disable that check rather than break
      // anything visibly.
      expect(source, contains('MODE_ACK:GUEST'));
      expect(source, contains('MODE_ACK:STAFF'));
    });

    test('an unknown token is delivered, not guessed at', () {
      // The client's job is transport; resolution belongs to XSModules, which
      // returns null and leaves the highlight alone.
      client.debugHandleLine('MENU_SEL:LABS');

      expect(tokens, ['LABS']);
      expect(XSModules.forNav('LABS'), isNull);
    });
  });
}
