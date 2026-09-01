import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../../core/api/server_discovery.dart';
import '../../core/theme/xs_colors.dart';
import '../../core/theme/xs_scale.dart';
import '../../core/theme/xs_spacing.dart';
import '../../state/xs_settings.dart';

/// Splash screen with XSIGHT logotype.
///
/// The logo scales up out of a breathing ring while a scan sweep crosses it —
/// same visual language as the X-ray scan overlay, so the kiosk introduces
/// itself as an imaging device from the first second.
///
/// While the intro plays, the LAN is swept for the backend and the first hit is
/// adopted automatically: the server address moves with the venue's DHCP and a
/// kiosk has no keyboard, so "auto-find at startup" is what keeps the app off
/// the Settings screen entirely. The hand-off waits for the sweep to settle
/// (bounded) so the rest of the flow starts against a known-good server.
class SplashScreen extends StatefulWidget {
  final VoidCallback onReady;

  /// Set false in widget tests, where a real socket sweep would hang the
  /// fake-async zone.
  final bool autoDiscoverServer;

  const SplashScreen({
    super.key,
    required this.onReady,
    this.autoDiscoverServer = true,
  });

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _intro;

  /// Upper bound on the startup sweep. A quiet /24 settles well inside this;
  /// the point is that a missing server delays launch by seconds, not forever.
  static const _sweepBudget = Duration(seconds: 8);

  bool _introDone = false;
  bool _discoveryDone = false;
  bool _handedOff = false;
  String _serverNote = 'Looking for the server on this network…';

  @override
  void initState() {
    super.initState();
    _intro = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..forward();
    // Hand off once the intro has actually played AND the server hunt has had
    // its chance, instead of racing a hardcoded delay against them.
    _intro.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        _introDone = true;
        _maybeHandOff();
      }
    });
    if (widget.autoDiscoverServer) {
      _discoverServer();
    } else {
      _discoveryDone = true;
      _serverNote = '';
    }
  }

  Future<void> _discoverServer() async {
    String note;
    try {
      final candidate = await XSServerDiscovery.findFirst(
        preferred: XSSettings.I.backendUrl,
        overallTimeout: _sweepBudget,
      );
      if (candidate != null) {
        // Persist only on change — an unchanged address should not dirty prefs
        // every launch.
        if (XSSettings.I.backendUrl != candidate.baseUrl) {
          await XSSettings.I.setBackendUrl(candidate.baseUrl);
        }
        note = 'Server found · ${candidate.host}:${candidate.port}';
      } else {
        note = 'No server found — continuing offline';
      }
    } catch (_) {
      // Discovery must never block the launch path, whatever it throws.
      note = '';
    }
    if (!mounted) return;
    setState(() {
      _serverNote = note;
      _discoveryDone = true;
    });
    _maybeHandOff();
  }

  void _maybeHandOff() {
    if (_handedOff || !_introDone || !_discoveryDone) return;
    _handedOff = true;
    widget.onReady();
  }

  @override
  void dispose() {
    _intro.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    final s = XSScale.factor;

    return Scaffold(
      backgroundColor: palette.surface,
      body: Center(
        child: AnimatedBuilder(
          animation: _intro,
          builder: (context, _) {
            final t = _intro.value;
            // Logo settles in the first 60% of the intro; text follows.
            final logoIn = Curves.easeOutBack.transform(
              (t / 0.6).clamp(0.0, 1.0),
            );
            final textIn = Curves.easeOut.transform(
              ((t - 0.45) / 0.55).clamp(0.0, 1.0),
            );

            return Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  width: 280 * s,
                  height: 280 * s,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      CustomPaint(
                        size: Size.square(280 * s),
                        painter: _IntroRingPainter(t: t, color: palette.accent),
                      ),
                      Transform.scale(
                        scale: 0.7 + logoIn * 0.3,
                        child: Opacity(
                          opacity: logoIn.clamp(0.0, 1.0),
                          child: Image.asset(
                            'assets/images/logo.png',
                            width: 180 * s,
                            height: 180 * s,
                            fit: BoxFit.contain,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(height: XSSpacing.lg * s),
                Opacity(
                  opacity: textIn,
                  child: Transform.translate(
                    offset: Offset(0, (1 - textIn) * 10 * s),
                    child: Text(
                      'THORACIC ASSESSMENT',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 5,
                        color: palette.textSecondary,
                      ),
                    ),
                  ),
                ),
                if (widget.autoDiscoverServer &&
                    _serverNote.isNotEmpty) ...[
                  SizedBox(height: XSSpacing.sm * s),
                  Opacity(
                    opacity: textIn,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (!_discoveryDone)
                          SizedBox(
                            width: 14 * s,
                            height: 14 * s,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: palette.accent,
                            ),
                          )
                        else
                          Icon(
                            _serverNote.startsWith('Server found')
                                ? Icons.check_circle_outline
                                : Icons.wifi_off_outlined,
                            size: 16 * s,
                            color: _serverNote.startsWith('Server found')
                                ? palette.accent
                                : palette.textSecondary,
                          ),
                        SizedBox(width: 8 * s),
                        Flexible(
                          child: Text(
                            _serverNote,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12.5,
                              letterSpacing: 0.5,
                              fontWeight: FontWeight.w600,
                              color: palette.textSecondary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Breathing ring plus a single rotating sweep arc.
class _IntroRingPainter extends CustomPainter {
  final double t;
  final Color color;

  _IntroRingPainter({required this.t, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2 - 6;
    final fade = Curves.easeOut.transform((t / 0.35).clamp(0.0, 1.0));

    // Static track.
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = color.withValues(alpha: 0.18 * fade),
    );

    // Sweep arc: two full turns over the intro.
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      t * 4 * math.pi,
      math.pi * 0.55,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..color = color.withValues(alpha: 0.85 * fade)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
    );

    // Expanding pulse that fades as the logo lands.
    final pulse = (t / 0.8).clamp(0.0, 1.0);
    if (pulse < 1) {
      canvas.drawCircle(
        center,
        radius * (0.45 + pulse * 0.55),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2 * (1 - pulse)
          ..color = color.withValues(alpha: 0.35 * (1 - pulse)),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _IntroRingPainter old) =>
      old.t != t || old.color != color;
}
