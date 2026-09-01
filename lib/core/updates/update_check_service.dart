import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/updates_client.dart';
import '../sensor/esp32_serial_client.dart';

/// The one-time, per-run update check: the moment the hub first reports its
/// firmware version, ask the server what should be running and compare.
/// Fires exactly once per kiosk run no matter how many reconnects happen —
/// a flaky USB cable must not turn into a popup lottery.
///
/// Both prompts route through the server (see [UpdatesClient]); the kiosk
/// itself never talks to GitHub.
class UpdateCheckService {
  UpdateCheckService({
    required Esp32SerialClient esp32,
    required UpdatesClient updates,
  })  : _esp32 = esp32,
        _updates = updates;

  final Esp32SerialClient _esp32;
  final UpdatesClient _updates;

  bool _ranOnce = false;
  bool _listening = false;

  /// Fired when something needs the user's attention. At most one event per
  /// run — firmware outranks the server-code notice when both are behind.
  final _attention = StreamController<UpdateAttention>.broadcast();
  Stream<UpdateAttention> get attention => _attention.stream;

  /// Wire this once from the shell (or a widget's initState). Idempotent.
  void start() {
    if (_listening) return;
    _listening = true;
    _esp32.addListener(_onClientChanged);
    if (_esp32.deviceReady && _esp32.firmwareVersion != null) {
      scheduleMicrotask(_check);
    }
  }

  void _onClientChanged() {
    if (!_ranOnce && _esp32.deviceReady && _esp32.firmwareVersion != null) {
      _check();
    }
  }

  Future<void> _check() async {
    if (_ranOnce) return;
    _ranOnce = true;
    _esp32.removeListener(_onClientChanged);

    try {
      final status = await _updates.status();
      final hubVersion = _esp32.firmwareVersion;

      // Hub firmware: outdated AND the server has the binary to fix it.
      if (status.firmwareActionable &&
          hubVersion != null &&
          hubVersion != status.firmwareExpectedVersion) {
        _attention.add(UpdateAttention.firmware(
          current: hubVersion,
          expected: status.firmwareExpectedVersion!,
        ));
        return;
      }
      if (status.serverUpdateAvailable) {
        _attention.add(const UpdateAttention.server());
      }
    } catch (e) {
      // Offline/degraded is a kiosk's normal state — an update check that
      // cannot run is not worth interrupting anyone for.
      debugPrint('[updates] check skipped: $e');
    }
  }

  void dispose() {
    _esp32.removeListener(_onClientChanged);
    unawaited(_attention.close());
  }
}

class UpdateAttention {
  const UpdateAttention.firmware({required this.current, required this.expected})
      : serverUpdate = false;

  const UpdateAttention.server()
      : serverUpdate = true,
        current = null,
        expected = null;

  /// True when this is the "server code is behind" notice rather than the
  /// hub-firmware popup.
  final bool serverUpdate;
  final String? current;
  final String? expected;
}
