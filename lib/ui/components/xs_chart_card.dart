import 'package:flutter/material.dart';
import '../../core/theme/xs_colors.dart';
import '../../core/theme/xs_scale.dart';
import 'xs_card.dart';

class XSChartPoint {
  final double x;
  final double y;
  const XSChartPoint(this.x, this.y);
}

/// Live trend card — smoothed line, gradient area fill, glowing live endpoint.
///
/// Custom-painted rather than `fl_chart` because these plot a rolling sensor
/// window with no axes, legend, or touch interaction; the dependency would buy
/// nothing here.
class XSChartCard extends StatelessWidget {
  final String title;
  final List<XSChartPoint> data;
  final String? subtitle;

  /// Line/fill tint. Defaults to the ambient (or module) accent.
  final Color? color;

  /// Trailing widget in the header — usually the current value.
  final Widget? trailing;

  const XSChartCard({
    super.key,
    required this.title,
    required this.data,
    this.subtitle,
    this.color,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    final s = XSScale.factor;
    final c = color ?? palette.accent;

    return XSCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: palette.textPrimary,
                      ),
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle!,
                        style: TextStyle(
                          fontSize: 13,
                          color: palette.textSecondary,
                        ),
                      ),
                  ],
                ),
              ),
              ?trailing,
            ],
          ),
          SizedBox(height: 12 * s),
          Expanded(
            child: RepaintBoundary(
              child: SizedBox(
                width: double.infinity,
                child: CustomPaint(
                  painter: _LineChartPainter(
                    data: data,
                    stroke: c,
                    grid: palette.divider,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LineChartPainter extends CustomPainter {
  final List<XSChartPoint> data;
  final Color stroke;
  final Color grid;

  _LineChartPainter({
    required this.data,
    required this.stroke,
    required this.grid,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (data.length < 2) return;

    // Dashed baselines read as instrument gridlines rather than table rules.
    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1.0;
    for (int i = 1; i < 4; i++) {
      final y = size.height * i / 4;
      for (double x = 0; x < size.width; x += 8) {
        canvas.drawLine(Offset(x, y), Offset(x + 4, y), gridPaint);
      }
    }

    final minY = data.map((e) => e.y).reduce((a, b) => a < b ? a : b);
    final maxY = data.map((e) => e.y).reduce((a, b) => a > b ? a : b);
    final range = (maxY - minY).abs() < 0.001 ? 1 : (maxY - minY);

    double xAt(int i) => i / (data.length - 1) * size.width;
    double yAt(int i) =>
        size.height -
        ((data[i].y - minY) / range) * size.height * 0.85 -
        size.height * 0.075;

    // Quadratic midpoint smoothing: cheap, no overshoot past data extremes,
    // which matters when the plotted value is a vital sign.
    final path = Path()..moveTo(xAt(0), yAt(0));
    for (int i = 1; i < data.length; i++) {
      final px = xAt(i - 1), py = yAt(i - 1);
      final cx = xAt(i), cy = yAt(i);
      path.quadraticBezierTo(px, py, (px + cx) / 2, (py + cy) / 2);
    }
    path.lineTo(xAt(data.length - 1), yAt(data.length - 1));

    // Area fill under the line.
    final fill = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            stroke.withValues(alpha: 0.28),
            stroke.withValues(alpha: 0.0),
          ],
        ).createShader(Offset.zero & size),
    );

    final linePaint = Paint()
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // Blurred underlay gives the trace a soft emissive edge.
    canvas.drawPath(
      path,
      Paint.from(linePaint)
        ..color = stroke.withValues(alpha: 0.35)
        ..strokeWidth = 6
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );
    canvas.drawPath(path, Paint.from(linePaint)..color = stroke);

    // Live endpoint: halo + dot, marking "this is now".
    final end = Offset(xAt(data.length - 1), yAt(data.length - 1));
    canvas.drawCircle(
      end,
      9,
      Paint()..color = stroke.withValues(alpha: 0.22),
    );
    canvas.drawCircle(end, 4.5, Paint()..color = stroke);
    canvas.drawCircle(end, 2.0, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant _LineChartPainter old) =>
      old.data != data || old.stroke != stroke || old.grid != grid;
}
