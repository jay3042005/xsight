import 'package:flutter/material.dart';

import 'core/design.dart';
import 'ui/launcher_panel.dart';

void main() {
  runApp(const XSLauncherApp());
}

class XSLauncherApp extends StatelessWidget {
  const XSLauncherApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'XSIGHT Server Launcher',
      debugShowCheckedModeBanner: false,
      theme: _theme(),
      home: const LauncherPanel(),
    );
  }

  /// Dark, monochrome-neumorphic — the kiosk's dark surface with mint text,
  /// so the launcher reads as the same product family. The kiosk theme lives
  /// in its own package; this is a small standalone build of the same look.
  ThemeData _theme() {
    final base = ThemeData.dark(useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: XS.surface,
      colorScheme: base.colorScheme.copyWith(
        primary: XS.highlight,
        secondary: XS.sage,
        surface: XS.surface,
        onSurface: XS.textPrimary,
      ),
      textTheme: base.textTheme.apply(
        bodyColor: XS.textPrimary,
        displayColor: XS.textPrimary,
        fontFamily: 'Segoe UI',
      ),
      dividerColor: XS.divider,
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: XS.surfaceRaised,
        contentTextStyle: TextStyle(color: XS.textPrimary),
      ),
    );
  }
}
