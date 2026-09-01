import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/theme/xs_colors.dart';
import '../../core/theme/xs_radius.dart';
import '../../core/theme/xs_scale.dart';
import '../../core/theme/xs_spacing.dart';
import '../../state/xs_settings.dart';
import 'xs_button.dart';

/// "Take your summary with you" — a QR the patient scans to download the report
/// PDF onto their own phone.
///
/// The kiosk pushes the PDF to the transfer service and shows the code; the
/// phone downloads it from there. It cannot fetch from the kiosk directly, for
/// the same reason the film could not be sent to it: a page on an HTTPS origin
/// cannot reach a plain-HTTP LAN address.
///
/// Replaces copying a LAN URL to the clipboard, which a kiosk with no browser
/// and no keyboard could do nothing with.
class XSReportQrDialog extends StatefulWidget {
  final int consultationId;
  final String? patientName;

  const XSReportQrDialog({
    super.key,
    required this.consultationId,
    this.patientName,
  });

  static Future<void> show(
    BuildContext context, {
    required int consultationId,
    String? patientName,
  }) {
    return showDialog<void>(
      context: context,
      builder: (_) => XSReportQrDialog(
        consultationId: consultationId,
        patientName: patientName,
      ),
    );
  }

  @override
  State<XSReportQrDialog> createState() => _XSReportQrDialogState();
}

class _XSReportQrDialogState extends State<XSReportQrDialog> {
  String? _url;
  String? _error;
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    _mint();
  }

  Future<void> _mint() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final base = XSSettings.I.backendUrl;
    if (base.isEmpty) {
      setState(() {
        _busy = false;
        _error = 'No server IP set. Open Settings first.';
      });
      return;
    }
    try {
      final resp = await http
          .post(Uri.parse('$base/handoff/report/${widget.consultationId}'))
          .timeout(const Duration(seconds: 20));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        String detail = 'HTTP ${resp.statusCode}';
        try {
          final body = jsonDecode(resp.body);
          if (body is Map && body['detail'] is String) detail = body['detail'];
        } catch (_) {}
        throw StateError(detail);
      }
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _busy = false;
        _url = data['download_url'] as String?;
        if (_url == null) _error = 'Server did not return a download link.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    final s = XSScale.factor;

    return AlertDialog(
      backgroundColor: palette.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(XSRadius.lg),
      ),
      title: Row(
        children: [
          Icon(Icons.qr_code_2, size: 24 * s, color: palette.accent),
          SizedBox(width: 10 * s),
          Expanded(
            child: Text(
              'Take the summary with you',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: palette.textPrimary,
              ),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 380 * s,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.patientName != null)
              Padding(
                padding: EdgeInsets.only(bottom: XSSpacing.sm * s),
                child: Text(
                  widget.patientName!,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: palette.textSecondary,
                  ),
                ),
              ),
            if (_error != null)
              Column(
                children: [
                  Icon(Icons.error_outline,
                      size: 40 * s, color: XSColors.accentRed),
                  SizedBox(height: XSSpacing.sm * s),
                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 14, color: palette.textSecondary),
                  ),
                ],
              )
            else
              Column(
                children: [
                  Container(
                    width: 220 * s,
                    height: 220 * s,
                    padding: EdgeInsets.all(XSSpacing.sm * s),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(XSRadius.md),
                      border: Border.all(color: palette.divider),
                    ),
                    alignment: Alignment.center,
                    child: _busy || _url == null
                        ? const CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: XSColors.moduleSummary,
                          )
                        : QrImageView(
                            data: _url!,
                            version: QrVersions.auto,
                            size: 200 * s,
                            eyeStyle: const QrEyeStyle(
                              eyeShape: QrEyeShape.square,
                              color: XSColors.slate,
                            ),
                            dataModuleStyle: const QrDataModuleStyle(
                              dataModuleShape: QrDataModuleShape.square,
                              color: XSColors.slate,
                            ),
                          ),
                  ),
                  SizedBox(height: XSSpacing.md * s),
                  Text(
                    'Scan with a phone camera to download the PDF. The link '
                    'stops working after a few minutes.',
                    textAlign: TextAlign.center,
                    style:
                        TextStyle(fontSize: 14, color: palette.textSecondary),
                  ),
                ],
              ),
          ],
        ),
      ),
      actions: [
        if (_error != null)
          TextButton(onPressed: _mint, child: const Text('Try again')),
        XSButton(
          label: 'DONE',
          height: 52,
          width: 140,
          onPressed: () => Navigator.pop(context),
        ),
      ],
    );
  }
}
