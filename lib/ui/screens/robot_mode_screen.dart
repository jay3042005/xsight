import 'dart:math';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../../core/theme/xs_colors.dart';
import '../../core/theme/xs_radius.dart';
import '../../core/theme/xs_shadows.dart';
import '../../core/theme/xs_spacing.dart';
import '../../state/robot_controller.dart';
import '../components/xs_button.dart';
import '../components/xs_card.dart';
import '../components/xs_icon_button.dart';

/// Robot Mode — full-screen camera + animated orb + voice loop.
class RobotModeScreen extends StatefulWidget {
  const RobotModeScreen({super.key});

  @override
  State<RobotModeScreen> createState() => _RobotModeScreenState();
}

class _RobotModeScreenState extends State<RobotModeScreen>
    with TickerProviderStateMixin {
  final _robot = RobotController();
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..repeat();
    _robot.addListener(_onChange);
    WidgetsBinding.instance.addPostFrameCallback((_) => _robot.start());
  }

  void _onChange() {
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _exit() async {
    await _robot.stop();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _robot.removeListener(_onChange);
    _robot.dispose();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    return Scaffold(
      backgroundColor: palette.surface,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(XSSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Header(state: _robot.state, onClose: _exit),
              const SizedBox(height: XSSpacing.md),
              // Tap the orb to interrupt mid-speech.
              GestureDetector(
                onTap: () {
                  if (_robot.state == RobotState.speaking ||
                      _robot.state == RobotState.thinking) {
                    _robot.interrupt();
                  }
                },
                child: SizedBox(
                  height: 260,
                  child: LayoutBuilder(
                    builder: (context, c) {
                      final size = c.maxHeight.clamp(0, 260).toDouble();
                      return Center(
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            _RobotOrb(
                              pulse: _pulse,
                              size: size,
                              state: _robot.state,
                            ),
                            if (_robot.camera != null &&
                                _robot.camera!.value.isInitialized)
                              ClipOval(
                                child: SizedBox(
                                  width: size * 0.74,
                                  height: size * 0.74,
                                  child: FittedBox(
                                    fit: BoxFit.cover,
                                    child: SizedBox(
                                      width: _robot.camera!
                                          .value.previewSize!.height,
                                      height: _robot.camera!
                                          .value.previewSize!.width,
                                      child: CameraPreview(_robot.camera!),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(height: XSSpacing.md),
              _ObjectChips(objects: _robot.detectedObjects),
              const SizedBox(height: XSSpacing.xs),
              Expanded(
                child: _ConversationCard(robot: _robot),
              ),
              const SizedBox(height: XSSpacing.md),
              _ControlBar(
                state: _robot.state,
                onInterrupt: _robot.interrupt,
                onCancel: _exit,
                onSwitchCamera:
                    _robot.hasMultipleCameras ? _robot.switchCamera : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final RobotState state;
  final VoidCallback onClose;
  const _Header({required this.state, required this.onClose});

  String get _label {
    switch (state) {
      case RobotState.idle:
        return 'IDLE';
      case RobotState.initializing:
        return 'INITIALIZING';
      case RobotState.listening:
        return 'LISTENING';
      case RobotState.thinking:
        return 'THINKING';
      case RobotState.speaking:
        return 'SPEAKING';
      case RobotState.observing:
        return 'OBSERVING';
      case RobotState.error:
        return 'ERROR';
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    return Row(
      children: [
        XSIconButton(
          icon: Icons.close,
          size: 44,
          onPressed: onClose,
          semanticLabel: 'Exit Robot Mode',
        ),
        const SizedBox(width: XSSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Robot Mode',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 2),
              Text(_label,
                  style: Theme.of(context)
                      .textTheme
                      .labelSmall
                      ?.copyWith(color: palette.textSecondary)),
            ],
          ),
        ),
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: state == RobotState.error
                ? palette.textSecondary
                : palette.textPrimary,
            shape: BoxShape.circle,
          ),
        ),
      ],
    );
  }
}

class _RobotOrb extends StatelessWidget {
  final AnimationController pulse;
  final double size;
  final RobotState state;
  const _RobotOrb({
    required this.pulse,
    required this.size,
    required this.state,
  });

  double _intensity() {
    switch (state) {
      case RobotState.listening:
        return 1.0;
      case RobotState.thinking:
      case RobotState.observing:
        return 0.6;
      case RobotState.speaking:
        return 0.85;
      default:
        return 0.3;
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    final intensity = _intensity();

    return AnimatedBuilder(
      animation: pulse,
      builder: (context, _) {
        final t = pulse.value * 2 * pi;
        final scale = 1.0 + (sin(t) * 0.04 * intensity);
        return Transform.scale(
          scale: scale,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: palette.surface,
              boxShadow: XSShadows.convex(palette, intensity: 1.2),
            ),
            child: CustomPaint(
              painter: _OrbRingPainter(
                progress: pulse.value,
                color: palette.textPrimary,
                divider: palette.divider,
                intensity: intensity,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _OrbRingPainter extends CustomPainter {
  final double progress;
  final Color color;
  final Color divider;
  final double intensity;

  _OrbRingPainter({
    required this.progress,
    required this.color,
    required this.divider,
    required this.intensity,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2;

    // Base ring
    final basePaint = Paint()
      ..color = divider
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    canvas.drawCircle(center, r * 0.92, basePaint);

    // Animated arc
    final arcPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0
      ..strokeCap = StrokeCap.round;
    final sweep = pi * (0.6 + intensity * 0.6);
    final startAngle = progress * 2 * pi;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: r * 0.96),
      startAngle,
      sweep,
      false,
      arcPaint,
    );

    // Inner dotted ring
    final dotPaint = Paint()..color = color;
    final dotRing = r * 0.86;
    final count = 36;
    for (int i = 0; i < count; i++) {
      final a = (i / count) * 2 * pi;
      final mod = (sin(progress * 2 * pi * 2 + a * 4) + 1) / 2;
      final dotR = 1.5 + mod * 1.6 * intensity;
      final p = Offset(
        center.dx + dotRing * cos(a),
        center.dy + dotRing * sin(a),
      );
      canvas.drawCircle(p, dotR, dotPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _OrbRingPainter old) =>
      old.progress != progress || old.intensity != intensity;
}

class _ObjectChips extends StatelessWidget {
  final List<String> objects;
  const _ObjectChips({required this.objects});

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    if (objects.isEmpty) {
      return SizedBox(
        height: 28,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            'SCANNING...',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: palette.textSecondary,
                ),
          ),
        ),
      );
    }
    return SizedBox(
      height: 32,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: objects.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (context, i) {
          final tag = objects[i];
          return Container(
            padding: const EdgeInsets.symmetric(
              horizontal: 10,
              vertical: 6,
            ),
            decoration: BoxDecoration(
              color: palette.surface,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: palette.divider, width: 0.6),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: palette.textPrimary,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  tag,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: palette.textPrimary,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _ConversationCard extends StatefulWidget {
  final RobotController robot;
  const _ConversationCard({required this.robot});

  @override
  State<_ConversationCard> createState() => _ConversationCardState();
}

class _ConversationCardState extends State<_ConversationCard> {
  final ScrollController _scroll = ScrollController();

  @override
  void didUpdateWidget(covariant _ConversationCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Auto-scroll to the bottom whenever a new message arrives so the
    // latest turn is always in view.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final pos = _scroll.position;
      _scroll.animateTo(
        pos.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  String _statusLabel(RobotState s) {
    switch (s) {
      case RobotState.idle:
        return 'READY';
      case RobotState.initializing:
        return 'CONNECTING';
      case RobotState.listening:
        return 'LISTENING';
      case RobotState.thinking:
        return 'THINKING';
      case RobotState.observing:
        return 'OBSERVING';
      case RobotState.speaking:
        return 'SPEAKING';
      case RobotState.error:
        return 'ERROR';
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    final state = widget.robot.state;
    final turns = widget.robot.turns;

    return XSCard(
      padding: const EdgeInsets.all(XSSpacing.lg),
      radius: XSRadius.lg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                _statusLabel(state),
                style: Theme.of(context).textTheme.labelSmall,
              ),
              const Spacer(),
              if (widget.robot.lastVision != null)
                Tooltip(
                  message: widget.robot.lastVision!,
                  child: Icon(Icons.remove_red_eye_outlined,
                      size: 14, color: palette.textSecondary),
                ),
            ],
          ),
          const SizedBox(height: XSSpacing.xs),
          Expanded(
            child: turns.isEmpty
                ? _EmptyState(
                    state: state,
                    error: widget.robot.error,
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: EdgeInsets.zero,
                    itemCount: turns.length,
                    itemBuilder: (context, i) {
                      final turn = turns[i];
                      return _TurnTile(turn: turn, palette: palette);
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final RobotState state;
  final String? error;
  const _EmptyState({required this.state, this.error});

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    String body;
    if (state == RobotState.error) {
      body = error ?? 'Something went wrong. Please try again.';
    } else if (state == RobotState.initializing) {
      body = 'Connecting to camera, microphone, and AI...';
    } else {
      body = 'Say something to start.';
    }
    return Center(
      child: Text(
        body,
        textAlign: TextAlign.center,
        style: Theme.of(context)
            .textTheme
            .bodyMedium
            ?.copyWith(color: palette.textSecondary),
      ),
    );
  }
}

class _TurnTile extends StatelessWidget {
  final RobotTurn turn;
  final XSPalette palette;
  const _TurnTile({required this.turn, required this.palette});

  @override
  Widget build(BuildContext context) {
    final isUser = turn.speaker == RobotSpeaker.user;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment:
            isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 8,
              ),
              decoration: BoxDecoration(
                color: isUser
                    ? palette.textPrimary
                    : palette.surface,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(14),
                  topRight: const Radius.circular(14),
                  bottomLeft: Radius.circular(isUser ? 14 : 4),
                  bottomRight: Radius.circular(isUser ? 4 : 14),
                ),
                border: isUser
                    ? null
                    : Border.all(color: palette.divider, width: 0.6),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    isUser ? 'YOU' : 'ROBOT',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: isUser
                              ? palette.surface.withValues(alpha: 0.6)
                              : palette.textSecondary,
                          fontSize: 9,
                          letterSpacing: 1.5,
                        ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    turn.text,
                    style: TextStyle(
                      color: isUser
                          ? palette.surface
                          : palette.textPrimary,
                      fontSize: 15,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ControlBar extends StatelessWidget {
  final RobotState state;
  final VoidCallback onInterrupt;
  final VoidCallback onCancel;
  final VoidCallback? onSwitchCamera;
  const _ControlBar({
    required this.state,
    required this.onInterrupt,
    required this.onCancel,
    required this.onSwitchCamera,
  });

  @override
  Widget build(BuildContext context) {
    final canInterrupt =
        state == RobotState.speaking || state == RobotState.thinking;

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        XSIconButton(
          icon: Icons.mic_off_outlined,
          onPressed: canInterrupt ? onInterrupt : null,
          semanticLabel: 'Interrupt and speak',
        ),
        const SizedBox(width: XSSpacing.lg),
        XSButton(
          label: state == RobotState.error ? 'Exit' : 'End Session',
          inverted: true,
          icon: Icons.power_settings_new,
          onPressed: onCancel,
        ),
        const SizedBox(width: XSSpacing.lg),
        XSIconButton(
          icon: Icons.cameraswitch_outlined,
          onPressed: onSwitchCamera,
          semanticLabel: 'Switch camera',
        ),
      ],
    );
  }
}
