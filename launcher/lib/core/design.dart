import 'package:flutter/material.dart';

/// XSIGHT design tokens (subset) — copied from the kiosk's
/// `lib/core/theme/xs_colors.dart` so the launcher is a standalone package
/// with no path dependencies on the app. Keep these in sync with the app
/// tokens when the brand changes.
class XS {
  XS._();

  // Brand
  static const tealDark = Color(0xFF0F3D3E);
  static const teal = Color(0xFF1B6B6F);
  static const sage = Color(0xFF6C9A8B);
  static const mint = Color(0xFFDCEDEA);
  static const slate = Color(0xFF2F3E46);

  // Dark theme (the launcher always runs dark — it is a back-of-house tool)
  static const surface = slate;
  static const surfaceRaised = Color(0xFF3A4B54);
  static const highlight = teal;
  static const shadow = tealDark;
  static const textPrimary = mint;
  static const textSecondary = sage;
  static const divider = Color(0xFF25333B);

  // Status
  static const ok = Color(0xFF4CAF50);
  static const warn = Color(0xFFE65100);
  static const bad = Color(0xFFC62828);

  // Spacing scale
  static const double xxs = 4;
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 20;
  static const double xl = 24;
  static const double xxl = 32;
}
