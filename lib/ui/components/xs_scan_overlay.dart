import 'package:flutter/material.dart';

import '../../core/theme/xs_colors.dart';

/// Full-bleed scanning animation shown over an image while the backend is
/// analyzing it (chest X-ray screening, etc). Purely decorative — wrapped
/// in [IgnorePointer] so it never intercepts touches meant for the image
/// below it.
///
/// Layers (back to front): breathing dark tint, a technical scan grid that
/// brightens near the sweep line, staggered "detection reticles" blinking
/// on at plausible regions of interest, corner viewfinder brackets, the
/// sweep line itself (with a soft trailing glow), and a pulsing status
/// label.
class XSScanOverlay extends StatefulWidget {
  final String label;
  final Color lineColor;

  const XSScanOverlay({
    super.key,
    this.label = 'Analyzing...',
    this.lineColor = XSColors.moduleXray,
  });

  @override
  State<XSScanOverlay> createState() => _XSScanOverlayState();
}

class _XSScanOverlayState extends State<XSScanOverlay>
    with TickerProviderStateMixin {
  late final AnimationController _sweep;
  late final AnimationController _breathe;
  late final AnimationController _markers;

  /// Fractional (0..1) positions roughly over lung fields / mediastinum on
  /// a frontal chest radiograph — purely decorative, not real detections.
  static const List<Offset> _markerSpots = [
    Offset(0.30, 0.26),
    Offset(0.70, 0.26),
    Offset(0.50, 0.40),
    Offset(0.26, 0.62),
    Offset(0.74, 0.62),
    Offset(0.50, 0.76),
  ];

  @override
  void initState() {
    super.initState();
    _sweep = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat();
    _breathe = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1300),
    )..repeat(reverse: true);
    _markers = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3600),
    )..repeat();
  }

  @override
  void dispose() {
    _sweep.dispose();
    _breathe.dispose();
    _markers.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Breathing dark tint so the sweep line reads clearly on any
            // underlying image, light or dark.
            AnimatedBuilder(
              animation: _breathe,
              builder: (context, _) => Container(
                color: Colors.black.withValues(alpha: 0.10 + _breathe.value * 0.10),
              ),
            ),
            // Technical scan grid — faint horizontal lines that brighten
            // near the sweep line, like a readout being scanned.
            AnimatedBuilder(
              animation: _sweep,
              builder: (context, _) => CustomPaint(
                painter: _ScanGridPainter(
                  progress: Curves.easeInOut.transform(_sweep.value),
                  color: widget.lineColor,
                ),
              ),
            ),
            // Staggered "AI detection" reticles blinking on across a few
            // plausible regions of interest.
            AnimatedBuilder(
              animation: _markers,
              builder: (context, _) => LayoutBuilder(
                builder: (context, constraints) {
                  return Stack(
                    children: List.generate(_markerSpots.length, (i) {
                      final spot = _markerSpots[i];
                      final delay = i / _markerSpots.length;
                      final local = (_markers.value - delay) % 1.0;
                      const window = 0.32; // fraction of the loop visible
                      if (local > window) return const SizedBox.shrink();
                      final t = local / window; // 0..1 within visible window
                      final fadeIn =
                          Curves.easeOut.transform((t / 0.4).clamp(0.0, 1.0));
                      final fadeOut = t > 0.6
                          ? 1.0 -
                              Curves.easeIn
                                  .transform(((t - 0.6) / 0.4).clamp(0.0, 1.0))
                          : 1.0;
                      final opacity = (fadeIn * fadeOut).clamp(0.0, 1.0);
                      final scale = 0.6 +
                          0.4 * Curves.easeOutBack.transform(fadeIn.clamp(0.0, 1.0));
                      return Positioned(
                        left: spot.dx * constraints.maxWidth - 14,
                        top: spot.dy * constraints.maxHeight - 14,
                        child: Opacity(
                          opacity: opacity,
                          child: Transform.scale(
                            scale: scale,
                            child: _DetectionReticle(color: widget.lineColor),
                          ),
                        ),
                      );
                    }),
                  );
                },
              ),
            ),
            const _ScanCorners(),
            AnimatedBuilder(
              animation: _sweep,
              builder: (context, _) {
                return LayoutBuilder(
                  builder: (context, constraints) {
                    final t = Curves.easeInOut.transform(_sweep.value);
                    final top = t * constraints.maxHeight;
                    return Stack(
                      children: [
                        // Soft trailing glow band behind the sharp line.
                        Positioned(
                          top: (top - 30).clamp(-30.0, constraints.maxHeight),
                          left: 0,
                          right: 0,
                          child: Container(
                            height: 30,
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  widget.lineColor.withValues(alpha: 0),
                                  widget.lineColor.withValues(alpha: 0.14),
                                ],
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          top: top - 1.5,
                          left: 0,
                          right: 0,
                          child: Container(
                            height: 3,
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  widget.lineColor.withValues(alpha: 0),
                                  widget.lineColor.withValues(alpha: 0.95),
                                  widget.lineColor.withValues(alpha: 0),
                                ],
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: widget.lineColor.withValues(alpha: 0.6),
                                  blurRadius: 14,
                                  spreadRadius: 2,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                );
              },
            ),
            Positioned(
              bottom: 16,
              left: 0,
              right: 0,
              child: Center(
                child: _PulsingLabel(text: widget.label, breathe: _breathe),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Faint horizontal scanlines that glow brighter near the current sweep
/// position, giving a "reading a strip of the image" readout feel.
class _ScanGridPainter extends CustomPainter {
  final double progress; // 0..1, fractional vertical position of the sweep
  final Color color;

  _ScanGridPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    const spacing = 22.0;
    final sweepY = progress * size.height;
    final linePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.6;
    for (double y = 0; y < size.height; y += spacing) {
      final dist = (y - sweepY).abs();
      final glow = (1 - (dist / 90)).clamp(0.0, 1.0);
      linePaint.color = color.withValues(alpha: 0.03 + glow * 0.12);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), linePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _ScanGridPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.color != color;
}

/// Small crosshair-in-ring marker used for the blinking "detection" spots.
class _DetectionReticle extends StatelessWidget {
  final Color color;
  const _DetectionReticle({required this.color});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 28,
      height: 28,
      child: CustomPaint(
        painter: _ReticlePainter(color: color),
      ),
    );
  }
}

class _ReticlePainter extends CustomPainter {
  final Color color;
  _ReticlePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);

    final ringPaint = Paint()
      ..color = color.withValues(alpha: 0.9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    canvas.drawCircle(center, size.width / 2 - 4, ringPaint);

    final tickPaint = Paint()
      ..color = color.withValues(alpha: 0.9)
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;
    const tickLen = 5.0;
    canvas.drawLine(
        Offset(center.dx, 0), Offset(center.dx, tickLen), tickPaint);
    canvas.drawLine(Offset(center.dx, size.height),
        Offset(center.dx, size.height - tickLen), tickPaint);
    canvas.drawLine(
        Offset(0, center.dy), Offset(tickLen, center.dy), tickPaint);
    canvas.drawLine(Offset(size.width, center.dy),
        Offset(size.width - tickLen, center.dy), tickPaint);

    canvas.drawCircle(center, 1.6, Paint()..color = color.withValues(alpha: 0.9));
  }

  @override
  bool shouldRepaint(covariant _ReticlePainter oldDelegate) => false;
}

class _ScanCorners extends StatelessWidget {
  const _ScanCorners();

  @override
  Widget build(BuildContext context) {
    Widget corner({required bool top, required bool left}) => Positioned(
          top: top ? 10 : null,
          bottom: top ? null : 10,
          left: left ? 10 : null,
          right: left ? null : 10,
          child: SizedBox(
            width: 26,
            height: 26,
            child: CustomPaint(
              painter: _CornerPainter(top: top, left: left),
            ),
          ),
        );
    return Stack(
      children: [
        corner(top: true, left: true),
        corner(top: true, left: false),
        corner(top: false, left: true),
        corner(top: false, left: false),
      ],
    );
  }
}

class _CornerPainter extends CustomPainter {
  final bool top;
  final bool left;

  _CornerPainter({required this.top, required this.left});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.9)
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final path = Path();
    if (top && left) {
      path.moveTo(0, size.height);
      path.lineTo(0, 0);
      path.lineTo(size.width, 0);
    } else if (top && !left) {
      path.moveTo(0, 0);
      path.lineTo(size.width, 0);
      path.lineTo(size.width, size.height);
    } else if (!top && left) {
      path.moveTo(0, 0);
      path.lineTo(0, size.height);
      path.lineTo(size.width, size.height);
    } else {
      path.moveTo(size.width, 0);
      path.lineTo(size.width, size.height);
      path.lineTo(0, size.height);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _CornerPainter oldDelegate) => false;
}

class _PulsingLabel extends StatelessWidget {
  final String text;
  final Animation<double> breathe;
  const _PulsingLabel({required this.text, required this.breathe});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: breathe,
      builder: (context, _) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55 + breathe.value * 0.15),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 13,
              height: 13,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation(Colors.white),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              text,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
