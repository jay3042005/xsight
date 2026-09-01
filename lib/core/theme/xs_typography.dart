import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class XSTypography {
  XSTypography._();

  static TextTheme textTheme(Color primary, Color secondary) {
    final base = GoogleFonts.interTextTheme();
    return base.copyWith(
      displayLarge: base.displayLarge?.copyWith(
        fontSize: 32,
        fontWeight: FontWeight.w700,
        color: primary,
        letterSpacing: -0.5,
      ),
      titleLarge: base.titleLarge?.copyWith(
        fontSize: 22,
        fontWeight: FontWeight.w600,
        color: primary,
      ),
      titleMedium: base.titleMedium?.copyWith(
        fontSize: 18,
        fontWeight: FontWeight.w500,
        color: primary,
      ),
      bodyLarge: base.bodyLarge?.copyWith(
        fontSize: 15,
        fontWeight: FontWeight.w400,
        color: primary,
      ),
      bodyMedium: base.bodyMedium?.copyWith(
        fontSize: 15,
        fontWeight: FontWeight.w400,
        color: primary,
      ),
      bodySmall: base.bodySmall?.copyWith(
        fontSize: 13,
        fontWeight: FontWeight.w400,
        color: secondary,
      ),
      labelLarge: base.labelLarge?.copyWith(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: primary,
        letterSpacing: 0.2,
      ),
      labelMedium: base.labelMedium?.copyWith(
        fontSize: 13,
        fontWeight: FontWeight.w500,
        color: secondary,
        letterSpacing: 0.4,
      ),
      labelSmall: base.labelSmall?.copyWith(
        fontSize: 11,
        fontWeight: FontWeight.w500,
        color: secondary,
        letterSpacing: 1.0,
      ),
    );
  }

  /// Style used for live numeric vitals readouts.
  static TextStyle stat(Color color) => GoogleFonts.inter(
        fontSize: 28,
        fontWeight: FontWeight.w700,
        color: color,
        letterSpacing: -0.5,
        height: 1.0,
      );

  /// Oversized readout for the one number a kiosk user reads from a step back
  /// (temperature, heart rate, risk score). Tabular figures so digits don't
  /// jitter horizontally as a live value changes.
  static TextStyle hero(Color color, {double fontSize = 64}) =>
      GoogleFonts.inter(
        fontSize: fontSize,
        fontWeight: FontWeight.w800,
        color: color,
        letterSpacing: -2,
        height: 1.0,
        fontFeatures: const [FontFeature.tabularFigures()],
      );

  /// All-caps section label. Kiosk minimum is 13px before text scaling.
  static TextStyle eyebrow(Color color) => GoogleFonts.inter(
        fontSize: 13,
        fontWeight: FontWeight.w800,
        color: color,
        letterSpacing: 1.2,
      );
}
