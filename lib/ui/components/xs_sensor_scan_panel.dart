import 'package:flutter/material.dart';

import '../../core/theme/xs_colors.dart';
import '../../core/theme/xs_scale.dart';
import '../../core/theme/xs_spacing.dart';
import 'xs_button.dart';
import 'xs_card.dart';

/// Where a guided sensor reading has got to.
enum XSScanPhase {
  /// Sensor armed, nothing on it yet.
  guide,

  /// Contact made, but not yet a complete reading.
  acquiring,

  /// A complete reading is coming in; the timed window is running.
  scanning,

  /// The window elapsed and we are waiting for the module to confirm.
  ///
  /// Kept distinct from [scanning] because the module owns the decision: its
  /// clock and this countdown are separate, and claiming a result the module has
  /// not sent would be inventing one.
  finishing,
}

/// The guided-reading surface for a sensor station.
///
/// Replaces the modal "place your finger" prompt. A dialog was the wrong shape
/// for this: it covered the screen the reading appears on, it needed a Cancel
/// button as its only escape, and on a kiosk driven by hardware buttons a modal
/// is one more thing that can be left up with nothing behind it. This lives in
/// the station instead, so the coaching, the countdown and the result all occupy
/// the same place.
///
/// Presentational only — the owning screen decides the phase from what the module
/// reports, so the panel cannot claim progress the hardware has not made.
///
/// Two things keep it usable on a landscape phone's ~240 px slot:
///   - a compact layout (smaller art and type, tighter spacing) chosen by the
///     slot's height, so the guided content stays near 1:1 scale and legible;
///   - the CANCEL button lives OUTSIDE the FittedBox, so no geometry can ever
///     scale its 52 px touch target down to the ~30 px it used to become —
///     which is what made cancel feel unclickable on phones.
class XSSensorScanPanel extends StatelessWidget {
  final XSScanPhase phase;

  /// The animated guide for this sensor (finger, thermometer).
  final Widget Function(double size) guide;

  /// Shown while waiting for contact.
  final String guideMessage;

  /// Shown once there is contact but no complete reading yet.
  final String acquiringMessage;

  /// Countdown, in seconds, and the window it counts down from.
  final int secondsLeft;
  final int totalSeconds;

  final Color accent;

  /// Live values to show during the timed window. Empty until there are any.
  final List<({String label, String value, String unit})> live;

  /// Abandon the reading. Wired to the same stop command the module expects.
  final VoidCallback? onCancel;

  const XSSensorScanPanel({
    super.key,
    required this.phase,
    required this.guide,
    required this.guideMessage,
    required this.acquiringMessage,
    required this.secondsLeft,
    required this.totalSeconds,
    required this.accent,
    this.live = const [],
    this.onCancel,
  });

  bool get _timed => phase == XSScanPhase.scanning || phase == XSScanPhase.finishing;

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    final s = XSScale.factor;

    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 520 * s),
        child: XSCard(
          padding: EdgeInsets.all(XSSpacing.xl * s),
          glow: accent,
          borderColor: accent.withValues(alpha: 0.3),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxHeight.isFinite &&
                  constraints.maxHeight < 380 * s;
              final art = (compact ? 116.0 : 190.0) * s;

              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Guided content: shrinks only if even the compact layout
                  // cannot fit (very short slots), as a last resort.
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_timed)
                            _ring(palette, s, art, compact)
                          else
                            SizedBox(
                              width: art,
                              height: art,
                              child: guide(art),
                            ),
                          SizedBox(
                            height: (compact ? XSSpacing.sm : XSSpacing.lg) * s,
                          ),
                          Text(
                            switch (phase) {
                              XSScanPhase.guide => guideMessage,
                              XSScanPhase.acquiring => acquiringMessage,
                              XSScanPhase.scanning => 'Reading — hold still',
                              XSScanPhase.finishing => 'Finishing up',
                            },
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: compact ? 17.0 : 20.0,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.3,
                              color: palette.textPrimary,
                            ),
                          ),
                          SizedBox(height: (compact ? 2.0 : 6.0) * s),
                          Text(
                            switch (phase) {
                              XSScanPhase.guide =>
                                'The station starts on its own — there is no button to press.',
                              XSScanPhase.acquiring =>
                                'Keep still. The reading starts once both values come through.',
                              XSScanPhase.scanning =>
                                'Stay as you are until the countdown finishes.',
                              XSScanPhase.finishing => 'Saving your reading.',
                            },
                            textAlign: TextAlign.center,
                            maxLines: compact ? 1 : 3,
                            overflow: compact ? TextOverflow.ellipsis : null,
                            style: TextStyle(
                              fontSize: compact ? 12.5 : 14.0,
                              height: 1.45,
                              color: palette.textSecondary,
                            ),
                          ),
                          if (_timed && live.isNotEmpty) ...[
                            SizedBox(height: XSSpacing.sm * s),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                for (final r in live) ...[
                                  _liveValue(palette, s, r, compact),
                                  if (r != live.last)
                                    SizedBox(width: XSSpacing.xl * s),
                                ],
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  // CANCEL only once there is something to abandon. In the
                  // guide phase nothing is running — a CANCEL there resets
                  // to the state the user is already in, which reads as a
                  // dead button (exactly what it looked like on setups with
                  // no ESP32 attached, where the panel never leaves guide).
                  // Leaving the station is hardware BACK / edge swipe.
                  if (onCancel != null && phase != XSScanPhase.guide) ...[
                    SizedBox(height: XSSpacing.md * s),
                    // Fixed width and natural height: this button is NOT
                    // inside the FittedBox above, so its 52 px touch target
                    // survives every geometry — including the compact phone
                    // layout that used to scale it out of reach.
                    XSButton(
                      label: 'CANCEL',
                      icon: Icons.close,
                      height: 52,
                      width: (compact ? 240.0 : 280.0) * s,
                      onPressed: onCancel,
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// Countdown ring. Empties as the window runs down, so the remaining time is
  /// readable from across the room without reading the number.
  Widget _ring(XSPalette palette, double s, double size, bool compact) {
    final total = totalSeconds <= 0 ? 1 : totalSeconds;
    final elapsed = (total - secondsLeft).clamp(0, total);
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox(
            width: size,
            height: size,
            child: CircularProgressIndicator(
              // Indeterminate once the window is up: the module has not confirmed
              // yet, and a full ring sitting still would read as finished.
              value: phase == XSScanPhase.finishing ? null : elapsed / total,
              strokeWidth: (compact ? 7.0 : 10.0) * s,
              backgroundColor: palette.divider,
              valueColor: AlwaysStoppedAnimation(accent),
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                phase == XSScanPhase.finishing ? '—' : '$secondsLeft',
                style: TextStyle(
                  fontSize: compact ? 38.0 : 54.0,
                  fontWeight: FontWeight.w900,
                  height: 1,
                  letterSpacing: -2,
                  color: palette.textPrimary,
                ),
              ),
              SizedBox(height: 2 * s),
              Text(
                'SECONDS',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.4,
                  color: palette.textSecondary,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _liveValue(
    XSPalette palette,
    double s,
    ({String label, String value, String unit}) r,
    bool compact,
  ) {
    return Column(
      children: [
        Text(
          r.label,
          style: TextStyle(
            fontSize: compact ? 10.0 : 11.0,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.2,
            color: palette.textSecondary,
          ),
        ),
        SizedBox(height: 4 * s),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              r.value,
              style: TextStyle(
                fontSize: compact ? 26.0 : 34.0,
                fontWeight: FontWeight.w900,
                height: 1,
                letterSpacing: -1,
                color: XSColors.slate == accent ? palette.textPrimary : accent,
              ),
            ),
            Padding(
              padding: EdgeInsets.only(left: 3 * s, bottom: 3 * s),
              child: Text(
                r.unit,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: palette.textSecondary,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
