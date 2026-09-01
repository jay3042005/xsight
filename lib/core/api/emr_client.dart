import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../state/xs_settings.dart';

/// Thrown when an EMR request fails (network, non-2xx, or bad payload).
class EMRException implements Exception {
  final String message;
  final int? status;
  EMRException(this.message, {this.status});
  @override
  String toString() => 'EMRException($status): $message';
}

/// EMR client — patient management, vitals history, consultations.
///
/// Every call validates the backend URL is configured and checks the HTTP
/// status before decoding, so callers get an actionable [EMRException]
/// instead of a raw JSON-decode crash or a silently ignored failure.
class EMRClient {
  String get _base {
    final url = XSSettings.I.backendUrl;
    if (url.isEmpty) {
      throw EMRException('No server configured. Set the backend IP in Settings.');
    }
    return '$url/emr';
  }

  static const _timeout = Duration(seconds: 8);

  dynamic _decode(http.Response resp) {
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw EMRException(_errorText(resp), status: resp.statusCode);
    }
    if (resp.body.isEmpty) return null;
    try {
      return jsonDecode(resp.body);
    } catch (_) {
      throw EMRException('Malformed server response.', status: resp.statusCode);
    }
  }

  String _errorText(http.Response resp) {
    try {
      final data = jsonDecode(resp.body);
      if (data is Map) {
        final detail = data['detail'] ?? data['error'] ?? data['message'];
        if (detail is String && detail.isNotEmpty) return detail;
      }
    } catch (_) {}
    return 'Server error ${resp.statusCode}';
  }

  Future<List<dynamic>> _getList(Uri uri) async {
    final data = _decode(await http.get(uri).timeout(_timeout));
    return data is List ? data : const [];
  }

  Future<Map<String, dynamic>> _getMap(Uri uri) async {
    final data = _decode(await http.get(uri).timeout(_timeout));
    return data is Map<String, dynamic> ? data : <String, dynamic>{};
  }

  // Patients
  Future<List<dynamic>> listPatients({int limit = 50, int offset = 0}) {
    return _getList(Uri.parse('$_base/patients?limit=$limit&offset=$offset'));
  }

  Future<List<dynamic>> searchPatients(String q) {
    return _getList(Uri.parse('$_base/patients/search?q=${Uri.encodeComponent(q)}'));
  }

  Future<Map<String, dynamic>> getPatient(int id) {
    return _getMap(Uri.parse('$_base/patients/$id'));
  }

  Future<Map<String, dynamic>> createPatient(Map<String, dynamic> data) async {
    final resp = await http.post(
      Uri.parse('$_base/patients'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(data),
    ).timeout(_timeout);
    final decoded = _decode(resp);
    return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
  }

  Future<void> updatePatient(int id, Map<String, dynamic> data) async {
    _decode(await http.put(
      Uri.parse('$_base/patients/$id'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(data),
    ).timeout(_timeout));
  }

  Future<void> deletePatient(int id) async {
    _decode(await http.delete(Uri.parse('$_base/patients/$id')).timeout(_timeout));
  }

  // Vitals
  Future<List<dynamic>> getVitals(int patientId, {int limit = 100}) {
    return _getList(Uri.parse('$_base/patients/$patientId/vitals?limit=$limit'));
  }

  Future<Map<String, dynamic>> recordVitals(int patientId, Map<String, dynamic> data) async {
    final resp = await http.post(
      Uri.parse('$_base/patients/$patientId/vitals'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(data),
    ).timeout(_timeout);
    final decoded = _decode(resp);
    return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
  }

  // X-ray history
  Future<List<dynamic>> getXrayHistory(int patientId) {
    return _getList(Uri.parse('$_base/patients/$patientId/xrays'));
  }

  // Lung sound history
  Future<List<dynamic>> getLungHistory(int patientId) {
    return _getList(Uri.parse('$_base/patients/$patientId/lung-sounds'));
  }

  // Consultations
  Future<List<dynamic>> getConsultations(int patientId) {
    return _getList(Uri.parse('$_base/patients/$patientId/consultations'));
  }

  Future<List<dynamic>> listConsultations({int limit = 50}) {
    return _getList(Uri.parse('$_base/consultations?limit=$limit'));
  }

  Future<Map<String, dynamic>> createConsultation(int patientId, Map<String, dynamic> data) async {
    final resp = await http.post(
      Uri.parse('$_base/patients/$patientId/consultations'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(data),
    ).timeout(_timeout);
    final decoded = _decode(resp);
    return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
  }

  // Notifications
  Future<List<dynamic>> getNotifications({bool unread = false}) {
    return _getList(Uri.parse('$_base/notifications?unread=$unread'));
  }

  Future<void> markRead(int id) async {
    _decode(await http.put(Uri.parse('$_base/notifications/$id/read')).timeout(_timeout));
  }

  Future<void> markAllRead() async {
    _decode(await http.put(Uri.parse('$_base/notifications/read-all')).timeout(_timeout));
  }

  // PDF Export
  String getPdfUrl(int consultationId) {
    return '${XSSettings.I.backendUrl}/reports/$consultationId/pdf';
  }

  // Analytics
  Future<Map<String, dynamic>> getAnalytics() {
    return _getMap(Uri.parse('$_base/analytics'));
  }

  // Dynamic Server Guest Session
  Future<Map<String, dynamic>> createGuestSession() async {
    try {
      final resp = await http.post(
        Uri.parse('$_base/guest-session'),
        headers: {'Content-Type': 'application/json'},
      ).timeout(_timeout);
      final decoded = _decode(resp);
      return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    } catch (_) {
      final randSuffix = DateTime.now().millisecondsSinceEpoch % 10000;
      final guestId = 'GST-${DateTime.now().millisecondsSinceEpoch ~/ 1000}-$randSuffix';
      return {
        'guest_id': guestId,
        'mrn': guestId,
        'name': 'Walk-In Guest Session (#$randSuffix)',
        'is_guest': true,
      };
    }
  }
}
