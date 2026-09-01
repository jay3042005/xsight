import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../state/xs_settings.dart';
import '../config/xs_config.dart';

/// The server's picture of what needs updating — the only update source the
/// kiosk consults. The kiosk never talks to GitHub: a walk-up tablet on a
/// clinic LAN has no business holding repo credentials or burning API quota,
/// and one source of truth means the launcher and kiosk can never disagree
/// about what "current" is.
class UpdatesStatus {
  const UpdatesStatus({
    required this.serverUpdateAvailable,
    required this.firmwareExpectedVersion,
    required this.firmwareBinAvailable,
    required this.firmwareBinBytes,
  });

  factory UpdatesStatus.fromJson(Map<String, dynamic> json) {
    final server = (json['server'] as Map?) ?? const {};
    final fw = (json['firmware'] as Map?) ?? const {};
    return UpdatesStatus(
      // Tri-state on the wire; collapsed to "don't know → don't prompt".
      serverUpdateAvailable: server['update_available'] == true,
      firmwareExpectedVersion: fw['expected_version'] as String?,
      firmwareBinAvailable: fw['bin_available'] == true,
      firmwareBinBytes: (fw['bin_bytes'] as num?)?.toInt() ?? 0,
    );
  }

  final bool serverUpdateAvailable;
  final String? firmwareExpectedVersion;
  final bool firmwareBinAvailable;
  final int firmwareBinBytes;

  /// Outdated firmware is only actionable when the server can actually hand
  /// us a binary to push.
  bool get firmwareActionable =>
      firmwareBinAvailable &&
      firmwareExpectedVersion != null &&
      firmwareBinBytes > 0;
}

class UpdatesClient {
  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 6);

  String get _base {
    final base = XSSettings.I.hasBackend
        ? XSSettings.I.backendUrl
        : XSConfig.backendBaseUrl;
    if (base.isEmpty) throw Exception('No server IP configured.');
    return base;
  }

  Future<UpdatesStatus> status() async {
    final req = await _http.getUrl(Uri.parse('$_base/updates'));
    final res = await req.close();
    if (res.statusCode != 200) {
      throw Exception('Updates check failed: HTTP ${res.statusCode}');
    }
    return UpdatesStatus.fromJson(
      jsonDecode(await res.transform(utf8.decoder).join()) as Map<String, dynamic>,
    );
  }

  /// The flashable hub firmware, exactly as the server serves it.
  Future<Uint8List> firmwareBinary() async {
    final req = await _http.getUrl(Uri.parse('$_base/firmware/bin'));
    final res = await req.close();
    if (res.statusCode != 200) {
      throw Exception('Firmware download failed: HTTP ${res.statusCode}');
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in res) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }
}
