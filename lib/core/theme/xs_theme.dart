import 'package:flutter/material.dart';
import 'xs_colors.dart';
import 'xs_typography.dart';

class XSTheme {
  XSTheme._();

  static ThemeData light() {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      scaffoldBackgroundColor: XSColors.surfaceLight,
      canvasColor: XSColors.surfaceLight,
      colorScheme: const ColorScheme.light(
        primary: XSColors.textPrimaryLight,
        onPrimary: XSColors.surfaceLight,
        secondary: XSColors.textSecondaryLight,
        onSecondary: XSColors.surfaceLight,
        surface: XSColors.surfaceLight,
        onSurface: XSColors.textPrimaryLight,
        error: XSColors.textPrimaryLight,
        onError: XSColors.surfaceLight,
      ),
      textTheme: XSTypography.textTheme(
        XSColors.textPrimaryLight,
        XSColors.textSecondaryLight,
      ),
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
    );
  }

  static ThemeData dark() {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: XSColors.surfaceDark,
      canvasColor: XSColors.surfaceDark,
      colorScheme: const ColorScheme.dark(
        primary: XSColors.textPrimaryDark,
        onPrimary: XSColors.surfaceDark,
        secondary: XSColors.textSecondaryDark,
        onSecondary: XSColors.surfaceDark,
        surface: XSColors.surfaceDark,
        onSurface: XSColors.textPrimaryDark,
        error: XSColors.textPrimaryDark,
        onError: XSColors.surfaceDark,
      ),
      textTheme: XSTypography.textTheme(
        XSColors.textPrimaryDark,
        XSColors.textSecondaryDark,
      ),
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
    );
  }
}
