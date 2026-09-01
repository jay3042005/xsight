import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../config/xs_config.dart';
import '../../state/xs_settings.dart';
import '../ai/xs_ai_card.dart';
import 'pcm_player.dart';

/// State of the voice loop.
enum VoiceState {
  idle,
  connecting,
  listening,
  thinking,
  speaking,
  error,
}

/// Realtime voice client that pipes mic audio into the backend's
/// `/ws/voice` endpoint and plays the returned PCM16 audio chunks.
class VoiceClient extends ChangeNotifier {
  final AudioRecorder _recorder = AudioRecorder();
  final SafePcmPlayer _player = SafePcmPlayer(sampleRate: 24000);

  // Android's built-in speech recognizer (Google's STT service). When
  // available it replaces the mic-streaming input path: it cannot share the
  // microphone with `record`, so the recorder is never started and
  // recognized text is sent as a normal text turn (see [_startOnDevice]).
  final SpeechToText _stt = SpeechToText();
  bool _sttReady = false;
  bool _sttActive = false;
  bool _speechStartedFired = false;

  WebSocketChannel? _channel;
  StreamSubscription<Uint8List>? _micSub;
  bool _disposed = false;
  bool _playerOpen = false;

  VoiceState _state = VoiceState.idle;
  String _transcript = '';
  String _reply = '';
  List<XSAiCard> _cards = const [];
  String? _error;
  double _micLevel = 0;
  double _outLevel = 0;
  Timer? _levelTicker;
  Timer? _ttsDoneTimer;
  Stopwatch? _ttsPlaybackClock;
  Timer? _releaseTimer;

  /// Fired when the server's VAD detects the start of a user utterance.
  /// RobotController hooks this to start a parallel camera capture.
  VoidCallback? onSpeechStarted;

  /// True when the platform's built-in speech recognizer (Google's STT
  /// service on Android) is handling voice input. The voice stage surfaces
  /// this so a user can tell which input path is live.
  bool get usingOnDeviceStt => _sttReady;

  /// The on-device recognizer is only wired for Android, where Google's STT
  /// service is built in. Other platforms keep the server's Whisper path.
  static bool get _onDeviceSttSupported => !kIsWeb && Platform.isAndroid;

  VoiceState get state => _state;
  String get transcript => _transcript;
  String get reply => _reply;

  /// Visual-answer cards for the turn currently being answered. Cleared when a
  /// new utterance starts, so the panel on screen always belongs to the reply
  /// being spoken rather than the previous question.
  List<XSAiCard> get cards => _cards;
  String? get error => _error;
  bool get isConnected => _channel != null && _state != VoiceState.idle;

  /// Live input amplitude, 0..1, computed from the outgoing mic frames.
  /// Non-zero only while [VoiceState.listening].
  double get micLevel => _micLevel;

  /// Live output amplitude, 0..1, from the TTS chunk currently playing.
  /// Non-zero only while the assistant is speaking.
  double get outLevel => _outLevel;

  /// Whichever side is currently making sound — what a single visualizer
  /// should react to.
  double get activeLevel =>
      _state == VoiceState.listening ? _micLevel : _outLevel;

  /// Enumerate the microphones this platform can record from.
  ///
  /// Static so Settings can list devices without owning a live voice session.
  /// Returns empty rather than throwing when the platform has no enumeration
  /// support, so the caller can fall back to "system default only".
  static Future<List<InputDevice>> listInputDevices() async {
    final recorder = AudioRecorder();
    try {
      return await recorder.listInputDevices();
    } catch (e) {
      debugPrint('[voice] input-device enumeration unavailable: $e');
      return const [];
    } finally {
      await recorder.dispose();
    }
  }

  /// The mic chosen in Settings, or null for the platform default.
  ///
  /// Resolved per-recording rather than cached: a USB headset can be plugged in
  /// or pulled out between turns, and a stale [InputDevice] would silently
  /// record from nothing.
  InputDevice? _selectedInputDevice() {
    final id = XSSettings.I.inputDeviceId;
    if (id.isEmpty) return null;
    return InputDevice(id: id, label: XSSettings.I.inputDeviceLabel);
  }

  Future<void> start() async {
    if (_state != VoiceState.idle && _state != VoiceState.error) return;
    _setState(VoiceState.connecting);
    _error = null;

    final base = XSSettings.I.hasBackend
        ? XSSettings.I.backendUrl
        : XSConfig.backendBaseUrl;
    if (base.isEmpty) {
      _error = 'No server IP configured. Set it in Settings.';
      _setState(VoiceState.error);
      return;
    }

    final wsUrl = base
        .replaceFirst(RegExp(r'^http://'), 'ws://')
        .replaceFirst(RegExp(r'^https://'), 'wss://');
    final uri = Uri.parse('$wsUrl/ws/voice');
    debugPrint('[voice] connecting to $uri');

    try {
      _channel = IOWebSocketChannel.connect(
        uri,
        pingInterval: const Duration(seconds: 30),
      );
      _channel!.stream.listen(
        _onWsMessage,
        onError: (e) {
          // Kiosk panel: never render transport internals (URLs, socket
          // errors) — they go to the debug log, the stage shows the generic
          // line.
          debugPrint('[voice] ws error: $e');
          _error = 'No connection. Please try again.';
          _setState(VoiceState.error);
        },
        onDone: () {
          debugPrint('[voice] ws closed');
          if (!_disposed) _setState(VoiceState.idle);
        },
        cancelOnError: false,
      );

      // Android: prefer the platform's built-in speech recognizer. It takes
      // over the microphone, so the recorder stream below is never started —
      // recognized text is sent as a text turn and the reply path (chat +
      // streamed TTS) is identical either way. If the recognizer is missing
      // or denied, fall back to streaming raw audio to the server.
      if (_onDeviceSttSupported) {
        try {
          _sttReady = await _stt.initialize(
            onError: (e) => debugPrint('[voice] on-device STT error: $e'),
            onStatus: (s) => debugPrint('[voice] on-device STT status: $s'),
          );
        } catch (e) {
          debugPrint('[voice] on-device STT init failed: $e');
          _sttReady = false;
        }
        if (_sttReady) {
          debugPrint('[voice] input: on-device Google speech recognition');
          _startLevelTicker();
          _setState(VoiceState.idle);
          return;
        }
        debugPrint(
          '[voice] on-device STT unavailable — using server streaming',
        );
      }

      if (!await _recorder.hasPermission()) {
        _error = 'Microphone permission denied.';
        _setState(VoiceState.error);
        return;
      }

      final stream = await _recorder.startStream(
        RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
          bitRate: 256000,
          autoGain: true,
          echoCancel: true,
          noiseSuppress: true,
          // Honour the mic chosen in Settings. Null means the platform default,
          // which on a kiosk is often the wrong one — a tablet with a USB
          // headset attached may still route to its own far-field mic.
          device: _selectedInputDevice(),
        ),
      );

      _micSub = stream.listen(
        (Uint8List bytes) {
          final ch = _channel;
          if (ch == null) return;
          if (_state == VoiceState.listening) {
            ch.sink.add(bytes);
            _micLevel = _rms(bytes);
          } else if (_micLevel != 0) {
            _micLevel = 0;
          }
        },
        onError: (e) => debugPrint('[voice] mic error: $e'),
      );

      _startLevelTicker();
      _setState(VoiceState.idle);
    } catch (e) {
      debugPrint('[voice] start failed: $e');
      _error = 'No connection. Please try again.';
      _setState(VoiceState.error);
    }
  }

  /// Start listening for user voice input.
  void startListening() {
    if (_state == VoiceState.listening) return;
    _releaseTimer?.cancel();
    _releaseTimer = null;
    if (_state == VoiceState.speaking || _state == VoiceState.thinking) {
      interrupt();
    }
    if (_sttReady) {
      _startOnDeviceListening();
      return;
    }
    _setState(VoiceState.listening);
  }

  /// On-device (Google) recognition: hold-to-talk drives the recognizer, the
  /// final result is submitted as a normal text turn, and the level events
  /// feed the visualizer in place of the mic frames the recorder used to
  /// provide.
  Future<void> _startOnDeviceListening() async {
    _setState(VoiceState.listening);
    _sttActive = true;
    _speechStartedFired = false;
    _transcript = '';
    try {
      await _stt.listen(
        onResult: (result) {
          _transcript = result.recognizedWords;
          // Parity with the server path's VAD event, which this recognizer
          // has no equivalent of: fire once per turn on first speech.
          if (!_speechStartedFired && _transcript.isNotEmpty) {
            _speechStartedFired = true;
            try {
              onSpeechStarted?.call();
            } catch (e) {
              debugPrint('[voice] onSpeechStarted error: $e');
            }
          }
          if (result.finalResult) {
            _sttActive = false;
            _micLevel = 0;
            final clean = _transcript.trim();
            if (clean.isNotEmpty) {
              sendTextQuery(clean);
            } else if (_state == VoiceState.listening) {
              _setState(VoiceState.idle);
            }
          }
          notifyListeners();
        },
        onSoundLevelChange: (db) {
          // The recognizer reports dB relative to full scale; map the normal
          // speaking range onto the visualizer's 0..1.
          _micLevel = ((db + 25) / 25).clamp(0.0, 1.0);
          notifyListeners();
        },
        listenOptions: SpeechListenOptions(
          partialResults: true,
          cancelOnError: true,
          autoPunctuation: true,
        ),
      );
    } catch (e) {
      debugPrint('[voice] on-device listen failed: $e');
      _sttActive = false;
      if (_state == VoiceState.listening) _setState(VoiceState.idle);
    }
  }

  /// Hold-to-talk release.
  ///
  /// The server's VAD closes an utterance only after ~500 ms of trailing
  /// silence, and silence is only counted while frames keep arriving — a
  /// client that simply stops streaming on release would leave the turn open
  /// forever. So keep the mic (now pointed at a quiet room) running for just
  /// under a second; that IS the end-of-turn signal. If no transcript lands
  /// in the window, nobody spoke and the loop drops back to idle.
  void releaseMic() {
    if (_state != VoiceState.listening) return;
    // On-device recognizer: stop() emits the final result, which submits the
    // turn. The timer below is the no-speech fallback — it only lands if no
    // result arrives (held the button, said nothing).
    if (_sttActive) {
      _sttActive = false;
      _stt.stop();
    }
    _releaseTimer?.cancel();
    _releaseTimer = Timer(const Duration(milliseconds: 950), () {
      if (_state == VoiceState.listening) _setState(VoiceState.idle);
    });
  }

  /// Send a text query over the websocket channel.
  ///
  /// The server handles this as a full turn (transcript → reply → TTS), so a
  /// typed question behaves exactly like a spoken one.
  void sendTextQuery(String text) {
    final clean = text.trim();
    if (clean.isEmpty) return;
    final ch = _channel;
    if (ch == null) {
      // Surface it instead of dropping the tap: a quick-ask pill pressed
      // before the socket is up used to do nothing at all.
      _error = 'Voice gateway not connected. Tap the sphere to retry.';
      _setState(VoiceState.error);
      return;
    }
    _transcript = clean;
    _setState(VoiceState.thinking);
    ch.sink.add(jsonEncode({'event': 'text', 'text': clean}));
  }

  /// Give the server the session's measured readings. Injected after the
  /// trusted system prompt, so it adds facts without overriding safety rules.
  /// Safe to call repeatedly; last value wins for subsequent turns.
  void setPatientContext(String context) {
    final ch = _channel;
    if (ch == null) return;
    ch.sink.add(jsonEncode({'event': 'patient_context', 'text': context}));
  }

  /// Tell the server which persona to answer in: the clinical CDSS assistant
  /// for staff, the warm companion for a walk-up guest.
  ///
  /// The socket used to be hardcoded to the companion persona server-side, so a
  /// clinician asking a clinical question aloud got reassurance instead of
  /// decision support. Safe to call repeatedly; applies from the next turn.
  void setKioskMode(bool kiosk) {
    final ch = _channel;
    if (ch == null) return;
    ch.sink.add(jsonEncode({'event': 'mode', 'kiosk': kiosk}));
  }

  /// Tap-to-interrupt: stop the robot and re-arm the mic.
  Future<void> interrupt() async {
    final ch = _channel;
    if (ch == null) return;
    debugPrint('[voice] interrupt');
    _releaseTimer?.cancel();
    _releaseTimer = null;
    await _player.stop();
    _playerOpen = false;
    _outLevel = 0;
    ch.sink.add(jsonEncode({'event': 'interrupt'}));
    _setState(VoiceState.idle);
  }

  /// Inject a one-shot vision context that the server will prepend to the
  /// next user turn (so the LLM "sees" what the camera saw).
  void setVisionContext(String description) {
    final ch = _channel;
    if (ch == null) return;
    ch.sink.add(jsonEncode({
      'event': 'vision_context',
      'text': description,
    }));
  }

  void reset() {
    _channel?.sink.add(jsonEncode({'event': 'reset'}));
    _transcript = '';
    _reply = '';
    _cards = const [];
    notifyListeners();
  }

  Future<void> stop() async {
    _levelTicker?.cancel();
    _levelTicker = null;
    _ttsDoneTimer?.cancel();
    _ttsDoneTimer = null;
    _releaseTimer?.cancel();
    _releaseTimer = null;
    _sttActive = false;
    if (_sttReady) {
      try {
        await _stt.stop();
      } catch (_) {}
      _sttReady = false; // re-initialize on the next start()
    }
    await _micSub?.cancel();
    _micSub = null;
    try {
      await _recorder.stop();
    } catch (_) {}
    try {
      await _channel?.sink.close();
    } catch (_) {}
    _channel = null;
    await _player.stop();
    _playerOpen = false;
    _micLevel = 0;
    _outLevel = 0;
    _setState(VoiceState.idle);
  }

  // -------------------------------------------------------------------

  /// Republishes the playback amplitude on a fixed cadence.
  ///
  /// Mic level updates arrive with each outgoing frame, but TTS output level
  /// only changes when a chunk lands — which is far too coarse for a smooth
  /// visualizer. A 60 ms tick gives the UI a steady signal without rebuilding
  /// on every audio callback.
  void _startLevelTicker() {
    _levelTicker?.cancel();
    _levelTicker = Timer.periodic(const Duration(milliseconds: 60), (_) {
      if (_disposed) return;
      final next = _state == VoiceState.speaking ? _player.level : 0.0;
      final changed = (next - _outLevel).abs() > 0.01;
      _outLevel = next;
      if (changed || _state == VoiceState.listening) notifyListeners();
    });
  }

  /// Root-mean-square amplitude of a PCM16 LE frame, normalized to 0..1.
  static double _rms(Uint8List bytes) {
    final samples = bytes.lengthInBytes ~/ 2;
    if (samples == 0) return 0;
    final view = ByteData.sublistView(bytes, 0, samples * 2);
    var sum = 0.0;
    var counted = 0;
    for (var i = 0; i < samples; i += 4) {
      final s = view.getInt16(i * 2, Endian.little) / 32768.0;
      sum += s * s;
      counted++;
    }
    if (counted == 0) return 0;
    // Mic input sits well below full scale; scale up so a normal speaking
    // voice uses most of the visual range instead of a flat sliver.
    return (math.sqrt(sum / counted) * 3.2).clamp(0.0, 1.0);
  }

  void _onWsMessage(dynamic msg) {
    if (_disposed) return;
    if (msg is List<int>) {
      // Binary frame: PCM16 audio chunk from Kokoro.
      _ensurePlayer();
      _player.feed(Uint8List.fromList(msg));
      return;
    }
    if (msg is String) {
      try {
        final obj = jsonDecode(msg) as Map<String, dynamic>;
        final event = obj['event'] as String?;
        switch (event) {
          case 'speech_started':
            // VAD detected the start of a user utterance.
            try {
              onSpeechStarted?.call();
            } catch (e) {
              debugPrint('[voice] onSpeechStarted error: $e');
            }
            break;
          case 'transcript':
            _transcript = (obj['text'] as String?) ?? '';
            if (_transcript.isNotEmpty) {
              // A new question invalidates the previous answer's visuals.
              _cards = const [];
              _setState(VoiceState.thinking);
            }
            notifyListeners();
            break;
          case 'reply':
            _reply = (obj['text'] as String?) ?? '';
            // Safety net: the backend strips card fences before TTS, but an
            // older server would leave them in the reply text, where they
            // would render as raw JSON in the transcript card.
            final salvaged = XSAiCard.extract(_reply);
            if (salvaged.$2.isNotEmpty) {
              _reply = salvaged.$1;
              _cards = [..._cards, ...salvaged.$2];
            }
            // Keep the thinking state until audio is about to arrive. Showing
            // the answer early made the visual state race ahead of TTS.
            notifyListeners();
            break;
          case 'card':
            final card = XSAiCard.parseList([obj['data']]);
            if (card.isNotEmpty) {
              _cards = [..._cards, ...card];
              notifyListeners();
            }
            break;
          case 'tts_start':
            _ensurePlayer();
            _ttsPlaybackClock = Stopwatch()..start();
            _setState(VoiceState.speaking);
            break;
          case 'tts_done':
            _player.end();
            _playerOpen = false;
            _outLevel = 0;
            final totalMs = (obj['audio_duration_ms'] as num?)?.toInt() ?? 0;
            final elapsedMs = _ttsPlaybackClock?.elapsedMilliseconds ?? 0;
            _ttsPlaybackClock = null;
            _ttsDoneTimer?.cancel();
            // WebSocket delivery completes before SoLoud drains its PCM queue.
            // Keep the UI/mic in speaking mode until that queued audio ends.
            _ttsDoneTimer = Timer(
              Duration(milliseconds: math.max(0, totalMs - elapsedMs + 250)),
              () {
                if (!_disposed && _state == VoiceState.speaking) {
                  _setState(VoiceState.idle);
                }
              },
            );
            break;
          case 'error':
            _error = obj['detail']?.toString() ?? 'unknown error';
            debugPrint('[voice] server error: $_error');
            _setState(VoiceState.error);
            break;
        }
      } catch (e) {
        debugPrint('[voice] bad json: $e');
      }
    }
  }

  void _ensurePlayer() {
    if (_playerOpen) return;
    _playerOpen = true;
    // Begin asynchronously; feed() is safe to call before begin completes
    // because SafePcmPlayer guards on its inner instance.
    _player.begin();
  }

  void _setState(VoiceState s) {
    if (s != VoiceState.speaking) {
      _ttsDoneTimer?.cancel();
      _ttsDoneTimer = null;
      _ttsPlaybackClock = null;
    }
    _state = s;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    stop();
    super.dispose();
  }
}
