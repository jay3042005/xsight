import 'package:flutter/material.dart';

/// XSIGHT color tokens.
///
/// Brand palette:
///   #0F3D3E  dark teal
///   #1B6B6F  teal
///   #6C9A8B  sage green
///   #DCEDEA  pale mint (off-white)
///   #2F3E46  dark slate blue
class XSColors {
  XSColors._();

  // Brand palette
  static const tealDark = Color(0xFF0F3D3E);
  static const teal = Color(0xFF1B6B6F);
  static const sage = Color(0xFF6C9A8B);
  static const mint = Color(0xFFDCEDEA);
  static const slate = Color(0xFF2F3E46);

  // Light theme
  static const surfaceLight = mint;
  static const highlightLight = Color(0xFFFFFFFF);
  static const shadowLight = sage;
  static const textPrimaryLight = slate;
  static const textSecondaryLight = teal;
  static const dividerLight = Color(0xFFC9E0DA);

  // Dark theme
  static const surfaceDark = slate;
  static const highlightDark = teal;
  static const shadowDark = tealDark;
  static const textPrimaryDark = mint;
  static const textSecondaryDark = sage;
  static const dividerDark = teal;

  // Risk levels (intensity carries meaning)
  static const riskLow = sage;
  static const riskModerate = teal;
  static const riskHigh = tealDark;

  // Semantic status colors (kept distinct for clinical clarity)
  static const accentGreen = Color(0xFF2E7D32);
  static const accentRed = Color(0xFFC62828);
  static const accentBlue = Color(0xFF1565C0);
  static const accentOrange = Color(0xFFE65100);

  /// Per-module accent colors. Each kiosk tool owns a hue so a walk-up user
  /// can recognise where they are before reading a single word. These were
  /// previously inlined in `kiosk_shell.dart`; they live here so screens,
  /// menus, and headers can all agree on one identity per module.
  static const moduleXray = Color(0xFF1565C0); // blue    — radiology
  static const moduleSteth = Color(0xFF00897B); // teal    — acoustics
  static const moduleVitals = Color(0xFFE53935); // red     — pulse
  static const moduleTemp = Color(0xFFF57C00); // orange  — thermal
  static const moduleSummary = Color(0xFF7B1FA2); // purple  — reporting
  static const moduleAssistant = Color(0xFF3F51B5); // indigo  — AI
  static const moduleSettings = Color(0xFF455A64); // slate   — system
}

/// Resolves colors based on current brightness.
class XSPalette {
  final Color surface;
  final Color highlight;
  final Color shadow;
  final Color textPrimary;
  final Color textSecondary;
  final Color divider;
  final Color accent;

  const XSPalette({
    required this.surface,
    required this.highlight,
    required this.shadow,
    required this.textPrimary,
    required this.textSecondary,
    required this.divider,
    required this.accent,
  });

  static XSPalette of(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final base = dark
        ? const XSPalette(
            surface: XSColors.surfaceDark,
            highlight: XSColors.highlightDark,
            shadow: XSColors.shadowDark,
            textPrimary: XSColors.textPrimaryDark,
            textSecondary: XSColors.textSecondaryDark,
            divider: XSColors.dividerDark,
            accent: XSColors.sage,
          )
        : const XSPalette(
            surface: XSColors.surfaceLight,
            highlight: XSColors.highlightLight,
            shadow: XSColors.shadowLight,
            textPrimary: XSColors.textPrimaryLight,
            textSecondary: XSColors.textSecondaryLight,
            divider: XSColors.dividerLight,
            accent: XSColors.teal,
          );

    // A module wrapper (see XSModuleAccent) recolors `accent` for its subtree,
    // so every existing `palette.accent` reference picks up the module hue.
    final module = XSModuleAccent.maybeOf(context);
    return module == null ? base : base.withAccent(module);
  }

  XSPalette withAccent(Color color) => XSPalette(
        surface: surface,
        highlight: highlight,
        shadow: shadow,
        textPrimary: textPrimary,
        textSecondary: textSecondary,
        divider: divider,
        accent: color,
      );
}

/// Scopes a module accent color to a subtree.
///
/// Wrap a kiosk tool in this and `XSPalette.of(context).accent` becomes that
/// tool's hue, giving each screen a recognisable identity without editing the
/// screen itself.
class XSModuleAccent extends InheritedWidget {
  final Color color;

  const XSModuleAccent({
    super.key,
    required this.color,
    required super.child,
  });

  static Color? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<XSModuleAccent>()?.color;

  @override
  bool updateShouldNotify(XSModuleAccent oldWidget) => color != oldWidget.color;
}
