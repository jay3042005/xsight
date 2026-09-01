import 'package:flutter/material.dart';
import '../../core/theme/xs_colors.dart';
import '../../core/theme/xs_radius.dart';
import '../../core/theme/xs_scale.dart';

/// Small labelled pill — status badges, tags, quick replies.
///
/// This replaces the ~20 hand-rolled badge `Container`s per kiosk screen, each
/// of which had picked its own padding, radius, and (usually sub-13px) size.
/// Text is never smaller than 13 logical px here; kiosk scale is applied on
/// top.
class XSChip extends StatelessWidget {
  final String label;

  /// Tint. Defaults to the ambient (or module) accent.
  final Color? color;

  final IconData? icon;

  /// Solid fill + white text, for the loudest state on a screen.
  final bool filled;

  /// Tap handler. Omit for a pure status badge.
  final VoidCallback? onTap;

  const XSChip({
    super.key,
    required this.label,
    this.color,
    this.icon,
    this.filled = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    final c = color ?? palette.accent;
    final fg = filled ? Colors.white : c;
    final s = XSScale.factor;

    final chip = Container(
      padding: EdgeInsets.symmetric(horizontal: 12 * s, vertical: 7 * s),
      decoration: BoxDecoration(
        color: filled ? c : c.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(XSRadius.pill),
        border: filled ? null : Border.all(color: c.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 15 * s, color: fg),
            SizedBox(width: 6 * s),
          ],
          // Flexible + ellipsis: a chip is a badge, not a paragraph, and it
          // must degrade rather than overflow inside a tight Row or Wrap.
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: fg,
                letterSpacing: 0.3,
              ),
            ),
          ),
        ],
      ),
    );

    if (onTap == null) return chip;
    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(onTap: onTap, child: chip),
    );
  }
}
