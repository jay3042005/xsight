import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/config/xs_config.dart';

/// Persistent settings (server IP, etc.). Loaded once at app start, then
/// listened to by [ChangeNotifier]-aware widgets.
class XSSettings extends ChangeNotifier {
  XSSettings._();
  static final XSSettings I = XSSettings._();

  static const _kBackendUrl = 'backend_url';
  static const _kInputDeviceId = 'input_device_id';
  static const _kInputDeviceLabel = 'input_device_label';
  static const _kVoiceGuideEnabled = 'voice_guide_enabled';
  static const _kVoiceGuideVolume = 'voice_guide_volume';

  String _backendUrl = XSConfig.backendBaseUrl;
  String _inputDeviceId = '';
  String _inputDeviceLabel = '';
  bool _voiceGuideEnabled = true;
  double _voiceGuideVolume = 1.0;

  /// Currently active backend base URL. Falls back to compile-time
  /// `--dart-define=BACKEND_BASE_URL` when no override is saved.
  String get backendUrl => _backendUrl;

  /// Platform id of the chosen microphone, or empty for the system default.
  ///
  /// A kiosk has more than one plausible input — the tablet's built-in mic, a
  /// USB headset, the ESP32 module's own audio path — and the system default is
  /// often the wrong one. Persisted so a kiosk keeps its mic across restarts.
  String get inputDeviceId => _inputDeviceId;

  /// Human-readable name of the chosen microphone, for display without having
  /// to re-enumerate devices (which needs mic permission on some platforms).
  String get inputDeviceLabel => _inputDeviceLabel;

  bool get hasInputDeviceOverride => _inputDeviceId.isNotEmpty;

  /// Whether the kiosk speaks its pre-recorded guidance.
  ///
  /// On by default: the guide exists for walk-up users who cannot or will not
  /// read the screen, and a kiosk that ships silent helps none of them. Staff
  /// can mute a shared room from Settings, and the choice persists.
  bool get voiceGuideEnabled => _voiceGuideEnabled;

  /// Playback level for guidance clips, 0..1.
  double get voiceGuideVolume => _voiceGuideVolume;

  /// True when the app is configured to talk to a local FastAPI server
  /// (overrides direct Zen calls when set).
  bool get hasBackend => _backendUrl.isNotEmpty;

  /// Loads persisted values. Call once before runApp().
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_kBackendUrl);
    if (saved != null && saved.isNotEmpty) {
      _backendUrl = saved;
    }
    _inputDeviceId = prefs.getString(_kInputDeviceId) ?? '';
    _inputDeviceLabel = prefs.getString(_kInputDeviceLabel) ?? '';
    _voiceGuideEnabled = prefs.getBool(_kVoiceGuideEnabled) ?? true;
    _voiceGuideVolume =
        (prefs.getDouble(_kVoiceGuideVolume) ?? 1.0).clamp(0.0, 1.0);
    notifyListeners();
  }

  Future<void> setVoiceGuideEnabled(bool on) async {
    if (_voiceGuideEnabled == on) return;
    _voiceGuideEnabled = on;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kVoiceGuideEnabled, on);
    notifyListeners();
  }

  Future<void> setVoiceGuideVolume(double volume) async {
    final clamped = volume.clamp(0.0, 1.0);
    if (_voiceGuideVolume == clamped) return;
    _voiceGuideVolume = clamped;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kVoiceGuideVolume, clamped);
    notifyListeners();
  }

  /// Records the chosen microphone. Pass null to fall back to the system
  /// default.
  Future<void> setInputDevice({String? id, String? label}) async {
    final prefs = await SharedPreferences.getInstance();
    if (id == null || id.isEmpty) {
      await prefs.remove(_kInputDeviceId);
      await prefs.remove(_kInputDeviceLabel);
      _inputDeviceId = '';
      _inputDeviceLabel = '';
    } else {
      await prefs.setString(_kInputDeviceId, id);
      await prefs.setString(_kInputDeviceLabel, label ?? id);
      _inputDeviceId = id;
      _inputDeviceLabel = label ?? id;
    }
    notifyListeners();
  }

  /// Saves a new backend URL. Empty string clears the override and falls
  /// back to the compile-time default.
  Future<void> setBackendUrl(String url) async {
    final cleaned = _normalize(url);
    final prefs = await SharedPreferences.getInstance();
    if (cleaned.isEmpty) {
      await prefs.remove(_kBackendUrl);
      _backendUrl = XSConfig.backendBaseUrl;
    } else {
      await prefs.setString(_kBackendUrl, cleaned);
      _backendUrl = cleaned;
    }
    notifyListeners();
  }

  /// Resets to the compile-time default.
  Future<void> reset() => setBackendUrl('');

  String _normalize(String input) {
    var v = input.trim();
    if (v.isEmpty) return '';
    // Allow "192.168.1.10:8000" or "192.168.1.10" (assume http + 8000).
    if (!v.startsWith('http://') && !v.startsWith('https://')) {
      v = 'http://$v';
    }
    if (!v.contains(RegExp(r':\d+'), v.indexOf('://') + 3)) {
      v = '$v:8000';
    }
    // Strip trailing slash.
    if (v.endsWith('/')) v = v.substring(0, v.length - 1);
    return v;
  }
}
