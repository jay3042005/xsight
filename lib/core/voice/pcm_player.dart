import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_soloud/flutter_soloud.dart';

/// Streams raw PCM16 mono audio chunks to the speaker as they arrive.
///
/// Uses SoLoud's buffer-stream API: one stream source is allocated on [begin],
/// each [feed] chunk is appended and starts playing as soon as
/// [_bufferingSeconds] of audio is queued, and [end] marks the data complete so
/// the source stops when the queue drains.
///
/// This replaced a buffer-everything-then-`loadMem` implementation where
/// first-audio latency equalled *full* synthesis time — the backend streams TTS
/// chunks, so waiting for the last one wasted the entire pipeline.
class PcmPlayer {
  PcmPlayer({this.sampleRate = 24000});

  final int sampleRate;

  /// How much audio must be queued before playback un-pauses. Low enough to
  /// feel immediate, high enough to absorb a slow synth chunk without an
  /// audible gap.
  static const double _bufferingSeconds = 0.25;

  /// Hard bound on a single utterance's buffer. Replies are capped at 120
  /// tokens server-side, so this is generous; it only exists so a runaway
  /// stream can't grow without limit.
  static const Duration _maxBuffer = Duration(minutes: 2);

  bool _initialized = false;
  AudioSource? _source;
  SoundHandle? _handle;
  bool _playing = false;
  bool _ended = false;

  /// Amplitude of the most recently fed chunk, 0..1. Drives the "AI is
  /// talking" visuals.
  double get level => _level;
  double _level = 0;

  /// True between [begin] and the source draining/stopping.
  bool get isActive => _source != null;

  Future<void> _ensureInit() async {
    if (_initialized) return;
    final so = SoLoud.instance;
    if (!so.isInitialized) {
      await so.init();
    }
    _initialized = true;
  }

  /// Begin a new playback stream. Call [feed] with PCM16 LE chunks.
  Future<void> begin() async {
    await stop();
    await _ensureInit();
    _ended = false;
    _playing = false;
    _level = 0;
    _source = SoLoud.instance.setBufferStream(
      maxBufferSizeDuration: _maxBuffer,
      bufferingType: BufferingType.released,
      bufferingTimeNeeds: _bufferingSeconds,
      sampleRate: sampleRate,
      channels: Channels.mono,
      format: BufferType.s16le,
    );
  }

  /// Append a PCM16 LE chunk. Playback starts on the first chunk.
  void feed(Uint8List chunk) {
    final src = _source;
    if (src == null || _ended || chunk.isEmpty) return;
    _level = _rms(chunk);
    try {
      SoLoud.instance.addAudioDataStream(src, chunk);
    } catch (e) {
      debugPrint('[PcmPlayer] feed error: $e');
      return;
    }
    if (!_playing) {
      _playing = true;
      // Fire-and-forget: play() completes once the handle exists, and feeding
      // more data before then is safe (it lands in the same buffer).
      SoLoud.instance.play(src).then((h) => _handle = h).catchError((e) {
        debugPrint('[PcmPlayer] play error: $e');
        return SoundHandle(0);
      });
    }
  }

  /// Mark the stream complete; the source stops once the queue drains.
  Future<void> end() async {
    final src = _source;
    if (src == null || _ended) return;
    _ended = true;
    try {
      SoLoud.instance.setDataIsEnded(src);
    } catch (e) {
      debugPrint('[PcmPlayer] end error: $e');
    }
    _level = 0;
  }

  /// Hard stop: cancel anything still playing and free the source.
  Future<void> stop() async {
    final so = SoLoud.instance;
    _level = 0;
    _playing = false;
    _ended = false;
    final h = _handle;
    final src = _source;
    // Detach first so a second stop() while this one is awaiting cannot
    // re-enter with the same source.
    _handle = null;
    _source = null;
    if (src != null) {
      // 1. Mark the stream complete so the native side detaches its buffer
      //    machinery cleanly.
      try {
        so.setDataIsEnded(src);
      } catch (_) {}
    }
    if (h != null) {
      // 2. AWAIT the stop. It completes via a native "voice ended" event back
      //    into Dart — disposing the source before that event arrives made
      //    native invoke a callback Dart had already deleted:
      //    "Callback invoked after it has been deleted" -> SIGABRT on
      //    Android when leaving voice mode mid-playback. The call caps
      //    itself at 300 ms internally, so this cannot hang.
      try {
        await so.stop(h);
      } catch (_) {}
    }
    if (src != null) {
      // 3. Only now is the source's memory safe to reclaim.
      try {
        await so.disposeSource(src);
      } catch (_) {}
    }
  }

  /// Root-mean-square amplitude of a PCM16 LE chunk, normalized to 0..1.
  static double _rms(Uint8List chunk) {
    final samples = chunk.lengthInBytes ~/ 2;
    if (samples == 0) return 0;
    final view = ByteData.sublistView(chunk, 0, samples * 2);
    var sum = 0.0;
    // Every 4th sample is plenty for a visual envelope and keeps this off the
    // frame budget on long chunks.
    var counted = 0;
    for (var i = 0; i < samples; i += 4) {
      final s = view.getInt16(i * 2, Endian.little) / 32768.0;
      sum += s * s;
      counted++;
    }
    if (counted == 0) return 0;
    return math.sqrt(sum / counted).clamp(0.0, 1.0);
  }

  Future<void> dispose() async {
    await stop();
  }
}

/// Best-effort wrapper that swallows exceptions and falls back to a no-op
/// when SoLoud is not available (e.g. unsupported platform during tests).
class SafePcmPlayer {
  SafePcmPlayer({this.sampleRate = 24000});

  final int sampleRate;
  PcmPlayer? _inner;
  bool _failed = false;
  bool _starting = false;
  final List<Uint8List> _pending = [];

  double get level => _inner?.level ?? 0;

  Future<void> begin() async {
    if (_failed || _starting) return;
    _starting = true;
    try {
      _inner = PcmPlayer(sampleRate: sampleRate);
      await _inner!.begin();
      for (final chunk in _pending) {
        _inner!.feed(chunk);
      }
      _pending.clear();
    } catch (e) {
      debugPrint('[voice] SoLoud init failed, falling back to silent: $e');
      _failed = true;
      _inner = null;
    } finally {
      _starting = false;
    }
  }

  void feed(Uint8List chunk) {
    if (_starting) {
      _pending.add(chunk);
      return;
    }
    if (_inner == null) return;
    try {
      _inner!.feed(chunk);
    } catch (_) {}
  }

  Future<void> end() async {
    if (_inner == null) return;
    try {
      await _inner!.end();
    } catch (_) {}
  }

  Future<void> stop() async {
    _pending.clear();
    if (_inner == null) return;
    try {
      await _inner!.stop();
      await _inner!.dispose();
    } catch (_) {}
    _inner = null;
  }

  Future<void> dispose() async {
    await stop();
    _inner = null;
  }
}
