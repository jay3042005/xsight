import 'package:flutter/material.dart';
import '../../core/theme/xs_colors.dart';
import '../../core/theme/xs_radius.dart';
import '../../core/theme/xs_spacing.dart';
import '../../core/theme/xs_typography.dart';
import 'xs_card.dart';

/// Vital sign / numeric statistic tile.
class XSStat extends StatelessWidget {
  final String label;
  final String value;
  final String unit;
  final IconData? icon;
  final bool compact;

  const XSStat({
    super.key,
    required this.label,
    required this.value,
    required this.unit,
    this.icon,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    return XSCard(
      padding: EdgeInsets.all(compact ? XSSpacing.sm : XSSpacing.md),
      radius: XSRadius.md,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 14, color: palette.textSecondary),
                const SizedBox(width: XSSpacing.xs),
              ],
              Expanded(
                child: Text(
                  label.toUpperCase(),
                  style: Theme.of(context).textTheme.labelSmall,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
            ],
          ),
          const SizedBox(height: XSSpacing.xs),
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                value,
                style: XSTypography.stat(palette.textPrimary),
                maxLines: 1,
              ),
            ),
          ),
          const SizedBox(height: XSSpacing.xxs),
          Text(
            unit,
            style: Theme.of(context).textTheme.labelMedium,
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          ),
        ],
      ),
    );
  }
}
