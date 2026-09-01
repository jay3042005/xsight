import 'package:flutter/material.dart';
import '../../core/theme/xs_colors.dart';
import '../../core/theme/xs_spacing.dart';
import '../../state/chat_controller.dart';
import '../components/xs_app_bar.dart';
import '../components/xs_chat_bubble.dart';
import '../components/xs_icon_button.dart';
import '../components/xs_input_field.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  final _chat = ChatController();

  @override
  void initState() {
    super.initState();
    _chat.addListener(_onChat);
  }

  void _onChat() {
    if (!mounted) return;
    setState(() {});
    Future.delayed(const Duration(milliseconds: 60), () {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _chat.busy) return;
    _controller.clear();
    await _chat.send(text);
  }

  @override
  void dispose() {
    _chat.removeListener(_onChat);
    _chat.dispose();
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    final messages = _chat.messages;

    return Column(
      children: [
        XSAppBar(
          title: 'Chat',
          showStatusDot: true,
          connected: _chat.aiConfigured,
        ),
        if (!_chat.aiConfigured)
          Container(
            margin: const EdgeInsets.fromLTRB(
              XSSpacing.lg,
              XSSpacing.xs,
              XSSpacing.lg,
              0,
            ),
            padding: const EdgeInsets.symmetric(
              horizontal: XSSpacing.md,
              vertical: XSSpacing.sm,
            ),
            decoration: BoxDecoration(
              color: palette.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: palette.divider, width: 0.6),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline,
                    size: 16, color: palette.textSecondary),
                const SizedBox(width: XSSpacing.xs),
                Expanded(
                  child: Text(
                    'Demo mode (offline replies). Set ZEN_API_KEY to enable AI.',
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: ListView.builder(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(
              XSSpacing.lg,
              XSSpacing.sm,
              XSSpacing.lg,
              XSSpacing.lg,
            ),
            itemCount: messages.length + (_chat.busy ? 1 : 0),
            itemBuilder: (context, i) {
              if (_chat.busy && i == messages.length) {
                return Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: XSSpacing.xs),
                    padding: const EdgeInsets.symmetric(
                      horizontal: XSSpacing.md,
                      vertical: XSSpacing.sm + 2,
                    ),
                    decoration: BoxDecoration(
                      color: palette.surface,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: palette.divider, width: 0.6),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _Dot(color: palette.textPrimary, delay: 0),
                        const SizedBox(width: 4),
                        _Dot(color: palette.textPrimary, delay: 200),
                        const SizedBox(width: 4),
                        _Dot(color: palette.textPrimary, delay: 400),
                      ],
                    ),
                  ),
                );
              }
              final m = messages[i];
              return XSChatBubble(text: m.content, isUser: m.isUser);
            },
          ),
        ),
        Container(
          color: palette.surface,
          padding: EdgeInsets.fromLTRB(
            XSSpacing.lg,
            XSSpacing.sm,
            XSSpacing.lg,
            MediaQuery.of(context).padding.bottom +
                XSSpacing.huge +
                XSSpacing.sm,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: XSInputField(
                  controller: _controller,
                  hintText: _chat.busy
                      ? 'XSIGHT is thinking...'
                      : 'Ask XSIGHT...',
                  onSubmitted: (_) => _send(),
                ),
              ),
              const SizedBox(width: XSSpacing.sm),
              XSIconButton(
                icon: Icons.mic_none,
                size: 48,
                onPressed: () {},
                semanticLabel: 'Voice input',
              ),
              const SizedBox(width: XSSpacing.xs),
              XSIconButton(
                icon: Icons.send_rounded,
                size: 48,
                inverted: true,
                onPressed: _chat.busy ? null : _send,
                semanticLabel: 'Send message',
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Dot extends StatefulWidget {
  final Color color;
  final int delay;
  const _Dot({required this.color, required this.delay});

  @override
  State<_Dot> createState() => _DotState();
}

class _DotState extends State<_Dot> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    Future.delayed(Duration(milliseconds: widget.delay), () {
      if (mounted) _ctrl.repeat();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        final t = (_ctrl.value * 2 - 1).abs();
        return Opacity(
          opacity: 0.4 + (1 - t) * 0.6,
          child: Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: widget.color,
              shape: BoxShape.circle,
            ),
          ),
        );
      },
    );
  }
}
