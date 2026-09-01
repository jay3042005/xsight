import 'package:flutter/material.dart';
import '../../core/theme/xs_colors.dart';
import '../../core/theme/xs_radius.dart';
import '../../core/theme/xs_spacing.dart';

enum XSRiskLevel { low, moderate, high }

/// Horizontal risk indicator with concave track and filled segment.
class XSRiskMeter extends StatelessWidget {
  final XSRiskLevel level;
  final double height;

  const XSRiskMeter({
    super.key,
    required this.level,
    this.height = 18,
  });

  double _progress() {
    switch (level) {
      case XSRiskLevel.low:
        return 0.33;
      case XSRiskLevel.moderate:
        return 0.66;
      case XSRiskLevel.high:
        return 1.0;
    }
  }

  String _label() {
    switch (level) {
      case XSRiskLevel.low:
        return 'LOW RISK';
      case XSRiskLevel.moderate:
        return 'MODERATE RISK';
      case XSRiskLevel.high:
        return 'HIGH RISK';
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    final progress = _progress();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(_label(),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: palette.textSecondary,
                )),
        const SizedBox(height: XSSpacing.xs),
        LayoutBuilder(
          builder: (context, c) {
            final width = c.maxWidth;
            return Stack(
              children: [
                Container(
                  width: width,
                  height: height,
                  decoration: BoxDecoration(
                    color: palette.surface,
                    borderRadius: BorderRadius.circular(XSRadius.pill),
                    border: Border.all(color: palette.divider, width: 0.6),
                    gradient: LinearGradient(
                      colors: [
                        palette.shadow.withValues(alpha: 0.18),
                        palette.highlight.withValues(alpha: 0.5),
                      ],
                    ),
                  ),
                ),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 600),
                  curve: Curves.easeOutCubic,
                  width: width * progress,
                  height: height,
                  decoration: BoxDecoration(
                    color: palette.textPrimary,
                    borderRadius: BorderRadius.circular(XSRadius.pill),
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}
