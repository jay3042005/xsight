import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../../core/theme/xs_colors.dart';
import '../../core/theme/xs_scale.dart';
import '../../core/theme/xs_typography.dart';

/// Animated arc gauge for a single scalar reading.
///
/// The kiosk's job is to answer one question per station, so each station gets
/// one large gauge: a 240-degree track, a colored sweep that animates to the
/// current value, a glowing tip marking the needle, and the number in the
/// middle at hero size. Readable from a step back; no legend needed.
class XSDialGauge extends StatelessWidget {
  /// Current reading. Clamped into [min]..[max] for display.
  final double value;
  final double min;
  final double max;

  /// Big centre text, e.g. `'37.4'`. Caller formats; the gauge doesn't guess
  /// significant figures for a clinical value.
  final String label;

  /// Small unit under the number, e.g. `'°C'`.
  final String unit;

  /// Status line under the unit, e.g. `'NORMAL TEMPERATURE'`.
  final String? status;

  /// Sweep + glow color. Defaults to the ambient (or module) accent.
  final Color? color;

  final double size;

  const XSDialGauge({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.label,
    this.unit = '',
    this.status,
    this.color,
    this.size = 240,
  });

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    final s = XSScale.factor;
    final c = color ?? palette.accent;
    final d = size * s;

    final range = (max - min).abs() < 1e-9 ? 1.0 : (max - min);
    final fraction = ((value - min) / range).clamp(0.0, 1.0);

    return SizedBox(
      width: d,
      height: d,
      child: TweenAnimationBuilder<double>(
        // Sweeping to a new reading, rather than snapping, communicates that
        // the device measured something.
        tween: Tween(begin: 0, end: fraction),
        duration: const Duration(milliseconds: 900),
        curve: Curves.easeOutCubic,
        builder: (context, t, _) {
          return CustomPaint(
            painter: _DialPainter(
              fraction: t,
              color: c,
              track: palette.divider,
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Font sizes key off the unscaled [size]; the app-wide
                  // textScaler applies the kiosk factor, so scaling here too
                  // would double-count it.
                  Text(
                    label,
                    style: XSTypography.hero(c, fontSize: size * 0.26),
                  ),
                  if (unit.isNotEmpty)
                    Text(
                      unit,
                      style: TextStyle(
                        fontSize: size * 0.09,
                        fontWeight: FontWeight.w700,
                        color: palette.textSecondary,
                      ),
                    ),
                  if (status != null) ...[
                    SizedBox(height: d * 0.03),
                    SizedBox(
                      width: d * 0.66,
                      child: Text(
                        status!,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: math.max(13, size * 0.055),
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.6,
                          color: c,
                          height: 1.2,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _DialPainter extends CustomPainter {
  final double fraction;
  final Color color;
  final Color track;

  /// 240-degree arc starting at lower-left, so the gap sits at the bottom
  /// where the status text lives.
  static const _start = math.pi * 0.75;
  static const _sweep = math.pi * 1.5;

  _DialPainter({
    required this.fraction,
    required this.color,
    required this.track,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.075;
    final rect = Rect.fromCircle(
      center: size.center(Offset.zero),
      radius: (size.width - stroke) / 2,
    );

    final base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;

    // Track.
    canvas.drawArc(
      rect, _start, _sweep, false, Paint.from(base)..color = track);

    if (fraction <= 0) return;

    // Sweep, brightening toward the current value.
    canvas.drawArc(
      rect,
      _start,
      _sweep * fraction,
      false,
      Paint.from(base)
        ..shader = SweepGradient(
          startAngle: _start,
          endAngle: _start + _sweep,
          colors: [
            color.withValues(alpha: 0.45),
            color,
          ],
          transform: GradientRotation(_start),
        ).createShader(rect),
    );

    // Blurred duplicate under the sweep for an emissive edge.
    canvas.drawArc(
      rect,
      _start,
      _sweep * fraction,
      false,
      Paint.from(base)
        ..color = color.withValues(alpha: 0.30)
        ..strokeWidth = stroke * 1.8
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, stroke * 0.6),
    );

    // Needle tip: a bright dot at the end of the sweep.
    final tipAngle = _start + _sweep * fraction;
    final tip = rect.center +
        Offset(math.cos(tipAngle), math.sin(tipAngle)) *
            (rect.width / 2);
    canvas.drawCircle(
        tip, stroke * 0.75, Paint()..color = color.withValues(alpha: 0.30));
    canvas.drawCircle(tip, stroke * 0.42, Paint()..color = Colors.white);
    canvas.drawCircle(tip, stroke * 0.26, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _DialPainter old) =>
      old.fraction != fraction || old.color != color || old.track != track;
}
