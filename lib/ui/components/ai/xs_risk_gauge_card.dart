import 'package:flutter/material.dart';

import '../../../core/theme/xs_colors.dart';
import '../../../core/theme/xs_scale.dart';
import '../../../core/theme/xs_spacing.dart';
import '../xs_dial_gauge.dart';
import 'xs_ai_card_frame.dart';

/// Overall risk dial, matching the CDSS screen's hero treatment so the two
/// never present the same session at different weights.
///
/// [score] and [level] may come from the model, but the caller should pass the
/// session-derived triage when it has one: the local computation is the honest
/// number, and the model has been known to round.
class XSRiskGaugeCard extends StatelessWidget {
  /// 0..1. Null means nothing has been measured yet.
  final double? score;

  /// `low` / `moderate` / `high` / `critical`, or null to derive from [score].
  final String? level;

  /// How many of the four stations have data behind this score.
  final int measuredStations;
  final int totalStations;

  const XSRiskGaugeCard({
    super.key,
    this.score,
    this.level,
    this.measuredStations = 0,
    this.totalStations = 4,
  });

  static const _levels = <String, ({String label, Color color})>{
    'low': (label: 'LOW', color: XSColors.accentGreen),
    'moderate': (label: 'MODERATE', color: XSColors.accentOrange),
    'high': (label: 'HIGH', color: XSColors.accentRed),
    'critical': (label: 'CRITICAL', color: XSColors.accentRed),
  };

  /// Level from an explicit value, else banded from [score]. Bands match
  /// `server/app/cdss.py`'s thresholds.
  ({String label, Color color}) get _resolved {
    final named = _levels[level?.trim().toLowerCase()];
    if (named != null) return named;
    final s = score;
    if (s == null) return (label: 'NOT ASSESSED', color: XSColors.sage);
    if (s >= 0.75) return _levels['critical']!;
    if (s >= 0.5) return _levels['high']!;
    if (s >= 0.25) return _levels['moderate']!;
    return _levels['low']!;
  }

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    final s = XSScale.factor;
    final resolved = _resolved;
    final assessed = measuredStations > 0 && score != null;

    return XSAiCardFrame(
      label: 'OVERALL RISK',
      sublabel: '$measuredStations of $totalStations stations',
      icon: Icons.speed_outlined,
      accent: resolved.color,
      child: !assessed
          ? const XSAiCardUnavailable(
              message: 'Nothing measured yet — a risk level needs at least one '
                  'completed station.',
            )
          : Row(
              children: [
                XSDialGauge(
                  value: score!,
                  min: 0,
                  max: 1,
                  label: score!.toStringAsFixed(2),
                  status: resolved.label,
                  color: resolved.color,
                  size: 132,
                ),
                SizedBox(width: XSSpacing.md * s),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        '${resolved.label} RISK',
                        style: TextStyle(
                          fontSize: 21,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.2,
                          color: resolved.color,
                        ),
                      ),
                      SizedBox(height: 4 * s),
                      Text(
                        measuredStations < totalStations
                            ? 'Based on $measuredStations of $totalStations '
                                'stations — completing the rest may change this.'
                            : 'Based on all $totalStations stations.',
                        style: TextStyle(
                          fontSize: 14,
                          color: palette.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}
