import 'dart:io';

import 'package:flutter/material.dart';

import '../../../core/ai/xs_ai_card.dart';
import '../../../state/kiosk_patient_state.dart';
import 'xs_differential_card.dart';
import 'xs_risk_gauge_card.dart';
import 'xs_vitals_table_card.dart';
import 'xs_xray_compare_card.dart';

/// Renders the AI's visual-answer cards.
///
/// This is where the core safety property of the feature is enforced: the model
/// names a card, and *this widget* supplies the values, always from
/// [KioskPatientSession]. Nothing a model writes can put a heart rate or an
/// image on screen. The single exception is [XSAiCardType.differential], whose
/// conditions are the model's reasoning and are labelled as such by
/// [XSDifferentialCard].
///
/// Cards are deduplicated by type, so a model that asks for the same view twice
/// in one reply renders it once.
class XSAiCanvas extends StatelessWidget {
  final List<XSAiCard> cards;

  /// Cap on rendered cards. The prompt asks for at most two; this enforces it
  /// regardless of what arrives.
  static const _maxCards = 3;

  const XSAiCanvas({super.key, required this.cards});

  @override
  Widget build(BuildContext context) {
    if (cards.isEmpty) return const SizedBox.shrink();

    final seen = <XSAiCardType>{};
    final unique = <XSAiCard>[];
    for (final c in cards) {
      if (seen.add(c.type)) unique.add(c);
      if (unique.length >= _maxCards) break;
    }

    return ListenableBuilder(
      listenable: KioskPatientSession.I,
      builder: (context, _) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [for (final c in unique) _build(c)],
      ),
    );
  }

  Widget _build(XSAiCard card) {
    final session = KioskPatientSession.I;

    switch (card.type) {
      case XSAiCardType.xrayCompare:
        final path = session.guestXrayImagePath;
        // A path recorded in a previous session can outlive its temp file, so
        // check the file is actually there rather than handing Image.file a
        // path that will throw during paint.
        final file = (path != null && path.isNotEmpty) ? File(path) : null;
        return XSXrayCompareCard(
          patientImage: (file != null && file.existsSync()) ? file : null,
          heatmap: XSXrayCompareCard.tryDecodeHeatmap(
            session.guestXrayHeatmapB64,
          ),
          finding: session.guestXrayFinding,
          focus: card.focus,
        );

      case XSAiCardType.vitalsTable:
        return XSVitalsTableCard(
          hr: session.guestHr,
          spo2: session.guestSpo2,
          temp: session.guestTemp,
          // `recordVitals` only captures HR and SpO2, so no respiratory rate
          // ever reaches session state even though the sensor frame has a field
          // for it. Reported as unmeasured rather than shown as 0.
          rr: null,
        );

      case XSAiCardType.riskGauge:
        final triage = session.sessionTriage;
        return XSRiskGaugeCard(
          // The locally computed score wins over a model-supplied one: it is
          // derived from the actual readings, and the two disagreeing on screen
          // would be worse than ignoring the model's guess.
          score: triage.level == 'notAssessed' ? null : triage.score,
          level: triage.level == 'notAssessed' ? null : triage.level,
          measuredStations: session.measuredStationCount,
        );

      case XSAiCardType.differential:
        return XSDifferentialCard(items: card.items);
    }
  }
}
