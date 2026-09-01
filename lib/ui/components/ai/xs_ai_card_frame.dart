import 'package:flutter/material.dart';

import '../../../core/theme/xs_colors.dart';
import '../../../core/theme/xs_radius.dart';
import '../../../core/theme/xs_scale.dart';
import '../../../core/theme/xs_shadows.dart';
import '../../../core/theme/xs_spacing.dart';

/// Shared chrome for every AI visual-answer card.
///
/// One frame for all card types so a canvas of three cards reads as one answer
/// rather than three unrelated panels, and so the "AI-generated" footer cannot
/// be forgotten on a new card: it lives here, not in each card body.
class XSAiCardFrame extends StatelessWidget {
  /// Eyebrow label, e.g. `'X-RAY COMPARISON'`.
  final String label;

  /// Small line beside the label — what the model asked to show.
  final String? sublabel;

  final IconData icon;
  final Color accent;
  final Widget child;

  /// Fixed body height. Image cards need one because they sit inside a
  /// scrolling chat list, which gives its children unbounded height.
  final double? bodyHeight;

  /// Set on cards whose content is the model's own reasoning rather than
  /// sensor data, so the footer can say which it is.
  final bool modelAuthored;

  const XSAiCardFrame({
    super.key,
    required this.label,
    required this.icon,
    required this.accent,
    required this.child,
    this.sublabel,
    this.bodyHeight,
    this.modelAuthored = false,
  });

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    final s = XSScale.factor;

    return Container(
      margin: EdgeInsets.only(top: XSSpacing.sm * s),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(XSRadius.lg),
        border: Border.all(color: accent.withValues(alpha: 0.35)),
        boxShadow: XSShadows.soft(palette),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: EdgeInsets.symmetric(
              horizontal: XSSpacing.md * s,
              vertical: XSSpacing.sm * s,
            ),
            decoration: BoxDecoration(
              color: palette.highlight,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(XSRadius.lg)),
            ),
            child: Row(
              children: [
                Icon(icon, size: 16 * s, color: accent),
                SizedBox(width: 8 * s),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.8,
                    color: palette.textSecondary,
                  ),
                ),
                if (sublabel != null) ...[
                  SizedBox(width: 8 * s),
                  Expanded(
                    child: Text(
                      sublabel!,
                      style: TextStyle(
                        fontSize: 13,
                        color: palette.textSecondary,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ],
            ),
          ),
          Padding(
            padding: EdgeInsets.all(XSSpacing.sm * s),
            child: bodyHeight == null
                ? child
                : SizedBox(height: bodyHeight! * s, child: child),
          ),
          // Non-negotiable on every card: the whole point of rendering AI
          // output as a clinical-looking panel is that it looks authoritative.
          Padding(
            padding: EdgeInsets.only(
              left: XSSpacing.md * s,
              right: XSSpacing.md * s,
              bottom: XSSpacing.sm * s,
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline,
                    size: 13 * s, color: palette.textSecondary),
                SizedBox(width: 5 * s),
                Expanded(
                  child: Text(
                    modelAuthored
                        ? 'AI-generated reasoning — screening support only, '
                            'requires clinician confirmation'
                        : 'Kiosk-captured data, AI-selected view — requires '
                            'clinician confirmation',
                    style: TextStyle(
                      fontSize: 13,
                      color: palette.textSecondary,
                    ),
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

/// One panel of a side-by-side image comparison.
///
/// Extracted from `kiosk_xray_screen.dart`'s `_comparisonPanel` so the screen
/// and the AI card render the identical treatment.
class XSComparePanel extends StatelessWidget {
  final String label;
  final String sublabel;
  final Color borderColor;
  final Widget child;

  const XSComparePanel({
    super.key,
    required this.label,
    required this.sublabel,
    required this.borderColor,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    return Column(
      children: [
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(XSRadius.sm),
              border: Border.all(
                color: borderColor.withValues(alpha: 0.5),
                width: 1.5,
              ),
            ),
            child: child,
          ),
        ),
        const SizedBox(height: XSSpacing.xs),
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: borderColor,
            letterSpacing: 0.6,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        Text(
          sublabel,
          style: TextStyle(fontSize: 13, color: palette.textSecondary),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

/// Shown in place of a card whose station has no data.
///
/// A card the model asked for but cannot be filled must say so plainly. The
/// alternative — rendering an empty table or a zeroed gauge — reads as a
/// measured normal result.
class XSAiCardUnavailable extends StatelessWidget {
  final String message;

  const XSAiCardUnavailable({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    final s = XSScale.factor;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: XSSpacing.md * s),
      child: Row(
        children: [
          Icon(Icons.remove_circle_outline,
              size: 18 * s, color: XSColors.accentOrange),
          SizedBox(width: 8 * s),
          Expanded(
            child: Text(
              message,
              style: TextStyle(fontSize: 14, color: palette.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}
