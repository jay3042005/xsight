import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/api/intake_handoff_client.dart';
import '../../core/theme/xs_colors.dart';
import '../../core/theme/xs_radius.dart';
import '../../core/theme/xs_scale.dart';
import '../../core/theme/xs_spacing.dart';
import 'xs_button.dart';
import 'xs_card.dart';

/// The check-in screen's live intake code.
///
/// Purely presentational, mirroring [XSHandoffPanel] for chest films: the owning
/// screen holds the [IntakeHandoffClient] so the code survives this widget
/// rebuilding, and every state the handoff can be in has a rendering here rather
/// than a spinner that never resolves.
class XSIntakeQrPanel extends StatelessWidget {
  final IntakeHandoffClient handoff;

  /// Re-issue the code after it expired or failed to mint.
  final VoidCallback onRetry;

  /// Name pulled out of a received submission, for the confirmation line.
  final String? receivedName;

  const XSIntakeQrPanel({
    super.key,
    required this.handoff,
    required this.onRetry,
    this.receivedName,
  });

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    final s = XSScale.factor;

    return XSCard(
      padding: EdgeInsets.all(XSSpacing.lg * s),
      glow: XSColors.teal,
      borderColor: XSColors.teal.withValues(alpha: 0.3),
      child: switch (handoff.state) {
        IntakeHandoffState.preparing => _qr(palette, s, isPreparing: true),
        IntakeHandoffState.waiting => _qr(palette, s, isPreparing: false),
        IntakeHandoffState.received => _received(palette, s),
        IntakeHandoffState.expired => _problem(
            palette,
            s,
            icon: Icons.timer_off_outlined,
            color: XSColors.accentOrange,
            title: 'That code expired',
            detail: 'Nothing arrived in time. Codes are short-lived so an '
                'abandoned one cannot be picked up by someone else later.',
            actionLabel: 'NEW CODE',
          ),
        IntakeHandoffState.failed => _problem(
            palette,
            s,
            icon: Icons.phonelink_off_outlined,
            color: XSColors.accentRed,
            title: 'Phone check-in unavailable',
            detail: handoff.error ?? 'Unknown error.',
            actionLabel: 'TRY AGAIN',
          ),
      },
    );
  }

  Widget _qr(XSPalette palette, double s, {required bool isPreparing}) {
    final url = isPreparing ? null : handoff.formUrl;
    final left = handoff.expiresIn;
    final countdown = left <= 0
        ? 'expired'
        : '${left ~/ 60}:${(left % 60).toString().padLeft(2, '0')}';

    return Column(
      children: [
        Text(
          isPreparing ? 'CREATING SECURE SESSION' : 'SCAN TO CHECK IN',
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.1,
            color: XSColors.teal,
          ),
        ),
        SizedBox(height: XSSpacing.md * s),
        Container(
          width: 155 * s,
          height: 155 * s,
          padding: EdgeInsets.all(XSSpacing.sm * s),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(XSRadius.md),
            border: Border.all(color: palette.divider),
          ),
          alignment: Alignment.center,
          child: isPreparing || url == null
              ? const CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: XSColors.teal,
                )
              : QrImageView(
                  data: url,
                  version: QrVersions.auto,
                  size: 140 * s,
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
        SizedBox(height: XSSpacing.sm * s),
        Text(
          isPreparing
              ? 'Connecting to secure clinical relay. Your QR code will appear here.'
              : 'Point your phone camera here. Fill in your name and symptoms, and this screen will continue on its own.',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13,
            height: 1.4,
            color: palette.textSecondary,
          ),
        ),
        if (!isPreparing) ...[
          SizedBox(height: XSSpacing.xs * s),
          Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Icon(Icons.timer_outlined,
                  size: 15 * s, color: palette.textSecondary),
              SizedBox(width: 5 * s),
              Text(
                'Expires in $countdown',
                style: TextStyle(fontSize: 13, color: palette.textSecondary),
              ),
              if (handoff.shortCode != null)
                Text(
                  '  ·  code ${handoff.shortCode}',
                  style: TextStyle(fontSize: 13, color: palette.textSecondary),
                ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _received(XSPalette palette, double s) => SizedBox(
        height: 240 * s,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.check_circle_outline,
                  size: 54 * s, color: XSColors.accentGreen),
              SizedBox(height: XSSpacing.md * s),
              Text(
                receivedName == null
                    ? 'Details received'
                    : 'Thank you, $receivedName',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: palette.textPrimary,
                ),
              ),
              SizedBox(height: 6 * s),
              Text(
                'Starting your screening…',
                style: TextStyle(fontSize: 14, color: palette.textSecondary),
              ),
            ],
          ),
        ),
      );

  Widget _problem(
    XSPalette palette,
    double s, {
    required IconData icon,
    required Color color,
    required String title,
    required String detail,
    required String actionLabel,
  }) {
    return Column(
      children: [
        Icon(icon, size: 42 * s, color: color),
        SizedBox(height: XSSpacing.sm * s),
        Text(
          title,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w800,
            color: palette.textPrimary,
          ),
        ),
        SizedBox(height: 6 * s),
        Text(
          detail,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13,
            height: 1.45,
            color: palette.textSecondary,
          ),
        ),
        SizedBox(height: XSSpacing.md * s),
        XSButton(
          label: actionLabel,
          icon: Icons.refresh,
          height: 52,
          width: double.infinity,
          onPressed: onRetry,
        ),
      ],
    );
  }
}
