import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/xs_colors.dart';

/// Slow-drifting aurora field painted behind kiosk surfaces.
///
/// A kiosk sits idle in a corridor for hours; a dead-flat mint background makes
/// it look powered off. Three large, low-opacity radial blooms drift on a long
/// loop so the screen reads as alive from across the room while staying quiet
/// enough to sit under text. The active module's accent tints one bloom, so
/// changing tools visibly changes the room's color.
class XSAmbientBackground extends StatefulWidget {
  final Widget child;

  /// Bloom tint. Defaults to the ambient palette accent.
  final Color? accent;

  /// 0 = invisible, 1 = full strength. Lower this behind dense content.
  final double intensity;

  const XSAmbientBackground({
    super.key,
    required this.child,
    this.accent,
    this.intensity = 1.0,
  });

  @override
  State<XSAmbientBackground> createState() => _XSAmbientBackgroundState();
}

class _XSAmbientBackgroundState extends State<XSAmbientBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _drift;

  @override
  void initState() {
    super.initState();
    // One very slow loop: perceptible over ~30s, never distracting.
    _drift = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 30),
    )..repeat();
  }

  @override
  void dispose() {
    _drift.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    final accent = widget.accent ?? palette.accent;

    return Stack(
      children: [
        Positioned.fill(
          child: RepaintBoundary(
            child: AnimatedBuilder(
              animation: _drift,
              builder: (context, _) => CustomPaint(
                painter: _AuroraPainter(
                  t: _drift.value,
                  accent: accent,
                  palette: palette,
                  intensity: widget.intensity.clamp(0.0, 1.0),
                ),
              ),
            ),
          ),
        ),
        widget.child,
      ],
    );
  }
}

class _AuroraPainter extends CustomPainter {
  final double t;
  final Color accent;
  final XSPalette palette;
  final double intensity;

  _AuroraPainter({
    required this.t,
    required this.accent,
    required this.palette,
    required this.intensity,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (intensity <= 0) return;
    final tau = 2 * math.pi;

    // Each bloom: fractional center, phase, radius fraction, color, alpha.
    final blooms = <({
      Offset base,
      double phase,
      double radius,
      Color color,
      double alpha,
    })>[
      (
        base: const Offset(0.18, 0.18),
        phase: 0.0,
        radius: 0.62,
        color: accent,
        alpha: 0.22,
      ),
      (
        base: const Offset(0.86, 0.30),
        phase: 0.37,
        radius: 0.54,
        color: XSColors.sage,
        alpha: 0.20,
      ),
      (
        base: const Offset(0.50, 0.94),
        phase: 0.71,
        radius: 0.70,
        color: XSColors.teal,
        alpha: 0.14,
      ),
    ];

    for (final b in blooms) {
      final a = (t + b.phase) * tau;
      // Lissajous drift keeps the motion non-repeating to the eye.
      final center = Offset(
        (b.base.dx + 0.05 * math.cos(a)) * size.width,
        (b.base.dy + 0.05 * math.sin(a * 1.3)) * size.height,
      );
      final radius = b.radius * size.shortestSide;
      // Breathe each bloom slightly out of phase with its drift.
      final breath = 0.90 + 0.10 * math.sin(a * 0.7);
      final alpha = b.alpha * intensity * breath;

      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..shader = RadialGradient(
            colors: [
              b.color.withValues(alpha: alpha),
              b.color.withValues(alpha: 0),
            ],
          ).createShader(Rect.fromCircle(center: center, radius: radius)),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _AuroraPainter old) =>
      old.t != t || old.accent != accent || old.intensity != intensity;
}
