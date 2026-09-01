import 'package:flutter/material.dart';
import '../../core/theme/xs_colors.dart';
import '../../core/theme/xs_radius.dart';
import '../../core/theme/xs_shadows.dart';
import '../../core/theme/xs_spacing.dart';

/// Concave (inset) text input field.
class XSInputField extends StatelessWidget {
  final TextEditingController? controller;
  final String? hintText;
  final IconData? prefixIcon;
  final Widget? suffix;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final FocusNode? focusNode;
  final TextInputAction textInputAction;
  final int? maxLines;

  const XSInputField({
    super.key,
    this.controller,
    this.hintText,
    this.prefixIcon,
    this.suffix,
    this.onSubmitted,
    this.onChanged,
    this.focusNode,
    this.textInputAction = TextInputAction.send,
    this.maxLines = 1,
  });

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: XSSpacing.md,
        vertical: XSSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(XSRadius.md),
        // Concave look: subtle inner shadow approximation via gradient + border.
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            palette.shadow.withValues(alpha: 0.18),
            palette.surface,
            palette.highlight.withValues(alpha: 0.6),
          ],
          stops: const [0.0, 0.5, 1.0],
        ),
        border: Border.all(color: palette.divider, width: 0.6),
      ),
      child: Row(
        children: [
          if (prefixIcon != null) ...[
            Icon(prefixIcon, color: palette.textSecondary, size: 18),
            const SizedBox(width: XSSpacing.sm),
          ],
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              onChanged: onChanged,
              onSubmitted: onSubmitted,
              textInputAction: textInputAction,
              maxLines: maxLines,
              cursorColor: palette.textPrimary,
              style: TextStyle(
                color: palette.textPrimary,
                fontSize: 15,
              ),
              decoration: InputDecoration(
                isDense: true,
                hintText: hintText,
                hintStyle: TextStyle(color: palette.textSecondary),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
          if (suffix != null) ...[
            const SizedBox(width: XSSpacing.sm),
            suffix!,
          ],
        ],
      ),
    );
  }

  // ignore: unused_element
  static List<BoxShadow> _concave(XSPalette p) => XSShadows.pressed(p);
}
