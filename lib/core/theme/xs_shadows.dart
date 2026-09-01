import 'package:flutter/material.dart';
import 'xs_colors.dart';

/// Neumorphic shadow recipes for convex/concave surfaces.
class XSShadows {
  XSShadows._();

  /// Convex (raised) shadow stack.
  static List<BoxShadow> convex(XSPalette p, {double intensity = 1.0}) {
    final blur = 16.0 * intensity;
    final offset = 6.0 * intensity;
    return [
      BoxShadow(
        color: p.highlight,
        offset: Offset(-offset, -offset),
        blurRadius: blur,
      ),
      BoxShadow(
        color: p.shadow.withValues(alpha: 0.55),
        offset: Offset(offset, offset),
        blurRadius: blur,
      ),
    ];
  }

  /// Soft convex (smaller depth) for tiles inside cards.
  static List<BoxShadow> soft(XSPalette p) => convex(p, intensity: 0.6);

  /// Pressed look — flat shadows.
  static List<BoxShadow> pressed(XSPalette p) => [
        BoxShadow(
          color: p.shadow.withValues(alpha: 0.25),
          offset: const Offset(2, 2),
          blurRadius: 4,
        ),
      ];

  /// Colored halo used to make the active module / live reading glow.
  /// Sits *under* a neumorphic stack: `[...glow(c), ...convex(p)]`.
  static List<BoxShadow> glow(Color color, {double intensity = 1.0}) => [
        BoxShadow(
          color: color.withValues(alpha: 0.30 * intensity),
          blurRadius: 28 * intensity,
          spreadRadius: 2 * intensity,
        ),
      ];

  /// Lifted surface — for the one element that should read as "on top",
  /// e.g. the focused module card in the navigator.
  static List<BoxShadow> raised(XSPalette p) => [
        BoxShadow(
          color: p.highlight,
          offset: const Offset(-10, -10),
          blurRadius: 26,
        ),
        BoxShadow(
          color: p.shadow.withValues(alpha: 0.60),
          offset: const Offset(10, 14),
          blurRadius: 30,
        ),
      ];
}
