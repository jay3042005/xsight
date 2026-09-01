import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../state/xs_settings.dart';

class CDSSException implements Exception {
  final String message;
  final int? status;
  CDSSException(this.message, {this.status});
  @override
  String toString() => 'CDSSException($status): $message';
}

/// CDSS client — calls /cdss/assess to fuse findings.
class CDSSClient {
  static const _timeout = Duration(seconds: 8);

  /// Map qualitative or numeric confidence strings to 0..1.
  static double parseConfidence(Object? raw) {
    if (raw is num) return raw.toDouble().clamp(0.0, 1.0);
    final s = (raw ?? '').toString().trim().toLowerCase();
    if (s.isEmpty) return 0.0;
    final n = double.tryParse(s);
    if (n != null) return n.clamp(0.0, 1.0);
    return switch (s) {
      'high' || 'very high' => 0.85,
      'medium' || 'moderate' => 0.55,
      'low' => 0.3,
      _ => 0.5,
    };
  }

  Future<Map<String, dynamic>> assess({
    String xrayPrediction = '',
    double xrayConfidence = 0.0,
    String lungLabel = '',
    double lungConfidence = 0.0,
    Map<String, double> vitals = const {},
    int patientId = 0,
  }) async {
    final base = XSSettings.I.backendUrl;
    if (base.isEmpty) {
      throw CDSSException('No server configured. Set the backend IP in Settings.');
    }
    final uri = Uri.parse('$base/cdss/assess');
    final resp = await http
        .post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'xray_prediction': xrayPrediction,
            'xray_confidence': xrayConfidence,
            'lung_label': lungLabel,
            'lung_confidence': lungConfidence,
            'vitals': vitals,
            'patient_id': patientId,
          }),
        )
        .timeout(_timeout);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw CDSSException('CDSS request failed', status: resp.statusCode);
    }
    try {
      final data = jsonDecode(resp.body);
      if (data is Map<String, dynamic>) return data;
      throw CDSSException('Malformed CDSS response', status: resp.statusCode);
    } catch (e) {
      if (e is CDSSException) rethrow;
      throw CDSSException('Malformed CDSS response', status: resp.statusCode);
    }
  }
}
