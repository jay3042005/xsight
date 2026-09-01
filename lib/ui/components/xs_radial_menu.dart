import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/xs_colors.dart';
import '../../core/theme/xs_radius.dart';
import '../../core/theme/xs_scale.dart';
import '../../core/theme/xs_shadows.dart';
import '../../core/theme/xs_spacing.dart';
import 'xs_button.dart';
import 'xs_chip.dart';

/// One module in [XSRadialMenu].
typedef XSRadialMenuItem = ({
  IconData icon,
  String label,
  String sub,
  String tag,
  String sensor,
  List<String> details,
  Color color,
});

/// Radial command cockpit: module cards orbit an ellipse, the focused one is
/// pinned to the top of the arc, and a central HUD describes it.
///
/// Selection is owned by the parent because the kiosk drives this from the
/// XSIGHT module's physical UP / DOWN / OK buttons as well as from touch.
/// Rotating the orbit (rather than moving a highlight) means the focused module
/// is always in the same place on screen, which is what makes the hardware
/// buttons predictable for a walk-up user.
class XSRadialMenu extends StatefulWidget {
  final List<XSRadialMenuItem> items;
  final int selectedIndex;
  final ValueChanged<int> onSelectIndex;
  final VoidCallback onLaunch;

  /// Optional strip pinned under the cockpit — the kiosk puts the hardware key
  /// guide here so the module's buttons are discoverable while the menu is up.
  final Widget? footer;

  const XSRadialMenu({
    super.key,
    required this.items,
    required this.selectedIndex,
    required this.onSelectIndex,
    required this.onLaunch,
    this.footer,
  });

  @override
  State<XSRadialMenu> createState() => _XSRadialMenuState();
}

class _XSRadialMenuState extends State<XSRadialMenu>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 3),
  );

  @override
  void initState() {
    super.initState();
    // A repeating radar sweep on a kiosk that idles for hours is a real power
    // draw, so honour the platform's reduce-motion setting.
    if (!WidgetsBinding.instance.platformDispatcher.accessibilityFeatures
        .disableAnimations) {
      _pulse.repeat();
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    final s = XSScale.factor;
    final total = widget.items.length;
    final activeItem = widget.items[widget.selectedIndex.clamp(0, total - 1)];
    final activeColor = activeItem.color;

    return Column(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final w = constraints.maxWidth;
              final h = constraints.maxHeight;
              final isWide = w >= 800;

              final rx = isWide ? w * 0.40 : w * 0.43;
              final ry = isWide ? h * 0.36 : h * 0.30;
              final cx = w / 2;
              final cy = h / 2;

              return Stack(
                alignment: Alignment.center,
                children: [
                  // 1. Radar background canvas.
                  RepaintBoundary(
                    child: AnimatedBuilder(
                      animation: _pulse,
                      builder: (context, _) {
                        return CustomPaint(
                          size: Size(w, h),
                          painter: _RadialCockpitPainter(
                            cx: cx,
                            cy: cy,
                            rx: rx,
                            ry: ry,
                            activeColor: activeColor,
                            pulseValue: _pulse.value,
                            palette: palette,
                            totalNodes: total,
                            selectedIndex: widget.selectedIndex,
                          ),
                        );
                      },
                    ),
                  ),

                  // 2. Central HUD telemetry spotlight.
                  Center(
                    child: _hud(palette, activeItem, activeColor, isWide, s),
                  ),

                  // 3. Orbital node cards.
                  for (int i = 0; i < total; i++)
                    _orbitalNode(
                      palette: palette,
                      index: i,
                      total: total,
                      cx: cx,
                      cy: cy,
                      rx: rx,
                      ry: ry,
                      item: widget.items[i],
                    ),
                ],
              );
            },
          ),
        ),
        if (widget.footer != null)
          Padding(
            padding: EdgeInsets.only(top: XSSpacing.xs * s),
            child: widget.footer,
          ),
      ],
    );
  }

  Widget _hud(
    XSPalette palette,
    XSRadialMenuItem item,
    Color activeColor,
    bool isWide,
    double s,
  ) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      width: (isWide ? 440 : 320) * s,
      padding: EdgeInsets.all(XSSpacing.lg * s),
      decoration: BoxDecoration(
        color: palette.surface.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(XSRadius.xl),
        border: Border.all(color: activeColor.withValues(alpha: 0.6), width: 2),
        boxShadow: [
          ...XSShadows.glow(activeColor, intensity: 0.9),
          ...XSShadows.soft(palette),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          XSChip(label: item.tag, color: activeColor),
          SizedBox(height: XSSpacing.sm * s),

          // Icon + title.
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 56 * s,
                height: 56 * s,
                decoration: BoxDecoration(
                  color: activeColor.withValues(alpha: 0.18),
                  shape: BoxShape.circle,
                ),
                child: Icon(item.icon, size: 30 * s, color: activeColor),
              ),
              SizedBox(width: 12 * s),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.label,
                      style: TextStyle(
                        fontSize: 23,
                        fontWeight: FontWeight.w800,
                        color: palette.textPrimary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      item.sub,
                      style: TextStyle(
                        fontSize: 14,
                        color: palette.textSecondary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: XSSpacing.xs * s),

          // Sensor telemetry.
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.sensors, size: 16 * s, color: activeColor),
              SizedBox(width: 4 * s),
              Flexible(
                child: Text(
                  item.sensor,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: activeColor,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          SizedBox(height: XSSpacing.sm * s),

          // Capabilities.
          for (final detail in item.details.take(2))
            Padding(
              padding: EdgeInsets.only(bottom: 4 * s),
              child: Row(
                children: [
                  Container(
                    width: 6 * s,
                    height: 6 * s,
                    decoration: BoxDecoration(
                      color: activeColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  SizedBox(width: 8 * s),
                  Expanded(
                    child: Text(
                      detail,
                      style: TextStyle(
                        fontSize: 13,
                        color: palette.textPrimary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          SizedBox(height: XSSpacing.md * s),

          XSButton(
            label: 'LAUNCH MODULE',
            icon: Icons.play_arrow_rounded,
            color: activeColor,
            width: double.infinity,
            onPressed: widget.onLaunch,
          ),
        ],
      ),
    );
  }

  Widget _orbitalNode({
    required XSPalette palette,
    required int index,
    required int total,
    required double cx,
    required double cy,
    required double rx,
    required double ry,
    required XSRadialMenuItem item,
  }) {
    final step = (2 * math.pi) / total;
    // Offsetting by the selection keeps the focused node at the top of the arc,
    // so the orbit rotates under a fixed focus point.
    final angle = -math.pi / 2 + (index - widget.selectedIndex) * step;
    final nx = cx + rx * math.cos(angle);
    final ny = cy + ry * math.sin(angle);

    final isSelected = index == widget.selectedIndex;
    final itemColor = item.color;
    final s = XSScale.factor;

    // Kiosk-sized: label + number + icon must be readable across the room, and
    // the whole card is a touch target.
    final cardWidth = (isSelected ? 268.0 : 240.0) * s;
    final cardHeight = (isSelected ? 64.0 : 58.0) * s;

    return AnimatedPositioned(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
      left: nx - (cardWidth / 2),
      top: ny - (cardHeight / 2),
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 280),
        opacity: isSelected ? 1.0 : 0.92,
        child: AnimatedScale(
          duration: const Duration(milliseconds: 280),
          scale: isSelected ? 1.05 : 0.96,
          child: Semantics(
            button: true,
            selected: isSelected,
            label: item.label,
            child: GestureDetector(
              // First tap focuses, second launches — the same two-step the
              // hardware buttons enforce, so touch can't skip the HUD preview.
              onTap: () => isSelected
                  ? widget.onLaunch()
                  : widget.onSelectIndex(index),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 280),
                width: cardWidth,
                height: cardHeight,
                padding: EdgeInsets.symmetric(horizontal: 12 * s),
                decoration: BoxDecoration(
                  color: isSelected ? itemColor : palette.surface,
                  borderRadius: BorderRadius.circular(XSRadius.lg),
                  border: Border.all(
                    color: isSelected ? itemColor : palette.divider,
                    width: isSelected ? 2.5 : 1.5,
                  ),
                  boxShadow: isSelected
                      ? XSShadows.glow(itemColor, intensity: 0.8)
                      : XSShadows.soft(palette),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 34 * s,
                      height: 34 * s,
                      decoration: BoxDecoration(
                        color: isSelected
                            ? Colors.white.withValues(alpha: 0.25)
                            : itemColor.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(9 * s),
                      ),
                      child: Center(
                        child: Text(
                          '0${index + 1}',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w900,
                            color: isSelected ? Colors.white : itemColor,
                          ),
                        ),
                      ),
                    ),
                    SizedBox(width: 8 * s),
                    Icon(
                      item.icon,
                      size: 21 * s,
                      color: isSelected ? Colors.white : itemColor,
                    ),
                    SizedBox(width: 6 * s),
                    Expanded(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          item.label,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                            color:
                                isSelected ? Colors.white : palette.textPrimary,
                            letterSpacing: 0.2,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Orbit ring, spokes, and the sweeping radar pulse behind the node cards.
class _RadialCockpitPainter extends CustomPainter {
  final double cx;
  final double cy;
  final double rx;
  final double ry;
  final Color activeColor;
  final double pulseValue;
  final XSPalette palette;
  final int totalNodes;
  final int selectedIndex;

  _RadialCockpitPainter({
    required this.cx,
    required this.cy,
    required this.rx,
    required this.ry,
    required this.activeColor,
    required this.pulseValue,
    required this.palette,
    required this.totalNodes,
    required this.selectedIndex,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(cx, cy);
    final canvasRect = Offset.zero & size;

    // White background carrying a wash of the focused module's hue, so the
    // cockpit is unmistakably "the heart screen" or "the x-ray screen" at a
    // glance. A radial gradient rather than a flat tint: the colour is strongest
    // behind the central HUD, where the module is actually named, and fades to
    // near-white at the edges so the orbiting cards keep their contrast.
    canvas.drawRect(
      canvasRect,
      Paint()
        ..shader = RadialGradient(
          center: Alignment(
            (cx / size.width) * 2 - 1,
            (cy / size.height) * 2 - 1,
          ),
          radius: 0.95,
          colors: [
            Color.lerp(Colors.white, activeColor, 0.22)!,
            Color.lerp(Colors.white, activeColor, 0.10)!,
            Color.lerp(Colors.white, activeColor, 0.03)!,
          ],
          stops: const [0.0, 0.55, 1.0],
        ).createShader(canvasRect),
    );

    final orbit = Rect.fromCenter(
      center: center,
      width: rx * 2,
      height: ry * 2,
    );

    // Orbit ring the node cards ride on. Drawn in the module hue rather than the
    // neutral divider so it reads as part of the tinted background.
    canvas.drawOval(
      orbit,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = activeColor.withValues(alpha: 0.30),
    );

    // Expanding pulse ring: one sweep from the hub out to the orbit, fading as
    // it goes, which gives the otherwise static cockpit a live-instrument feel.
    final grow = Curves.easeOut.transform(pulseValue);
    canvas.drawOval(
      Rect.fromCenter(
        center: center,
        width: rx * 2 * grow,
        height: ry * 2 * grow,
      ),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = activeColor.withValues(alpha: 0.45 * (1 - grow)),
    );

    // Hub.
    canvas.drawCircle(
      center,
      5,
      Paint()..color = activeColor.withValues(alpha: 0.7),
    );

    // Spokes out to each node. The focused spoke is brighter so the eye is led
    // from the hub to the module the OK button will launch.
    final step = (2 * math.pi) / totalNodes;
    for (var i = 0; i < totalNodes; i++) {
      final angle = -math.pi / 2 + (i - selectedIndex) * step;
      final node = Offset(cx + rx * math.cos(angle), cy + ry * math.sin(angle));
      final isSelected = i == selectedIndex;
      canvas.drawLine(
        center,
        node,
        Paint()
          ..color = isSelected
              ? activeColor.withValues(alpha: 0.55)
              : activeColor.withValues(alpha: 0.16)
          ..strokeWidth = isSelected ? 2.0 : 1.0,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _RadialCockpitPainter oldDelegate) {
    return oldDelegate.pulseValue != pulseValue ||
        oldDelegate.selectedIndex != selectedIndex ||
        oldDelegate.activeColor != activeColor ||
        oldDelegate.rx != rx ||
        oldDelegate.ry != ry;
  }
}
