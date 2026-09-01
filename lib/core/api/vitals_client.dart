import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../config/xs_config.dart';
import '../../state/xs_settings.dart';

class VitalsSnapshot {
  final double hr;
  final double spo2;
  final double temp;
  final double rr;
  final double sbp;
  final double dbp;
  final DateTime ts;

  const VitalsSnapshot({
    required this.hr,
    required this.spo2,
    required this.temp,
    required this.rr,
    required this.sbp,
    required this.dbp,
    required this.ts,
  });

  factory VitalsSnapshot.fromJson(Map<String, dynamic> json) {
    return VitalsSnapshot(
      hr: (json['hr'] as num?)?.toDouble() ?? 0,
      spo2: (json['spo2'] as num?)?.toDouble() ?? 0,
      temp: (json['temp'] as num?)?.toDouble() ?? 0,
      rr: (json['rr'] as num?)?.toDouble() ?? 0,
      sbp: (json['sbp'] as num?)?.toDouble() ?? 0,
      dbp: (json['dbp'] as num?)?.toDouble() ?? 0,
      ts: DateTime.fromMillisecondsSinceEpoch(
        ((json['ts'] as num?)?.toDouble() ?? 0) * 1000 ~/ 1,
      ),
    );
  }
}

/// Subscribes to the backend's `/ws/vitals` WebSocket and exposes the
/// latest reading + a rolling history for charts.
class VitalsClient extends ChangeNotifier {
  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  bool _disposed = false;

  VitalsSnapshot? _latest;
  final List<VitalsSnapshot> _history = [];
  bool _connected = false;
  String? _error;

  /// Latest reading (null until first frame arrives).
  VitalsSnapshot? get latest => _latest;

  /// Last N samples for trend charts.
  List<VitalsSnapshot> get history => List.unmodifiable(_history);
  bool get connected => _connected;
  String? get error => _error;

  static const int _maxHistory = 120;

  Future<void> start() async {
    if (_channel != null) return;
    final base = XSSettings.I.hasBackend
        ? XSSettings.I.backendUrl
        : XSConfig.backendBaseUrl;
    if (base.isEmpty) {
      _error = 'No server IP configured. Open Settings.';
      _connected = false;
      notifyListeners();
      return;
    }
    final wsUrl = base
        .replaceFirst(RegExp(r'^http://'), 'ws://')
        .replaceFirst(RegExp(r'^https://'), 'wss://');
    final uri = Uri.parse('$wsUrl/ws/vitals');
    debugPrint('[vitals] connecting to $uri');
    try {
      _channel = IOWebSocketChannel.connect(
        uri,
        pingInterval: const Duration(seconds: 30),
      );
      _connected = true;
      _error = null;
      notifyListeners();
      _sub = _channel!.stream.listen(
        _onMessage,
        onError: (e) {
          debugPrint('[vitals] error: $e');
          _error = 'Connection error: $e';
          _connected = false;
          notifyListeners();
        },
        onDone: () {
          debugPrint('[vitals] closed');
          _connected = false;
          if (!_disposed) notifyListeners();
        },
        cancelOnError: false,
      );
    } catch (e) {
      _error = 'Failed to connect: $e';
      _connected = false;
      notifyListeners();
    }
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    try {
      await _channel?.sink.close();
    } catch (_) {}
    _channel = null;
    _connected = false;
    if (!_disposed) notifyListeners();
  }

  void _onMessage(dynamic msg) {
    if (msg is! String) return;
    try {
      final obj = jsonDecode(msg) as Map<String, dynamic>;
      final snap = VitalsSnapshot.fromJson(obj);
      _latest = snap;
      _history.add(snap);
      if (_history.length > _maxHistory) {
        _history.removeRange(0, _history.length - _maxHistory);
      }
      notifyListeners();
    } catch (e) {
      debugPrint('[vitals] bad json: $e');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    stop();
    super.dispose();
  }
}
