import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../core/api/upload_client.dart';
import '../../core/sensor/esp32_serial_client.dart';
import '../../core/voice/voice_guide.dart';
import '../../core/api/cdss_client.dart';
import '../../core/theme/xs_colors.dart';
import '../../core/theme/xs_radius.dart';
import '../../core/theme/xs_spacing.dart';
import '../../core/theme/xs_shadows.dart';
import '../../state/kiosk_patient_state.dart';
import '../components/xs_button.dart';
import '../components/xs_chip.dart';
import '../components/xs_patient_picker.dart';

/// Auscultation anatomical landmark site
enum AuscultationSite {
  rul('RUL', 'Right Upper Lobe (Anterior Infraclavicular)'),
  lul('LUL', 'Left Upper Lobe (Anterior Infraclavicular)'),
  rll('RLL', 'Right Lower Lobe (Posterior Lower Axillary)'),
  lll('LLL', 'Left Lower Lobe (Posterior Lower Axillary)');

  final String code;
  final String label;
  const AuscultationSite(this.code, this.label);
}

/// Kiosk Digital Stethoscope Screen — Ultra-Premium Auscultation Suite.
/// Synchronized with firmware/XSIGHT hardware protocol (START_STETH / STOP_STETH),
/// 20Hz-800Hz IIR Bandpass audio visualization, and CDSS classification.
class KioskLungSoundScreen extends StatefulWidget {
  const KioskLungSoundScreen({super.key});

  @override
  State<KioskLungSoundScreen> createState() => _KioskLungSoundScreenState();
}

class _KioskLungSoundScreenState extends State<KioskLungSoundScreen>
    with SingleTickerProviderStateMixin {
  final UploadClient _upload = UploadClient();
  final Esp32SerialClient _esp32 = Esp32SerialClient.shared;
  final CDSSClient _cdss = CDSSClient();

  bool _recording = false;
  bool _uploading = false;
  Duration _elapsed = Duration.zero;
  Timer? _ticker;
  LungSoundResult? _result;
  String? _error;
  double _liveLevel = 0;
  AuscultationSite _currentSite = AuscultationSite.rul;
  bool _connected = false;
  bool _autoStartPending = true;

  /// Who this recording gets attached to. Read from the session rather than held
  /// locally, so this screen, the X-ray screen, the dashboard's patient chip and
  /// the OLED's `PATIENT:` line can never name different people.
  int? get _selectedPatientId => KioskPatientSession.I.selectedPatientId;

  static const int _targetDurationSec = 10;

  @override
  void initState() {
    super.initState();
    _esp32.onStethState = _onHardwareStethState;
    _connected = _esp32.connected;
    _esp32.addListener(_onLink);
    KioskPatientSession.I.addListener(_onSessionChanged);
    if (_connected) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _tryAutoStart());
    } else {
      _esp32.connect().then((_) => _tryAutoStart());
    }
  }

  void _onSessionChanged() {
    if (mounted) setState(() {});
  }

  /// Cheap link-state watcher. Shares the notifier with the sample stream, so
  /// it guards on an actual change to avoid rebuilding at 50 Hz.
  void _onLink() {
    if (!mounted || _connected == _esp32.connected) return;
    setState(() => _connected = _esp32.connected);
    _tryAutoStart();
  }

  void _tryAutoStart() {
    if (!mounted || !_autoStartPending || !_esp32.connected) return;
    _autoStartPending = false;
    unawaited(_start());
  }

  void _onHardwareStethState(String line) {
    if (!mounted) return;
    if (line == 'STETH_START:1') {
      if (!_recording) _start(fromHardware: true);
    } else if (line == 'STETH_DONE:1') {
      if (_recording) _stop(fromHardware: true);
    }
  }

  Future<void> _toggleRecord() async {
    if (_recording) {
      await _stop();
    } else {
      await _start();
    }
  }

  Future<void> _start({bool fromHardware = false}) async {
    if (_recording || _uploading) return;
    if (!_esp32.connected) {
      setState(() => _error = 'Connect XSIGHT Module first.');
      return;
    }
    _esp32.clearStethSamples();
    _esp32.addListener(_onSerial);
    setState(() {
      _recording = true;
      _elapsed = Duration.zero;
      _result = null;
      _error = null;
    });

    if (!fromHardware && !_esp32.sendCommand('START_STETH')) {
      _esp32.removeListener(_onSerial);
      setState(() {
        _recording = false;
        _error = 'Could not start the XSIGHT Module recording.';
      });
      return;
    }
    VoiceGuide.I.say(XSVoiceCue.lungsBreathe);

    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _elapsed += const Duration(seconds: 1);
        if (_elapsed.inSeconds >= _targetDurationSec && _recording) {
          _stop();
        }
      });
    });
  }

  void _onSerial() {
    final sample = _esp32.latestSteth?.value;
    if (sample != null && mounted) {
      setState(() => _liveLevel = sample);
    }
  }

  Future<void> _stop({bool fromHardware = false}) async {
    if (!_recording) return;
    _ticker?.cancel();
    setState(() => _recording = false);
    _esp32.removeListener(_onSerial);
    if (!fromHardware) {
      _esp32.sendCommand('STOP_STETH');
    }
    await _analyzeEsp32();
  }

  Future<void> _analyzeEsp32() async {
    if (_uploading) return;
    final samples = _esp32.stethSamples;
    if (samples.length < 100) {
      setState(
        () => _error =
            'Insufficient acoustic data. Please position stethoscope on chest and try again.',
      );
      VoiceGuide.I.say(XSVoiceCue.lungsRetry);
      return;
    }
    setState(() {
      _uploading = true;
      _error = null;
    });
    VoiceGuide.I.say(XSVoiceCue.lungsChecking);
    try {
      final res = await _upload.uploadLungSound(
        bytes: _wav(samples),
        patientId: _selectedPatientId,
      );
      if (mounted) {
        setState(() {
          _result = res;
          _uploading = false;
        });
        VoiceGuide.I.say(XSVoiceCue.lungsDone);
      }
      // Recorded in both modes. Gating this on `isGuest` meant a staff member's
      // auscultation never reached the CDSS summary, the AI assistant's patient
      // context, or the PDF report, while vitals and temperature always did.
      KioskPatientSession.I.recordStethoscope('', res.label);
      try {
        await _cdss.assess(
          lungLabel: res.label,
          lungConfidence: res.confidence,
          patientId: _selectedPatientId ?? 0,
        );
      } catch (e) {
        debugPrint('[steth] CDSS sync skipped: $e');
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          // The backend rejects a capture with no lung sound in it (422) and the
          // detail names what to do about it, so show that rather than wrapping a
          // coaching message in "UploadException(422):".
          _error = e is UploadException ? e.message : '$e';
          _uploading = false;
        });
        VoiceGuide.I.say(XSVoiceCue.lungsRetry);
      }
    }
  }

  Uint8List _wav(List<int> samples) {
    final data = <int>[];
    void u16(int v) {
      data
        ..add(v & 255)
        ..add((v >> 8) & 255);
    }

    void u32(int v) {
      u16(v & 0xffff);
      u16(v >> 16);
    }

    final bytes = samples.length * 2;
    data.addAll('RIFF'.codeUnits);
    u32(36 + bytes);
    data.addAll('WAVE'.codeUnits);
    data.addAll('fmt '.codeUnits);
    u32(16);
    u16(1); // PCM
    u16(1); // Mono
    u32(2000); // 2kHz sample rate (MAX9814 matching firmware/XSIGHT)
    u32(4000); // Byte rate (2000 * 2)
    u16(2); // Block align
    u16(16); // 16-bit
    data.addAll('data'.codeUnits);
    u32(bytes);
    for (final sample in samples) {
      u16(sample < 0 ? sample + 65536 : sample);
    }
    return Uint8List.fromList(data);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _esp32.removeListener(_onSerial);
    _esp32.removeListener(_onLink);
    KioskPatientSession.I.removeListener(_onSessionChanged);
    if (_esp32.onStethState == _onHardwareStethState) {
      _esp32.onStethState = null;
    }
    super.dispose();
  }

  String get _timeStr =>
      '${_elapsed.inMinutes.toString().padLeft(2, '0')}:'
      '${(_elapsed.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    return Padding(
      padding: const EdgeInsets.all(XSSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header Bar
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: XSColors.moduleSteth.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.graphic_eq,
                  size: 22,
                  color: XSColors.moduleSteth,
                ),
              ),
              const SizedBox(width: XSSpacing.sm),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'DIGITAL AUSCULTATION SUITE',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.2,
                      color: palette.textPrimary,
                    ),
                  ),
                  Text(
                    'MAX9814 20Hz–800Hz Bandpassed Acoustic Pipeline',
                    style: TextStyle(
                      fontSize: 13,
                      color: palette.textSecondary,
                    ),
                  ),
                ],
              ),
              const Spacer(),
              _LinkChip(
                connected: _connected,
                onConnect: () => _esp32.connect(),
              ),
              const SizedBox(width: XSSpacing.sm),
              XSPatientPicker(
                selectedPatientId: _selectedPatientId,
                onChanged: (patient) => patient == null
                    ? KioskPatientSession.I.unlinkPatient()
                    : KioskPatientSession.I.selectPatient(patient),
              ),
            ],
          ),
          const SizedBox(height: XSSpacing.md),

          // Main Layout
          Expanded(
            child: Row(
              children: [
                // Left Panel: Oscilloscope Waveform & Anatomical Guide
                Expanded(
                  flex: 3,
                  child: Container(
                    padding: const EdgeInsets.all(XSSpacing.lg),
                    decoration: BoxDecoration(
                      color: palette.surface,
                      borderRadius: BorderRadius.circular(XSRadius.lg),
                      boxShadow: XSShadows.soft(palette),
                      border: Border.all(color: palette.divider),
                    ),
                    child: Column(
                      children: [
                        // Site Picker Bar
                        Row(
                          children: [
                            Text(
                              'AUSCULTATION LANDMARK:',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w800,
                                color: palette.textSecondary,
                                letterSpacing: 0.8,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                child: Row(
                                  children: AuscultationSite.values.map((site) {
                                    final selected = site == _currentSite;
                                    return GestureDetector(
                                      onTap: () =>
                                          setState(() => _currentSite = site),
                                      child: Container(
                                        margin: const EdgeInsets.only(right: 6),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 4,
                                        ),
                                        decoration: BoxDecoration(
                                          color: selected
                                              ? XSColors.moduleSteth
                                              : palette.highlight,
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                          border: Border.all(
                                            color: selected
                                                ? XSColors.moduleSteth
                                                : palette.divider,
                                          ),
                                        ),
                                        child: Text(
                                          site.code,
                                          style: TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w800,
                                            color: selected
                                                ? Colors.white
                                                : palette.textPrimary,
                                          ),
                                        ),
                                      ),
                                    );
                                  }).toList(),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: XSSpacing.xs),
                        Text(
                          _currentSite.label,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: XSColors.moduleSteth,
                          ),
                        ),
                        const SizedBox(height: XSSpacing.md),

                        // Real-Time Acoustic Oscilloscope Canvas
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(XSRadius.md),
                            child: Container(
                              color: const Color(0xFF0D1B2A),
                              child: Stack(
                                children: [
                                  // Grid & Waveform Painter
                                  CustomPaint(
                                    size: Size.infinite,
                                    painter: _StethOscilloscopePainter(
                                      samples: _esp32.stethSamples,
                                      recording: _recording,
                                      liveLevel: _liveLevel,
                                    ),
                                  ),

                                  // Top Telemetry Overlay
                                  Positioned(
                                    top: 12,
                                    left: 12,
                                    child: Row(
                                      children: [
                                        Container(
                                          width: 8,
                                          height: 8,
                                          decoration: BoxDecoration(
                                            color: _recording
                                                ? XSColors.accentRed
                                                : XSColors.accentGreen,
                                            shape: BoxShape.circle,
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        Text(
                                          _recording
                                              ? 'LIVE 2kHz STREAM'
                                              : 'STANDBY',
                                          style: TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w800,
                                            color: _recording
                                                ? Colors.redAccent
                                                : Colors.greenAccent,
                                            fontFamily: 'monospace',
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),

                                  // Live Amplitude Monitor
                                  if (_recording)
                                    Positioned(
                                      top: 12,
                                      right: 12,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 3,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.black.withValues(
                                            alpha: 0.6,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            6,
                                          ),
                                          border: Border.all(
                                            color: Colors.cyanAccent.withValues(
                                              alpha: 0.4,
                                            ),
                                          ),
                                        ),
                                        child: Text(
                                          'AMP: ${_liveLevel.toStringAsFixed(0)}',
                                          style: const TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w800,
                                            color: Colors.cyanAccent,
                                            fontFamily: 'monospace',
                                          ),
                                        ),
                                      ),
                                    ),

                                  // Timer Display Overlay
                                  Align(
                                    alignment: Alignment.center,
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        if (_recording) ...[
                                          Text(
                                            _timeStr,
                                            style: const TextStyle(
                                              fontSize: 42,
                                              fontWeight: FontWeight.w900,
                                              color: Colors.white,
                                              fontFamily: 'monospace',
                                              shadows: [
                                                Shadow(
                                                  color: Colors.black,
                                                  blurRadius: 10,
                                                ),
                                              ],
                                            ),
                                          ),
                                          Text(
                                            'HOLD STILL — ${(_targetDurationSec - _elapsed.inSeconds).clamp(0, _targetDurationSec)}s LEFT',
                                            style: TextStyle(
                                              fontSize: 13,
                                              fontWeight: FontWeight.w800,
                                              color: Colors.white.withValues(
                                                alpha: 0.7,
                                              ),
                                              letterSpacing: 1.0,
                                            ),
                                          ),
                                          const SizedBox(height: 8),
                                          SizedBox(
                                            width: 180,
                                            child: ClipRRect(
                                              borderRadius:
                                                  BorderRadius.circular(4),
                                              child: LinearProgressIndicator(
                                                value:
                                                    (_elapsed.inSeconds /
                                                            _targetDurationSec)
                                                        .clamp(0.0, 1.0),
                                                minHeight: 6,
                                                backgroundColor: Colors.white
                                                    .withValues(alpha: 0.15),
                                                color: Colors.cyanAccent,
                                              ),
                                            ),
                                          ),
                                        ] else if (_esp32
                                            .stethSamples
                                            .isEmpty) ...[
                                          Icon(
                                            Icons.monitor_heart_outlined,
                                            size: 48,
                                            color: Colors.white.withValues(
                                              alpha: 0.3,
                                            ),
                                          ),
                                          const SizedBox(height: 8),
                                          Text(
                                            _connected
                                                ? 'POSITION STETHOSCOPE OVER ${_currentSite.code}'
                                                : 'XSIGHT MODULE NOT CONNECTED',
                                            style: TextStyle(
                                              fontSize: 13,
                                              fontWeight: FontWeight.w800,
                                              color: Colors.white.withValues(
                                                alpha: 0.7,
                                              ),
                                              letterSpacing: 1.0,
                                            ),
                                          ),
                                          Text(
                                            _connected
                                                ? 'Press OK on XSIGHT Module or button below to record'
                                                : 'Plug in the module over USB, then tap CONNECT above',
                                            style: TextStyle(
                                              fontSize: 13,
                                              color: Colors.white.withValues(
                                                alpha: 0.5,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: XSSpacing.md),

                        // Hardware Controls Bar
                        Row(
                          children: [
                            Expanded(
                              child: XSButton(
                                icon: _recording
                                    ? Icons.stop_rounded
                                    : Icons.play_arrow_rounded,
                                label: _recording
                                    ? 'STOP & CLASSIFY'
                                    : _uploading
                                    ? 'CLASSIFYING...'
                                    : 'START RECORDING',
                                tooltip: _recording
                                    ? 'Stop & Analyze'
                                    : 'Start Recording',
                                inverted: true,
                                onPressed: (!_connected || _uploading)
                                    ? null
                                    : _toggleRecord,
                              ),
                            ),
                            if (_esp32.stethSamples.isNotEmpty &&
                                !_recording) ...[
                              const SizedBox(width: XSSpacing.sm),
                              XSButton(
                                icon: Icons.refresh,
                                label: 'RE-CLASSIFY',
                                tooltip: 'Re-run classifier on captured audio',
                                onPressed: _uploading ? null : _analyzeEsp32,
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: XSSpacing.md),

                // Right Panel: AI Classification Results & Pathology Checklist
                Expanded(
                  flex: 2,
                  child: Column(
                    children: [
                      // Classification Result Box
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.all(XSSpacing.md),
                          decoration: BoxDecoration(
                            color: palette.surface,
                            borderRadius: BorderRadius.circular(XSRadius.lg),
                            boxShadow: XSShadows.soft(palette),
                            border: Border.all(color: palette.divider),
                          ),
                          child: _uploading
                              ? const Center(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      CircularProgressIndicator(),
                                      SizedBox(height: XSSpacing.md),
                                      Text(
                                        'Running Spectral Classifier...',
                                        style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                )
                              : _result == null
                              ? Center(
                                  child: _error == null
                                      ? Text(
                                          'Record acoustic signals to run AI classification',
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                            fontSize: 14,
                                            color: palette.textSecondary,
                                          ),
                                        )
                                      : Column(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            const Icon(
                                              Icons.error_outline,
                                              size: 28,
                                              color: XSColors.accentRed,
                                            ),
                                            const SizedBox(
                                              height: XSSpacing.xs,
                                            ),
                                            Text(
                                              _error!,
                                              textAlign: TextAlign.center,
                                              style: const TextStyle(
                                                fontSize: 14,
                                                fontWeight: FontWeight.w600,
                                                color: XSColors.accentRed,
                                              ),
                                            ),
                                          ],
                                        ),
                                )
                              : Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'ACOUSTIC CLASSIFICATION',
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w800,
                                        color: palette.textSecondary,
                                        letterSpacing: 0.8,
                                      ),
                                    ),
                                    const SizedBox(height: XSSpacing.xs),
                                    Row(
                                      children: [
                                        Text(
                                          _result!.label.toUpperCase(),
                                          style: TextStyle(
                                            fontSize: 24,
                                            fontWeight: FontWeight.w900,
                                            color: _result!.label == 'normal'
                                                ? XSColors.accentGreen
                                                : _result!.label ==
                                                      'inconclusive'
                                                ? palette.textSecondary
                                                : XSColors.accentOrange,
                                          ),
                                        ),
                                        const SizedBox(width: XSSpacing.xs),
                                        // The heuristic is a set of
                                        // hand-picked frequency thresholds,
                                        // not a trained model. It answers in
                                        // the same shape, so without saying so
                                        // there is no way to tell one reading
                                        // from the other.
                                        if (_result!.isHeuristic)
                                          const XSChip(
                                            label: 'NO MODEL — ESTIMATE',
                                            icon: Icons.rule,
                                            color: Colors.amber,
                                          ),
                                        // The backend gates low-confidence
                                        // predictions to "inconclusive":
                                        // every model trained for this kiosk
                                        // is wrong more often than right at
                                        // low confidence, and presenting that
                                        // as a finding would be worse than
                                        // saying nothing.
                                        if (_result!.label == 'inconclusive')
                                          const XSChip(
                                            label: 'LOW CONFIDENCE — RETRY',
                                            icon: Icons.help_outline,
                                            color: Colors.grey,
                                          ),
                                      ],
                                    ),
                                    const SizedBox(height: XSSpacing.sm),
                                    LinearProgressIndicator(
                                      value: _result!.confidence,
                                      backgroundColor: palette.highlight,
                                      color: _result!.label == 'normal'
                                          ? XSColors.accentGreen
                                          : _result!.label == 'inconclusive'
                                              ? palette.textSecondary
                                              : XSColors.accentOrange,
                                      minHeight: 8,
                                    ),
                                    const SizedBox(height: XSSpacing.xs),
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      children: [
                                        Text(
                                          'Confidence: ${(_result!.confidence * 100).toStringAsFixed(1)}%',
                                          style: TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w700,
                                            color: palette.textPrimary,
                                          ),
                                        ),
                                        Text(
                                          '${_result!.bytesReceived} bytes'
                                          ' \u00B7 '
                                          '${_result!.signalRmsCounts.toStringAsFixed(0)} ct RMS',
                                          style: TextStyle(
                                            fontSize: 13,
                                            color: palette.textSecondary,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                        ),
                      ),
                      const SizedBox(height: XSSpacing.sm),

                      // Sound Pathology Reference List
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.all(XSSpacing.md),
                          decoration: BoxDecoration(
                            color: palette.surface,
                            borderRadius: BorderRadius.circular(XSRadius.lg),
                            boxShadow: XSShadows.soft(palette),
                            border: Border.all(color: palette.divider),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'ACOUSTIC PATHOLOGY TARGETS',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w800,
                                  color: palette.textSecondary,
                                  letterSpacing: 0.8,
                                ),
                              ),
                              const SizedBox(height: XSSpacing.xs),
                              Expanded(
                                child: ListView(
                                  children: [
                                    _findingTile(
                                      palette,
                                      'Normal Breath Sounds',
                                      'Vesicular breath sounds, no rales',
                                      'normal',
                                    ),
                                    _findingTile(
                                      palette,
                                      'Crackle (Rales)',
                                      'Discontinuous explosive popping sounds',
                                      'crackle',
                                    ),
                                    _findingTile(
                                      palette,
                                      'Wheeze',
                                      'Continuous high-pitched musical sound',
                                      'wheeze',
                                    ),
                                    _findingTile(
                                      palette,
                                      'Mixed (Both)',
                                      'Co-occurring crackle & wheeze',
                                      'both',
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _findingTile(
    XSPalette palette,
    String name,
    String desc,
    String value,
  ) {
    final isActive = _result?.label == value;
    final color = value == 'normal'
        ? XSColors.accentGreen
        : XSColors.accentOrange;

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(XSSpacing.sm),
      decoration: BoxDecoration(
        color: isActive ? color.withValues(alpha: 0.12) : palette.highlight,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isActive ? color : palette.divider,
          width: isActive ? 2 : 1,
        ),
      ),
      child: Row(
        children: [
          Icon(
            isActive ? Icons.check_circle : Icons.circle_outlined,
            size: 16,
            color: isActive ? color : palette.textSecondary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: isActive ? FontWeight.w800 : FontWeight.w600,
                    color: isActive ? color : palette.textPrimary,
                  ),
                ),
                Text(
                  desc,
                  style: TextStyle(fontSize: 13, color: palette.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Module Link Status Chip ───────────────────────────────────────
/// Serial link state + one-tap reconnect. The stethoscope is hardware-only —
/// no phone mic path — so a dead link is the single most common failure and
/// deserves a permanent readout rather than an error after the fact.
class _LinkChip extends StatelessWidget {
  final bool connected;
  final VoidCallback onConnect;
  const _LinkChip({required this.connected, required this.onConnect});

  @override
  Widget build(BuildContext context) {
    final color = connected ? XSColors.accentGreen : XSColors.accentOrange;
    return Tooltip(
      message: connected
          ? 'XSIGHT module connected over USB serial'
          : 'Module not connected — tap to retry',
      child: GestureDetector(
        onTap: connected ? null : onConnect,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: color),
          ),
          child: Row(
            children: [
              Icon(
                connected ? Icons.usb : Icons.usb_off,
                size: 14,
                color: color,
              ),
              const SizedBox(width: 6),
              Text(
                connected ? 'MODULE LINKED' : 'CONNECT',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.6,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Real-Time Oscilloscope Waveform Painter ──────────────────────
class _StethOscilloscopePainter extends CustomPainter {
  final List<int> samples;
  final bool recording;
  final double liveLevel;

  _StethOscilloscopePainter({
    required this.samples,
    required this.recording,
    required this.liveLevel,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final cy = h / 2;

    // 1. Draw Grid Lines
    final gridPaint = Paint()
      ..color = Colors.cyan.withValues(alpha: 0.08)
      ..strokeWidth = 1.0;

    for (double x = 0; x < w; x += 40) {
      canvas.drawLine(Offset(x, 0), Offset(x, h), gridPaint);
    }
    for (double y = 0; y < h; y += 30) {
      canvas.drawLine(Offset(0, y), Offset(w, y), gridPaint);
    }

    // Center Baseline
    final basePaint = Paint()
      ..color = Colors.cyan.withValues(alpha: 0.25)
      ..strokeWidth = 1.0;
    canvas.drawLine(Offset(0, cy), Offset(w, cy), basePaint);

    if (samples.isEmpty) return;

    // 2. Draw Real-Time Waveform Path
    final wavePath = Path();
    final pointCount = math.min(samples.length, 300);
    final startIdx = samples.length - pointCount;
    final stepX = w / (pointCount - 1);

    for (int i = 0; i < pointCount; i++) {
      final val = samples[startIdx + i];
      // Normalize ADC 0..4095 or signed sample around center
      final norm = (val - 2048) / 2048.0;
      final y = cy - (norm * (h * 0.45));

      final x = i * stepX;
      if (i == 0) {
        wavePath.moveTo(x, y);
      } else {
        wavePath.lineTo(x, y);
      }
    }

    final wavePaint = Paint()
      ..color = recording ? Colors.cyanAccent : Colors.tealAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    canvas.drawPath(wavePath, wavePaint);

    // Glow effect
    final glowPaint = Paint()
      ..color = (recording ? Colors.cyanAccent : Colors.tealAccent).withValues(
        alpha: 0.3,
      )
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.0;
    canvas.drawPath(wavePath, glowPaint);
  }

  @override
  bool shouldRepaint(covariant _StethOscilloscopePainter oldDelegate) {
    return oldDelegate.samples.length != samples.length ||
        oldDelegate.recording != recording ||
        oldDelegate.liveLevel != liveLevel;
  }
}
