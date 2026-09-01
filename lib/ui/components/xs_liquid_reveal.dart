import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/xs_colors.dart';
import '../../core/theme/xs_scale.dart';

/// Liquid-morph reveal that grows out of an on-screen anchor.
///
/// Collapsed, this widget draws nothing at all — the anchor it expands from
/// (the dashboard's START disc) is the only affordance, so the kiosk keeps one
/// unmistakable target instead of two. Opened, the panel grows from the
/// anchor's exact bounds to the full surface, and [child] fades in once the
/// frame is nearly full.
///
/// The panel is a container only: the caller supplies what appears inside it
/// (the kiosk supplies its radial cockpit) so the reveal and the navigation
/// stay independent.
class XSLiquidReveal extends StatefulWidget {
  /// Expanded when true. The parent owns this so the module's OK button, the
  /// space bar, and a finger on the anchor drive one identical state change.
  final bool isOpen;

  final VoidCallback onClose;

  /// Revealed inside the open panel.
  final Widget child;

  /// Hue the panel settles on — the kiosk passes the focused module's color.
  final Color accent;

  /// Widget the panel grows out of. Must be the anchor's own painted box, not a
  /// padded wrapper, or the first frame will not line up with it. When null (or
  /// not yet laid out) the panel expands from the centre of the surface.
  final GlobalKey? anchorKey;

  /// The anchor's own fill. The panel starts here and lerps to [accent], so the
  /// first frame is indistinguishable from the anchor it replaces.
  final Color originColor;

  /// Cross-fades out instead of collapsing back onto the anchor.
  ///
  /// The collapse only makes sense when the anchor is what the user is returning
  /// to. Launching a module replaces the whole surface, so shrinking the panel
  /// back into a disc first would animate towards something that is about to be
  /// gone. Set this for that case and the panel simply fades away.
  final bool fadeOutOnClose;

  /// How long the grow-out takes. Exposed so tests can sample fractions of the
  /// timeline without restating the number and silently drifting out of step
  /// with it.
  @visibleForTesting
  static const openDuration = Duration(milliseconds: 700);

  const XSLiquidReveal({
    super.key,
    required this.isOpen,
    required this.onClose,
    required this.accent,
    required this.child,
    this.anchorKey,
    this.originColor = XSColors.teal,
    this.fadeOutOnClose = false,
  });

  @override
  State<XSLiquidReveal> createState() => _XSLiquidRevealState();
}

class _XSLiquidRevealState extends State<XSLiquidReveal>
    with SingleTickerProviderStateMixin {
  /// 0 = anchor footprint, 1 = full-surface panel.
  late final AnimationController _morph = AnimationController(
    vsync: this,
    duration: XSLiquidReveal.openDuration,
    reverseDuration: const Duration(milliseconds: 480),
    value: widget.isOpen ? 1 : 0,
  );

  /// Opening easing, cubic-bezier(0.33, 0, 0.45, 1).
  ///
  /// Two failure modes to stay between. A front-loaded curve such as
  /// cubic-bezier(0.22, 1, 0.36, 1) is 98% travelled a quarter of the way in, so
  /// the disc appears to snap to full screen and only the tail settle is
  /// visible. Pushing the other way — a slow ease-in with a long decelerating
  /// tail — makes the whole thing feel sluggish, because most of the wall-clock
  /// time is spent creeping through the last few percent of travel where there
  /// is nothing left to see.
  ///
  /// This curve accelerates briskly off the disc, does its real growing through
  /// the middle, and lands with a short tail: ~140ms inside the final 5% rather
  /// than the ~290ms the previous pairing spent there. The perceived speed-up is
  /// mostly that recovered tail, not the 400ms taken off the duration.
  static const _ease = Cubic(0.33, 0, 0.45, 1);

  /// Closing runs the mirrored curve, not the same one backwards. Replaying a
  /// front-loaded ease in reverse spends its last frames at full speed, which
  /// reads as the panel snapping shut instead of settling onto the disc.
  late final Animation<double> _curved = CurvedAnimation(
    parent: _morph,
    curve: _ease,
    reverseCurve: const FlippedCurve(_ease),
  );

  /// Marks this widget's own box so the anchor can be measured into its
  /// coordinate space.
  final GlobalKey _selfKey = GlobalKey();

  /// The anchor's bounds in this widget's coordinates, captured when opening.
  /// Held for the whole animation: the anchor is typically unmounted or moving
  /// while the panel is open, so re-measuring mid-flight would jump.
  Rect? _origin;

  /// True while the current close is a cross-fade rather than a collapse. Held
  /// as state because it has to outlive the frame the close was requested on:
  /// the geometry must stay at full size for every frame until the controller
  /// reaches 0.
  bool _fadingOut = false;

  /// A cross-fade is a hand-off to the next screen, so it is over quickly — the
  /// collapse is a deliberate motion the user watches, this is not.
  static const _fadeOut = Duration(milliseconds: 220);

  @override
  void didUpdateWidget(XSLiquidReveal old) {
    super.didUpdateWidget(old);
    if (widget.isOpen == old.isOpen) return;
    if (widget.isOpen) {
      _origin = _measureAnchor();
      _fadingOut = false;
    } else {
      _fadingOut = widget.fadeOutOnClose;
    }
    if (MediaQuery.of(context).disableAnimations) {
      _morph.value = widget.isOpen ? 1 : 0;
    } else if (widget.isOpen) {
      _morph.forward();
    } else if (_fadingOut) {
      // animateBack, not reverse: this needs its own duration, and the curve is
      // a plain ease because there is no geometry to make feel physical.
      _morph.animateBack(0, duration: _fadeOut, curve: Curves.easeOut);
    } else {
      _morph.reverse();
    }
  }

  @override
  void dispose() {
    _morph.dispose();
    super.dispose();
  }

  /// The anchor's rect in this widget's coordinates, or null if it cannot be
  /// resolved (no key, not mounted, or not laid out yet).
  Rect? _measureAnchor() {
    final self = _selfKey.currentContext?.findRenderObject();
    final anchor = widget.anchorKey?.currentContext?.findRenderObject();
    if (self is! RenderBox || anchor is! RenderBox) return null;
    if (!self.hasSize || !anchor.hasSize) return null;
    return anchor.localToGlobal(Offset.zero, ancestor: self) & anchor.size;
  }

  @override
  Widget build(BuildContext context) {
    final s = XSScale.factor;

    return SizedBox.expand(
      key: _selfKey,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final full = Offset.zero & constraints.biggest;
          // Falling back to a centred circle still reads as a grow-out, just
          // without the visual tie to a specific button.
          final origin = _origin ??
              Rect.fromCenter(
                center: full.center,
                width: 200 * s,
                height: 200 * s,
              );

          return AnimatedBuilder(
            animation: _curved,
            builder: (context, _) {
              // Closed: draw nothing. No stray hit targets, and `child` stays
              // unmounted so its controllers do not tick unseen.
              if (_morph.status == AnimationStatus.dismissed) {
                return const SizedBox.shrink();
              }

              // Fading out: geometry is frozen at full size and opacity alone
              // carries the exit, so the panel hands over to the module screen
              // without appearing to retreat into a disc that is about to be
              // replaced anyway.
              final t = _fadingOut ? 1.0 : _curved.value;

              final stack = Stack(
                children: [
                  // Tapping outside dismisses. Below the panel in paint order,
                  // so it can never swallow a tap meant for the contents.
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: widget.onClose,
                      child: const SizedBox.shrink(),
                    ),
                  ),
                  // The panel always occupies the full surface; the *clip* is
                  // what animates. Growing a circular hole out of the anchor
                  // means the reveal starts as a true circle matching the START
                  // disc, and the contents are laid out once at their final
                  // size, so nothing reflows or rescales mid-flight.
                  Positioned.fromRect(
                    rect: full,
                    child: ClipPath(
                      clipper: RevealClipper(
                        origin: origin,
                        full: full,
                        t: t,
                      ),
                      child: _panel(full.size, origin, t, s),
                    ),
                  ),
                ],
              );

              if (!_fadingOut) return stack;
              return IgnorePointer(
                child: Opacity(opacity: _morph.value, child: stack),
              );
            },
          );
        },
      ),
    );
  }

  Widget _panel(Size size, Rect origin, double t, double s) {
    // The disc's own teal for the first frames — while the clip is still disc
    // sized there is nothing to distinguish the panel from the button it grew
    // out of — resolving to the accent-tinted white the cockpit paints, so the
    // handover to the menu's own background is seamless.
    final fill = Color.lerp(
      widget.originColor,
      Color.lerp(Colors.white, widget.accent, 0.10),
      // Ahead of the growth so the colour has already arrived by the time the
      // circle is large enough for a wash of teal to look like a mistake.
      _delayed(t, 0.05),
    )!;

    return Stack(
      children: [
        Positioned.fill(child: ColoredBox(color: fill)),

        // The START label, held under the growing circle for the first stretch.
        // Without it the disc's face vanishes the instant it is tapped, which is
        // what made the expansion hard to follow: there was no longer anything
        // recognisable to watch grow.
        if (t < 0.45)
          Positioned.fromRect(
            rect: origin,
            child: Center(
              child: Opacity(
                opacity: 1 - _delayed(t, 0.2),
                child: Icon(
                  Icons.touch_app_rounded,
                  size: origin.shortestSide * 0.30,
                  color: Colors.white,
                ),
              ),
            ),
          ),

        // Revealed content, always laid out at the panel's final size, so its
        // internals never reflow and the clip alone does the revealing. Starts
        // while the circle is still growing: overlapping the two makes the
        // reveal feel like one motion instead of grow-then-populate, and it
        // means the cockpit is already legible as the panel lands.
        Positioned.fill(
          child: IgnorePointer(
            ignoring: !widget.isOpen,
            child: Opacity(
              opacity: _delayed(t, 0.42),
              child: widget.child,
            ),
          ),
        ),

        // Close affordance. Top-right, clear of the radial cockpit's own
        // footer, and only hittable once the panel is actually open.
        if (t > 0.6)
          Positioned(
            top: 0,
            right: 0,
            child: Opacity(
              opacity: _delayed(t, 0.6),
              child: IconButton(
                tooltip: 'Close menu',
                iconSize: 26 * s,
                onPressed: widget.isOpen ? widget.onClose : null,
                icon: const Icon(Icons.close_rounded),
                color: XSColors.slate,
              ),
            ),
          ),
      ],
    );
  }

  /// Re-maps [t] so it only starts moving after [start] of the timeline.
  double _delayed(double t, double start) =>
      ((t - start) / (1 - start)).clamp(0.0, 1.0);
}

/// Circular reveal: a hole that opens out of [origin] until it covers [full].
///
/// The clip is a circle for the entire animation, which is what makes the panel
/// look like it is genuinely swelling out of the round START disc rather than a
/// rectangle appearing over it.
///
/// Deliberately no rounded-rectangle phase at the end. The panel is full-bleed,
/// so rounded corners would only expose the dashboard behind them once at rest,
/// and lerping a covering circle towards the surface rect pulls the clip back
/// off the corners — the reveal would visibly pinch inward just as it finishes.
@visibleForTesting
class RevealClipper extends CustomClipper<Path> {
  /// Anchor bounds, in the clipped box's coordinates.
  final Rect origin;

  /// The clipped box itself.
  final Rect full;

  /// Eased 0..1 progress.
  final double t;

  const RevealClipper({
    required this.origin,
    required this.full,
    required this.t,
  });

  /// Radius that covers [full] from [origin]'s centre: the distance to the
  /// farthest corner, plus a hair so the boundary never lands exactly on it.
  double get coverRadius {
    final c = origin.center;
    return [
          full.topLeft,
          full.topRight,
          full.bottomLeft,
          full.bottomRight,
        ].map((corner) => (corner - c).distance).reduce(math.max) +
        1;
  }

  @override
  Path getClip(Size size) {
    final from = origin.shortestSide / 2;
    final radius = from + (coverRadius - from) * t;
    return Path()
      ..addOval(Rect.fromCircle(center: origin.center, radius: radius));
  }

  @override
  bool shouldReclip(RevealClipper old) =>
      old.t != t || old.origin != origin || old.full != full;
}
