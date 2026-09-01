import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/api/xray_handoff_client.dart';
import '../../core/theme/xs_colors.dart';
import '../../core/theme/xs_radius.dart';
import '../../core/theme/xs_scale.dart';
import '../../core/theme/xs_spacing.dart';
import '../../core/theme/xs_typography.dart';
import 'xs_button.dart';

/// The X-ray station's resting state: a live transfer code.
///
/// Not a dialog and not behind a button — the code is minted the moment the
/// station opens, so the first thing a clinician sees is something a phone can
/// already scan. Getting a film in is the whole purpose of this screen, and
/// making that cost a tap first was the wrong default.
///
/// Purely presentational: the owning screen holds the [XrayHandoffClient], so
/// the code survives this widget rebuilding and the film can be analysed
/// without a route popping out from under it.
class XSHandoffPanel extends StatelessWidget {
  final XrayHandoffClient handoff;

  /// Fallback when a phone is not an option — flat battery, or a film already
  /// on a USB stick.
  final VoidCallback onUseFile;

  /// Raise the upload prompt on the clinician's web portal instead. Null when no
  /// portal is connected, which renders the route as unavailable rather than as a
  /// button that silently does nothing.
  final VoidCallback? onUseWebPortal;

  const XSHandoffPanel({
    super.key,
    required this.handoff,
    required this.onUseFile,
    this.onUseWebPortal,
  });

  String get _countdown {
    final s = handoff.expiresIn;
    if (s <= 0) return 'expired';
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    final s = XSScale.factor;

    return Container(
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(XSRadius.lg),
        border: Border.all(color: palette.divider),
      ),
      padding: EdgeInsets.all(XSSpacing.lg * s),
      child: switch (handoff.state) {
        XrayHandoffState.preparing => _busy(palette, s),
        XrayHandoffState.waiting => _waiting(palette, s),
        XrayHandoffState.received => _received(palette, s),
        XrayHandoffState.expired => _problem(
            palette,
            s,
            icon: Icons.timer_off_outlined,
            color: XSColors.accentOrange,
            title: 'That code expired',
            detail: 'Nothing arrived in time. Codes are short-lived so an '
                'abandoned one cannot be picked up later.',
            actionLabel: 'NEW CODE',
          ),
        XrayHandoffState.failed => _problem(
            palette,
            s,
            icon: Icons.error_outline,
            color: XSColors.accentRed,
            title: 'Transfer unavailable',
            detail: handoff.error ?? 'Unknown error.',
            actionLabel: 'TRY AGAIN',
          ),
      },
    );
  }

  Widget _busy(XSPalette palette, double s) => Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            SizedBox(height: XSSpacing.md * s),
            Text('Creating a transfer code…',
                style: TextStyle(fontSize: 15, color: palette.textSecondary)),
          ],
        ),
      );

  Widget _received(XSPalette palette, double s) {
    final film = handoff.film;
    // Show the actual film, not just a tick: the clinician needs to see *what*
    // arrived before it disappears into the analyser, and a patient who just
    // sent it gets immediate confirmation it was the right photo.
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeOutBack,
      builder: (context, t, child) => Opacity(
        opacity: t.clamp(0.0, 1.0),
        // Slight overshoot on arrival, then it settles — reads as the film
        // landing on the panel rather than blinking into place.
        child: Transform.scale(scale: 0.92 + 0.08 * t, child: child),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.check_circle,
                  size: 22 * s, color: XSColors.accentGreen),
              SizedBox(width: 8 * s),
              Text('Film received',
                  style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: XSColors.accentGreen)),
            ],
          ),
          SizedBox(height: XSSpacing.md * s),
          if (film != null)
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(XSRadius.md),
                  border: Border.all(
                    color: XSColors.accentGreen.withValues(alpha: 0.6),
                    width: 2,
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: Image.memory(film, fit: BoxFit.contain),
              ),
            ),
          SizedBox(height: XSSpacing.sm * s),
          Text('Sending to the analyser…',
              style: TextStyle(fontSize: 14, color: palette.textSecondary)),
        ],
      ),
    );
  }

  Widget _waiting(XSPalette palette, double s) {
    return LayoutBuilder(
      builder: (context, c) {
        // Side by side where there is room; stacked on a portrait panel.
        final wide = c.maxWidth >= 700;
        final qrSize =
            (wide ? c.maxWidth * 0.34 : c.maxWidth * 0.62).clamp(180.0, 340.0);

        final qrBlock = Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: qrSize,
              height: qrSize,
              padding: EdgeInsets.all(XSSpacing.sm * s),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(XSRadius.md),
                border: Border.all(color: palette.divider),
              ),
              alignment: Alignment.center,
              child: handoff.captureUrl == null
                  ? const CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: XSColors.moduleXray,
                    )
                  : QrImageView(
                      data: handoff.captureUrl!,
                      version: QrVersions.auto,
                      size: qrSize - 24 * s,
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
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.timer_outlined,
                    size: 15 * s, color: palette.textSecondary),
                SizedBox(width: 5 * s),
                Text('Expires in $_countdown',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: palette.textSecondary)),
                if (handoff.shortCode != null)
                  Text('  ·  ${handoff.shortCode}',
                      style: TextStyle(
                          fontSize: 13, color: palette.textSecondary)),
              ],
            ),
          ],
        );

        final steps = Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('SCAN TO SEND A CHEST FILM',
                style: XSTypography.eyebrow(palette.textSecondary)
                    .copyWith(fontSize: 13)),
            SizedBox(height: XSSpacing.sm * s),
            _step(palette, s, 1, 'Point a phone camera at the code',
                'No app to install.'),
            _step(palette, s, 2, 'Follow the guide it opens',
                'How to photograph a film without glare.'),
            _step(palette, s, 3, 'Send',
                'It lands here and analysis starts on its own.'),
            SizedBox(height: XSSpacing.sm * s),
            Row(
              children: [
                Icon(Icons.lock_outline,
                    size: 14 * s, color: palette.textSecondary),
                SizedBox(width: 5 * s),
                Expanded(
                  child: Text(
                    'Deleted from the transfer service as soon as this kiosk '
                    'has it.',
                    style: TextStyle(
                        fontSize: 13, color: palette.textSecondary),
                  ),
                ),
              ],
            ),
            SizedBox(height: XSSpacing.md * s),
            Text('OR SEND IT ANOTHER WAY',
                style: XSTypography.eyebrow(palette.textSecondary)
                    .copyWith(fontSize: 12)),
            SizedBox(height: XSSpacing.sm * s),
            // Three routes in, deliberately all visible at once: the QR beside
            // this, the clinician's own browser, and a local file. Which one
            // works depends on what the person in the room happens to have.
            _altRoute(
              palette,
              s,
              icon: Icons.laptop_chromebook_rounded,
              label: 'ASK THE WEB PORTAL',
              detail: onUseWebPortal == null
                  ? 'No portal is connected to this kiosk right now.'
                  : 'Pops the upload box on the clinician\'s browser.',
              onPressed: onUseWebPortal,
            ),
            SizedBox(height: XSSpacing.xs * s),
            _altRoute(
              palette,
              s,
              icon: Icons.folder_open,
              label: 'CHOOSE A FILE',
              detail: 'A film already saved on this kiosk or a USB stick.',
              onPressed: onUseFile,
            ),
          ],
        );

        if (!wide) {
          return SingleChildScrollView(
            child: Column(children: [
              qrBlock,
              SizedBox(height: XSSpacing.lg * s),
              steps,
            ]),
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(child: qrBlock),
            SizedBox(width: XSSpacing.lg * s),
            Expanded(child: steps),
          ],
        );
      },
    );
  }

  /// One non-QR way to get a film in: action on the left, why you'd pick it on
  /// the right. Disabled when the route genuinely is not available.
  Widget _altRoute(
    XSPalette palette,
    double s, {
    required IconData icon,
    required String label,
    required String detail,
    VoidCallback? onPressed,
  }) {
    final enabled = onPressed != null;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        XSButton(
          label: label,
          icon: icon,
          height: 48,
          width: 232,
          onPressed: onPressed,
        ),
        SizedBox(width: XSSpacing.sm * s),
        Expanded(
          child: Text(
            detail,
            style: TextStyle(
              fontSize: 12.5,
              height: 1.35,
              color: palette.textSecondary
                  .withValues(alpha: enabled ? 0.85 : 0.5),
            ),
          ),
        ),
      ],
    );
  }

  Widget _step(
      XSPalette palette, double s, int n, String title, String detail) {
    return Padding(
      padding: EdgeInsets.only(bottom: XSSpacing.sm * s),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 26 * s,
            height: 26 * s,
            decoration: BoxDecoration(
              color: XSColors.moduleXray.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text('$n',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: XSColors.moduleXray)),
            ),
          ),
          SizedBox(width: XSSpacing.sm * s),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: palette.textPrimary)),
                Text(detail,
                    style: TextStyle(
                        fontSize: 13, color: palette.textSecondary)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _problem(
    XSPalette palette,
    double s, {
    required IconData icon,
    required Color color,
    required String title,
    required String detail,
    required String actionLabel,
  }) {
    return Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 44 * s, color: color),
            SizedBox(height: XSSpacing.sm * s),
            Text(title,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: palette.textPrimary)),
            SizedBox(height: 4 * s),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: 460 * s),
              child: Text(detail,
                  textAlign: TextAlign.center,
                  style:
                      TextStyle(fontSize: 14, color: palette.textSecondary)),
            ),
            SizedBox(height: XSSpacing.md * s),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: XSSpacing.sm * s,
              runSpacing: XSSpacing.xs * s,
              children: [
                XSButton(
                  label: actionLabel,
                  icon: Icons.refresh,
                  color: XSColors.moduleXray,
                  height: 52,
                  width: 220,
                  onPressed: handoff.restart,
                ),
                XSButton(
                  label: 'USE A FILE INSTEAD',
                  icon: Icons.folder_open,
                  height: 52,
                  width: 260,
                  onPressed: onUseFile,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
