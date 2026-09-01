import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../state/xs_settings.dart';

/// Where the handoff has got to, for the waiting UI to render.
enum XrayHandoffState {
  /// Asking the backend to mint a session.
  preparing,

  /// QR is on screen; nobody has uploaded yet.
  waiting,

  /// A film arrived and is being handed to the analyser.
  received,

  /// The code timed out with no upload.
  expired,

  /// Something went wrong; [XrayHandoffClient.error] says what.
  failed,
}

/// Drives the phone → kiosk chest-film handoff.
///
/// Asks the local backend for a capture session, exposes the URL to put in a QR
/// code, and holds a WebSocket open until the film arrives. The film is handed
/// back as raw bytes so the caller runs its *existing* analysis path on it —
/// upload, EMR write, and CDSS fusion stay in one place rather than being
/// duplicated for this route.
///
/// The socket is to the kiosk's own backend on the LAN, not to the relay: a
/// browser cannot post to a plain-HTTP LAN address from an HTTPS page, and
/// serverless functions cannot hold a socket open. The backend bridges the two.
class XrayHandoffClient extends ChangeNotifier {
  XrayHandoffState _state = XrayHandoffState.preparing;
  String? _captureUrl;
  String? _sid;
  String? _error;
  int _expiresIn = 0;
  Uint8List? _film;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _countdown;
  bool _disposed = false;

  XrayHandoffState get state => _state;

  /// The URL the QR code should encode, once minted.
  String? get captureUrl => _captureUrl;

  /// The live capture session id, or null before one is minted.
  ///
  /// Published to the kiosk event hub so the web portal can drop a film into
  /// *this* session — the portal's upload has to reach the station the clinician
  /// is standing at, not a server-side path that files a result they never see.
  String? get sid => _sid;

  String? get error => _error;

  /// Seconds left before the code stops working. Drives the countdown so a
  /// clinician can see whether it is worth waiting or worth re-issuing.
  int get expiresIn => _expiresIn;

  /// The received film, or null until one arrives.
  Uint8List? get film => _film;

  /// Short, human-readable session tag for support ("code ends 4f2a").
  String? get shortCode {
    final sid = _sid;
    if (sid == null || sid.length < 4) return null;
    return sid.substring(sid.length - 4).toUpperCase();
  }

  String get _base {
    final url = XSSettings.I.backendUrl;
    if (url.isEmpty) {
      throw StateError('No server configured. Set the backend IP in Settings.');
    }
    return url;
  }

  /// Whether this kiosk's backend can broker a phone handoff at all.
  ///
  /// Checked before the X-ray screen offers the QR route, so a kiosk with no
  /// relay configured keeps a way to get a film in rather than showing a code
  /// that can never work.
  static Future<bool> isAvailable() async {
    final base = XSSettings.I.backendUrl;
    if (base.isEmpty) return false;
    try {
      final ch = await _decode(
        await http.get(Uri.parse('$base/handoff/status')).timeout(_timeout),
      );
      return ch?['available'] == true;
    } catch (_) {
      return false;
    }
  }

  /// Decode a JSON object body, or null when there isn't one.
  ///
  /// Short timeout on purpose: this only ever talks to the kiosk's own backend
  /// on the LAN, so a slow reply means misconfiguration, and the clinician
  /// should be told that rather than left watching a spinner.
  static const _timeout = Duration(seconds: 8);

  static Future<Map<String, dynamic>?> _decode(http.Response resp) async {
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      String detail = 'HTTP ${resp.statusCode}';
      try {
        final body = jsonDecode(resp.body);
        if (body is Map && body['detail'] is String) detail = body['detail'];
      } catch (_) {}
      throw StateError(detail);
    }
    if (resp.body.isEmpty) return null;
    final decoded = jsonDecode(resp.body);
    return decoded is Map<String, dynamic> ? decoded : null;
  }

  /// Mint a session and start waiting for the phone.
  Future<void> start() async {
    _setState(XrayHandoffState.preparing);
    _error = null;
    _film = null;
    try {
      final data = await _decode(
        await http.post(Uri.parse('$_base/handoff/xray')).timeout(_timeout),
      );
      if (data == null) throw StateError('Empty response from server.');
      _sid = data['sid'] as String?;
      _captureUrl = data['capture_url'] as String?;
      _expiresIn = (data['expires_in'] as num?)?.toInt() ?? 600;
      if (_sid == null || _captureUrl == null) {
        throw StateError('Server did not return a capture session.');
      }
      _listen();
      _startCountdown();
      _setState(XrayHandoffState.waiting);
    } catch (e) {
      _error = _humanize(e);
      _setState(XrayHandoffState.failed);
    }
  }

  void _listen() {
    final ws = _base
        .replaceFirst(RegExp(r'^http://'), 'ws://')
        .replaceFirst(RegExp(r'^https://'), 'wss://');
    final uri = Uri.parse('$ws/ws/handoff/$_sid');
    _channel = IOWebSocketChannel.connect(
      uri,
      pingInterval: const Duration(seconds: 20),
    );
    _sub = _channel!.stream.listen(
      _onFrame,
      onError: (e) {
        if (_disposed) return;
        _error = 'Lost contact with the kiosk server: $e';
        _setState(XrayHandoffState.failed);
      },
      onDone: () {
        if (_disposed) return;
        // A close after delivery is the normal end of the handoff. A close
        // while still waiting means the server gave up on us.
        if (_state == XrayHandoffState.waiting) {
          _setState(XrayHandoffState.expired);
        }
      },
      cancelOnError: false,
    );
  }

  void _onFrame(dynamic raw) {
    if (_disposed || raw is! String) return;
    Map<String, dynamic> obj;
    try {
      obj = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    switch (obj['event'] as String?) {
      case 'waiting':
        _expiresIn = (obj['expires_in'] as num?)?.toInt() ?? _expiresIn;
        _setState(XrayHandoffState.waiting);
      case 'film':
        final b64 = obj['image_b64'] as String?;
        if (b64 == null || b64.isEmpty) {
          _error = 'The kiosk server sent an empty film.';
          _setState(XrayHandoffState.failed);
          return;
        }
        try {
          _film = base64Decode(b64);
        } on FormatException {
          _error = 'The film arrived corrupted. Ask the phone to send again.';
          _setState(XrayHandoffState.failed);
          return;
        }
        _countdown?.cancel();
        _setState(XrayHandoffState.received);
      case 'expired':
        _setState(XrayHandoffState.expired);
      case 'error':
        _error = obj['detail']?.toString() ?? 'Handoff failed.';
        _setState(XrayHandoffState.failed);
    }
  }

  void _startCountdown() {
    _countdown?.cancel();
    _countdown = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_disposed) {
        t.cancel();
        return;
      }
      if (_expiresIn <= 0) {
        t.cancel();
        if (_state == XrayHandoffState.waiting) {
          _setState(XrayHandoffState.expired);
        }
        return;
      }
      _expiresIn--;
      notifyListeners();
    });
  }

  /// Tear down the socket without disposing, so the screen can re-issue a code.
  Future<void> cancel() async {
    _countdown?.cancel();
    _countdown = null;
    await _sub?.cancel();
    _sub = null;
    await _channel?.sink.close();
    _channel = null;
  }

  Future<void> restart() async {
    await cancel();
    await start();
  }

  String _humanize(Object e) {
    final s = e.toString();
    if (s.contains('503') || s.contains('not configured')) {
      return 'Phone handoff is not set up on this server. '
          'Use “Choose a file instead”.';
    }
    if (s.contains('No server configured')) {
      return 'No server IP set. Open Settings first.';
    }
    return s;
  }

  void _setState(XrayHandoffState s) {
    _state = s;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _countdown?.cancel();
    _sub?.cancel();
    _channel?.sink.close();
    super.dispose();
  }
}
