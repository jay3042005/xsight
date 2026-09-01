import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../state/xs_settings.dart';

/// An HTTP failure that kept its status code.
///
/// `StateError(detail).toString()` renders as `Bad state: <detail>`, so matching a
/// status by substring both leaks Dart's wording into patient-facing copy and
/// misses whenever the server sends a message rather than a number: a bare
/// FastAPI 404 arrives as "Not Found", with no "404" anywhere in it.
class IntakeHttpFailure implements Exception {
  final int status;
  final String detail;

  const IntakeHttpFailure(this.status, this.detail);

  @override
  String toString() => detail;
}

/// Where the intake handoff has got to, for the waiting UI to render.
enum IntakeHandoffState {
  /// Asking the backend to mint a session.
  preparing,

  /// QR is on screen; nobody has submitted the form yet.
  waiting,

  /// Details arrived and are ready to apply to the session.
  received,

  /// The code timed out with nothing submitted.
  expired,

  /// Something went wrong; [IntakeHandoffClient.error] says what.
  failed,
}

/// Drives the phone → kiosk patient-intake handoff.
///
/// Same store-and-pickup relay as the chest-film handoff, carrying a form
/// submission instead of an image: the kiosk mints a session, renders its URL as
/// a QR, and holds a socket to its *own* backend until the phone's answers come
/// back. See `server/app/handoff.py` for why the phone cannot post to the kiosk
/// directly.
///
/// Why this route exists at all: the kiosk is driven by hardware buttons and is
/// deliberately not a typing surface, so the one step that genuinely needs a
/// keyboard happens on a device that already has a good one.
class IntakeHandoffClient extends ChangeNotifier {
  IntakeHandoffState _state = IntakeHandoffState.preparing;
  String? _formUrl;
  String? _sid;
  String? _error;
  int _expiresIn = 0;
  Map<String, dynamic>? _details;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _countdown;
  bool _disposed = false;

  IntakeHandoffState get state => _state;

  /// The URL the QR code should encode, once minted.
  String? get formUrl => _formUrl;

  String? get error => _error;

  /// Seconds left before the code stops working.
  int get expiresIn => _expiresIn;

  /// The submitted answers, or null until they arrive.
  ///
  /// Shape is whatever the relay's intake form posts — `name`, `age`, `sex`,
  /// `symptoms`. Treated as untrusted input by the caller: it came from a
  /// browser, so nothing here may be written to an EMR record unattended.
  Map<String, dynamic>? get details => _details;

  /// Short, human-readable session tag for support ("code ends 4F2A").
  String? get shortCode {
    final sid = _sid;
    if (sid == null || sid.length < 4) return null;
    return sid.substring(sid.length - 4).toUpperCase();
  }

  static const _timeout = Duration(seconds: 8);

  String get _base {
    final url = XSSettings.I.backendUrl;
    if (url.isEmpty) {
      throw StateError('No server configured. Set the backend IP in Settings.');
    }
    return url;
  }

  static Future<Map<String, dynamic>?> _decode(http.Response resp) async {
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      String detail = 'HTTP ${resp.statusCode}';
      try {
        final body = jsonDecode(resp.body);
        if (body is Map && body['detail'] is String) detail = body['detail'];
      } catch (_) {}
      throw IntakeHttpFailure(resp.statusCode, detail);
    }
    if (resp.body.isEmpty) return null;
    final decoded = jsonDecode(resp.body);
    return decoded is Map<String, dynamic> ? decoded : null;
  }

  /// Mint a session and start waiting for the phone.
  Future<void> start() async {
    _setState(IntakeHandoffState.preparing);
    _error = null;
    _details = null;
    try {
      final data = await _decode(
        await http.post(Uri.parse('$_base/handoff/intake')).timeout(_timeout),
      );
      if (data == null) throw StateError('Empty response from server.');
      _sid = data['sid'] as String?;
      // `form_url` is this handoff's field; `capture_url` is accepted as well so
      // a backend that reuses the film handoff's response shape still works.
      _formUrl = (data['form_url'] ?? data['capture_url']) as String?;
      _expiresIn = (data['expires_in'] as num?)?.toInt() ?? 600;
      if (_sid == null || _formUrl == null) {
        throw StateError('Server did not return an intake session.');
      }
      _listen();
      _startCountdown();
      _setState(IntakeHandoffState.waiting);
    } catch (e) {
      _error = _humanize(e);
      _setState(IntakeHandoffState.failed);
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
        _setState(IntakeHandoffState.failed);
      },
      onDone: () {
        if (_disposed) return;
        if (_state == IntakeHandoffState.waiting) {
          _setState(IntakeHandoffState.expired);
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
        _setState(IntakeHandoffState.waiting);
      case 'intake':
        final payload = obj['details'];
        if (payload is! Map) {
          _error = 'The kiosk server sent an empty intake form.';
          _setState(IntakeHandoffState.failed);
          return;
        }
        _details = Map<String, dynamic>.from(payload);
        _countdown?.cancel();
        _setState(IntakeHandoffState.received);
      case 'expired':
        _setState(IntakeHandoffState.expired);
      case 'error':
        _error = obj['detail']?.toString() ?? 'Handoff failed.';
        _setState(IntakeHandoffState.failed);
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
        if (_state == IntakeHandoffState.waiting) {
          _setState(IntakeHandoffState.expired);
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

  /// Patient-facing wording. Every branch names the way out, because this text is
  /// shown on a kiosk to somebody who cannot fix the server.
  String _humanize(Object e) {
    if (e is IntakeHttpFailure) {
      return switch (e.status) {
        404 => 'This kiosk server is running a build without phone check-in. '
            'Use “Enter details on the kiosk”.',
        503 => 'Phone check-in is not set up on this server. '
            'Use “Enter details on the kiosk”.',
        _ => 'The kiosk server refused the check-in (${e.status}). ${e.detail}',
      };
    }
    if (e is StateError && e.message.contains('No server configured')) {
      return 'No server IP set. Open Settings first.';
    }
    // Anything left is transport: DNS, refused connection, timeout.
    return 'Could not reach the kiosk server. '
        'Check the backend address in Settings.';
  }

  void _setState(IntakeHandoffState s) {
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
