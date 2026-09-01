import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:http/http.dart' as http;
import '../../state/xs_settings.dart';
import '../../state/kiosk_patient_state.dart';
import '../../core/ai/xs_ai_card.dart';
import '../../core/api/zen_chat_client.dart';
import '../../core/voice/voice_guide.dart';
import '../../core/theme/xs_colors.dart';
import '../../core/theme/xs_scale.dart';
import '../../core/theme/xs_spacing.dart';
import '../../core/theme/xs_radius.dart';
import '../../core/theme/xs_typography.dart';
import '../components/xs_card.dart';
import '../components/xs_button.dart';
import '../components/xs_chip.dart';
import '../components/ai/xs_ai_canvas.dart';

/// Cross-platform TTS player calling backend /tts endpoint.
class BackendTtsPlayer {
  static AudioSource? _currentSource;

  static Future<void> stop() async {
    if (_currentSource == null) return;
    try {
      // Touching SoLoud.instance loads a native library that may be absent
      // (headless host, audio-less kiosk image). Never let that escape from a
      // dispose path.
      await SoLoud.instance.disposeSource(_currentSource!);
    } catch (e) {
      debugPrint('[backend_tts] stop unavailable: $e');
    }
    _currentSource = null;
  }

  static Future<void> speak(String text) async {
    final textClean = text.trim();
    if (textClean.isEmpty) return;

    final base = XSSettings.I.backendUrl;
    if (base.isEmpty) return;

    try {
      await stop();
      final so = SoLoud.instance;
      if (!so.isInitialized) {
        await so.init();
      }

      final uri = Uri.parse('$base/tts');
      final resp = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'text': textClean}),
          )
          .timeout(const Duration(seconds: 15));

      if (resp.statusCode == 200 && resp.bodyBytes.isNotEmpty) {
        final key = 'tts_${DateTime.now().millisecondsSinceEpoch}';
        final source = await so.loadMem(key, resp.bodyBytes);
        _currentSource = source;
        await so.play(source);
      }
    } catch (e) {
      debugPrint('[backend_tts] speak error: $e');
    }
  }
}

/// Kiosk CDSS + LLM chat assistant with real-time patient context injection.
class KioskChatScreen extends StatefulWidget {
  const KioskChatScreen({super.key});
  @override
  State<KioskChatScreen> createState() => _KioskChatScreenState();
}

/// One turn in the transcript.
///
/// Replaced a `Map<String, String>` when assistant turns gained visual-answer
/// cards: the cards belong to the turn that produced them, so scrolling back to
/// an earlier answer brings its comparison back with it.
class _Turn {
  final String role; // 'user' | 'assistant'
  final String content;
  final List<XSAiCard> cards;

  const _Turn(this.role, this.content, {this.cards = const []});

  bool get isUser => role == 'user';
}

class _KioskChatScreenState extends State<KioskChatScreen> {
  @override
  void initState() {
    super.initState();
    // This screen speaks its replies through `/tts`. Letting a guidance clip
    // start mid-answer would talk over it on the same speaker.
    VoiceGuide.I.suspend();
  }

  final _ctrl = TextEditingController();
  final _scroll = ScrollController();
  final _zen = ZenChatClient();
  final List<_Turn> _messages = [];
  bool _busy = false;
  bool _speakAudio = true;

  /// Text of the reply currently streaming in, rendered as a live bubble.
  /// Empty when no request is in flight.
  String _streaming = '';

  StreamSubscription<ChatStreamEvent>? _streamSub;

  @override
  void dispose() {
    VoiceGuide.I.resume();
    _streamSub?.cancel();
    BackendTtsPlayer.stop();
    _zen.dispose();
    _ctrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _speak(String text) async {
    if (!_speakAudio || text.isEmpty) return;
    await BackendTtsPlayer.speak(text);
  }

  void _scrollToEnd() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      _scroll.position.maxScrollExtent,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  Future<void> _send([String? preset]) async {
    final text = (preset ?? _ctrl.text).trim();
    if (text.isEmpty || _busy) return;
    _ctrl.clear();

    setState(() {
      _messages.add(_Turn('user', text));
      _busy = true;
      _streaming = '';
    });
    await Future.delayed(const Duration(milliseconds: 50));
    _scrollToEnd();

    // Streamed rather than a single POST /chat: on a local gateway a full
    // reply takes several seconds, and a spinner that long reads as a hang.
    final history = _messages
        .where((m) => m.role != 'system')
        .map((m) => ZenMessage(role: m.role, content: m.content))
        .toList();

    await _streamSub?.cancel();
    final completer = Completer<void>();
    String finalText = '';
    var finalCards = const <XSAiCard>[];

    _streamSub = _zen
        .stream(
          history,
          kioskMode: true,
          patientContext: KioskPatientSession.I.clinicalContextPrompt,
        )
        .listen(
          (event) {
            if (!mounted) return;
            if (event.isFinal) {
              finalText = event.finalText ?? '';
              finalCards = event.cards;
            } else if (event.delta != null) {
              setState(() => _streaming += event.delta!);
              _scrollToEnd();
            }
          },
          onError: (e) {
            if (!mounted) return;
            // Full upstream details (URLs, gateway bodies) stay in the debug log —
            // this is a public kiosk panel, so the bubble only ever says the
            // generic line.
            debugPrint('[chat] stream failed: $e');
            setState(() {
              _messages.add(
                const _Turn('assistant', 'No connection. Please try again.'),
              );
              _busy = false;
              _streaming = '';
            });
            if (!completer.isCompleted) completer.complete();
          },
          onDone: () {
            if (!mounted) return;
            // The backend's `final` payload is the fully cleaned text; deltas are
            // filtered incrementally and can differ slightly. Prefer `final`.
            var reply = finalText.isNotEmpty ? finalText : _streaming;
            var cards = finalCards;
            // Safety net for a backend that does not strip card fences: without
            // this the JSON renders in the bubble and gets read aloud by TTS.
            if (cards.isEmpty) {
              final salvaged = XSAiCard.extract(reply);
              reply = salvaged.$1;
              cards = salvaged.$2;
            }
            setState(() {
              if (reply.isNotEmpty || cards.isNotEmpty) {
                _messages.add(_Turn('assistant', reply, cards: cards));
              }
              _busy = false;
              _streaming = '';
            });
            if (reply.isNotEmpty) _speak(reply);
            _scrollToEnd();
            if (!completer.isCompleted) completer.complete();
          },
          cancelOnError: true,
        );

    await completer.future;
  }

  Widget _quickChip(XSPalette palette, String label, IconData icon) {
    return Padding(
      padding: EdgeInsets.only(right: XSSpacing.xs * XSScale.factor),
      child: XSChip(
        label: label,
        icon: icon,
        color: XSColors.moduleAssistant,
        onTap: _busy ? null : () => _send(label),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    final session = KioskPatientSession.I;
    final s = XSScale.factor;

    // Material, not Padding, at the root: this screen is pushed as a route
    // from the voice stage, and a pushed page has no Material ancestor — the
    // starter-card InkWells then die with "No Material widget found" and take
    // the frame (and everything after it) down. Embedded inside the shell's
    // Scaffold the ancestor existed, which is why this only surfaced once
    // chat became a route. Material also supplies the page background the
    // Scaffold used to provide.
    return Material(
      type: MaterialType.canvas,
      color: palette.surface,
      child: Padding(
        padding: EdgeInsets.all(XSSpacing.lg * s),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ─── TOP HEADER ────────────────────────────────────────────────
            // The old design burned a full banner row just to name the patient;
            // that context now lives in the subtitle, which matters on a
            // 655px-tall panel where every reclaimed row is another visible reply.
            Row(
              children: [
                Container(
                  padding: EdgeInsets.all(9 * s),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        XSColors.moduleAssistant,
                        XSColors.moduleAssistant.withValues(alpha: 0.55),
                      ],
                    ),
                    borderRadius: BorderRadius.circular(12 * s),
                  ),
                  child: Icon(
                    Icons.psychology_outlined,
                    size: 25 * s,
                    color: Colors.white,
                  ),
                ),
                SizedBox(width: XSSpacing.sm * s),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'AI Clinical Assistant',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          color: palette.textPrimary,
                        ),
                      ),
                      Text(
                        '${session.patientDisplayName} · '
                        '$_measuredCount of 4 stations',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: palette.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                XSButton(
                  icon: _speakAudio ? Icons.volume_up : Icons.volume_off,
                  tooltip: _speakAudio
                      ? 'Voice response ON'
                      : 'Voice response OFF',
                  color: _speakAudio ? XSColors.moduleAssistant : null,
                  onPressed: () => setState(() {
                    _speakAudio = !_speakAudio;
                    if (!_speakAudio) BackendTtsPlayer.stop();
                  }),
                ),
                SizedBox(width: XSSpacing.xs * s),
                XSButton(
                  icon: Icons.clear_all,
                  tooltip: 'Clear chat',
                  onPressed: _messages.isEmpty
                      ? null
                      : () => setState(() {
                          BackendTtsPlayer.stop();
                          _streamSub?.cancel();
                          _messages.clear();
                          _streaming = '';
                          _busy = false;
                        }),
                ),
              ],
            ),
            SizedBox(height: XSSpacing.sm * s),

            // ─── CHAT MESSAGES LIST ─────────────────────────────────────────
            Expanded(
              child: XSCard(
                padding: EdgeInsets.all(XSSpacing.md * s),
                // The welcome text used to be injected as a fake assistant
                // message, which then got sent back to the model as real
                // conversation history. It is now a pure empty state.
                child: _messages.isEmpty && !_busy
                    ? _ChatEmptyState(
                        patientLabel: session.patientDisplayName,
                        measured: _measuredCount,
                        onAsk: _send,
                      )
                    : ListView.builder(
                        controller: _scroll,
                        itemCount: _messages.length + (_busy ? 1 : 0),
                        itemBuilder: (ctx, i) {
                          if (i == _messages.length && _busy) {
                            // Live reply. Falls back to a spinner row until the
                            // first token lands.
                            return _streaming.isEmpty
                                ? _PendingBubble(palette: palette, scale: s)
                                : _bubble(
                                    context,
                                    palette,
                                    s,
                                    isUser: false,
                                    content: _streaming,
                                    streaming: true,
                                  );
                          }

                          final m = _messages[i];
                          return _bubble(
                            context,
                            palette,
                            s,
                            isUser: m.isUser,
                            content: m.content,
                            cards: m.cards,
                          );
                        },
                      ),
              ),
            ),
            SizedBox(height: XSSpacing.sm * s),

            // ─── QUICK REPLIES CHIPS BAR ────────────────────────────────────
            SizedBox(
              height: 48 * s,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  _quickChip(
                    palette,
                    'Summarize my findings',
                    Icons.assessment_outlined,
                  ),
                  // Phrased to invite a visual answer — these are the prompts the
                  // assistant most reliably answers with an xray_compare /
                  // vitals_table card.
                  _quickChip(
                    palette,
                    'Compare with a normal X-ray',
                    Icons.compare_outlined,
                  ),
                  _quickChip(
                    palette,
                    'Show vitals against reference ranges',
                    Icons.table_rows_outlined,
                  ),
                  _quickChip(
                    palette,
                    'What could this be?',
                    Icons.account_tree_outlined,
                  ),
                  _quickChip(
                    palette,
                    'Explain X-ray results',
                    Icons.medical_services_outlined,
                  ),
                  _quickChip(palette, 'Assess lung sounds', Icons.graphic_eq),
                  _quickChip(
                    palette,
                    'Check vital signs',
                    Icons.monitor_heart_outlined,
                  ),
                  _quickChip(
                    palette,
                    'Recommend next steps',
                    Icons.lightbulb_outline,
                  ),
                  _quickChip(
                    palette,
                    'Draft referral note',
                    Icons.description_outlined,
                  ),
                ],
              ),
            ),
            SizedBox(height: XSSpacing.xs * s),

            // ─── INPUT BAR ──────────────────────────────────────────────────
            Row(
              children: [
                XSButton(
                  icon: Icons.mic,
                  tooltip: 'Back to Voice Mode',
                  height: 64,
                  // The chat is pushed over the embedded voice stage, so "mic"
                  // means going back to it — pushing a second stage would stack
                  // two live voice sockets on one speaker.
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
                SizedBox(width: XSSpacing.xs * s),
                Expanded(
                  child: TextField(
                    controller: _ctrl,
                    enabled: !_busy,
                    textInputAction: TextInputAction.send,
                    style: const TextStyle(fontSize: 16),
                    decoration: InputDecoration(
                      hintText: _busy
                          ? 'Waiting for the assistant...'
                          : 'Ask about your readings...',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14 * s),
                      ),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 16 * s,
                        vertical: 18 * s,
                      ),
                    ),
                    onSubmitted: (_) => _send(),
                  ),
                ),
                SizedBox(width: XSSpacing.sm * s),
                XSButton(
                  icon: Icons.send,
                  tooltip: 'Send',
                  color: XSColors.moduleAssistant,
                  height: 64,
                  onPressed: _busy ? null : _send,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// One chat bubble. Shared by history and the live streaming reply so both
  /// can't drift apart visually.
  Widget _bubble(
    BuildContext context,
    XSPalette palette,
    double s, {
    required bool isUser,
    required String content,
    bool streaming = false,
    List<XSAiCard> cards = const [],
  }) {
    // Cards need more room than a prose bubble: a three-panel film comparison
    // inside a 760px cap is unreadable on a kiosk panel.
    final maxWidth =
        (MediaQuery.of(context).size.width * (cards.isEmpty ? 0.7 : 0.92))
            .clamp(280.0, cards.isEmpty ? 760.0 : 1100.0);

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (content.trim().isNotEmpty)
              _bubbleBody(
                context,
                palette,
                s,
                isUser: isUser,
                content: content,
                streaming: streaming,
                hasCards: cards.isNotEmpty,
              ),
            if (cards.isNotEmpty)
              Padding(
                padding: EdgeInsets.only(bottom: XSSpacing.sm * s),
                child: XSAiCanvas(cards: cards),
              ),
          ],
        ),
      ),
    );
  }

  Widget _bubbleBody(
    BuildContext context,
    XSPalette palette,
    double s, {
    required bool isUser,
    required String content,
    required bool streaming,
    required bool hasCards,
  }) {
    return Container(
      margin: EdgeInsets.only(bottom: hasCards ? 0 : XSSpacing.sm * s),
      padding: EdgeInsets.symmetric(
        horizontal: XSSpacing.lg * s,
        vertical: XSSpacing.md * s,
      ),
      decoration: BoxDecoration(
        color: isUser
            ? XSColors.moduleAssistant.withValues(alpha: 0.14)
            : palette.highlight,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(18 * s),
          topRight: Radius.circular(18 * s),
          bottomLeft: Radius.circular(isUser ? 18 * s : 4 * s),
          bottomRight: Radius.circular(isUser ? 4 * s : 18 * s),
        ),
        border: Border.all(
          color: isUser
              ? XSColors.moduleAssistant.withValues(alpha: 0.35)
              : streaming
              ? XSColors.moduleAssistant.withValues(alpha: 0.45)
              : palette.divider,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isUser ? Icons.person_outline : Icons.psychology_outlined,
                size: 14 * s,
                color: isUser
                    ? XSColors.moduleAssistant
                    : palette.textSecondary,
              ),
              SizedBox(width: 5 * s),
              Text(
                isUser ? 'YOU' : 'XSIGHT AI',
                style: XSTypography.eyebrow(
                  isUser ? XSColors.moduleAssistant : palette.textSecondary,
                ).copyWith(fontSize: 11),
              ),
              if (streaming) ...[
                SizedBox(width: 6 * s),
                _TypingCaret(color: XSColors.moduleAssistant),
              ],
            ],
          ),
          SizedBox(height: 6 * s),
          SelectableText(
            content,
            style: TextStyle(
              fontSize: 16,
              height: 1.5,
              color: palette.textPrimary,
            ),
          ),
        ],
      ),
    );
  }

  /// How many of the four stations have real data behind them.
  int get _measuredCount => KioskPatientSession.I.measuredStationCount;
}

/// Shown before the first message. Replaces a synthetic "assistant" greeting
/// that was being replayed to the model as if the user had heard it.
class _ChatEmptyState extends StatelessWidget {
  final String patientLabel;
  final int measured;
  final void Function(String) onAsk;

  const _ChatEmptyState({
    required this.patientLabel,
    required this.measured,
    required this.onAsk,
  });

  static const _starters = [
    (
      icon: Icons.assessment_outlined,
      title: 'Summarize this session',
      sub: 'What was measured and what it means',
      query: 'Summarize the readings captured in this session.',
    ),
    (
      icon: Icons.medical_services_outlined,
      title: 'Explain the X-ray finding',
      sub: 'Plain-language reading of the radiograph result',
      query: 'Explain the chest X-ray finding for this patient.',
    ),
    (
      icon: Icons.graphic_eq,
      title: 'Interpret the lung sounds',
      sub: 'What the acoustic classification suggests',
      query: 'Interpret the stethoscope acoustic finding.',
    ),
    (
      icon: Icons.lightbulb_outline,
      title: 'Recommend next steps',
      sub: 'Triage priority and follow-up options',
      query: 'Recommend appropriate next steps for this patient.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    final s = XSScale.factor;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(height: XSSpacing.md * s),
          Icon(
            Icons.psychology_outlined,
            size: 44 * s,
            color: XSColors.moduleAssistant,
          ),
          SizedBox(height: XSSpacing.sm * s),
          Text(
            'Ask about this session',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: palette.textPrimary,
            ),
          ),
          SizedBox(height: 4 * s),
          Text(
            measured == 0
                ? 'No stations completed yet — I can still answer clinical '
                      'questions, but I have no readings for $patientLabel.'
                : 'I have $measured of 4 stations for $patientLabel.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: palette.textSecondary),
          ),
          SizedBox(height: XSSpacing.lg * s),
          // Wrap rather than a fixed grid: the kiosk panel and a phone are
          // both in play, and cards must reflow instead of overflowing.
          Wrap(
            alignment: WrapAlignment.center,
            spacing: XSSpacing.sm * s,
            runSpacing: XSSpacing.sm * s,
            children: _starters.map((item) {
              return ConstrainedBox(
                constraints: BoxConstraints(maxWidth: 340 * s),
                child: InkWell(
                  onTap: () => onAsk(item.query),
                  borderRadius: BorderRadius.circular(XSRadius.md),
                  child: Container(
                    width: 340 * s,
                    padding: EdgeInsets.all(XSSpacing.sm * s),
                    decoration: BoxDecoration(
                      color: palette.highlight,
                      borderRadius: BorderRadius.circular(XSRadius.md),
                      border: Border.all(color: palette.divider),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          item.icon,
                          size: 20 * s,
                          color: XSColors.moduleAssistant,
                        ),
                        SizedBox(width: XSSpacing.sm * s),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                item.title,
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  color: palette.textPrimary,
                                ),
                              ),
                              Text(
                                item.sub,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: palette.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Icon(
                          Icons.arrow_forward_ios,
                          size: 12 * s,
                          color: palette.textSecondary,
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          SizedBox(height: XSSpacing.lg * s),
          Text(
            'AI-assisted decision support. Not a diagnosis — clinician '
            'confirmation required.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: palette.textSecondary),
          ),
        ],
      ),
    );
  }
}

/// Spinner bubble shown between send and the first streamed token.
class _PendingBubble extends StatelessWidget {
  final XSPalette palette;
  final double scale;
  const _PendingBubble({required this.palette, required this.scale});

  @override
  Widget build(BuildContext context) {
    final s = scale;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: EdgeInsets.only(bottom: XSSpacing.sm * s),
        padding: EdgeInsets.all(XSSpacing.md * s),
        decoration: BoxDecoration(
          color: palette.surface,
          borderRadius: BorderRadius.circular(14 * s),
          border: Border.all(color: palette.divider),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 17 * s,
              height: 17 * s,
              child: const CircularProgressIndicator(
                strokeWidth: 2,
                color: XSColors.moduleAssistant,
              ),
            ),
            SizedBox(width: 10 * s),
            Text(
              'Thinking...',
              style: TextStyle(fontSize: 15, color: palette.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

/// Blinking caret marking a reply that is still arriving.
class _TypingCaret extends StatefulWidget {
  final Color color;
  const _TypingCaret({required this.color});

  @override
  State<_TypingCaret> createState() => _TypingCaretState();
}

class _TypingCaretState extends State<_TypingCaret>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 600),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween(begin: 1.0, end: 0.15).animate(_ctrl),
      child: Container(
        width: 7,
        height: 7,
        decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
      ),
    );
  }
}
