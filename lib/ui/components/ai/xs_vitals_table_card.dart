import 'package:flutter/material.dart';

import '../../../core/ai/xs_ai_card.dart';
import '../../../core/theme/xs_colors.dart';
import '../../../core/theme/xs_scale.dart';
import 'xs_ai_card_frame.dart';

/// This session's vitals against reference ranges.
///
/// Every value comes from the kiosk's own sensors — the model only asks for the
/// card, never supplies the numbers. An unmeasured station renders as
/// "not measured", so the table cannot imply a reading that never happened
/// (and cannot repeat the vitals screen's habit of treating a missing reading
/// as a 0 that trips the low-HR alarm).
class XSVitalsTableCard extends StatelessWidget {
  final double? hr;
  final double? spo2;
  final double? temp;
  final double? rr;

  const XSVitalsTableCard({
    super.key,
    this.hr,
    this.spo2,
    this.temp,
    this.rr,
  });

  static Color _statusColor(XSVitalStatus s) => switch (s) {
        XSVitalStatus.alarm => XSColors.accentRed,
        XSVitalStatus.borderline => XSColors.accentOrange,
        XSVitalStatus.normal => XSColors.accentGreen,
        XSVitalStatus.notMeasured => XSColors.slate,
      };

  static String _statusText(XSVitalStatus s) => switch (s) {
        XSVitalStatus.alarm => 'OUT OF RANGE',
        XSVitalStatus.borderline => 'BORDERLINE',
        XSVitalStatus.normal => 'NORMAL',
        XSVitalStatus.notMeasured => '—',
      };

  static IconData _statusIcon(XSVitalStatus s) => switch (s) {
        XSVitalStatus.alarm => Icons.warning_amber_rounded,
        XSVitalStatus.borderline => Icons.error_outline,
        XSVitalStatus.normal => Icons.check_rounded,
        XSVitalStatus.notMeasured => Icons.remove,
      };

  @override
  Widget build(BuildContext context) {
    final rows = <({XSVitalRange range, double? value})>[
      (range: XSVitalRanges.hr, value: hr),
      (range: XSVitalRanges.spo2, value: spo2),
      (range: XSVitalRanges.temp, value: temp),
      (range: XSVitalRanges.rr, value: rr),
    ];
    final measured = rows
        .where((r) => r.range.statusOf(r.value) != XSVitalStatus.notMeasured)
        .length;

    return XSAiCardFrame(
      label: 'VITALS vs REFERENCE',
      sublabel: '$measured of ${rows.length} measured',
      icon: Icons.monitor_heart_outlined,
      accent: XSColors.moduleVitals,
      child: measured == 0
          ? const XSAiCardUnavailable(
              message: 'No vitals captured in this session yet — run the pulse '
                  'and temperature stations first.',
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final r in rows) _row(context, r.range, r.value),
              ],
            ),
    );
  }

  Widget _row(BuildContext context, XSVitalRange range, double? value) {
    final palette = XSPalette.of(context);
    final s = XSScale.factor;
    final status = range.statusOf(value);
    final color = _statusColor(status);
    final missing = status == XSVitalStatus.notMeasured;

    return Padding(
      padding: EdgeInsets.symmetric(vertical: 5 * s),
      child: Row(
        children: [
          SizedBox(
            width: 132 * s,
            child: Text(
              range.label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: palette.textPrimary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(
            width: 96 * s,
            child: Text(
              missing ? 'not measured' : '${range.format(value!)} ${range.unit}',
              style: TextStyle(
                fontSize: missing ? 13 : 16,
                fontWeight: missing ? FontWeight.w500 : FontWeight.w800,
                fontStyle: missing ? FontStyle.italic : FontStyle.normal,
                color: missing ? palette.textSecondary : color,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(
            child: Text(
              range.referenceText,
              style: TextStyle(fontSize: 13, color: palette.textSecondary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Icon(_statusIcon(status), size: 15 * s, color: color),
          SizedBox(width: 5 * s),
          SizedBox(
            width: 108 * s,
            child: Text(
              _statusText(status),
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
                color: color,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
