import 'package:flutter/material.dart';
import '../../core/theme/xs_colors.dart';
import '../../core/theme/xs_spacing.dart';

/// Top app bar with neumorphic surface (no elevation).
class XSAppBar extends StatelessWidget implements PreferredSizeWidget {
  final String title;
  final List<Widget> actions;
  final Widget? leading;
  final bool showStatusDot;
  final bool connected;

  const XSAppBar({
    super.key,
    required this.title,
    this.actions = const [],
    this.leading,
    this.showStatusDot = false,
    this.connected = false,
  });

  @override
  Size get preferredSize => const Size.fromHeight(72);

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    return Container(
      padding: EdgeInsets.fromLTRB(
        XSSpacing.lg,
        MediaQuery.of(context).padding.top + XSSpacing.sm,
        XSSpacing.lg,
        XSSpacing.sm,
      ),
      color: palette.surface,
      child: Row(
        children: [
          if (leading != null) ...[
            leading!,
            const SizedBox(width: XSSpacing.sm),
          ],
          Text(
            title,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          if (showStatusDot) ...[
            const SizedBox(width: XSSpacing.sm),
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: connected ? palette.textPrimary : palette.textSecondary,
                shape: BoxShape.circle,
              ),
            ),
          ],
          const Spacer(),
          ...actions,
        ],
      ),
    );
  }
}
