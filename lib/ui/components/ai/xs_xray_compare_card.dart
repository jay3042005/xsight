import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../core/theme/xs_colors.dart';
import '../../../core/theme/xs_radius.dart';
import '../../../core/theme/xs_spacing.dart';
import 'xs_ai_card_frame.dart';

/// Side-by-side chest-film comparison: healthy baseline, this patient's film,
/// and the Grad-CAM overlay when one exists.
///
/// Same three-panel treatment as the X-ray screen's COMPARISON tab — both use
/// [XSComparePanel] — so a film the AI summons into chat looks identical to the
/// one the clinician was just looking at.
class XSXrayCompareCard extends StatelessWidget {
  /// The patient's film. Null renders the unavailable state.
  final File? patientImage;

  /// Grad-CAM overlay. Null (the multimodal-vision fallback path, which
  /// produces no heatmap) drops the third panel rather than failing.
  final Uint8List? heatmap;

  /// Classifier label for the patient panel's sublabel, e.g. `'PNEUMONIA'`.
  final String? finding;

  /// Region the model asked to highlight, shown in the header.
  final String? focus;

  const XSXrayCompareCard({
    super.key,
    this.patientImage,
    this.heatmap,
    this.finding,
    this.focus,
  });

  /// Decodes a base64 heatmap, returning null rather than throwing.
  ///
  /// The `/xray` response reuses its `raw` field for two different things —
  /// base64 PNG from the local classifier, free-form prose from the vision
  /// fallback — so a decode here must be allowed to fail.
  static Uint8List? tryDecodeHeatmap(String? b64) {
    if (b64 == null || b64.trim().isEmpty) return null;
    try {
      final bytes = base64Decode(b64.trim());
      return bytes.isEmpty ? null : bytes;
    } on FormatException {
      return null;
    }
  }

  bool get _abnormal {
    final f = finding?.trim().toLowerCase();
    if (f == null || f.isEmpty) return false;
    return f != 'normal';
  }

  @override
  Widget build(BuildContext context) {
    final file = patientImage;

    return XSAiCardFrame(
      label: 'X-RAY COMPARISON',
      sublabel: focus == null ? null : 'focus: $focus',
      icon: Icons.compare_outlined,
      accent: XSColors.moduleXray,
      bodyHeight: file == null ? null : 260,
      child: file == null
          ? const XSAiCardUnavailable(
              message: 'No chest film in this session yet — run the X-ray '
                  'station to compare against the baseline.',
            )
          : Row(
              children: [
                Expanded(
                  child: XSComparePanel(
                    label: 'NORMAL REFERENCE',
                    sublabel: 'Healthy lung baseline',
                    borderColor: XSColors.accentGreen,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(XSRadius.sm),
                      child: Image.asset(
                        'assets/images/normal_chest_xray.jpg',
                        fit: BoxFit.contain,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: XSSpacing.sm),
                Expanded(
                  child: XSComparePanel(
                    label: 'THIS PATIENT',
                    sublabel: (finding?.trim().isNotEmpty ?? false)
                        ? finding!.toUpperCase()
                        : 'captured this session',
                    borderColor: _abnormal
                        ? XSColors.accentOrange
                        : XSColors.accentGreen,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(XSRadius.sm),
                      child: Image.file(file, fit: BoxFit.contain),
                    ),
                  ),
                ),
                // Third panel only when there is genuinely a heatmap to show.
                if (heatmap != null) ...[
                  const SizedBox(width: XSSpacing.sm),
                  Expanded(
                    child: XSComparePanel(
                      label: 'AI HEATMAP',
                      sublabel: 'Regions of interest',
                      borderColor: Colors.deepOrange,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(XSRadius.sm),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Image.file(file, fit: BoxFit.contain),
                            Opacity(
                              opacity: 0.55,
                              child: Image.memory(
                                heatmap!,
                                fit: BoxFit.contain,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
    );
  }
}
