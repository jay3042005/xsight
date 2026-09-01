import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import '../../core/theme/xs_colors.dart';
import '../../core/theme/xs_radius.dart';
import '../../core/theme/xs_scale.dart';
import '../../core/theme/xs_shadows.dart';
import '../../core/theme/xs_spacing.dart';

/// Convex neumorphic card surface.
///
/// Three optional treatments, all off by default so existing usages are
/// unchanged:
///   * [glow] — colored halo, for the active/live card.
///   * [glass] — frosted translucency, for panels floating over imagery.
///   * [borderColor] — hairline accent edge.
class XSCard extends StatelessWidget {
  final Widget child;

  /// Inner padding. Defaults to `XSSpacing.lg` scaled for the panel.
  ///
  /// Only the *default* is scaled. A value passed in is used verbatim, because
  /// nearly every call site already writes `XSSpacing.md * s` and multiplying
  /// again would double it.
  final EdgeInsetsGeometry? padding;

  /// Corner radius. Defaults to `XSRadius.lg` scaled for the panel, so a card on
  /// a 1280px kiosk panel does not carry the same 20px corner as one on a phone
  /// while everything inside it renders 25% larger.
  final double? radius;

  final double? width;
  final double? height;
  final bool soft;
  final VoidCallback? onTap;

  /// Colored halo beneath the card. Use the owning module's accent.
  final Color? glow;

  /// Frost the backdrop instead of painting an opaque surface.
  final bool glass;

  /// Hairline edge. Pairs well with [glow].
  final Color? borderColor;

  const XSCard({
    super.key,
    required this.child,
    this.padding,
    this.radius,
    this.width,
    this.height,
    this.soft = false,
    this.onTap,
    this.glow,
    this.glass = false,
    this.borderColor,
  });

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    final s = XSScale.factor;
    final pad = padding ?? EdgeInsets.all(XSSpacing.lg * s);
    final r = radius ?? XSRadius.lg * s;
    final shadows = [
      if (glow != null) ...XSShadows.glow(glow!),
      ...(soft ? XSShadows.soft(palette) : XSShadows.convex(palette)),
    ];

    Widget container = Container(
      width: width,
      height: height,
      padding: pad,
      decoration: BoxDecoration(
        // Glass relies on the blurred backdrop showing through, so the fill
        // is only a tint.
        color: glass
            ? palette.surface.withValues(alpha: 0.55)
            : palette.surface,
        borderRadius: BorderRadius.circular(r),
        border: borderColor == null
            ? null
            : Border.all(color: borderColor!, width: 1.5 * s),
        boxShadow: shadows,
      ),
      child: child,
    );

    if (glass) {
      container = ClipRRect(
        borderRadius: BorderRadius.circular(r),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18 * s, sigmaY: 18 * s),
          child: container,
        ),
      );
    }

    if (onTap == null) return container;
    // Use Material + InkWell so tappable cards get ripple feedback, focus,
    // hover, and keyboard/semantics support.
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(r),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(r),
        child: container,
      ),
    );
  }
}
