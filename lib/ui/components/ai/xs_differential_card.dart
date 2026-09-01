import 'package:flutter/material.dart';

import '../../../core/ai/xs_ai_card.dart';
import '../../../core/theme/xs_colors.dart';
import '../../../core/theme/xs_scale.dart';
import '../../../core/theme/xs_spacing.dart';
import '../xs_confidence_meter.dart';
import 'xs_ai_card_frame.dart';

/// Ranked candidate conditions with confidence bars.
///
/// The one card whose content is model-authored rather than sensor-derived, so
/// its frame carries the reasoning disclaimer and each row names the evidence
/// the model says it came from. Confidences are clamped to 0..1 by
/// [XSDifferentialItem], so a model emitting `85` for 85% cannot draw a bar 85
/// times too long.
class XSDifferentialCard extends StatelessWidget {
  final List<XSDifferentialItem> items;

  /// Cap on rendered rows — a long list stops being a differential and starts
  /// being a textbook index.
  static const _maxRows = 5;

  const XSDifferentialCard({super.key, required this.items});

  static Color _confidenceColor(double c) {
    if (c >= 0.7) return XSColors.accentRed;
    if (c >= 0.4) return XSColors.accentOrange;
    return XSColors.sage;
  }

  @override
  Widget build(BuildContext context) {
    // Highest confidence first — the model's ordering is not reliable.
    final ranked = [...items]
      ..sort((a, b) => b.confidence.compareTo(a.confidence));
    final shown = ranked.take(_maxRows).toList();

    return XSAiCardFrame(
      label: 'DIFFERENTIAL',
      sublabel: shown.length < ranked.length
          ? 'top ${shown.length} of ${ranked.length}'
          : null,
      icon: Icons.account_tree_outlined,
      accent: XSColors.moduleAssistant,
      modelAuthored: true,
      child: shown.isEmpty
          ? const XSAiCardUnavailable(
              message: 'The assistant proposed no candidate conditions.',
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < shown.length; i++)
                  _row(context, i + 1, shown[i]),
              ],
            ),
    );
  }

  Widget _row(BuildContext context, int rank, XSDifferentialItem item) {
    final palette = XSPalette.of(context);
    final s = XSScale.factor;
    final color = _confidenceColor(item.confidence);

    return Padding(
      padding: EdgeInsets.symmetric(vertical: 5 * s),
      child: Row(
        children: [
          SizedBox(
            width: 20 * s,
            child: Text(
              '$rank',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w800,
                color: palette.textSecondary,
              ),
            ),
          ),
          Expanded(
            flex: 4,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.condition,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: palette.textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (item.source.isNotEmpty)
                  Text(
                    'from ${item.source}',
                    style: TextStyle(
                      fontSize: 13,
                      color: palette.textSecondary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          SizedBox(width: XSSpacing.sm * s),
          Expanded(
            flex: 3,
            child: XSConfidenceMeter(value: item.confidence, color: color),
          ),
        ],
      ),
    );
  }
}
