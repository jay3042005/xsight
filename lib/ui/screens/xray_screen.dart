import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/api/upload_client.dart';
import '../../core/theme/xs_colors.dart';
import '../../core/theme/xs_radius.dart';
import '../../core/theme/xs_spacing.dart';
import '../../core/theme/xs_typography.dart';
import '../components/xs_app_bar.dart';
import '../components/xs_button.dart';
import '../components/xs_card.dart';
import '../components/xs_scan_overlay.dart';
import '../components/xs_confidence_meter.dart';
import '../components/xs_result_reveal.dart';

/// Chest X-ray analytics — pick or capture an image, upload to /xray,
/// render a structured AI screening result.
class XrayScreen extends StatefulWidget {
  const XrayScreen({super.key});

  @override
  State<XrayScreen> createState() => _XrayScreenState();
}

class _XrayScreenState extends State<XrayScreen> {
  final ImagePicker _picker = ImagePicker();
  final UploadClient _upload = UploadClient();

  File? _selectedFile;
  XrayResult? _result;
  String? _error;
  bool _busy = false;
  int _resultRevision = 0;

  Future<void> _pickFromGallery() async {
    try {
      final XFile? f = await _picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 92,
        maxWidth: 1600,
      );
      if (f == null) return;
      setState(() {
        _selectedFile = File(f.path);
        _result = null;
        _error = null;
      });
    } catch (e) {
      setState(() => _error = 'Failed to pick image: $e');
    }
  }

  Future<void> _captureFromCamera() async {
    try {
      final XFile? f = await _picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 92,
        maxWidth: 1600,
      );
      if (f == null) return;
      setState(() {
        _selectedFile = File(f.path);
        _result = null;
        _error = null;
      });
    } catch (e) {
      setState(() => _error = 'Failed to capture image: $e');
    }
  }

  /// The scan overlay animation needs at least one full sweep cycle to read
  /// as a deliberate "analysis" rather than a flicker — the local ONNX
  /// model often responds in well under a second, so we pad the busy state
  /// out to this floor before revealing the result.
  static const _minAnalyzeDuration = Duration(milliseconds: 2200);

  Future<void> _analyze() async {
    final file = _selectedFile;
    if (file == null) return;
    setState(() {
      _busy = true;
      _error = null;
      _result = null;
    });
    final stopwatch = Stopwatch()..start();
    try {
      final res = await _upload.uploadXray(file: file);
      await _waitOutMinDuration(stopwatch);
      if (!mounted) return;
      setState(() {
        _result = res;
        _busy = false;
        _resultRevision++;
      });
    } on UploadException catch (e) {
      await _waitOutMinDuration(stopwatch);
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _busy = false;
      });
    } catch (e) {
      await _waitOutMinDuration(stopwatch);
      if (!mounted) return;
      setState(() {
        _error = 'Upload failed: $e';
        _busy = false;
      });
    }
  }

  Future<void> _waitOutMinDuration(Stopwatch stopwatch) async {
    final remaining = _minAnalyzeDuration - stopwatch.elapsed;
    if (remaining > Duration.zero) {
      await Future.delayed(remaining);
    }
  }

  /// Maps the backend's categorical confidence string to a 0..1 value for
  /// the animated meter (the backend only reports low/moderate/high, not a
  /// raw probability).
  double _confidenceValue(String confidence) {
    switch (confidence.toLowerCase()) {
      case 'high':
        return 0.9;
      case 'moderate':
        return 0.65;
      default:
        return 0.35;
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    return Scaffold(
      backgroundColor: palette.surface,
      body: SafeArea(
        child: Column(
          children: [
            XSAppBar(
              title: 'Chest X-Ray',
              leading: GestureDetector(
                onTap: () => Navigator.of(context).pop(),
                child: Icon(Icons.arrow_back_ios_new,
                    size: 20, color: palette.textPrimary),
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  XSSpacing.lg,
                  XSSpacing.sm,
                  XSSpacing.lg,
                  XSSpacing.huge,
                ),
                children: [
                  Text(
                    'Upload or capture a frontal chest radiograph for '
                    'AI-assisted screening.',
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(color: palette.textSecondary),
                  ),
                  const SizedBox(height: XSSpacing.md),
                  _ImagePreview(
                    file: _selectedFile,
                    palette: palette,
                    analyzing: _busy,
                    onPick: _busy ? null : _pickFromGallery,
                  ),
                  const SizedBox(height: XSSpacing.md),
                  Row(
                    children: [
                      Expanded(
                        child: XSButton(
                          label: 'Gallery',
                          icon: Icons.photo_library_outlined,
                          onPressed: _busy ? null : _pickFromGallery,
                        ),
                      ),
                      const SizedBox(width: XSSpacing.sm),
                      Expanded(
                        child: XSButton(
                          label: 'Camera',
                          icon: Icons.photo_camera_outlined,
                          onPressed: _busy ? null : _captureFromCamera,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: XSSpacing.sm),
                  XSButton(
                    label: _busy ? 'Analyzing...' : 'Analyze X-Ray',
                    inverted: true,
                    icon: Icons.auto_awesome,
                    width: double.infinity,
                    onPressed: (_selectedFile == null || _busy) ? null : _analyze,
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: XSSpacing.md),
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
                                Text(
                                  _error!,
                                  style:
                                      Theme.of(context).textTheme.bodyMedium,
                                ),
                                if (_selectedFile != null) ...[
                                  const SizedBox(height: XSSpacing.sm),
                                  XSButton(
                                    label: 'Retry',
                                    icon: Icons.refresh,
                                    onPressed: _busy ? null : _analyze,
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 300),
                    child: _busy
                        ? Padding(
                            key: const ValueKey('analyzing-card'),
                            padding: const EdgeInsets.only(top: XSSpacing.lg),
                            child: _AnalyzingCard(palette: palette),
                          )
                        : _result != null
                            ? Padding(
                                key: ValueKey('result-card-$_resultRevision'),
                                padding: const EdgeInsets.only(top: XSSpacing.lg),
                                child: XSResultReveal(
                                  trigger: _resultRevision,
                                  child: _ResultCard(
                                    result: _result!,
                                    palette: palette,
                                    confidenceValue: _confidenceValue(_result!.confidence),
                                  ),
                                ),
                              )
                            : const SizedBox.shrink(key: ValueKey('no-result')),
                  ),
                  const SizedBox(height: XSSpacing.lg),
                  XSCard(
                    child: Row(
                      children: [
                        Icon(Icons.info_outline,
                            size: 18, color: palette.textSecondary),
                        const SizedBox(width: XSSpacing.sm),
                        Expanded(
                          child: Text(
                            'AI-assisted screening only. Not a medical '
                            'diagnosis. Always consult a licensed clinician.',
                            style: Theme.of(context).textTheme.labelMedium,
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
      ),
    );
  }
}

class _ImagePreview extends StatelessWidget {
  final File? file;
  final XSPalette palette;
  final bool analyzing;

  /// Tapping the empty placeholder opens the gallery — the buttons below stay
  /// as the discoverable path, this is just the shortcut everyone tries first.
  final VoidCallback? onPick;

  const _ImagePreview({
    required this.file,
    required this.palette,
    this.analyzing = false,
    this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    final f = file;
    return AspectRatio(
      aspectRatio: 4 / 3,
      child: Container(
        decoration: BoxDecoration(
          color: palette.surface,
          borderRadius: BorderRadius.circular(XSRadius.lg),
          border: Border.all(color: palette.divider, width: 0.6),
        ),
        clipBehavior: Clip.antiAlias,
        child: f == null
            ? Semantics(
                button: true,
                label: 'Select a chest X-ray image',
                child: InkWell(
                  onTap: onPick,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.add_photo_alternate_outlined,
                            size: 48, color: palette.textSecondary),
                        const SizedBox(height: 8),
                        Text(
                          'Tap to select an X-ray',
                          style: Theme.of(context).textTheme.labelMedium,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'PNG or JPG, frontal view',
                          style: Theme.of(context)
                              .textTheme
                              .labelSmall
                              ?.copyWith(color: palette.textSecondary),
                        ),
                      ],
                    ),
                  ),
                ),
              )
            : Stack(
                fit: StackFit.expand,
                children: [
                  Image.file(f, fit: BoxFit.contain),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 250),
                    child: analyzing
                        ? const XSScanOverlay(
                            key: ValueKey('scanning'),
                            label: 'Analyzing X-ray...',
                          )
                        : const SizedBox.shrink(key: ValueKey('idle')),
                  ),
                ],
              ),
      ),
    );
  }
}

/// Shimmer skeleton shown under the image while an analysis request is in
/// flight, mirroring the eventual `_ResultCard` layout.
class _AnalyzingCard extends StatefulWidget {
  final XSPalette palette;
  const _AnalyzingCard({required this.palette});

  @override
  State<_AnalyzingCard> createState() => _AnalyzingCardState();
}

class _AnalyzingCardState extends State<_AnalyzingCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        final glow = 0.35 + _ctrl.value * 0.35;
        Widget bar(double width, double height) => Container(
              width: width,
              height: height,
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: widget.palette.divider.withValues(alpha: glow * 0.6),
                borderRadius: BorderRadius.circular(6),
              ),
            );
        return XSCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation(
                        widget.palette.textPrimary.withValues(alpha: glow),
                      ),
                    ),
                  ),
                  const SizedBox(width: XSSpacing.sm),
                  Text('ANALYZING',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.6,
                          color: widget.palette.textSecondary.withValues(alpha: glow))),
                ],
              ),
              const SizedBox(height: XSSpacing.lg),
              bar(160, 26),
              bar(120, 12),
              const SizedBox(height: XSSpacing.sm),
              bar(double.infinity, 13),
              bar(double.infinity, 13),
              bar(220, 13),
            ],
          ),
        );
      },
    );
  }
}

class _ResultCard extends StatelessWidget {
  final XrayResult result;
  final XSPalette palette;
  final double confidenceValue;
  const _ResultCard({
    required this.result,
    required this.palette,
    required this.confidenceValue,
  });

  @override
  Widget build(BuildContext context) {
    return XSCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('AI ASSESSMENT',
                  style: Theme.of(context).textTheme.labelSmall),
              const Spacer(),
              Text(
                '${result.tookMs} ms',
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ],
          ),
          const SizedBox(height: XSSpacing.sm),
          if (result.unstable) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(XSSpacing.sm),
              margin: const EdgeInsets.only(bottom: XSSpacing.sm),
              decoration: BoxDecoration(
                color: Colors.amber.shade900.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(XSRadius.sm),
                border: Border.all(color: Colors.amber.shade700, width: 0.8),
              ),
              child: Row(
                children: [
                  Icon(Icons.warning_amber_rounded, size: 16, color: Colors.amber.shade400),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'UNSTABLE MODEL — Retrained 5-class classifier in use.',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Colors.amber.shade300,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          Text(
            _humanLabel(result.label),
            style: XSTypography.stat(palette.textPrimary),
          ),
          const SizedBox(height: 4),
          Text(
            'Confidence ${result.confidence}',
            style: Theme.of(context).textTheme.labelMedium,
          ),
          const SizedBox(height: XSSpacing.sm),
          XSConfidenceMeter(
            value: confidenceValue,
            color: result.label.toLowerCase() == 'normal'
                ? XSColors.accentGreen
                : XSColors.accentOrange,
          ),
          const SizedBox(height: XSSpacing.md),
          if (result.findings.isNotEmpty) ...[
            Text('Findings',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(result.findings,
                style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: XSSpacing.md),
          ],
          if (result.notes.isNotEmpty) ...[
            Text('Notes',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(result.notes,
                style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: XSSpacing.md),
          ],
          Container(
            padding: const EdgeInsets.all(XSSpacing.sm),
            decoration: BoxDecoration(
              color: palette.surface,
              borderRadius: BorderRadius.circular(XSRadius.sm),
              border: Border.all(color: palette.divider, width: 0.6),
            ),
            child: Text(
              'Model: ${result.model}',
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
        ],
      ),
    );
  }

  String _humanLabel(String raw) {
    switch (raw) {
      case 'normal':
        return 'Likely Normal';
      case 'pneumonia':
        return 'Pneumonia';
      case 'tuberculosis':
        return 'Tuberculosis';
      case 'effusion':
        return 'Pleural Effusion';
      case 'cardiomegaly':
        return 'Cardiomegaly';
      case 'mass':
        return 'Mass';
      case 'other':
        return 'Other Finding';
      default:
        return 'Inconclusive';
    }
  }
}
