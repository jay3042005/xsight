import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/api/zen_chat_client.dart';
import '../core/voice/voice_client.dart';

/// High-level state of Robot Mode (mirrors VoiceClient's states + adds
/// the visual-observation phase so the UI can show "looking at you").
enum RobotState {
  idle,
  initializing,
  listening,
  thinking,
  speaking,
  observing,
  error,
}

/// One side of the conversation, shown in the persistent transcript card.
enum RobotSpeaker { user, robot }

class RobotTurn {
  final RobotSpeaker speaker;
  final String text;
  final DateTime ts;
  const RobotTurn({
    required this.speaker,
    required this.text,
    required this.ts,
  });

  RobotTurn copyWith({String? text}) =>
      RobotTurn(speaker: speaker, text: text ?? this.text, ts: ts);
}

/// Drives Robot Mode using the server-side voice pipeline:
///   - Mic audio is streamed to the backend `/ws/voice` (faster-whisper).
///   - The server runs the chat call and streams Kokoro PCM16 audio back.
///   - When the user asks a "what do you see" style question, this
///     controller takes a camera frame, calls `/vision`, and pushes the
///     description into the WebSocket as a `vision_context` event so the
///     LLM "sees" what the camera saw.
class RobotController extends ChangeNotifier {
  final VoiceClient _voice = VoiceClient();
  final ZenChatClient _vision = ZenChatClient();

  CameraController? camera;
  bool _disposed = false;
  Timer? _backgroundVisionTimer;
  Timer? _objectDetectionTimer;
  bool _detectInFlight = false;
  List<CameraDescription> _availableCameras = const [];
  int _activeCameraIndex = 0;
  bool _switchingCamera = false;

  RobotState _state = RobotState.idle;
  String? _error;
  String? _lastVision;
  List<String> _detectedObjects = const [];

  /// Persistent transcript shown in the conversation card. We keep both
  /// user turns and robot replies here so previous messages don't vanish
  /// when the state changes.
  final List<RobotTurn> _turns = [];

  /// Tracks the currently-streaming robot reply so we can update its text
  /// in place as more PCM chunks arrive.
  String _lastSeenReply = '';

  /// Tracks the last finalized user transcript so we don't add it twice.
  String _lastSeenTranscript = '';

  RobotState get state => _state;
  String get transcript => _voice.transcript;
  String get lastReply => _voice.reply;
  String? get lastVision => _lastVision;
  String? get error => _error ?? _voice.error;
  List<RobotTurn> get turns => List.unmodifiable(_turns);
  List<String> get detectedObjects => List.unmodifiable(_detectedObjects);

  /// True when more than one camera is available so the UI can show the
  /// "switch camera" button.
  bool get hasMultipleCameras => _availableCameras.length > 1;

  /// Lens direction of the currently active camera (front / back / external).
  CameraLensDirection? get activeCameraLensDirection {
    if (_availableCameras.isEmpty) return null;
    return _availableCameras[_activeCameraIndex].lensDirection;
  }

  RobotController() {
    _voice.addListener(_onVoiceChange);
    _voice.onSpeechStarted = _onSpeechStarted;
  }

  /// Server told us the user just started talking — kick off a camera
  /// capture in parallel so the vision context is ready by the time the
  /// user finishes the sentence.
  void _onSpeechStarted() {
    debugPrint('[robot] speech_started — capturing frame in parallel');
    // ignore: unawaited_futures
    _backgroundCapture();
  }

  void _onVoiceChange() {
    if (_disposed) return;
    _captureTurnsFromVoice();
    // Mirror the voice client state into our higher-level state.
    switch (_voice.state) {
      case VoiceState.idle:
        if (_state != RobotState.error) _setState(RobotState.idle);
        break;
      case VoiceState.connecting:
        _setState(RobotState.initializing);
        break;
      case VoiceState.listening:
        _setState(RobotState.listening);
        // When we just heard a transcript, see if the user asked a visual
        // question and (if so) capture a frame off the main loop, passing
        // the user's question so the vision model adapts.
        final text = _voice.transcript.trim();
        if (text.isNotEmpty && _wantsVision(text)) {
          _maybeCaptureVision(text);
        }
        break;
      case VoiceState.thinking:
        _setState(RobotState.thinking);
        final text = _voice.transcript.trim();
        if (text.isNotEmpty && _wantsVision(text)) {
          _maybeCaptureVision(text);
        }
        break;
      case VoiceState.speaking:
        _setState(RobotState.speaking);
        break;
      case VoiceState.error:
        _setState(RobotState.error);
        break;
    }
    notifyListeners();
  }

  /// Pull the latest user transcript and robot reply out of the voice
  /// client and append/extend the persistent transcript list.
  void _captureTurnsFromVoice() {
    final transcript = _voice.transcript.trim();
    if (transcript.isNotEmpty && transcript != _lastSeenTranscript) {
      _lastSeenTranscript = transcript;
      // If the last turn is already a user turn for this transcript, just
      // update it (partial result growing). Otherwise add a new user turn.
      if (_turns.isNotEmpty &&
          _turns.last.speaker == RobotSpeaker.user &&
          _turns.last.text != transcript &&
          // Heuristic: if the transcript starts with the previous one we
          // assume it's a partial growing into a final.
          transcript.startsWith(_turns.last.text)) {
        _turns[_turns.length - 1] =
            _turns.last.copyWith(text: transcript);
      } else if (_turns.isEmpty || _turns.last.text != transcript) {
        // Promote the streaming reply to a final entry before adding new.
        _turns.add(RobotTurn(
          speaker: RobotSpeaker.user,
          text: transcript,
          ts: DateTime.now(),
        ));
      }
    }

    final reply = _voice.reply.trim();
    if (reply.isNotEmpty && reply != _lastSeenReply) {
      _lastSeenReply = reply;
      if (_turns.isNotEmpty &&
          _turns.last.speaker == RobotSpeaker.robot &&
          _turns.last.text != reply) {
        _turns[_turns.length - 1] = _turns.last.copyWith(text: reply);
      } else {
        _turns.add(RobotTurn(
          speaker: RobotSpeaker.robot,
          text: reply,
          ts: DateTime.now(),
        ));
      }
    }
  }

  // ---------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------

  Future<void> start() async {
    if (_state != RobotState.idle && _state != RobotState.error) return;
    _setState(RobotState.initializing);
    _error = null;

    // Robot Mode needs the camera/mic plugins, which only ship on mobile.
    // On desktop (Windows/Linux/macOS) and web, fail gracefully instead of
    // crashing on the missing plugin.
    final supportsRobot = !kIsWeb && (Platform.isAndroid || Platform.isIOS);
    if (!supportsRobot) {
      _error = 'Robot Mode requires a mobile device with a camera and microphone.';
      _setState(RobotState.error);
      return;
    }

    try {
      final mic = await Permission.microphone.request();
      final cam = await Permission.camera.request();
      if (!mic.isGranted || !cam.isGranted) {
        _error = 'Microphone and camera permissions are required.';
        _setState(RobotState.error);
        return;
      }

      // Spin up the camera so the orb can show the live preview.
      _availableCameras = await availableCameras();
      if (_availableCameras.isEmpty) {
        _error = 'No camera detected on this device.';
        _setState(RobotState.error);
        return;
      }
      // Prefer the front-facing camera by default.
      _activeCameraIndex = _availableCameras.indexWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
      );
      if (_activeCameraIndex < 0) _activeCameraIndex = 0;
      camera = await _initCameraAt(_activeCameraIndex);

      // Open the WebSocket voice loop. From this point on, the mic streams
      // to the backend and PCM audio comes back in real time.
      await _voice.start();

      // Periodically refresh the server's vision cache so the robot has
      // an up-to-date description ready when the user asks a visual
      // question — no per-turn round-trip wait.
      _backgroundVisionTimer?.cancel();
      _backgroundVisionTimer = Timer.periodic(
        const Duration(seconds: 3),
        (_) => _backgroundCapture(),
      );
      // Fire one immediately so the cache is warm before the first turn.
      // ignore: unawaited_futures
      _backgroundCapture();

      // Continuously detect objects so the UI can show live chips.
      _objectDetectionTimer?.cancel();
      _objectDetectionTimer = Timer.periodic(
        const Duration(milliseconds: 1500),
        (_) => _detectObjectsTick(),
      );
      // ignore: unawaited_futures
      _detectObjectsTick();
    } catch (e) {
      _error = 'Failed to start Robot Mode: $e';
      _setState(RobotState.error);
    }
  }

  Future<void> stop() async {
    _backgroundVisionTimer?.cancel();
    _backgroundVisionTimer = null;
    _objectDetectionTimer?.cancel();
    _objectDetectionTimer = null;
    await _voice.stop();
    await camera?.dispose();
    camera = null;
    _setState(RobotState.idle);
  }

  /// Tap-to-interrupt: stop TTS playback and re-open the mic immediately.
  Future<void> interrupt() async {
    await _voice.interrupt();
  }

  /// Cycle to the next camera (front <-> back) and refresh the preview.
  /// Safe to call repeatedly; ignored if a switch is already in flight.
  Future<void> switchCamera() async {
    if (_disposed) return;
    if (_switchingCamera) return;
    if (_availableCameras.length < 2) {
      debugPrint('[robot] switchCamera: only one camera available');
      return;
    }
    _switchingCamera = true;
    try {
      final next = (_activeCameraIndex + 1) % _availableCameras.length;
      debugPrint(
        '[robot] switching camera $_activeCameraIndex -> $next '
        '(${_availableCameras[next].lensDirection.name})',
      );
      // Drop the old controller before initialising the new one so we
      // don't keep two camera streams open simultaneously.
      final old = camera;
      camera = null;
      notifyListeners();
      try {
        await old?.dispose();
      } catch (e) {
        debugPrint('[robot] disposing old camera: $e');
      }
      camera = await _initCameraAt(next);
      _activeCameraIndex = next;
      notifyListeners();
      // Refresh the server's vision cache for the new lens.
      // ignore: unawaited_futures
      _backgroundCapture();
    } catch (e, st) {
      debugPrint('[robot] switchCamera failed: $e\n$st');
    } finally {
      _switchingCamera = false;
    }
  }

  Future<CameraController> _initCameraAt(int index) async {
    final desc = _availableCameras[index];
    final controller = CameraController(
      desc,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: Platform.isIOS
          ? ImageFormatGroup.bgra8888
          : ImageFormatGroup.yuv420,
    );
    await controller.initialize();
    return controller;
  }

  // ---------------------------------------------------------------------
  // Vision capture
  // ---------------------------------------------------------------------

  bool _captureInFlight = false;

  /// Background capture — fires every few seconds to keep the server's
  /// vision cache fresh. Skips if a capture is already in flight or the
  /// camera isn't ready. Runs even while speaking so the cache stays
  /// fresh for the user's NEXT turn.
  Future<void> _backgroundCapture() async {
    if (_disposed) return;
    if (_captureInFlight) return;
    final cam = camera;
    if (cam == null || !cam.value.isInitialized) return;
    await _captureAndSend(silent: true);
  }

  Future<void> _maybeCaptureVision(String userText) async {
    if (_captureInFlight) return;
    final cam = camera;
    if (cam == null || !cam.value.isInitialized) return;
    await _captureAndSend(silent: false, userQuery: userText);
  }

  Future<void> _captureAndSend({
    required bool silent,
    String? userQuery,
  }) async {
    _captureInFlight = true;
    final prevState = _state;
    if (!silent) _setState(RobotState.observing);
    try {
      final cam = camera!;
      final XFile shot = await cam.takePicture();
      final bytes = await shot.readAsBytes();
      final b64 = base64Encode(bytes);
      if (!silent) {
        debugPrint('[robot] vision -> ${bytes.length} bytes (foreground)');
      }
      // Build a query-aware prompt so the vision model adapts to what the
      // user actually asked (e.g. "read the contents", "what is this").
      final prompt = userQuery != null && userQuery.trim().isNotEmpty
          ? _buildQueryPrompt(userQuery.trim())
          : null;
      final desc = await _vision.describeImage(b64, prompt: prompt);
      if (!silent) {
        debugPrint('[robot] vision <- ${desc.length} chars: $desc');
      }
      if (_isUsefulVision(desc)) {
        _lastVision = desc;
        _voice.setVisionContext(desc);
      } else {
        debugPrint('[robot] vision dropped (low quality): "$desc"');
      }
    } on ZenChatException catch (e) {
      if (!silent) debugPrint('[robot] vision failed: $e');
    } catch (e, st) {
      if (!silent) debugPrint('[robot] vision exception: $e\n$st');
    } finally {
      _captureInFlight = false;
      if (!silent && _state == RobotState.observing) {
        _setState(prevState);
      }
    }
  }

  /// Build a vision prompt tailored to the user's spoken question. This
  /// nudges the vision model to e.g. transcribe text when the user asked
  /// to "read the contents", or describe a specific object when asked
  /// "what is this".
  String _buildQueryPrompt(String userQuery) {
    return 'You are the eyes of an AI assistant. The user just asked: '
        '"$userQuery"\n'
        'Describe what is visible in the camera image so an assistant can '
        'answer that question. Mention specific objects, text, people, and '
        'environment. If the user wants to read text on a screen or paper, '
        'transcribe the readable text verbatim (or as much as you can read). '
        'Keep it under 80 words. Plain factual language.';
  }

  /// Polls the lightweight `/vision/objects` endpoint so the UI can show
  /// a live strip of object chips. Skips if a detection is already in
  /// flight, the camera isn't ready, or the robot is currently talking.
  Future<void> _detectObjectsTick() async {
    if (_disposed) return;
    if (_detectInFlight) return;
    if (_state == RobotState.speaking) return;
    final cam = camera;
    if (cam == null || !cam.value.isInitialized) return;
    _detectInFlight = true;
    try {
      final XFile shot = await cam.takePicture();
      final bytes = await shot.readAsBytes();
      final b64 = base64Encode(bytes);
      final objs = await _vision.detectObjects(b64);
      if (_disposed) return;
      if (objs.isNotEmpty) {
        _detectedObjects = objs;
        notifyListeners();
      }
    } on ZenChatException catch (e) {
      debugPrint('[robot] objects failed: $e');
    } catch (e) {
      debugPrint('[robot] objects exception: $e');
    } finally {
      _detectInFlight = false;
    }
  }

  // ---------------------------------------------------------------------
  // Intent helpers
  // ---------------------------------------------------------------------

  /// Returns true when the user's message likely refers to something the
  /// robot can see — used to gate camera capture so we don't waste calls.
  bool _wantsVision(String text) {
    final t = text.toLowerCase();
    const keywords = [
      'see', 'look', 'looking', 'show me', 'what is this',
      "what's this", 'whats this', 'what am i', 'who am i',
      'what do you see', 'can you see', 'what can you see',
      'what is in', "what's in", 'whats in',
      'how do i look', 'how am i', 'check me', 'observe',
      'this image', 'this picture', 'in front of',
      'what is that', "what's that", 'whats that',
      'identify', 'describe', 'recognize', 'recognise',
      'my face', 'my posture', 'hold up', 'holding',
    ];
    for (final k in keywords) {
      if (t.contains(k)) return true;
    }
    return false;
  }

  /// Returns true if the vision text looks like a real description rather
  /// than garbage tokens from a tiny local model.
  bool _isUsefulVision(String text) {
    final t = text.trim();
    if (t.length < 20) return false;
    final words = t.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.length < 4) return false;
    final fragments =
        words.where((w) => !RegExp(r'[aeiouAEIOU]').hasMatch(w)).length;
    if (fragments * 2 > words.length) return false;
    return true;
  }

  void _setState(RobotState s) {
    _state = s;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _backgroundVisionTimer?.cancel();
    _objectDetectionTimer?.cancel();
    _voice.removeListener(_onVoiceChange);
    _voice.dispose();
    camera?.dispose();
    _vision.dispose();
    super.dispose();
  }
}
