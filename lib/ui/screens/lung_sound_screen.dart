import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../core/api/upload_client.dart';
import '../../core/theme/xs_colors.dart';
import '../../core/theme/xs_spacing.dart';
import '../../core/theme/xs_typography.dart';
import '../components/xs_app_bar.dart';
import '../components/xs_button.dart';
import '../components/xs_card.dart';
import '../components/xs_confidence_meter.dart';
import '../components/xs_icon_button.dart';
import '../components/xs_result_reveal.dart';
import '../components/xs_waveform.dart';

class LungSoundScreen extends StatefulWidget {
  const LungSoundScreen({super.key});

  @override
  State<LungSoundScreen> createState() => _LungSoundScreenState();
}

class _LungSoundScreenState extends State<LungSoundScreen> {
  final AudioRecorder _recorder = AudioRecorder();
  final UploadClient _upload = UploadClient();

  bool _recording = false;
  bool _uploading = false;
  Duration _elapsed = Duration.zero;
  Timer? _ticker;
  String? _recordedPath;

  String? _resultLabel;
  double? _resultConfidence;
  String? _error;
  int _resultRevision = 0;

  /// Below this the clip rarely covers a full inspiration/expiration cycle, so
  /// the classifier result is noise. Soft guidance only — we still let staff
  /// stop early and upload if they want.
  static const _minUsefulRecording = Duration(seconds: 8);

  Future<void> _toggleRecord() async {
    if (_recording) {
      await _stop();
    } else {
      await _start();
    }
  }

  Future<void> _start() async {
    if (!await _recorder.hasPermission()) {
      setState(() => _error = 'Microphone permission denied.');
      return;
    }
    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/xsight_lung_${DateTime.now().millisecondsSinceEpoch}.wav';
    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
      ),
      path: path,
    );
    setState(() {
      _recording = true;
      _recordedPath = path;
      _elapsed = Duration.zero;
      _resultLabel = null;
      _resultConfidence = null;
      _error = null;
    });
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _elapsed += const Duration(seconds: 1));
    });
  }

  Future<void> _stop() async {
    _ticker?.cancel();
    final path = await _recorder.stop();
    setState(() {
      _recording = false;
      if (path != null) _recordedPath = path;
    });
    if (_recordedPath != null && File(_recordedPath!).existsSync()) {
      await _analyze();
    }
  }

  Future<void> _analyze() async {
    final path = _recordedPath;
    if (path == null) return;
    setState(() {
      _uploading = true;
      _error = null;
    });
    try {
      final res = await _upload.uploadLungSound(file: File(path));
      if (!mounted) return;
      setState(() {
        _resultLabel = _humanLabel(res.label);
        _resultConfidence = res.confidence;
        _uploading = false;
        _resultRevision++;
      });
    } on UploadException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _uploading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Upload failed: $e';
        _uploading = false;
      });
    }
  }

  String _humanLabel(String raw) {
    switch (raw) {
      case 'normal':
        return 'Normal Breath Sounds';
      case 'wheeze':
        return 'Wheeze Detected';
      case 'crackle':
        return 'Crackles Detected';
      default:
        return raw;
    }
  }

  String _format(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _recorder.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    final tooShort = _elapsed < _minUsefulRecording;
    return Column(
      children: [
        const XSAppBar(title: 'Lung Sound'),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(
              XSSpacing.lg,
              XSSpacing.sm,
              XSSpacing.lg,
              XSSpacing.huge + XSSpacing.lg,
            ),
            child: Column(
              children: [
                Text(
                  _recording
                      ? 'Recording... breathe normally'
                      : _uploading
                          ? 'Uploading and analyzing...'
                          : 'Place stethoscope and tap to record',
                  textAlign: TextAlign.center,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: palette.textSecondary),
                ),
                const SizedBox(height: XSSpacing.xl),
                XSCard(
                  glow: _recording ? XSColors.moduleSteth : null,
                  borderColor: _recording ? XSColors.moduleSteth : null,
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (_recording) ...[
                            _RecDot(color: XSColors.accentRed),
                            const SizedBox(width: XSSpacing.xs),
                          ],
                          Text(
                            _format(_elapsed),
                            style: XSTypography.stat(palette.textPrimary),
                          ),
                        ],
                      ),
                      const SizedBox(height: XSSpacing.xxs),
                      Text(
                        _recording && tooShort
                            ? 'Keep going — aim for ${_minUsefulRecording.inSeconds}s'
                            : _recording
                                ? 'Enough audio captured — tap stop when ready'
                                : 'Target ${_minUsefulRecording.inSeconds}s of quiet breathing',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: palette.textSecondary,
                            ),
                      ),
                      const SizedBox(height: XSSpacing.lg),
                      XSWaveform(active: _recording),
                    ],
                  ),
                ),
                const SizedBox(height: XSSpacing.xxl),
                XSIconButton(
                  icon: _recording ? Icons.stop_rounded : Icons.mic_rounded,
                  size: 96,
                  inverted: _recording,
                  onPressed: _uploading ? null : _toggleRecord,
                  semanticLabel: _recording
                      ? 'Stop recording'
                      : 'Start recording',
                ),
                const SizedBox(height: XSSpacing.xl),
                if (_uploading)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor:
                              AlwaysStoppedAnimation(palette.textSecondary),
                        ),
                      ),
                      const SizedBox(width: XSSpacing.sm),
                      Text('Classifying breath sounds...',
                          style: Theme.of(context).textTheme.labelMedium),
                    ],
                  ),
                if (_error != null)
                  XSCard(
                    borderColor: XSColors.accentRed,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.error_outline,
                            size: 18, color: XSColors.accentRed),
                        const SizedBox(width: XSSpacing.sm),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(_error!,
                                  style:
                                      Theme.of(context).textTheme.bodyMedium),
                              if (_recordedPath != null) ...[
                                const SizedBox(height: XSSpacing.sm),
                                XSButton(
                                  label: 'Retry',
                                  icon: Icons.refresh,
                                  onPressed: _uploading ? null : _analyze,
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                if (_resultLabel != null && _resultConfidence != null)
                  XSResultReveal(
                    trigger: _resultRevision,
                    child: XSCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('AI Result',
                              style: Theme.of(context).textTheme.titleMedium),
                          const SizedBox(height: XSSpacing.sm),
                          Text(_resultLabel!,
                              style: XSTypography.stat(palette.textPrimary)),
                          const SizedBox(height: XSSpacing.sm),
                          Text(
                            'Confidence ${(_resultConfidence! * 100).toStringAsFixed(0)}%',
                            style: Theme.of(context).textTheme.labelMedium,
                          ),
                          const SizedBox(height: XSSpacing.xs),
                          XSConfidenceMeter(
                            value: _resultConfidence!,
                            color: _resultLabel == 'Normal Breath Sounds'
                                ? XSColors.accentGreen
                                : XSColors.accentOrange,
                          ),
                          const SizedBox(height: XSSpacing.md),
                          Row(
                            children: [
                              Expanded(
                                child: XSButton(
                                  label: 'Re-record',
                                  icon: Icons.mic_none_rounded,
                                  onPressed: _uploading ? null : _start,
                                ),
                              ),
                              const SizedBox(width: XSSpacing.sm),
                              Expanded(
                                child: XSButton(
                                  label: 'Analyze again',
                                  inverted: true,
                                  icon: Icons.refresh,
                                  onPressed:
                                      (_uploading || _recordedPath == null)
                                          ? null
                                          : _analyze,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: XSSpacing.md),
                          Text(
                            'AI-assisted screening only. Not a diagnosis. '
                            'Consult a licensed clinician.',
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Pulsing red dot next to the elapsed timer — the one unambiguous "live"
/// signal, since the waveform animates on synthetic data too.
class _RecDot extends StatefulWidget {
  final Color color;
  const _RecDot({required this.color});

  @override
  State<_RecDot> createState() => _RecDotState();
}

class _RecDotState extends State<_RecDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween(begin: 1.0, end: 0.25).animate(_ctrl),
      child: Container(
        width: 10,
        height: 10,
        decoration:
            BoxDecoration(color: widget.color, shape: BoxShape.circle),
      ),
    );
  }
}
