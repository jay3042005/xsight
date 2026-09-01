import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../../state/xs_settings.dart';

/// Client that connects to the local backend Kiosk Event Hub (`/ws/kiosk/events`).
/// Listens for remote session triggers from the Web Portal and stop-session commands.
class KioskHubClient extends ChangeNotifier {
  static final KioskHubClient instance = KioskHubClient._();
  KioskHubClient._();

  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  Timer? _reconnectTimer;
  bool _connected = false;
  bool _manualDisconnect = false;
  bool get isConnected => _connected;

  /// Callback when a web user triggers a remote session
  void Function(Map<String, dynamic> patientData)? onRemoteSessionRequest;

  /// Callback when a remote stop session is received
  VoidCallback? onRemoteStopSession;

  /// What the server has been told, kept so a reconnect can republish it.
  ///
  /// [sendEvent] drops silently when the socket is down, and callers announce
  /// once — so a blip left the server believing the kiosk was nowhere near the
  /// X-ray station, and the portal's upload fell back to filing against the
  /// record instead of reaching the kiosk. Re-publishing on every accepted
  /// connection makes the announcement self-healing rather than a single shot.
  String? _station;
  String? _xraySid;

  void connect() {
    if (_connected) return;
    _manualDisconnect = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    try {
      final base = XSSettings.I.backendUrl;
      final wsBase = base.replaceFirst(RegExp(r'^http'), 'ws');
      final wsUrl = '$wsBase/ws/kiosk/events';
      final uri = Uri.parse(wsUrl);

      _channel = WebSocketChannel.connect(uri);
      _sub = _channel!.stream.listen(
        (data) {
          try {
            final msg = jsonDecode(data.toString()) as Map<String, dynamic>;
            _handleMessage(msg);
          } catch (e) {
            debugPrint('[KioskHub] Parse error: $e');
          }
        },
        onDone: _onDisconnect,
        onError: (err) {
          debugPrint('[KioskHub] WebSocket error: $err');
          _onDisconnect();
        },
      );
      _connected = true;
      notifyListeners();
    } catch (e) {
      debugPrint('[KioskHub] Connect exception: $e');
      _onDisconnect();
    }
  }

  void _handleMessage(Map<String, dynamic> msg) {
    final event = msg['event'];
    if (event == 'connected') {
      _connected = true;
      _resync();
      notifyListeners();
    } else if (event == 'remote_session_request') {
      final patient = msg['patient'] as Map<String, dynamic>?;
      if (patient != null && onRemoteSessionRequest != null) {
        onRemoteSessionRequest!(patient);
      }
    } else if (event == 'session_stopped') {
      if (onRemoteStopSession != null) {
        onRemoteStopSession!();
      }
    }
  }

  void _onDisconnect() {
    _connected = false;
    _sub?.cancel();
    _sub = null;
    _channel = null;
    notifyListeners();

    if (!_manualDisconnect) {
      _reconnectTimer?.cancel();
      _reconnectTimer = Timer(const Duration(seconds: 3), () {
        if (!_manualDisconnect) connect();
      });
    }
  }

  void disconnect() {
    _manualDisconnect = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _sub?.cancel();
    _sub = null;
    _channel?.sink.close();
    _channel = null;
    _connected = false;
  }

  void sendEvent(Map<String, dynamic> data) {
    if (_channel == null || !_connected) {
      // Not fatal: _resync() replays station and capture session once the socket
      // is accepted. Logged because a silently dropped event was invisible.
      debugPrint('[KioskHub] Dropped ${data['event']} - socket down');
      return;
    }
    try {
      _channel!.sink.add(jsonEncode(data));
    } catch (e) {
      debugPrint('[KioskHub] Send error: $e');
    }
  }

  void notifyStationChange(String station) {
    _station = station;
    sendEvent({'event': 'station_change', 'station': station});
  }

  /// Tell a freshly-accepted socket everything it missed.
  ///
  /// Order matters: `station_change` clears any stale capture session server-side
  /// when the station is not the X-ray one, so the sid must go second.
  void _resync() {
    final station = _station;
    if (station != null) {
      sendEvent({'event': 'station_change', 'station': station});
    }
    final sid = _xraySid;
    if (sid != null) {
      sendEvent({'event': 'xray_session', 'sid': sid});
    }
  }

  void notifySessionStarted(String? patientName) {
    sendEvent({'event': 'kiosk_session_active', 'patient_name': patientName});
  }

  void notifySessionStopped() {
    _station = null;
    _xraySid = null;
    sendEvent({'event': 'kiosk_session_idle'});
  }

  /// Tell the portal which capture session a film should be posted into.
  ///
  /// The portal uploads to `/handoff/session/{sid}/film`, the same door the phone
  /// uses, so the film lands on the kiosk and is analysed and displayed there.
  void notifyXraySession(String? sid) {
    _xraySid = sid;
    sendEvent({'event': 'xray_session', 'sid': sid});
  }

  /// Ask the web portal to raise its X-ray upload prompt now.
  ///
  /// Distinct from [notifyStationChange]: the portal polls, and it already
  /// ignores a station it has seen, so re-announcing `xray` could not re-open a
  /// prompt someone had closed. The server bumps a counter for this instead.
  void requestXrayUpload() {
    sendEvent({'event': 'request_xray_upload'});
  }

  /// Whether the portal could actually receive [requestXrayUpload] — used to
  /// grey out the option rather than offer a button that quietly does nothing.
  bool get canReachWebPortal => _connected;
}
