import 'package:flutter/material.dart';

/// Flutter port of the shadcn/ui "ShiningText" component.
///
/// A text sweep where a bright band travels across otherwise-muted glyphs —
/// used as the assistant's "thinking" indicator. The React original animates
/// `background-position` over a fixed gradient; here the equivalent is a
/// [ShaderMask] whose gradient is translated from +200% to −200% on a linear
/// loop, which reproduces the identical visual.
class XSShiningText extends StatefulWidget {
  final String text;

  /// Muted colour the text sits in between sweeps.
  final Color base;

  /// The travelling highlight band.
  final Color shine;

  final TextStyle? style;

  /// One full left-to-right sweep.
  final Duration period;

  const XSShiningText({
    super.key,
    required this.text,
    this.base = const Color(0xFF94A3B8),
    this.shine = Colors.white,
    this.style,
    this.period = const Duration(milliseconds: 2000),
  });

  @override
  State<XSShiningText> createState() => _XSShiningTextState();
}

class _XSShiningTextState extends State<XSShiningText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: widget.period,
  )..repeat();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
  // AnimatedBuilder is load-bearing: without it nothing subscribes to the
  // controller, `_ctrl.value` is read once at t=0 and the sweep never runs.
  return AnimatedBuilder(
  animation: _ctrl,
  builder: (context, _) {
  // Same ramp as bg-[linear-gradient(110deg,#404040,35%,#fff,50%,
  // #404040,75%,#404040)] — muted, muted, highlight mid, muted, muted.
  final gradient = LinearGradient(
  begin: Alignment.centerLeft,
  end: Alignment.centerRight,
  colors: [
  widget.base,
  widget.base,
  widget.shine,
  widget.base,
  widget.base,
  ],
  stops: const [0.0, 0.35, 0.5, 0.75, 1.0],
  // background-position 200% -> -200%: slide the whole gradient two
  // viewport-widths out, then two back through.
  transform: _SlideGradientTransform(offset: 2 - 4 * _ctrl.value),
  );

  return ShaderMask(
  blendMode: BlendMode.srcIn,
  shaderCallback: (bounds) => gradient.createShader(bounds),
  child: Text(widget.text, style: widget.style),
  );
  },
  );
  }
}

class _SlideGradientTransform extends GradientTransform {
  final double offset;

  const _SlideGradientTransform({required this.offset});

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) =>
      Matrix4.translationValues(bounds.width * offset, 0, 0);
}
