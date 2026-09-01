import 'package:flutter/material.dart';
import '../../core/theme/xs_colors.dart';
import '../../core/theme/xs_radius.dart';
import '../../core/theme/xs_scale.dart';
import '../../core/theme/xs_shadows.dart';
import '../../core/theme/xs_spacing.dart';

/// Neumorphic primary button. Inverted = filled (black on light, white on dark).
class XSButton extends StatefulWidget {
  final String? label;
  final VoidCallback? onPressed;
  final bool inverted;
  final IconData? icon;
  final double height;
  final double? width;
  final String? tooltip;

  /// Fill color override. Implies a filled button with a matching halo — use
  /// the owning module's accent for the primary action on a screen.
  final Color? color;

  const XSButton({
    super.key,
    this.label,
    this.onPressed,
    this.inverted = false,
    this.icon,
    this.height = 56,
    this.width,
    this.tooltip,
    this.color,
  });

  @override
  State<XSButton> createState() => _XSButtonState();
}

class _XSButtonState extends State<XSButton> {
  bool _pressed = false;

  void _setPressed(bool v) {
    if (widget.onPressed == null) return;
    setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    final disabled = widget.onPressed == null;

    final filled = widget.color != null || widget.inverted;
    final bgColor =
        widget.color ?? (widget.inverted ? palette.textPrimary : palette.surface);
    final fgColor = filled
        ? (widget.color != null ? Colors.white : palette.surface)
        : palette.textPrimary;

    // Scale up on larger kiosk surfaces where fixed tablet sizes render small.
    // Font size is left unscaled: MediaQuery's textScaler already applies
    // XSScale.factor app-wide, so multiplying here would double-count it.
    final height = widget.height * XSScale.factor;
    final width = widget.width == null ? null : widget.width! * XSScale.factor;
    final iconSize = 20 * XSScale.factor;
    const fontSize = 15.0;

    final btn = GestureDetector(
      onTapDown: (_) => _setPressed(true),
      onTapCancel: () => _setPressed(false),
      onTapUp: (_) => _setPressed(false),
      onTap: widget.onPressed,
      child: AnimatedScale(
        // Ripple is disabled app-wide (xs_theme), so the press must be felt
        // geometrically or the button reads as dead.
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          width: widget.label == null && width == null ? height : width,
          height: height,
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(XSRadius.pill),
            boxShadow: _pressed
                ? XSShadows.pressed(palette)
                : [
                    if (widget.color != null && !disabled)
                      ...XSShadows.glow(widget.color!, intensity: 0.6),
                    ...XSShadows.convex(palette,
                        intensity: filled ? 0.8 : 1.0),
                  ],
          ),
          alignment: Alignment.center,
          child: Opacity(
            opacity: disabled ? 0.5 : 1,
            child: widget.label != null
                ? Padding(
                    // Keep content off the pill's rounded ends, and let the
                    // label shrink rather than overflow when a fixed [width]
                    // is too small for the text at large scale factors.
                    padding: EdgeInsets.symmetric(
                        horizontal: XSSpacing.md * XSScale.factor),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (widget.icon != null) ...[
                          Icon(widget.icon, color: fgColor, size: iconSize),
                          SizedBox(width: XSSpacing.sm * XSScale.factor),
                        ],
                        Flexible(
                          child: Text(
                            widget.label!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: fgColor,
                              fontSize: fontSize,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.2,
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                : Icon(widget.icon ?? Icons.touch_app,
                    color: fgColor, size: iconSize),
          ),
        ),
      ),
    );

    if (widget.tooltip != null) {
      return Tooltip(message: widget.tooltip!, child: btn);
    }
    return btn;
  }
}
