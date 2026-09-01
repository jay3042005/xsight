import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:xsight_app/core/ai/xs_ai_card.dart';
import 'package:xsight_app/core/theme/xs_theme.dart';
import 'package:xsight_app/state/kiosk_patient_state.dart';
import 'package:xsight_app/ui/components/ai/xs_differential_card.dart';
import 'package:xsight_app/ui/components/ai/xs_risk_gauge_card.dart';
import 'package:xsight_app/ui/components/ai/xs_vitals_table_card.dart';
import 'package:xsight_app/ui/components/ai/xs_xray_compare_card.dart';

Widget _host(Widget child) => MaterialApp(
      theme: XSTheme.light(),
      home: Scaffold(body: child),
    );

void main() {
  group('XSAiCard.parseList', () {
    test('accepts the four known cards', () {
      final cards = XSAiCard.parseList([
        {'card': 'xray_compare'},
        {'card': 'vitals_table'},
        {'card': 'risk_gauge'},
        {'card': 'differential'},
      ]);
      expect(cards.map((c) => c.type), [
        XSAiCardType.xrayCompare,
        XSAiCardType.vitalsTable,
        XSAiCardType.riskGauge,
        XSAiCardType.differential,
      ]);
    });

    test('skips unknown names and junk instead of throwing', () {
      final cards = XSAiCard.parseList([
        {'card': 'launch_missiles'},
        'not a map',
        {'no_card_key': true},
        null,
        {'card': 'vitals_table'},
      ]);
      expect(cards.map((c) => c.type), [XSAiCardType.vitalsTable],
          reason: 'one bad card must cost one panel, never the whole answer');
    });

    test('returns empty for a non-list payload', () {
      expect(XSAiCard.parseList(null), isEmpty);
      expect(XSAiCard.parseList('cards'), isEmpty);
    });
  });

  group('XSAiCard.extract (client-side fallback)', () {
    test('splits prose from a fenced card', () {
      final (prose, cards) = XSAiCard.extract(
        'Lower-zone opacity is denser than baseline.\n\n'
        '```xsight-card\n{"card": "xray_compare", "focus": "left lower zone"}\n```',
      );
      expect(prose, 'Lower-zone opacity is denser than baseline.');
      expect(cards.single.type, XSAiCardType.xrayCompare);
      expect(cards.single.focus, 'left lower zone');
    });

    test('keeps the prose when the card JSON is malformed', () {
      final (prose, cards) = XSAiCard.extract(
        'Here is the summary.\n```xsight-card\n{card: broken,,}\n```',
      );
      expect(prose, 'Here is the summary.');
      expect(cards, isEmpty);
    });

    test('extracts several cards from one reply', () {
      final (_, cards) = XSAiCard.extract(
        'Summary.\n'
        '```xsight-card\n{"card":"vitals_table"}\n```\n'
        '```xsight-card\n{"card":"risk_gauge","score":0.72,"level":"high"}\n```',
      );
      expect(cards.map((c) => c.type),
          [XSAiCardType.vitalsTable, XSAiCardType.riskGauge]);
      expect(cards.last.score, closeTo(0.72, 1e-9));
      expect(cards.last.level, 'high');
    });

    test('recovers a card from a reply truncated at max_tokens', () {
      final (prose, cards) = XSAiCard.extract(
        'Cut off here.\n```xsight-card\n{"card":"vitals_table"}',
      );
      expect(prose, 'Cut off here.');
      expect(cards.single.type, XSAiCardType.vitalsTable);
    });

    test('leaves text with no fence untouched', () {
      const text = 'Just prose. No card.';
      final (prose, cards) = XSAiCard.extract(text);
      expect(prose, text);
      expect(cards, isEmpty);
    });
  });

  group('XSAiCard payload accessors', () {
    test('reads a whole-number score as a percentage', () {
      expect(const XSAiCard(XSAiCardType.riskGauge, {'score': 72}).score,
          closeTo(0.72, 1e-9));
      expect(const XSAiCard(XSAiCardType.riskGauge, {'score': 0.55}).score,
          closeTo(0.55, 1e-9));
      expect(const XSAiCard(XSAiCardType.riskGauge, {'score': 100}).score, 1.0);
    });

    test('refuses to interpret an implausible score', () {
      // 1.4 is neither a 0..1 value nor a percentage. Rescaling it would show
      // 1.4%; clamping it would show 100%. Both are inventions, so the widget
      // is told nothing and falls back to the session-derived score.
      expect(const XSAiCard(XSAiCardType.riskGauge, {'score': 1.4}).score,
          isNull);
      expect(const XSAiCard(XSAiCardType.riskGauge, {'score': 3.2}).score,
          isNull);
      expect(const XSAiCard(XSAiCardType.riskGauge, {'score': -3}).score,
          isNull);
      expect(const XSAiCard(XSAiCardType.riskGauge, {'score': 'high'}).score,
          isNull);
    });

    test('drops differential entries with no condition', () {
      const card = XSAiCard(XSAiCardType.differential, {
        'items': [
          {'condition': 'Pneumonia', 'confidence': 0.85, 'source': 'film'},
          {'confidence': 0.5},
          {'condition': '  ', 'confidence': 0.4},
          'junk',
        ]
      });
      expect(card.items.map((i) => i.condition), ['Pneumonia']);
    });

    test('reads a percentage confidence, and zeroes an unusable one', () {
      const card = XSAiCard(XSAiCardType.differential, {
        'items': [
          {'condition': 'A', 'confidence': 85},
          {'condition': 'B', 'confidence': 3.2},
          {'condition': 'C', 'confidence': -1},
          {'condition': 'D', 'confidence': 0.4},
        ]
      });
      final byName = {for (final i in card.items) i.condition: i.confidence};
      expect(byName['A'], closeTo(0.85, 1e-9),
          reason: '85 must read as 85%, not 85x');
      expect(byName['D'], closeTo(0.4, 1e-9));
      // Unusable values render an empty bar rather than a fabricated one.
      expect(byName['B'], 0.0);
      expect(byName['C'], 0.0);
    });
  });

  group('XSVitalRanges', () {
    test('a missing reading is notMeasured, never a low-side alarm', () {
      expect(XSVitalRanges.hr.statusOf(null), XSVitalStatus.notMeasured);
      expect(XSVitalRanges.spo2.statusOf(null), XSVitalStatus.notMeasured);
      // 0 is what an un-run station leaves behind, and it must not read as
      // "heart rate below 50".
      expect(XSVitalRanges.hr.statusOf(0), XSVitalStatus.notMeasured);
    });

    test('bands match the thresholds the vitals screen alarms on', () {
      expect(XSVitalRanges.hr.statusOf(72), XSVitalStatus.normal);
      expect(XSVitalRanges.hr.statusOf(55), XSVitalStatus.borderline);
      expect(XSVitalRanges.hr.statusOf(48), XSVitalStatus.alarm);
      expect(XSVitalRanges.hr.statusOf(104), XSVitalStatus.alarm);

      expect(XSVitalRanges.spo2.statusOf(98), XSVitalStatus.normal);
      expect(XSVitalRanges.spo2.statusOf(93), XSVitalStatus.borderline);
      expect(XSVitalRanges.spo2.statusOf(89), XSVitalStatus.alarm);

      expect(XSVitalRanges.temp.statusOf(36.8), XSVitalStatus.normal);
      expect(XSVitalRanges.temp.statusOf(37.6), XSVitalStatus.borderline);
      expect(XSVitalRanges.temp.statusOf(38.9), XSVitalStatus.alarm);
    });
  });

  group('XSXrayCompareCard.tryDecodeHeatmap', () {
    test('returns null for the vision-fallback prose in `raw`', () {
      // `/xray` reuses `raw` for base64 PNG (local classifier) and free-form
      // prose (multimodal fallback). Decoding the latter must not throw.
      expect(
        XSXrayCompareCard.tryDecodeHeatmap(
          'Findings: Bilateral patchy opacities.\nSuggested label: pneumonia',
        ),
        isNull,
      );
      expect(XSXrayCompareCard.tryDecodeHeatmap(''), isNull);
      expect(XSXrayCompareCard.tryDecodeHeatmap(null), isNull);
    });

    test('decodes real base64', () {
      // "hello" — enough to prove the happy path still works.
      expect(XSXrayCompareCard.tryDecodeHeatmap('aGVsbG8='), isNotNull);
    });
  });

  group('XSVitalsTableCard', () {
    testWidgets('names unmeasured stations instead of showing 0',
        (tester) async {
      await tester.pumpWidget(_host(const SingleChildScrollView(
        child: XSVitalsTableCard(hr: 92, spo2: 89),
      )));

      expect(find.text('92 bpm'), findsOneWidget);
      expect(find.text('89 %'), findsOneWidget);
      // Temperature and respiratory rate were never taken.
      expect(find.text('not measured'), findsNWidgets(2));
      expect(find.textContaining('0 °C'), findsNothing);
      expect(find.text('2 of 4 measured'), findsOneWidget);
    });

    testWidgets('says so plainly when nothing was measured', (tester) async {
      await tester.pumpWidget(_host(const SingleChildScrollView(
        child: XSVitalsTableCard(),
      )));
      expect(find.textContaining('No vitals captured'), findsOneWidget);
    });

    testWidgets('flags an out-of-range reading', (tester) async {
      await tester.pumpWidget(_host(const SingleChildScrollView(
        child: XSVitalsTableCard(hr: 72, spo2: 89),
      )));
      expect(find.text('OUT OF RANGE'), findsOneWidget, reason: 'SpO2 89%');
      expect(find.text('NORMAL'), findsOneWidget, reason: 'HR 72');
    });
  });

  group('XSXrayCompareCard', () {
    testWidgets('reports the missing film rather than rendering empty panels',
        (tester) async {
      await tester.pumpWidget(_host(const SingleChildScrollView(
        child: XSXrayCompareCard(),
      )));
      expect(find.textContaining('No chest film'), findsOneWidget);
      expect(find.text('NORMAL REFERENCE'), findsNothing);
    });
  });

  group('XSRiskGaugeCard', () {
    testWidgets('will not show a risk level with nothing measured',
        (tester) async {
      await tester.pumpWidget(_host(const SingleChildScrollView(
        child: XSRiskGaugeCard(score: 0.7, level: 'high', measuredStations: 0),
      )));
      expect(find.textContaining('Nothing measured yet'), findsOneWidget);
      expect(find.text('HIGH RISK'), findsNothing,
          reason: 'a score with no readings behind it must not be presented');
    });

    testWidgets('bands a score when the model gave no level', (tester) async {
      await tester.pumpWidget(_host(const SingleChildScrollView(
        child: XSRiskGaugeCard(score: 0.55, measuredStations: 2),
      )));
      expect(find.text('HIGH RISK'), findsOneWidget);
      expect(find.textContaining('2 of 4'), findsWidgets);
    });
  });

  group('XSDifferentialCard', () {
    testWidgets('ranks by confidence and labels itself model-authored',
        (tester) async {
      await tester.pumpWidget(_host(SingleChildScrollView(
        child: XSDifferentialCard(items: [
          XSDifferentialItem(condition: 'Crackles', confidence: 0.72),
          XSDifferentialItem(
              condition: 'Pneumonia', confidence: 0.85, source: 'chest film'),
        ]),
      )));

      final rank1 = tester.getTopLeft(find.text('Pneumonia')).dy;
      final rank2 = tester.getTopLeft(find.text('Crackles')).dy;
      expect(rank1, lessThan(rank2), reason: 'highest confidence first');
      expect(find.text('from chest film'), findsOneWidget);
      expect(find.textContaining('AI-generated reasoning'), findsOneWidget);
    });

    testWidgets('handles an empty list', (tester) async {
      await tester.pumpWidget(_host(const SingleChildScrollView(
        child: XSDifferentialCard(items: []),
      )));
      expect(find.textContaining('no candidate conditions'), findsOneWidget);
    });
  });

  group('KioskPatientSession clinical context', () {
    setUp(() => KioskPatientSession.I.setGuestMode());
    tearDown(() => KioskPatientSession.I.setGuestMode());

    test('a guest reports no demographics rather than the placeholder age', () {
      final ctx = KioskPatientSession.I.clinicalContextPrompt;
      expect(ctx, contains('Demographics: not on file'));
      // The walk-in record carries a placeholder age; it must not surface.
      expect(ctx, isNot(contains('age 32')));
      expect(KioskPatientSession.I.patientAgeYears, isNull);
    });

    test('a linked record contributes age, sex and build', () {
      KioskPatientSession.I.selectPatient({
        'id': 7,
        'name': 'Test Patient',
        'mrn': 'MRN-7',
        'dob': '1990-05-15',
        'sex': 'Male',
        'weight_kg': 68,
        'height_cm': 170,
      });
      final ctx = KioskPatientSession.I.clinicalContextPrompt;
      expect(ctx, contains('Demographics:'));
      expect(ctx, contains('male'));
      expect(ctx, contains('68 kg'));
      expect(ctx, contains('170 cm'));
      expect(KioskPatientSession.I.patientAgeYears, isNotNull);
      expect(KioskPatientSession.I.patientAgeYears, greaterThan(20));
    });

    test('an age field is used directly when there is no dob', () {
      KioskPatientSession.I.selectPatient({
        'id': 8,
        'name': 'Demo',
        'mrn': 'MRN-8',
        'age': 62,
        'gender': 'Female',
      });
      expect(KioskPatientSession.I.patientAgeYears, 62);
      expect(KioskPatientSession.I.patientSex, 'Female');
    });

    test('unmeasured stations stay unmeasured', () {
      final ctx = KioskPatientSession.I.clinicalContextPrompt;
      expect(ctx, contains('Heart Rate: not measured'));
      expect(ctx, contains('Chest Radiograph Heatmap: not available'));
    });
  });

  group('KioskPatientSession.sessionTriage', () {
    setUp(() => KioskPatientSession.I.setGuestMode());
    tearDown(() => KioskPatientSession.I.setGuestMode());

    test('nothing measured is notAssessed, not low risk', () {
      final t = KioskPatientSession.I.sessionTriage;
      expect(t.level, 'notAssessed');
      expect(t.score, 0);
    });

    test('hypoxia with fever escalates above a normal reading', () {
      final session = KioskPatientSession.I;
      session.recordVitals(72, 98);
      final healthy = session.sessionTriage;
      session.recordVitals(72, 89);
      session.recordTemp(38.9);
      final unwell = session.sessionTriage;

      expect(healthy.level, 'low');
      expect(unwell.score, greaterThan(healthy.score));
      expect(unwell.level, anyOf('moderate', 'high'));
    });
  });
}
