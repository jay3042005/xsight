import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../core/theme/xs_colors.dart';
import '../../core/theme/xs_radius.dart';
import '../../core/theme/xs_scale.dart';
import '../../core/theme/xs_spacing.dart';
import '../../core/voice/voice_client.dart';
import '../../core/voice/voice_guide.dart';
import '../../state/kiosk_patient_state.dart';
import '../components/xs_ambient_background.dart';
import '../components/xs_chip.dart';
import '../components/xs_icon_button.dart';
import '../components/xs_shining_text.dart';

/// State colours for the redesigned voice stage. Blue while capturing,
/// amber while working, green while talking — the same mapping as the
/// reference design this screen was ported from.
const _kListenBlue = Color(0xFF3B82F6);
const _kThinkAmber = Color(0xFFFBBF24);
const _kSpeakGreen = Color(0xFF4ADE80);

/// XSIGHT AI live voice — full-screen Siri-style stage.
///
/// Redesigned around a single hold-to-talk orb: press and hold (touch, the
/// hardware OK button, or Space) to talk, release to finish the turn. The
/// assistant answers with a shining "thinking" sweep, then its reply fades in
/// under the visualizer while it is spoken aloud.
///
/// This is the assistant module's *screen* — selecting the AI Assistant
/// station lands here directly, and the text chat is a button away
/// ([onOpenChat]). The hardware contract ([activeState], [onPushToTalkDown],
/// [onPushToTalkUp], [exit]) is unchanged from the previous dashboard-style
/// screen so the shell, the ESP32 push-to-talk wiring, and every caller keep
/// working untouched.
class VoiceModeScreen extends StatefulWidget {
  const VoiceModeScreen({super.key, this.onExit, this.onOpenChat});

  static VoiceModeScreenState? activeState;

  /// What "exit" means for this instance. Null (a pushed route): pop, as
  /// before. Provided (hosted inside the kiosk shell): the host owns
  /// navigation, so hand the request up — popping would otherwise close the
  /// whole shell.
  final VoidCallback? onExit;

  /// Opens the text chat. Supplied by the host rather than imported: the chat
  /// screen imports this screen, and importing it back would create a cycle.
  final VoidCallback? onOpenChat;

  @override
  State<VoiceModeScreen> createState() => VoiceModeScreenState();
}

class VoiceModeScreenState extends State<VoiceModeScreen>
    with TickerProviderStateMixin {
  final _voice = VoiceClient();
  final _focusNode = FocusNode();

  /// Ambient loop: drives particles, ring pulses, and status blink together.
  late final AnimationController _pulse;

  /// Waveform idle sway, phase-offset from [_pulse] so the bars don't move in
  /// lockstep with the rings.
  late final AnimationController _waveAnim;

  /// Smoothed copy of `VoiceClient.activeLevel`. Raw RMS is jumpy at frame
  /// rate; an asymmetric follower (fast attack, slow release) reads as speech
  /// rather than flicker.
  double _level = 0;

  /// Rolling amplitude history driving the 32-bar visualizer.
  /// Rolling visualizer window. Growable: `List.filled(48, 0)` without the
  /// flag is *fixed-length*, and the ticker's `removeAt` used to throw
  /// "Cannot remove from a fixed-length list" on every frame — which took
  /// the whole voice screen down with it.
  final List<double> _levelHistory = List<double>.filled(48, 0, growable: true);
  late final Ticker _levelTicker;

  /// True between pointer/key down and up on the talk control.
  bool _holdActive = false;

  /// True after a release while the mic is still streaming the trailing
  /// silence the server needs to close the turn (see `VoiceClient.releaseMic`).
  /// Renders exactly like `thinking`, so releasing feels immediate.
  bool _ending = false;

  VoiceState _prevState = VoiceState.idle;
  final Stopwatch _listenClock = Stopwatch();

  @override
  void initState() {
    super.initState();
    VoiceModeScreen.activeState = this;
    // The kiosk's pre-recorded guidance shares the speaker with this screen but
    // not its mute window: `/ws/voice` only silences the mic around audio the
    // server itself is streaming. A guide clip playing here would be captured,
    // transcribed, and answered as though the user had said it.
    VoiceGuide.I.suspend();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..repeat();
    _waveAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
    _voice.addListener(_onChange);
    KioskPatientSession.I.addListener(_onSessionChanged);
    _levelTicker = createTicker(_onLevelTick)..start();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      _focusNode.requestFocus();
      await _voice.start();
      // Give the model the session readings once the socket is up, so a
      // spoken "summarize my results" has the same context as text chat.
      if (mounted) _syncSessionToVoice();
    });
  }

  /// Push the current mode and readings to the server.
  ///
  /// Both must be re-sent whenever the session changes: a staff member can log
  /// in, link a patient, or hand the kiosk back to the public while a voice
  /// call is open, and the socket would otherwise keep answering with the
  /// persona and readings it was given at connect time.
  void _syncSessionToVoice() {
    final session = KioskPatientSession.I;
    _voice.setKioskMode(session.isStaffMode);
    _voice.setPatientContext(session.clinicalContextPrompt);
  }

  void _onSessionChanged() {
    if (!mounted) return;
    _syncSessionToVoice();
    setState(() {});
  }

  /// Drives the visualizer off real audio amplitude, decoupled from
  /// `notifyListeners` so the whole tree doesn't rebuild per audio frame.
  void _onLevelTick(Duration _) {
    if (!mounted) return;
    final target = _voice.activeLevel;
    // Attack fast so a syllable registers; release slowly so the bars settle
    // instead of strobing between words.
    final next = target > _level
        ? _level + (target - _level) * 0.45
        : _level + (target - _level) * 0.12;
    _levelHistory.removeAt(0);
    _levelHistory.add(next);
    setState(() => _level = next);
  }

  void onPushToTalkDown() {
    switch (_voice.state) {
      case VoiceState.speaking:
      case VoiceState.thinking:
        _voice.interrupt();
        break;
      case VoiceState.idle:
        _beginHold();
        break;
      case VoiceState.error:
        // A dead socket used to swallow the press silently. Retry instead.
        _voice.start().then((_) {
          if (_voice.isConnected) _beginHold();
        });
        break;
      case VoiceState.listening:
      case VoiceState.connecting:
        break;
    }
  }

  void _beginHold() {
  setState(() => _ending = false);
  _listenClock
  ..reset()
  ..start();
  _voice.startListening();
  }

  /// Release ends the turn. The mic keeps streaming quiet room tone for just
  /// under a second — that trailing silence is what tells the server's VAD
  /// the utterance is over (`VoiceClient.releaseMic`).
  void onPushToTalkUp() {
    if (_voice.state != VoiceState.listening) return;
    _voice.releaseMic();
    if (mounted) setState(() => _ending = true);
  }

  void _handleKeyEvent(KeyEvent event) {
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.space || key == LogicalKeyboardKey.enter) {
      if (event is KeyDownEvent) {
        if (!_holdActive) {
          _holdActive = true;
          onPushToTalkDown();
        }
      } else if (event is KeyUpEvent) {
        if (_holdActive) {
          _holdActive = false;
          onPushToTalkUp();
        }
      }
    } else if (key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.backspace) {
      if (event is KeyDownEvent) {
        exit();
      }
    }
  }

  void _onChange() {
    if (!mounted) return;
    final s = _voice.state;
    if (_prevState != VoiceState.listening && s == VoiceState.listening) {
      _ending = false;
    }
    if (s != VoiceState.listening && _prevState == VoiceState.listening) {
      _ending = false;
      _listenClock.stop();
    }
    _prevState = s;
    setState(() {});
  }

  Future<void> exit() async {
    await _voice.stop();
    if (!mounted) return;
    // Hosted in the shell: there is no route of our own to pop, navigation
    // belongs to the host. Pushed standalone (desktop/dev paths): pop.
    if (widget.onExit != null) {
      widget.onExit!();
    } else {
      Navigator.of(context).pop();
    }
  }

  @override
  void dispose() {
    if (VoiceModeScreen.activeState == this) {
      VoiceModeScreen.activeState = null;
    }
    VoiceGuide.I.resume();
    KioskPatientSession.I.removeListener(_onSessionChanged);
    _levelTicker.dispose();
    _focusNode.dispose();
    _voice.removeListener(_onChange);
    _voice.dispose();
    _pulse.dispose();
    _waveAnim.dispose();
    super.dispose();
  }

  void _sendQuickQuery(String text) {
    if (_voice.state == VoiceState.speaking ||
        _voice.state == VoiceState.thinking) {
      _voice.interrupt();
    }
    _voice.sendTextQuery(text);
  }

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    final session = KioskPatientSession.I;
    final s = XSScale.factor;

    return KeyboardListener(
      focusNode: _focusNode,
      onKeyEvent: _handleKeyEvent,
      autofocus: true,
      child: Scaffold(
        backgroundColor: palette.surface,
        body: XSAmbientBackground(
          accent: _stageColor,
          child: SafeArea(
            child: Stack(
              children: [
                // ─── CENTER GLOW ────────────────────────────────────
                Center(child: _GlowBlob(state: _voice.state)),

                // ─── DRIFTING PARTICLES ─────────────────────────────
                Positioned.fill(
                  child: RepaintBoundary(
                    child: AnimatedBuilder(
                      animation: _pulse,
                      builder: (context, _) => CustomPaint(
                        painter: _ParticlePainter(t: _pulse.value),
                      ),
                    ),
                  ),
                ),

                // ─── STAGE ──────────────────────────────────────────
                SafeArea(
                  child: Padding(
                    padding: EdgeInsets.all(XSSpacing.lg * s),
                    child: Column(
                      children: [
                        _TopBar(
                          palette: palette,
                          session: session,
                          onClose: exit,
                          onOpenChat: widget.onOpenChat,
                          onDeviceStt: _voice.usingOnDeviceStt,
                        ),
                        SizedBox(height: XSSpacing.sm * s),
                        // What the assistant can see of this session. Status
                        // only — measured or pending, never the readings — so
                        // the stage explains its own context without ever
                        // announcing a finding in a shared room.
                        _ContextRibbon(palette: palette, session: session),
                        // Scrollable stage: whatever the panel height, the
                        // orb and readouts can never be clipped.
                        Expanded(
                          child: SingleChildScrollView(
                            child: Column(
                              children: [
                                SizedBox(height: XSSpacing.md * s),
                                _StatusBlock(
                                  voice: _voice,
                                  ending: _ending,
                                  pulse: _pulse,
                                  palette: palette,
                                ),
                                SizedBox(height: XSSpacing.lg * s),
                                _TalkOrb(
                                  voice: _voice,
                                  pulse: _pulse,
                                  waveAnim: _waveAnim,
                                  holdActive: _holdActive,
                                  onHoldStart: () {
                                    setState(() => _holdActive = true);
                                    onPushToTalkDown();
                                  },
                                  onHoldEnd: () {
                                    setState(() => _holdActive = false);
                                    onPushToTalkUp();
                                  },
                                ),
                                SizedBox(height: XSSpacing.lg * s),
                                _Waveform(
                                  history: _levelHistory,
                                  waveAnim: _waveAnim,
                                  color: _stageColor,
                                  active: _isAudioLive,
                                ),
                                SizedBox(height: XSSpacing.sm * s),
                                _TimerText(
                                  clock: _listenClock,
                                  visible:
                                      _voice.state == VoiceState.listening,
                                  color: palette.textSecondary,
                                ),
                                SizedBox(height: XSSpacing.xs * s),
                                _VolumeMeter(level: _level, color: _stageColor),
                                SizedBox(height: XSSpacing.md * s),
                                _ReplyBlock(voice: _voice, palette: palette),
                              ],
                            ),
                          ),
                        ),
                        SizedBox(height: XSSpacing.sm * s),
                        _QuickAsks(
                          palette: palette,
                          isStaff: session.isStaffMode,
                          onSelect: _sendQuickQuery,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  bool get _isAudioLive =>
      (_voice.state == VoiceState.listening && !_ending) ||
      _voice.state == VoiceState.speaking;

  Color get _stageColor {
    switch (_voice.state) {
      case VoiceState.listening:
        return _ending ? _kThinkAmber : _kListenBlue;
      case VoiceState.thinking:
        return _kThinkAmber;
      case VoiceState.speaking:
        return _kSpeakGreen;
      case VoiceState.error:
        return XSColors.accentRed;
      default:
        return XSColors.teal;
    }
  }
}

// ─── TOP BAR ────────────────────────────────────────────────────────
class _TopBar extends StatelessWidget {
  final XSPalette palette;
  final KioskPatientSession session;
  final VoidCallback onClose;
  final VoidCallback? onOpenChat;

  /// True when the platform's built-in speech recognizer (Google's STT on
  /// Android) is capturing the voice, rather than the server's Whisper.
  final bool onDeviceStt;

  const _TopBar({
    required this.palette,
    required this.session,
    required this.onClose,
    this.onOpenChat,
    this.onDeviceStt = false,
  });

  @override
  Widget build(BuildContext context) {
    final s = XSScale.factor;
    return Row(
      children: [
        XSIconButton(
          icon: Icons.close_rounded,
          size: 40,
          onPressed: onClose,
          semanticLabel: 'Exit Voice Mode',
        ),
        const SizedBox(width: XSSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'XSIGHT AI',
                style: TextStyle(
                  fontSize: 17 * s,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.1,
                  color: palette.textPrimary,
                ),
              ),
              Text(
                '${session.isGuest ? "Guest" : "Staff"} · ${session.patientDisplayName}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5 * s,
                  color: palette.textSecondary,
                ),
              ),
            ],
          ),
        ),
        // Breathing "AI Voice Assistant" badge, straight from the reference.
        Icon(Icons.auto_awesome, size: 15 * s, color: palette.textSecondary),
        SizedBox(width: 7 * s),
        Text(
          'AI VOICE ASSISTANT',
          style: TextStyle(
            fontSize: 11.5 * s,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.2,
            color: palette.textSecondary,
          ),
        ),
        // Which input path is live. On Android the platform's built-in
        // Google recognizer captures speech (no server Whisper round-trip);
        // making that visible is the only way to tell the paths apart from
        // the front of the kiosk.
        if (onDeviceStt) ...[
          SizedBox(width: XSSpacing.xs * s),
          XSChip(
            label: 'ON-DEVICE MIC',
            icon: Icons.mic,
            color: XSColors.moduleAssistant,
          ),
        ],
        // The door to the text chat: some questions (exact numbers, referral
        // drafts) are easier to read than to hear, and this is the only way
        // into it now that the assistant module opens on the voice stage.
        if (onOpenChat != null) ...[
          SizedBox(width: XSSpacing.sm),
          XSIconButton(
            icon: Icons.chat_bubble_outline_rounded,
            size: 40,
            onPressed: onOpenChat,
            semanticLabel: 'Open text chat',
          ),
        ],
      ],
    );
  }
}

// ─── CONTEXT RIBBON ────────────────────────────────────────────────
/// The session's measurement stations as a strip of status pills.
///
/// Measured stations glow in their own orbit colour; pending ones stay
/// outline-only. Values are deliberately absent — this is a chart-index
/// gesture ("what I can see"), not a results display, so nothing here can
/// read a finding out into the room. It also gives a spoken "explain my
/// results" a visible referent: the pills are exactly the context the
/// backend was given.
class _ContextRibbon extends StatelessWidget {
  final XSPalette palette;
  final KioskPatientSession session;

  const _ContextRibbon({required this.palette, required this.session});

  @override
  Widget build(BuildContext context) {
    final s = XSScale.factor;
    final stations = [
      (
        label: 'Vitals',
        icon: Icons.monitor_heart_outlined,
        color: XSColors.moduleVitals,
        done: session.hasGuestVitals,
      ),
      (
        label: 'Temp',
        icon: Icons.thermostat_outlined,
        color: XSColors.moduleTemp,
        done: session.hasGuestTemp,
      ),
      (
        label: 'Lungs',
        icon: Icons.graphic_eq,
        color: XSColors.moduleSteth,
        done: session.hasGuestSteth,
      ),
      (
        label: 'X-ray',
        icon: Icons.medical_services_outlined,
        color: XSColors.moduleXray,
        done: session.hasGuestXray,
      ),
    ];
    final measured = stations.where((e) => e.done).length;

    return Row(
      children: [
        Text(
          'SESSION CONTEXT',
          style: TextStyle(
            fontSize: 10 * s,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.1,
            color: palette.textSecondary,
          ),
        ),
        SizedBox(width: XSSpacing.sm * s),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final (i, st) in stations.indexed) ...[
                  if (i > 0) SizedBox(width: XSSpacing.xs * s),
                  Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: 10 * s,
                      vertical: 5 * s,
                    ),
                    decoration: BoxDecoration(
                      color: st.done
                          ? st.color.withValues(alpha: 0.12)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(XSRadius.pill),
                      border: Border.all(
                        color: st.done
                            ? st.color.withValues(alpha: 0.55)
                            : palette.divider,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          st.done ? st.icon : Icons.circle_outlined,
                          size: 13 * s,
                          color: st.done
                              ? st.color
                              : palette.textSecondary.withValues(
                                  alpha: 0.6,
                                ),
                        ),
                        SizedBox(width: 5 * s),
                        Text(
                          st.label,
                          style: TextStyle(
                            fontSize: 11.5 * s,
                            fontWeight: FontWeight.w700,
                            color: st.done
                                ? palette.textPrimary
                                : palette.textSecondary.withValues(
                                    alpha: 0.7,
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        SizedBox(width: XSSpacing.sm * s),
        Text(
          '$measured/4',
          style: TextStyle(
            fontSize: 11 * s,
            fontWeight: FontWeight.w800,
            fontFeatures: const [FontFeature.tabularFigures()],
            color: measured > 0
                ? XSColors.moduleAssistant
                : palette.textSecondary,
          ),
        ),
      ],
    );
  }
}

// ─── STATUS BLOCK ───────────────────────────────────────────────────
/// One line of state copy. The thinking/flush states render the shining
/// sweep; everything else is a plain colour-coded label that blinks softly
/// while something is happening.
class _StatusBlock extends StatelessWidget {
  final VoiceClient voice;
  final bool ending;
  final AnimationController pulse;
  final XSPalette palette;

  const _StatusBlock({
    required this.voice,
    required this.ending,
    required this.pulse,
    required this.palette,
  });

  @override
  Widget build(BuildContext context) {
    final s = XSScale.factor;
    final state = voice.state;

  // The shine: "XSIGHT AI is thinking…" — shown from the instant the user
  // releases the button until the spoken answer begins. Sits on a dark pill
  // because the reference design's white sweep is invisible against the
  // kiosk's light surface; on near-black it pops exactly as intended.
  if ((state == VoiceState.listening && ending) ||
  state == VoiceState.thinking) {
  return Container(
  padding: EdgeInsets.symmetric(
  horizontal: 24 * s,
  vertical: 13 * s,
  ),
  decoration: BoxDecoration(
  color: const Color(0xFF10151E),
  borderRadius: BorderRadius.circular(XSRadius.pill),
  border: Border.all(color: _kThinkAmber.withValues(alpha: 0.35)),
  boxShadow: [
  BoxShadow(
  color: _kThinkAmber.withValues(alpha: 0.22),
  blurRadius: 26,
  spreadRadius: 1,
  ),
  ],
  ),
  child: XSShiningText(
  text: 'XSIGHT AI is thinking...',
  base: const Color(0xFF6B7280),
  shine: Colors.white,
  style: TextStyle(
  fontSize: 19 * s,
  fontWeight: FontWeight.w600,
  letterSpacing: 0.2,
  ),
  ),
  );
  }

    String text;
    Color color;
    var blink = false;
    switch (state) {
      case VoiceState.listening:
        text = 'Listening... release to finish';
        color = _kListenBlue;
        blink = true;
        break;
      case VoiceState.speaking:
        text = 'Speaking... tap to interrupt';
        color = _kSpeakGreen;
        blink = true;
        break;
      case VoiceState.connecting:
        text = 'Connecting to the voice gateway...';
        color = palette.textSecondary;
        blink = true;
        break;
      case VoiceState.error:
        text = voice.error ?? 'Voice gateway unavailable — hold to retry.';
        color = XSColors.accentRed;
        break;
      default:
        text = voice.reply.isEmpty
            ? 'Hold the mic and ask anything'
            : 'Hold to ask again';
        color = palette.textSecondary;
    }

    return AnimatedBuilder(
      animation: pulse,
      builder: (context, _) {
        final a =
            blink ? 0.62 + 0.38 * (sin(pulse.value * 2 * pi).abs()) : 1.0;
        return Opacity(
          opacity: a,
          child: Text(
            text,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 19 * s,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        );
      },
    );
  }
}

// ─── TALK ORB ───────────────────────────────────────────────────────
/// The single control: a circular button that is held to talk. Expanding
/// pulse rings while capturing, a spinner while thinking, a speaker while
/// talking. Touch and the hardware OK button drive the same handlers.
class _TalkOrb extends StatelessWidget {
  final VoiceClient voice;
  final AnimationController pulse;
  final AnimationController waveAnim;
  final bool holdActive;
  final VoidCallback onHoldStart;
  final VoidCallback onHoldEnd;

  const _TalkOrb({
    required this.voice,
    required this.pulse,
    required this.waveAnim,
    required this.holdActive,
    required this.onHoldStart,
    required this.onHoldEnd,
  });

  Color get _color {
    switch (voice.state) {
      case VoiceState.listening:
        return _kListenBlue;
      case VoiceState.thinking:
        return _kThinkAmber;
      case VoiceState.speaking:
        return _kSpeakGreen;
      case VoiceState.error:
        return XSColors.accentRed;
      default:
        return XSColors.teal;
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    final s = XSScale.factor;
    final listening = voice.state == VoiceState.listening;
    final thinking = voice.state == VoiceState.thinking;
    final speaking = voice.state == VoiceState.speaking;

    return LayoutBuilder(builder: (context, c) {
      final size = c.maxHeight.isFinite
          ? c.maxHeight.clamp(140.0, 220.0)
          : 180.0;
      final ringSize = size * 1.0;

      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => onHoldStart(),
        onTapUp: (_) => onHoldEnd(),
        onTapCancel: onHoldEnd,
        child: AnimatedScale(
          scale: holdActive ? 0.95 : 1.0,
          duration: const Duration(milliseconds: 110),
          child: SizedBox(
            width: ringSize,
            height: ringSize,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Expanding pulse rings while listening.
                if (listening)
                  AnimatedBuilder(
                    animation: pulse,
                    builder: (context, _) => Stack(
                      alignment: Alignment.center,
                      children: [
                        for (var i = 0; i < 2; i++)
                          _PulseRing(
                            t: (pulse.value + i * 0.5) % 1.0,
                            color: _color,
                          ),
                      ],
                    ),
                  ),
                // The button itself.
                AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  width: size * 0.86,
                  height: size * 0.86,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        _color.withValues(alpha: 0.22),
                        _color.withValues(alpha: 0.08),
                      ],
                    ),
                    border: Border.all(color: _color, width: 2.2),
                    boxShadow: [
                      BoxShadow(
                        color: _color.withValues(alpha: 0.28),
                        blurRadius: 26,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: Center(
                    child: thinking
                        ? SizedBox(
                            width: 46 * s,
                            height: 46 * s,
                            child: CircularProgressIndicator(
                              strokeWidth: 3.2,
                              color: _kThinkAmber,
                            ),
                          )
                        : AnimatedSwitcher(
                            duration: const Duration(milliseconds: 200),
                            child: Icon(
                              speaking
                                  ? Icons.volume_up_rounded
                                  : Icons.mic_rounded,
                              key: ValueKey(speaking),
                              size: 52 * s,
                              color: speaking ? _kSpeakGreen : _color,
                            ),
                          ),
                  ),
                ),
                // Subtle rotating arc so the idle orb still feels alive.
                if (!listening && !thinking && !speaking)
                  AnimatedBuilder(
                    animation: waveAnim,
                    builder: (context, _) => Transform.rotate(
                      angle: waveAnim.value * 2 * pi,
                      child: SizedBox(
                        width: size * 0.94,
                        height: size * 0.94,
                        child: CircularProgressIndicator(
                          value: 0.08,
                          strokeWidth: 2,
                          color: palette.divider,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    });
  }
}

class _PulseRing extends StatelessWidget {
  final double t; // 0..1 phase
  final Color color;

  const _PulseRing({required this.t, required this.color});

  @override
  Widget build(BuildContext context) {
    final scale = 0.9 + t * 0.55;
    final opacity = (1 - t) * 0.45;
    return Transform.scale(
      scale: scale,
      child: Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: color.withValues(alpha: opacity), width: 2),
        ),
      ),
    );
  }
}

// ─── WAVEFORM ───────────────────────────────────────────────────────
/// 32 rounded bars mirroring live amplitude; a gentle sway when silent.
class _Waveform extends StatelessWidget {
  final List<double> history;
  final AnimationController waveAnim;
  final Color color;
  final bool active;

  static const _bars = 32;

  const _Waveform({
    required this.history,
    required this.waveAnim,
    required this.color,
    required this.active,
  });

  @override
  Widget build(BuildContext context) {
    final s = XSScale.factor;
    return SizedBox(
      height: 58 * s,
      child: AnimatedBuilder(
        animation: waveAnim,
        builder: (context, _) {
          return Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(_bars, (i) {
              double amp;
              if (active) {
                // Map bars onto the newest slice of the rolling history.
                final idx =
                    history.length - 1 - ((_bars - 1 - i) * history.length) ~/
                        _bars;
                amp = (idx >= 0 && idx < history.length) ? history[idx] : 0;
                // Lens taper so the edges fall away like the reference.
                amp *= (1 - ((i / (_bars - 1)) - 0.5).abs() * 1.3)
                    .clamp(0.25, 1.0);
              } else {
                amp = (sin(waveAnim.value * 2 * pi + i * 0.42).abs()) * 0.14;
              }
              final h = (4 + amp * 50) * s;
              return Container(
                width: 3.2 * s,
                margin: EdgeInsets.symmetric(horizontal: 1.6 * s),
                height: h,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: active ? 1 : 0.30),
                  borderRadius: BorderRadius.circular(2 * s),
                ),
              );
            }),
          );
        },
      ),
    );
  }
}

// ─── TIMER ──────────────────────────────────────────────────────────
class _TimerText extends StatelessWidget {
  final Stopwatch clock;
  final bool visible;
  final Color color;

  const _TimerText({
    required this.clock,
    required this.visible,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final s = XSScale.factor;
    final secs = clock.elapsedMilliseconds ~/ 1000;
    final label =
        '${(secs ~/ 60).toString().padLeft(2, '0')}:${(secs % 60).toString().padLeft(2, '0')}';
    // Fixed-height slot so toggling the timer never shifts the layout.
    return SizedBox(
      height: 18 * s,
      child: visible
          ? Text(
              label,
              style: TextStyle(
                fontSize: 13 * s,
                fontFeatures: const [FontFeature.tabularFigures()],
                letterSpacing: 1.5,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            )
          : null,
    );
  }
}

// ─── VOLUME METER ───────────────────────────────────────────────────
class _VolumeMeter extends StatelessWidget {
  final double level;
  final Color color;

  const _VolumeMeter({required this.level, required this.color});

  @override
  Widget build(BuildContext context) {
    final s = XSScale.factor;
    final live = level > 0.02;
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 180),
      opacity: live ? 1 : 0,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.volume_mute_rounded,
              size: 15 * s, color: color.withValues(alpha: 0.7)),
          SizedBox(width: 7 * s),
          ClipRRect(
            borderRadius: BorderRadius.circular(XSRadius.pill),
            child: SizedBox(
              width: 110 * s,
              height: 6 * s,
              child: Stack(
                children: [
                  Container(color: color.withValues(alpha: 0.15)),
                  FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: level.clamp(0.0, 1.0),
                    child: Container(color: color),
                  ),
                ],
              ),
            ),
          ),
          SizedBox(width: 7 * s),
          Icon(Icons.volume_up_rounded,
              size: 15 * s, color: color.withValues(alpha: 0.7)),
        ],
      ),
    );
  }
}

// ─── REPLY BLOCK ────────────────────────────────────────────────────
/// What you asked, then the answer streamed in — the text types itself out
/// with a live caret while TTS reads it, so the screen keeps pace with the
/// voice instead of dumping the whole paragraph at once.
class _ReplyBlock extends StatefulWidget {
  final VoiceClient voice;
  final XSPalette palette;

  const _ReplyBlock({required this.voice, required this.palette});

  @override
  State<_ReplyBlock> createState() => _ReplyBlockState();
}

class _ReplyBlockState extends State<_ReplyBlock> {
  /// The slice of [VoiceClient.reply] revealed so far.
  String _shown = '';
  Timer? _stream;

  @override
  void initState() {
    super.initState();
    _restartStream();
  }

  @override
  void didUpdateWidget(covariant _ReplyBlock old) {
    super.didUpdateWidget(old);
    if (old.voice.reply != widget.voice.reply) {
      _restartStream();
    }
  }

  /// A new answer arrived: clear and re-stream from the first word. A short
  /// delay lets the "thinking" shine read as a distinct beat before prose
  /// starts landing.
  void _restartStream() {
    _stream?.cancel();
    _shown = '';
    final full = widget.voice.reply;
    if (full.isEmpty) return;
    _stream = Timer(const Duration(milliseconds: 180), () {
      if (!mounted) return;
      // ~90 ticks regardless of length: short answers don't crawl, long ones
      // don't flash past unreadably.
      final step = max(1, full.length ~/ 90);
      _stream = Timer.periodic(const Duration(milliseconds: 28), (t) {
        if (!mounted) return;
        setState(() {
          _shown = full.substring(0, min(full.length, _shown.length + step));
        });
        if (_shown.length >= full.length) t.cancel();
      });
    });
  }

  bool get _streaming =>
      widget.voice.reply.isNotEmpty &&
      _shown.length < widget.voice.reply.length;

  @override
  void dispose() {
    _stream?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = XSScale.factor;
    final palette = widget.palette;
    final voice = widget.voice;
    final hasTurn =
    voice.transcript.isNotEmpty || voice.reply.isNotEmpty;
    if (!hasTurn) return const SizedBox.shrink();

    return Padding(
    padding: EdgeInsets.symmetric(horizontal: XSSpacing.md * s),
    child: Column(
    children: [
    if (voice.transcript.isNotEmpty)
    Text(
    '“${voice.transcript}”',
    textAlign: TextAlign.center,
    maxLines: 2,
    overflow: TextOverflow.ellipsis,
    style: TextStyle(
    fontSize: 13.5 * s,
    fontStyle: FontStyle.italic,
    color: palette.textSecondary,
    ),
    ),
    if (voice.reply.isNotEmpty) ...[
    SizedBox(height: XSSpacing.xs * s),
    Container(
    constraints: BoxConstraints(maxHeight: 170 * s),
    width: double.infinity,
    padding: EdgeInsets.all(XSSpacing.md * s),
    decoration: BoxDecoration(
    color: _kSpeakGreen.withValues(alpha: 0.10),
    borderRadius: BorderRadius.circular(XSRadius.lg),
    border: Border.all(
    color: _kSpeakGreen.withValues(alpha: 0.35),
    ),
    ),
    child: SingleChildScrollView(
    child: SelectableText(
    // Live caret while the answer is still arriving.
    _streaming ? '$_shown ▍' : _shown,
    style: TextStyle(
    fontSize: 15.5 * s,
    height: 1.45,
    fontWeight: FontWeight.w500,
    color: palette.textPrimary,
    ),
    ),
    ),
    ),
    ],
    ],
    ),
    );
  }
}

// ─── QUICK ASKS ─────────────────────────────────────────────────────
class _QuickAsks extends StatelessWidget {
  final XSPalette palette;
  final bool isStaff;
  final ValueChanged<String> onSelect;

  static const _guestSuggestions = [
    (icon: Icons.monitor_heart_outlined, label: 'How do I check my vitals?'),
    (icon: Icons.graphic_eq, label: 'What does lung wheezing mean?'),
    (icon: Icons.medical_services_outlined, label: 'How does X-Ray AI work?'),
    (icon: Icons.thermostat_outlined, label: 'What is a normal temp?'),
  ];

  static const _staffSuggestions = [
    (icon: Icons.compare_outlined, label: 'Compare with a normal X-ray'),
    (icon: Icons.table_rows_outlined, label: 'Show vitals against reference'),
    (icon: Icons.account_tree_outlined, label: 'What could this be?'),
    (icon: Icons.lightbulb_outline, label: 'Recommend next steps'),
  ];

  const _QuickAsks({
    required this.palette,
    required this.isStaff,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final s = XSScale.factor;
    final items = isStaff ? _staffSuggestions : _guestSuggestions;
    return SizedBox(
      height: 40 * s,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: items.length,
        separatorBuilder: (_, _) => SizedBox(width: XSSpacing.xs * s),
        itemBuilder: (context, i) => XSChip(
          label: items[i].label,
          icon: items[i].icon,
          color: XSColors.moduleAssistant,
          onTap: () => onSelect(items[i].label),
        ),
      ),
    );
  }
}

// ─── CENTER GLOW ────────────────────────────────────────────────────
/// Soft colour wash breathing behind the orb — brighter while capturing.
class _GlowBlob extends StatelessWidget {
  final VoiceState state;

  const _GlowBlob({required this.state});

  Color get _color {
    switch (state) {
      case VoiceState.listening:
        return _kListenBlue;
      case VoiceState.thinking:
        return _kThinkAmber;
      case VoiceState.speaking:
        return _kSpeakGreen;
      default:
        return XSColors.teal;
    }
  }

  @override
  Widget build(BuildContext context) {
    final loud =
        state == VoiceState.listening || state == VoiceState.speaking;
    return IgnorePointer(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 600),
        width: 420,
        height: 420,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [
              _color.withValues(alpha: loud ? 0.16 : 0.07),
              _color.withValues(alpha: 0),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── PARTICLES ──────────────────────────────────────────────────────
/// Deterministic drifting dots. Positions are pure functions of the controller
/// time and a per-particle seed, so there is no mutable particle state to
/// rebuild — the paint pass alone produces the ambient motion.
class _ParticlePainter extends CustomPainter {
  final double t; // 0..1 looping

  _ParticlePainter({required this.t});

  @override
  void paint(Canvas canvas, Size size) {
    const count = 24;
    final rnd = Random(7); // fixed seed: stable field across frames
    for (var i = 0; i < count; i++) {
      final bx = rnd.nextDouble();
      final by = rnd.nextDouble();
      final vx = (rnd.nextDouble() - 0.5) * 0.02;
      final vy = (rnd.nextDouble() - 0.5) * 0.02;
      final phase = rnd.nextDouble();
      final radius = 1.0 + rnd.nextDouble() * 2.2;
      final alpha = 0.06 + rnd.nextDouble() * 0.14;

      final x = ((bx + vx * (t + phase)) % 1.0) * size.width;
      final y = ((by + vy * (t + phase)) % 1.0) * size.height;
      final breath = 0.75 +
          0.25 * sin((t + phase) * 2 * pi);

      canvas.drawCircle(
        Offset(x, y),
        radius * breath,
        Paint()..color = Colors.white.withValues(alpha: alpha * breath),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ParticlePainter old) => old.t != t;
}
