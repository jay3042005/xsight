import 'package:flutter/material.dart';
import '../../core/theme/xs_colors.dart';
import '../../core/theme/xs_radius.dart';
import '../../core/theme/xs_shadows.dart';
import '../../core/theme/xs_spacing.dart';

/// Chat bubble — user (filled, right) or assistant (surface, left).
class XSChatBubble extends StatelessWidget {
  final String text;
  final bool isUser;
  final String? timestamp;

  const XSChatBubble({
    super.key,
    required this.text,
    required this.isUser,
    this.timestamp,
  });

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    final bg = isUser ? palette.textPrimary : palette.surface;
    final fg = isUser ? palette.surface : palette.textPrimary;

    final radius = BorderRadius.only(
      topLeft: const Radius.circular(XSRadius.lg),
      topRight: const Radius.circular(XSRadius.lg),
      bottomLeft: Radius.circular(isUser ? XSRadius.lg : 6),
      bottomRight: Radius.circular(isUser ? 6 : XSRadius.lg),
    );

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.78,
        ),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: XSSpacing.xs),
          padding: const EdgeInsets.symmetric(
            horizontal: XSSpacing.md,
            vertical: XSSpacing.sm + 2,
          ),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: radius,
            boxShadow: isUser
                ? XSShadows.pressed(palette)
                : XSShadows.soft(palette),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                text,
                style: TextStyle(
                  color: fg,
                  fontSize: 15,
                  height: 1.4,
                ),
              ),
              if (timestamp != null) ...[
                const SizedBox(height: 4),
                Text(
                  timestamp!,
                  style: TextStyle(
                    color: fg.withValues(alpha: 0.6),
                    fontSize: 11,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
