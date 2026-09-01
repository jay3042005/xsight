import 'dart:ui' show PlatformDispatcher;

/// Global UI scale for the XSIGHT design system.
///
/// XSIGHT is a walk-up kiosk: readouts must be legible at arm's length and
/// touch targets must be hittable without aiming. We derive one multiplier
/// from the window's shortest side so phones stay compact while tablet and
/// desktop kiosk surfaces scale up together.
class XSScale {
  XSScale._();

  /// Logical (device-independent) shortest side of the primary window.
  static double get shortestSide {
    final views = PlatformDispatcher.instance.views;
    if (views.isEmpty) return 0;
    final view = views.first;
    final ratio = view.devicePixelRatio;
    if (ratio <= 0) return 0;
    return (view.physicalSize / ratio).shortestSide;
  }

  /// Multiplier applied to component dimensions and global text.
  ///
  /// Buckets rather than a continuous ramp so a window resize can't produce
  /// half-pixel type. `1.0` on phones, up to `1.35` on large kiosk panels —
  /// past that, dense staff screens stop fitting on a 768px-tall panel.
  static double get factor {
    final side = shortestSide;
    if (side <= 0) return 1.0; // Pre-first-frame: no metrics yet.
    if (side >= 900) return 1.35;
    if (side >= 700) return 1.25;
    if (side >= 600) return 1.15;
    return 1.0;
  }

  /// True when running on a surface large enough for the kiosk layout.
  static bool get isKiosk => factor > 1.0;

  /// Convenience: scale an arbitrary dimension.
  static double of(double value) => value * factor;
}
