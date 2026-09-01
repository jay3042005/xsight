import 'dart:math';
import 'package:flutter/material.dart';
import '../../core/theme/xs_colors.dart';

/// Animated visual guide showing thermometer placement for temperature reading.
/// Shows a thermometer approaching a forehead silhouette.
///
/// UNUSED, and deliberately not wired to anything: the MLX90614 on this device is
/// mounted beside the pulse sensor and reads a FINGERTIP, so the temperature
/// station uses [XSFingerGuide] in the thermal accent instead. Coaching a forehead
/// gesture would teach an action the hardware cannot perform. Kept only in case a
/// non-contact forehead variant of the module ever exists — do not reintroduce it
/// on the current one.
class XSThermometerGuide extends StatefulWidget {
  final double size;
  final Color? accentColor;

  const XSThermometerGuide({
    super.key,
    this.size = 200,
    this.accentColor,
  });

  @override
  State<XSThermometerGuide> createState() => _XSThermometerGuideState();
}

class _XSThermometerGuideState extends State<XSThermometerGuide>
    with TickerProviderStateMixin {
  late final AnimationController _pulseController;
  late final AnimationController _thermoController;
  late final AnimationController _glowController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();

    _thermoController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2500),
    )..repeat();

    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _thermoController.dispose();
    _glowController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    final accent = widget.accentColor ?? const Color(0xFFFB8C00);

    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: Listenable.merge([
          _pulseController,
          _thermoController,
          _glowController,
        ]),
        builder: (context, _) {
          return CustomPaint(
            painter: _ThermometerGuidePainter(
              pulseProgress: _pulseController.value,
              thermoProgress: _thermoController.value,
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

class _ThermometerGuidePainter extends CustomPainter {
  final double pulseProgress;
  final double thermoProgress;
  final double glowProgress;
  final Color accentColor;
  final Color surfaceColor;
  final Color dividerColor;

  _ThermometerGuidePainter({
    required this.pulseProgress,
    required this.thermoProgress,
    required this.glowProgress,
    required this.accentColor,
    required this.surfaceColor,
    required this.dividerColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height * 0.35);

    _drawForehead(canvas, center, size);
    _drawPulsingRings(canvas, center, size);
    _drawThermometer(canvas, center, size);
  }

  void _drawForehead(Canvas canvas, Offset center, Size size) {
    final headRadius = size.width * 0.25;
    final headCenter = Offset(center.dx, center.dy + headRadius * 0.3);

    // Forehead arc
    final headPaint = Paint()
      ..color = dividerColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;
    canvas.drawArc(
      Rect.fromCenter(
        center: headCenter,
        width: headRadius * 2,
        height: headRadius * 2,
      ),
      -pi * 0.8,
      pi * 0.6,
      false,
      headPaint,
    );

    // Forehead fill (subtle)
    final fillPaint = Paint()
      ..color = dividerColor.withValues(alpha: 0.15)
      ..style = PaintingStyle.fill;
    canvas.drawArc(
      Rect.fromCenter(
        center: headCenter,
        width: headRadius * 2,
        height: headRadius * 2,
      ),
      -pi * 0.8,
      pi * 0.6,
      false,
      fillPaint,
    );

    // Temperature target spot (glowing)
    final spotOpacity = 0.3 + glowProgress * 0.4;
    final spotPaint = Paint()
      ..color = accentColor.withValues(alpha: spotOpacity)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(
      Offset(center.dx - headRadius * 0.15, center.dy - headRadius * 0.1),
      6,
      spotPaint,
    );
  }

  void _drawPulsingRings(Canvas canvas, Offset center, Size size) {
    final targetSpot = Offset(
      center.dx - size.width * 0.25 * 0.15,
      center.dy - size.width * 0.25 * 0.1,
    );

    for (int i = 0; i < 3; i++) {
      final ringProgress = (pulseProgress + i * 0.33) % 1.0;
      final ringRadius = 6 + (15 * ringProgress);
      final ringOpacity = (1.0 - ringProgress).clamp(0.0, 0.3);

      final ringPaint = Paint()
        ..color = accentColor.withValues(alpha: ringOpacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5 * (1.0 - ringProgress);
      canvas.drawCircle(targetSpot, ringRadius, ringPaint);
    }
  }

  void _drawThermometer(Canvas canvas, Offset center, Size size) {
    // Thermometer moves from right side toward forehead
    final startX = size.width * 0.85;
    final endX = center.dx - size.width * 0.25 * 0.15;
    final targetY = center.dy - size.width * 0.25 * 0.1;

    // Ease: fast approach, slow near target
    final easedProgress = _easeInOutPause(thermoProgress);
    final thermoX = startX + (endX - startX) * easedProgress;
    final thermoY = targetY - 30 + (30 * easedProgress);

    canvas.save();
    canvas.translate(thermoX, thermoY);
    canvas.rotate(-pi * 0.15 * (1 - easedProgress)); // Slight angle that straightens

    final thermoWidth = 8.0;
    final thermoLength = 50.0;

    // Thermometer shadow
    final shadowPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.06)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(2, thermoLength * 0.4 + 2),
          width: thermoWidth + 4,
          height: thermoLength + 4,
        ),
        const Radius.circular(4),
      ),
      shadowPaint,
    );

    // Thermometer body (white)
    final bodyPaint = Paint()
      ..color = const Color(0xFFF5F5F5)
      ..style = PaintingStyle.fill;
    final bodyRect = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(0, thermoLength * 0.4),
        width: thermoWidth,
        height: thermoLength,
      ),
      const Radius.circular(4),
    );
    canvas.drawRRect(bodyRect, bodyPaint);

    // Thermometer body outline
    final outlinePaint = Paint()
      ..color = dividerColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    canvas.drawRRect(bodyRect, outlinePaint);

    // Mercury column (orange/red)
    final mercuryHeight = thermoLength * 0.6 * (0.5 + glowProgress * 0.5);
    final mercuryPaint = Paint()
      ..color = accentColor
      ..style = PaintingStyle.fill;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(0, thermoLength * 0.7 - mercuryHeight / 2),
          width: thermoWidth * 0.4,
          height: mercuryHeight,
        ),
        const Radius.circular(2),
      ),
      mercuryPaint,
    );

    // Thermometer bulb at bottom
    final bulbPaint = Paint()
      ..color = accentColor
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(0, thermoLength * 0.85), thermoWidth * 0.45, bulbPaint);

    // Measurement lines
    final linePaint = Paint()
      ..color = dividerColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.5;
    for (int i = 0; i < 5; i++) {
      final lineY = thermoLength * 0.2 + (i * thermoLength * 0.12);
      canvas.drawLine(
        Offset(-thermoWidth * 0.4, lineY),
        Offset(-thermoWidth * 0.15, lineY),
        linePaint,
      );
    }

    canvas.restore();
  }

  double _easeInOutPause(double t) {
    if (t < 0.7) {
      return (t / 0.7) * 0.85;
    } else {
      final slowT = (t - 0.7) / 0.3;
      return 0.85 + slowT * 0.15;
    }
  }

  @override
  bool shouldRepaint(_ThermometerGuidePainter oldDelegate) =>
      oldDelegate.pulseProgress != pulseProgress ||
      oldDelegate.thermoProgress != thermoProgress ||
      oldDelegate.glowProgress != glowProgress;
}
