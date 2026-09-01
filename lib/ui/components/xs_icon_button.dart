import 'package:flutter/material.dart';
import '../../core/theme/xs_colors.dart';
import '../../core/theme/xs_scale.dart';
import '../../core/theme/xs_shadows.dart';

/// Circular neumorphic icon button.
class XSIconButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback? onPressed;
  final double size;
  final bool inverted;
  final String? semanticLabel;

  const XSIconButton({
    super.key,
    required this.icon,
    this.onPressed,
    this.size = 56,
    this.inverted = false,
    this.semanticLabel,
  });

  @override
  State<XSIconButton> createState() => _XSIconButtonState();
}

class _XSIconButtonState extends State<XSIconButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    final bg = widget.inverted ? palette.textPrimary : palette.surface;
    final fg = widget.inverted ? palette.surface : palette.textPrimary;

    return Semantics(
      label: widget.semanticLabel,
      button: true,
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapCancel: () => setState(() => _pressed = false),
        onTapUp: (_) => setState(() => _pressed = false),
        onTap: widget.onPressed,
        child: AnimatedScale(
          // Ripple is disabled app-wide, so press must be felt geometrically.
          scale: _pressed ? 0.94 : 1.0,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            width: widget.size * XSScale.factor,
            height: widget.size * XSScale.factor,
            decoration: BoxDecoration(
              color: bg,
              shape: BoxShape.circle,
              boxShadow: _pressed
                  ? XSShadows.pressed(palette)
                  : XSShadows.convex(palette, intensity: 0.8),
            ),
            alignment: Alignment.center,
            child: Icon(widget.icon,
                color: fg, size: widget.size * XSScale.factor * 0.42),
          ),
        ),
      ),
    );
  }
}
