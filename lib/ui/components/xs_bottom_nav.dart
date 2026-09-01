import 'package:flutter/material.dart';
import '../../core/theme/xs_colors.dart';
import '../../core/theme/xs_radius.dart';
import '../../core/theme/xs_shadows.dart';
import '../../core/theme/xs_spacing.dart';

class XSNavItem {
  final IconData icon;
  final String label;
  const XSNavItem({required this.icon, required this.label});
}

/// Floating neumorphic bottom navigation.
class XSBottomNav extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;
  final List<XSNavItem> items;

  const XSBottomNav({
    super.key,
    required this.currentIndex,
    required this.onTap,
    required this.items,
  });

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        XSSpacing.lg,
        XSSpacing.xs,
        XSSpacing.lg,
        XSSpacing.lg,
      ),
      child: Container(
        height: 72,
        decoration: BoxDecoration(
          color: palette.surface,
          borderRadius: BorderRadius.circular(XSRadius.pill),
          boxShadow: XSShadows.convex(palette),
        ),
        padding: const EdgeInsets.all(8),
        child: Row(
          children: List.generate(items.length, (i) {
            final selected = i == currentIndex;
            final item = items[i];
            return Expanded(
              child: GestureDetector(
                onTap: () => onTap(i),
                behavior: HitTestBehavior.opaque,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  decoration: BoxDecoration(
                    color: palette.surface,
                    borderRadius: BorderRadius.circular(XSRadius.pill),
                    boxShadow: selected
                        ? XSShadows.pressed(palette)
                        : null,
                    gradient: selected
                        ? LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              palette.shadow.withValues(alpha: 0.15),
                              palette.surface,
                            ],
                          )
                        : null,
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(item.icon,
                          size: 22,
                          color: selected
                              ? palette.textPrimary
                              : palette.textSecondary),
                      const SizedBox(height: 2),
                      Text(
                        item.label,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w500,
                          color: selected
                              ? palette.textPrimary
                              : palette.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }
}
