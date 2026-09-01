import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/theme/xs_colors.dart';
import 'core/theme/xs_scale.dart';
import 'core/theme/xs_theme.dart';
import 'state/xs_settings.dart';
import 'state/kiosk_patient_state.dart';
import 'ui/screens/disclaimer_screen.dart';
import 'ui/screens/kiosk_guest_entry_screen.dart';
import 'ui/screens/kiosk_shell.dart';
import 'ui/screens/onboarding_screen.dart';
import 'ui/screens/splash_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await XSSettings.I.load();

  final isMobile = !kIsWeb && (Platform.isAndroid || Platform.isIOS);
  if (isMobile) {
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
        systemNavigationBarColor: XSColors.surfaceLight,
        systemNavigationBarIconBrightness: Brightness.dark,
      ),
    );
  }
  runApp(const XSightApp());
}

class XSightApp extends StatelessWidget {
  final bool autoDiscoverServer;

  const XSightApp({super.key, this.autoDiscoverServer = true});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'XSIGHT',
      debugShowCheckedModeBanner: false,
      theme: XSTheme.light(),
      darkTheme: XSTheme.dark(),
      themeMode: ThemeMode.light,
      builder: (context, child) {
        final media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(textScaler: TextScaler.linear(XSScale.factor)),
          child: child!,
        );
      },
      home: _Bootstrap(autoDiscoverServer: autoDiscoverServer),
    );
  }
}

enum _Stage { splash, onboarding, disclaimer, guestEntry, app }

class _Bootstrap extends StatefulWidget {
  final bool autoDiscoverServer;

  const _Bootstrap({required this.autoDiscoverServer});

  @override
  State<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<_Bootstrap> {
  _Stage _stage = _Stage.splash;

  void _setStage(_Stage s) {
    if (!mounted) return;
    setState(() => _stage = s);
  }

  void _enterGuestApp() {
    KioskPatientSession.I.setGuestMode();
    _setStage(_Stage.app);
  }

  void _enterRemoteSession(Map<String, dynamic> patient) {
    final session = KioskPatientSession.I;

    // The portal dispatches a real EMR record, so link it: every station already
    // writes its reading against `selectedPatientId`, and running this as an
    // anonymous intake session meant a whole visit's readings went nowhere and
    // the patient's history stayed empty.
    if (!session.linkPortalPatient(patient)) {
      // No usable record id — a walk-in dispatched by name only. Fall back to the
      // intake session, which holds readings without filing them.
      session.openIntakeSession(name: patient['name']?.toString());
      session.applyIntakeDetails(patient);
    }
    _setStage(_Stage.app);
  }

  @override
  Widget build(BuildContext context) {
    Widget child;
    switch (_stage) {
      case _Stage.splash:
        child = SplashScreen(
          onReady: () => _setStage(_Stage.onboarding),
          autoDiscoverServer: widget.autoDiscoverServer,
        );
        break;
      case _Stage.onboarding:
        child = OnboardingScreen(onFinish: () => _setStage(_Stage.disclaimer));
        break;
      case _Stage.disclaimer:
        child = DisclaimerScreen(
          onAccept: () => _setStage(_Stage.guestEntry),
          onDecline: () => _setStage(_Stage.onboarding),
        );
        break;
      case _Stage.guestEntry:
        child = KioskGuestEntryScreen(
          onEnterGuestMode: _enterGuestApp,
          onEnterRemoteSession: _enterRemoteSession,
        );
        break;
      case _Stage.app:
        child = KioskShell(onStopSession: () => _setStage(_Stage.guestEntry));
        break;
    }
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 320),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      child: KeyedSubtree(key: ValueKey(_stage), child: child),
    );
  }
}
