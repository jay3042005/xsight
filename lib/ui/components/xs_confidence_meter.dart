import 'package:flutter/material.dart';
import '../../core/theme/xs_colors.dart';
import '../../core/theme/xs_radius.dart';

/// Animates a confidence bar from 0 -> [value] (0..1) whenever [value]
/// changes, with a numeric readout that counts up in sync.
class XSConfidenceMeter extends StatelessWidget {
  final double value; // 0..1
  final Color color;
  final double height;

  const XSConfidenceMeter({
    super.key,
    required this.value,
    required this.color,
    this.height = 10,
  });

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    final target = value.clamp(0.0, 1.0);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: target),
      duration: const Duration(milliseconds: 900),
      curve: Curves.easeOutCubic,
      builder: (context, animated, _) {
        return Row(
          children: [
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final width = constraints.maxWidth;
                  return Stack(
                    children: [
                      Container(
                        width: width,
                        height: height,
                        decoration: BoxDecoration(
                          color: palette.divider.withValues(alpha: 0.4),
                          borderRadius: BorderRadius.circular(XSRadius.pill),
                        ),
                      ),
                      Container(
                        width: width * animated,
                        height: height,
                        decoration: BoxDecoration(
                          color: color,
                          borderRadius: BorderRadius.circular(XSRadius.pill),
                          boxShadow: [
                            BoxShadow(
                              color: color.withValues(alpha: 0.4),
                              blurRadius: 6,
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 42,
              child: Text(
                '${(animated * 100).round()}%',
                textAlign: TextAlign.right,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: palette.textPrimary,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
