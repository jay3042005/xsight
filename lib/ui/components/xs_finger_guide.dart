import 'package:flutter/material.dart';
import '../../core/theme/xs_colors.dart';

/// Animated visual guide showing finger placement on the sensor.
/// No text — purely visual animation with pulsing rings and a moving finger.
class XSFingerGuide extends StatefulWidget {
  final double size;
  final Color? accentColor;

  const XSFingerGuide({
    super.key,
    this.size = 200,
    this.accentColor,
  });

  @override
  State<XSFingerGuide> createState() => _XSFingerGuideState();
}

class _XSFingerGuideState extends State<XSFingerGuide>
    with TickerProviderStateMixin {
  late final AnimationController _pulseController;
  late final AnimationController _fingerController;
  late final AnimationController _glowController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();

    _fingerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat();

    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _fingerController.dispose();
    _glowController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    final accent = widget.accentColor ?? XSColors.accentGreen;

    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: Listenable.merge([
          _pulseController,
          _fingerController,
          _glowController,
        ]),
        builder: (context, _) {
          return CustomPaint(
            painter: _FingerGuidePainter(
              pulseProgress: _pulseController.value,
              fingerProgress: _fingerController.value,
              glowProgress: _glowController.value,
              accentColor: accent,
              surfaceColor: palette.surface,
              dividerColor: palette.divider,
            ),
          );
        },
      ),
    );
  }
}

class _FingerGuidePainter extends CustomPainter {
  final double pulseProgress;
  final double fingerProgress;
  final double glowProgress;
  final Color accentColor;
  final Color surfaceColor;
  final Color dividerColor;

  _FingerGuidePainter({
    required this.pulseProgress,
    required this.fingerProgress,
    required this.glowProgress,
    required this.accentColor,
    required this.surfaceColor,
    required this.dividerColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final sensorRadius = size.width * 0.22;

    _drawSensorGlow(canvas, center, sensorRadius);
    _drawPulsingRings(canvas, center, sensorRadius);
    _drawSensor(canvas, center, sensorRadius);
    _drawFinger(canvas, center, sensorRadius, size);
  }

  void _drawSensorGlow(Canvas canvas, Offset center, double radius) {
    final glowRadius = radius + (radius * 0.3 * glowProgress);
    final glowPaint = Paint()
      ..color = accentColor.withValues(alpha: 0.08 + glowProgress * 0.07)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 20);
    canvas.drawCircle(center, glowRadius, glowPaint);
  }

  void _drawPulsingRings(Canvas canvas, Offset center, double radius) {
    for (int i = 0; i < 3; i++) {
      final ringProgress = (pulseProgress + i * 0.33) % 1.0;
      final ringRadius = radius + (radius * 0.6 * ringProgress);
      final ringOpacity = (1.0 - ringProgress).clamp(0.0, 0.4);

      final ringPaint = Paint()
        ..color = accentColor.withValues(alpha: ringOpacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0 * (1.0 - ringProgress);
      canvas.drawCircle(center, ringRadius, ringPaint);
    }
  }

  void _drawSensor(Canvas canvas, Offset center, double radius) {
    // Sensor base (dark circle)
    final basePaint = Paint()
      ..color = dividerColor
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, radius, basePaint);

    // Sensor inner ring
    final innerPaint = Paint()
      ..color = accentColor.withValues(alpha: 0.3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    canvas.drawCircle(center, radius * 0.7, innerPaint);

    // LED indicator (pulsing)
    final ledOpacity = 0.4 + glowProgress * 0.6;
    final ledPaint = Paint()
      ..color = accentColor.withValues(alpha: ledOpacity)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, radius * 0.15, ledPaint);

    // Small LED glow
    final ledGlowPaint = Paint()
      ..color = accentColor.withValues(alpha: ledOpacity * 0.5)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);
    canvas.drawCircle(center, radius * 0.25, ledGlowPaint);
  }

  void _drawFinger(
      Canvas canvas, Offset center, double sensorRadius, Size size) {
    // Finger moves from bottom upward to sensor center
    final fingerStartY = size.height + size.height * 0.15;
    final fingerEndY = center.dy + sensorRadius * 0.3;

    // Ease the finger movement: pause near the sensor
    final easedProgress = _easeInOutPause(fingerProgress);
    final fingerY = fingerStartY + (fingerEndY - fingerStartY) * easedProgress;
    final fingerX = center.dx;

    final fingerWidth = sensorRadius * 0.7;
    final fingerLength = size.height * 0.35;

    canvas.save();
    canvas.translate(fingerX, fingerY);

    // Finger shadow
    final shadowPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.08)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(2, -fingerLength * 0.5 + 2),
        width: fingerWidth + 4,
        height: fingerLength + 4,
      ),
      shadowPaint,
    );

    // Finger body (rounded rectangle) — fingertip points upward
    final fingerPaint = Paint()
      ..color = const Color(0xFFE8B89D)
      ..style = PaintingStyle.fill;
    final fingerRect = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(0, -fingerLength * 0.45),
        width: fingerWidth,
        height: fingerLength,
      ),
      const Radius.circular(20),
    );
    canvas.drawRRect(fingerRect, fingerPaint);

    // Fingertip highlight (at top)
    final tipPaint = Paint()
      ..color = const Color(0xFFD4A088).withValues(alpha: 0.4)
      ..style = PaintingStyle.fill;
    final tipRect = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(0, -fingerLength * 0.85),
        width: fingerWidth * 0.85,
        height: fingerLength * 0.15,
      ),
      const Radius.circular(12),
    );
    canvas.drawRRect(tipRect, tipPaint);

    // Nail (at top)
    final nailPaint = Paint()
      ..color = const Color(0xFFF5D5C0)
      ..style = PaintingStyle.fill;
    final nailRect = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(0, -fingerLength * 0.92),
        width: fingerWidth * 0.55,
        height: fingerLength * 0.1,
      ),
      const Radius.circular(6),
    );
    canvas.drawRRect(nailRect, nailPaint);

    canvas.restore();
  }

  double _easeInOutPause(double t) {
    // Custom ease: fast start, slow near end (pause effect)
    if (t < 0.7) {
      // Fast movement phase
      return (t / 0.7) * 0.85;
    } else {
      // Slow approach phase
      final slowT = (t - 0.7) / 0.3;
      return 0.85 + slowT * 0.15;
    }
  }

  @override
  bool shouldRepaint(_FingerGuidePainter oldDelegate) =>
      oldDelegate.pulseProgress != pulseProgress ||
      oldDelegate.fingerProgress != fingerProgress ||
      oldDelegate.glowProgress != glowProgress;
}
