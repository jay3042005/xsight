import 'dart:async';

import '../api/updates_client.dart';
import 'esp32_serial_client.dart';

/// Streams a firmware .bin into the hub over the existing serial link.
///
/// Protocol (mirrors the sketch's OTA_* handlers):
///   OTA_BEGIN:size  → OTA_READY:maxChunk
///   OTA seq, crc32-hex, hex-chunk → OTA_ACK seq | OTA_NAK seq
///   OTA_END → OTA_OK (hub reboots into the new firmware)
///
/// One chunk in flight at a time — the per-chunk ack is flow control, so
/// this works identically at any baud and over USB or the BT link. A NAK
/// (bad CRC / wrong seq) retransmits the chunk; two consecutive NAKs on the
/// same chunk abort rather than spin.
class FirmwareOta {
  FirmwareOta(this._esp32, this._updates);

  final Esp32SerialClient _esp32;
  final UpdatesClient _updates;

  Completer<int>? _readyCompleter;
  Completer<int>? _ackCompleter;
  Completer<String>? _errorCompleter;
  Completer<void>? _okCompleter;
  bool _active = false;

  bool get isActive => _active;

  /// Runs the whole transfer. [onProgress] reports 0..1 of *bytes flashed*.
  ///
  /// Returns normally on OTA_OK — the hub reboots itself right after, so
  /// the caller should expect the link to drop and re-handshake.
  Future<void> run({void Function(double progress)? onProgress}) async {
    if (_active) throw StateError('an OTA transfer is already running');
    _active = true;
    _installListeners();
    try {
      final bin = await _updates.firmwareBinary();
      onProgress?.call(0);
      await _send('OTA_BEGIN:${bin.length}');
      final maxChunk = await _readyCompleter!.future
          .timeout(const Duration(seconds: 5), onTimeout: () => throw 'hub never answered OTA_BEGIN');

      // Chunk size: the hub's ceiling, capped by our 512-hex-char line
      // budget (matches the sketch's OTA_CHUNK_BYTES).
      final chunkSize = maxChunk < 256 ? maxChunk : 256;
      final totalChunks = (bin.length + chunkSize - 1) ~/ chunkSize;

      for (var seq = 0; seq < totalChunks; seq++) {
        final start = seq * chunkSize;
        final end = (start + chunkSize) < bin.length ? start + chunkSize : bin.length;
        final chunk = bin.sublist(start, end);
        var nakCount = 0;
        while (true) {
          _ackCompleter = Completer<int>();
          await _send('OTA:$seq:${_crc32(chunk).toRadixString(16)}:${_hex(chunk)}');
          final acked = await _ackCompleter!.future.timeout(
            const Duration(seconds: 10),
            onTimeout: () => -1,
          );
          if (acked == seq) break;
          nakCount++;
          if (nakCount >= 2) throw 'hub rejected chunk $seq twice — link unstable';
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        onProgress?.call(end / bin.length);
      }

      await _send('OTA_END');
      // OTA_OK is followed by a hub reboot; OTA_ERR:END is a failure. Wait
      // for whichever lands first, with room for the final flash verify.
      final outcome = await Future.any([
        _okCompleter!.future.then((_) => null),
        _errorCompleter!.future.then((e) => e),
      ]).timeout(const Duration(seconds: 30), onTimeout: () => 'no answer to OTA_END');
      if (outcome != null) throw 'flash failed: $outcome';
    } finally {
      _removeListeners();
      _active = false;
    }
  }

  /// Abort a transfer in progress (user cancelled). Best-effort: the hub
  /// ends up in a clean non-flashing state either way.
  Future<void> abort() async {
    if (!_active) return;
    final c = _errorCompleter;
    if (c != null && !c.isCompleted) c.complete('aborted by user');
    try {
      await _send('OTA_ABORT');
    } catch (_) {}
    _active = false;
  }

  Future<void> _send(String command) async {
    if (!_esp32.sendCommand(command)) {
      throw 'serial link not writable';
    }
  }

  void _installListeners() {
    _readyCompleter = Completer<int>();
    _errorCompleter = Completer<String>();
    _okCompleter = Completer<void>();
    _esp32.onOtaReady = (maxChunk) => _completeReady(maxChunk);
    _esp32.onOtaAck = _completeAck;
    _esp32.onOtaNak = (seq) => _completeAck(-1);
    _esp32.onOtaError = (reason) {
      final c = _errorCompleter;
      if (c != null && !c.isCompleted) c.complete(reason);
    };
    _esp32.onOtaOk = () {
      final c = _okCompleter;
      if (c != null && !c.isCompleted) c.complete();
    };
  }

  void _removeListeners() {
    _esp32.onOtaReady = null;
    _esp32.onOtaAck = null;
    _esp32.onOtaNak = null;
    _esp32.onOtaError = null;
    _esp32.onOtaOk = null;
    _esp32.onOtaAborted = null;
  }

  void _completeReady(int maxChunk) {
    final c = _readyCompleter;
    if (c != null && !c.isCompleted) c.complete(maxChunk);
  }

  void _completeAck(int seq) {
    final c = _ackCompleter;
    if (c != null && !c.isCompleted) c.complete(seq);
  }

  // CRC32 (reflected, poly 0xEDB88320) — the same value the sketch computes
  // and python's binascii.crc32 produces.
  static int _crc32(List<int> data) {
    var crc = 0xFFFFFFFF;
    for (final b in data) {
      crc ^= b;
      for (var k = 0; k < 8; k++) {
        crc = (crc >> 1) ^ (0xEDB88320 & (-(crc & 1)));
      }
    }
    return (~crc) & 0xFFFFFFFF;
  }

  static String _hex(List<int> data) {
    const digits = '0123456789abcdef';
    final buf = StringBuffer();
    for (final b in data) {
      buf.write(digits[(b >> 4) & 0xF]);
      buf.write(digits[b & 0xF]);
    }
    return buf.toString();
  }
}
