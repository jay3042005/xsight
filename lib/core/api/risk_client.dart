import 'dart:convert';
import 'dart:io';

import '../config/xs_config.dart';
import '../../state/xs_settings.dart';

class VitalsRisk {
  final String level; // low | moderate | high
  final List<String> reasons;
  const VitalsRisk({required this.level, required this.reasons});

  factory VitalsRisk.fromJson(Map<String, dynamic> json) => VitalsRisk(
        level: (json['level'] as String?) ?? 'low',
        reasons: ((json['reasons'] as List?) ?? const [])
            .whereType<String>()
            .toList(),
      );
}

class RiskClient {
  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 8);

  /// POSTs vitals to `/vitals` and returns the rule-based risk level.
  Future<VitalsRisk> scoreVitals({
    double? hr,
    double? spo2,
    double? temp,
    double? rr,
  }) async {
    final base = XSSettings.I.hasBackend
        ? XSSettings.I.backendUrl
        : XSConfig.backendBaseUrl;
    if (base.isEmpty) {
      throw Exception('No server IP configured.');
    }
    final uri = Uri.parse('$base/vitals');
    final body = jsonEncode({
      if (hr != null) 'hr': hr,
      if (spo2 != null) 'spo2': spo2,
      if (temp != null) 'temp': temp,
      if (rr != null) 'rr': rr,
    });
    final req = await _http.postUrl(uri);
    req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    req.add(utf8.encode(body));
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    if (res.statusCode >= 400) {
      throw Exception('Vitals risk failed (${res.statusCode}): $text');
    }
    return VitalsRisk.fromJson(jsonDecode(text) as Map<String, dynamic>);
  }

  void dispose() {
    _http.close(force: true);
  }
}
