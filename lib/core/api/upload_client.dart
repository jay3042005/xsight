import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'dart:convert';

import '../config/xs_config.dart';
import '../../state/xs_settings.dart';

/// Result of a chest X-ray screening call.
class XrayResult {
  final String label;
  final String confidence;
  final String findings;
  final String notes;
  final String raw;
  final String model;
  final int tookMs;
  final bool unstable;
  final String modelStatus;

  const XrayResult({
    required this.label,
    required this.confidence,
    required this.findings,
    required this.notes,
    required this.raw,
    required this.model,
    required this.tookMs,
    this.unstable = true,
    this.modelStatus = 'unstable',
  });

  factory XrayResult.fromJson(Map<String, dynamic> json) => XrayResult(
    label: (json['label'] as String?) ?? 'unknown',
    confidence: (json['confidence'] as String?) ?? 'low',
    findings: (json['findings'] as String?) ?? '',
    notes: (json['notes'] as String?) ?? '',
    raw: (json['raw'] as String?) ?? '',
    model: (json['model'] as String?) ?? 'unknown',
    tookMs: (json['took_ms'] as num?)?.toInt() ?? 0,
    unstable: (json['unstable'] as bool?) ?? true,
    modelStatus: (json['model_status'] as String?) ?? 'unstable',
  );
}

/// Result of a lung-sound classification call.
class LungSoundResult {
  final String label;
  final double confidence;
  final int bytesReceived;

  /// Which classifier produced [label] — `torch` for the trained CNN,
  /// `heuristic` for the hand-picked frequency thresholds it falls back to.
  ///
  /// Surfaced because the fallback is otherwise invisible: a model that fails to
  /// load leaves the backend serving labels and confidences of the same shape, so
  /// without this the kiosk cannot tell a trained reading from a guess.
  final String model;

  /// Signal strength of the capture, in ESP32 ADC counts RMS.
  ///
  /// The amplitude the classifier actually saw, measured before it normalises
  /// every recording to the same peak. Useful for judging whether a surprising
  /// label came from a weak capture — a bell on the chest reads in the tens.
  final double signalRmsCounts;

  const LungSoundResult({
    required this.label,
    required this.confidence,
    required this.bytesReceived,
    this.model = '',
    this.signalRmsCounts = 0,
  });

  /// True when the label came from the spectral heuristic rather than the model.
  bool get isHeuristic => model == 'heuristic';

  factory LungSoundResult.fromJson(Map<String, dynamic> json) {
    final features = json['features'];
    return LungSoundResult(
      label: (json['label'] as String?) ?? 'unknown',
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0,
      bytesReceived: (json['bytes_received'] as num?)?.toInt() ?? 0,
      model: (json['model'] as String?) ?? '',
      signalRmsCounts: features is Map
          ? ((features['signal_rms_counts'] as num?)?.toDouble() ?? 0)
          : 0,
    );
  }
}

class UploadException implements Exception {
  final String message;
  final int? status;
  UploadException(this.message, {this.status});
  @override
  String toString() => 'UploadException($status): $message';
}

/// Thin wrapper around the backend's multipart upload endpoints.
class UploadClient {
  static const _uploadTimeout = Duration(seconds: 60);

  String _backend() {
    final base = XSSettings.I.hasBackend
        ? XSSettings.I.backendUrl
        : XSConfig.backendBaseUrl;
    if (base.isEmpty) {
      throw UploadException(
        'No server IP configured. Open Settings to set it.',
      );
    }
    return base;
  }

  Future<XrayResult> uploadXray({
    File? file,
    Uint8List? bytes,
    String filename = 'xray.jpg',
    int? patientId,
  }) async {
    final uri = Uri.parse('${_backend()}/xray');
    final req = http.MultipartRequest('POST', uri);
    if (file != null) {
      req.files.add(await http.MultipartFile.fromPath('file', file.path));
    } else if (bytes != null) {
      req.files.add(
        http.MultipartFile.fromBytes('file', bytes, filename: filename),
      );
    } else {
      throw UploadException('No file or bytes provided.');
    }
    if (patientId != null) {
      req.fields['patient_id'] = '$patientId';
    }
    final res = await _send(req);
    if (res.statusCode >= 400) {
      throw UploadException(_extractError(res.body), status: res.statusCode);
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    return XrayResult.fromJson(data);
  }

  Future<LungSoundResult> uploadLungSound({
    File? file,
    Uint8List? bytes,
    int? patientId,
  }) async {
    final uri = Uri.parse('${_backend()}/lung-sound');
    final req = http.MultipartRequest('POST', uri);
    if (file != null) {
      req.files.add(await http.MultipartFile.fromPath('file', file.path));
    } else if (bytes != null) {
      req.files.add(
        http.MultipartFile.fromBytes('file', bytes, filename: 'esp32_lung.wav'),
      );
    } else {
      throw UploadException('No lung-sound data provided.');
    }
    if (patientId != null) {
      req.fields['patient_id'] = '$patientId';
    }
    final res = await _send(req);
    if (res.statusCode >= 400) {
      throw UploadException(_extractError(res.body), status: res.statusCode);
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    return LungSoundResult.fromJson(data);
  }

  Future<http.Response> _send(http.MultipartRequest request) async {
    try {
      final streamed = await request.send().timeout(_uploadTimeout);
      return await http.Response.fromStream(streamed).timeout(_uploadTimeout);
    } on TimeoutException {
      throw UploadException(
        'The server took too long to process the upload. Check the backend and try again.',
      );
    }
  }

  String _extractError(String body) {
    try {
      final data = jsonDecode(body);
      if (data is Map<String, dynamic>) {
        final err = data['error'] ?? data['detail'];
        if (err is String) return err;
        if (err is Map<String, dynamic>) {
          return err['message']?.toString() ?? body;
        }
      }
    } catch (_) {}
    return body.isEmpty ? 'Unknown error' : body;
  }
}
