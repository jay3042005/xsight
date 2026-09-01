import 'package:flutter/material.dart';

/// Fades + slides its child in once, whenever [trigger] changes identity
/// (pass a value that changes when new content should animate in, e.g. the
/// result object or its hashCode/timestamp).
class XSResultReveal extends StatefulWidget {
  final Widget child;
  final Object? trigger;
  final Duration duration;
  final Duration delay;

  const XSResultReveal({
    super.key,
    required this.child,
    required this.trigger,
    this.duration = const Duration(milliseconds: 420),
    this.delay = Duration.zero,
  });

  @override
  State<XSResultReveal> createState() => _XSResultRevealState();
}

class _XSResultRevealState extends State<XSResultReveal>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late Animation<double> _fade;
  late Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: widget.duration);
    _setupAnimations();
    _play();
  }

  void _setupAnimations() {
    _fade = CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic);
    _slide = Tween<Offset>(begin: const Offset(0, 0.06), end: Offset.zero)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));
  }

  Future<void> _play() async {
    _ctrl.reset();
    if (widget.delay > Duration.zero) {
      await Future.delayed(widget.delay);
      if (!mounted) return;
    }
    _ctrl.forward();
  }

  @override
  void didUpdateWidget(XSResultReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.trigger != widget.trigger) {
      _play();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(position: _slide, child: widget.child),
    );
  }
}
