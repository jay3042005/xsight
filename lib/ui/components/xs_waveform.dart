import 'dart:math';
import 'package:flutter/material.dart';
import '../../core/theme/xs_colors.dart';

/// Animated waveform bars for lung sound recording.
class XSWaveform extends StatefulWidget {
  final bool active;
  final double height;
  final int barCount;

  const XSWaveform({
    super.key,
    required this.active,
    this.height = 64,
    this.barCount = 28,
  });

  @override
  State<XSWaveform> createState() => _XSWaveformState();
}

class _XSWaveformState extends State<XSWaveform>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  final _rng = Random();
  late List<double> _seeds;

  @override
  void initState() {
    super.initState();
    _seeds =
        List.generate(widget.barCount, (_) => _rng.nextDouble() * 2 * pi);
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    return SizedBox(
      height: widget.height,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, _) {
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: List.generate(widget.barCount, (i) {
              final t = _ctrl.value * 2 * pi + _seeds[i];
              final amp = widget.active
                  ? 0.4 + (sin(t) + 1) / 2 * 0.6
                  : 0.18 + sin(t) * 0.04;
              return Container(
                width: 4,
                height: widget.height * amp,
                decoration: BoxDecoration(
                  color: palette.textPrimary,
                  borderRadius: BorderRadius.circular(2),
                ),
              );
            }),
          );
        },
      ),
    );
  }
}
