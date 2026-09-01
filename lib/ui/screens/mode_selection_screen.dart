import 'package:flutter/material.dart';
import '../../core/theme/xs_colors.dart';
import '../../core/theme/xs_scale.dart';
import '../../core/theme/xs_spacing.dart';
import '../../core/theme/xs_typography.dart';
import '../../state/kiosk_patient_state.dart';
import '../components/xs_ambient_background.dart';
import '../components/xs_button.dart';
import '../components/xs_card.dart';
import '../components/xs_staff_dialogs.dart';

/// Mode selection & staff login, shown after the disclaimer.
///
/// Two paths, both large enough to hit without aiming:
/// 1. Guest / walk-in triage
/// 2. Staff / clinician authenticated login
class ModeSelectionScreen extends StatefulWidget {
  final VoidCallback onProceed;

  const ModeSelectionScreen({super.key, required this.onProceed});

  @override
  State<ModeSelectionScreen> createState() => _ModeSelectionScreenState();
}

class _ModeSelectionScreenState extends State<ModeSelectionScreen> {
  void _continueAsGuest() {
    KioskPatientSession.I.setGuestMode();
    widget.onProceed();
  }

  /// Sign in through the shared [XSStaffLoginDialog].
  ///
  /// This screen used to carry its own inline PIN form — a second implementation
  /// of the same login with its own copy, its own error strings, and a soft
  /// keyboard the kiosk cannot count on. Deferring to the dialog also keeps both
  /// mode cards the same height, since the pad no longer has to fit inside one.
  Future<void> _openStaffLogin() async {
    final ok = await XSStaffLoginDialog.show(context);
    if (ok != true || !mounted) return;
    widget.onProceed();
    // Straight into patient selection: signing in is only useful once a record
    // is linked, and this is the one entry point that knows the session is new.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) XSPatientSearchModal.show(context);
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    final s = XSScale.factor;
    final mediaWidth = MediaQuery.of(context).size.width;
    final isCompact = mediaWidth < 800;

    return Scaffold(
      backgroundColor: palette.surface,
      body: XSAmbientBackground(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: EdgeInsets.all(XSSpacing.xl * s),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: 980 * s),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _brandHeader(palette, s),
                    SizedBox(height: XSSpacing.xxl * s),
                    Text(
                      'Who is using the kiosk?',
                      textAlign: TextAlign.center,
                      style: XSTypography.hero(
                        palette.textPrimary,
                        fontSize: (isCompact ? 30 : 40),
                      ).copyWith(letterSpacing: -1),
                    ),
                    SizedBox(height: 8 * s),
                    Text(
                      'Guest mode for walk-in self-screening. '
                      'Staff login to manage patient records.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 16,
                        height: 1.4,
                        color: palette.textSecondary,
                      ),
                    ),
                    SizedBox(height: XSSpacing.xl * s),
                    if (isCompact) ...[
                      _buildGuestCard(palette, s),
                      SizedBox(height: XSSpacing.lg * s),
                      _buildStaffCard(palette, s),
                    ] else
                      IntrinsicHeight(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(child: _buildGuestCard(palette, s)),
                            SizedBox(width: XSSpacing.lg * s),
                            Expanded(child: _buildStaffCard(palette, s)),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

 Widget _brandHeader(XSPalette palette, double s) {
  return Row(
  mainAxisAlignment: MainAxisAlignment.center,
  children: [
  Container(
  padding: EdgeInsets.all(12 * s),
  decoration: BoxDecoration(
  color: palette.accent.withValues(alpha: 0.12),
  shape: BoxShape.circle,
  ),
  child: Icon(Icons.health_and_safety_outlined,
  size: 36 * s, color: palette.accent),
  ),
  SizedBox(width: 14 * s),
  // Flexible, not bare: Row hands children unbounded width, so this
  // column could not wrap and pushed the tagline off narrow panels.
  Flexible(
  child: Column(
  crossAxisAlignment: CrossAxisAlignment.start,
  mainAxisSize: MainAxisSize.min,
  children: [
  Text(
  'XSIGHT KIOSK',
  style: TextStyle(
  fontSize: 27,
  fontWeight: FontWeight.w900,
  letterSpacing: 1.2,
  color: palette.textPrimary,
  ),
  ),
  Text(
  'Thoracic Assessment & Triage System',
  style: TextStyle(
  fontSize: 14,
  color: palette.textSecondary,
  ),
  ),
  ],
  ),
  ),
  ],
  );
 }

  Widget _buildGuestCard(XSPalette palette, double s) {
    const accent = XSColors.moduleTemp;
    return XSCard(
      padding: EdgeInsets.all(XSSpacing.xl * s),
      glow: accent,
      borderColor: accent.withValues(alpha: 0.35),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _cardHeading(
                palette,
                s,
                icon: Icons.assignment_ind_outlined,
                color: accent,
                title: 'Guest',
                subtitle: 'Walk-in self-screening',
              ),
              SizedBox(height: XSSpacing.lg * s),
              Text(
                'Run the full screening yourself. Nothing is saved.',
                style: TextStyle(
                  fontSize: 15,
                  height: 1.4,
                  color: palette.textSecondary,
                ),
              ),
              SizedBox(height: XSSpacing.md * s),
              _featureItem(palette, s, accent, 'Pulse, SpO\u2082 and temperature'),
              _featureItem(palette, s, accent, 'Digital stethoscope recording'),
              _featureItem(palette, s, accent, 'Step-by-step AI guidance'),
              _featureItem(palette, s, accent, 'Instant summary of findings'),
            ],
          ),
          SizedBox(height: XSSpacing.xl * s),
          XSButton(
            label: 'START AS GUEST',
            icon: Icons.arrow_forward,
            color: accent,
            height: 64,
            width: double.infinity,
            onPressed: _continueAsGuest,
          ),
        ],
      ),
    );
  }

  Widget _buildStaffCard(XSPalette palette, double s) {
    const accent = XSColors.moduleAssistant;
    return XSCard(
      padding: EdgeInsets.all(XSSpacing.xl * s),
      borderColor: palette.divider,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _cardHeading(
                palette,
                s,
                icon: Icons.admin_panel_settings_outlined,
                color: accent,
                title: 'Staff',
                subtitle: 'Clinician authenticated access',
              ),
              SizedBox(height: XSSpacing.lg * s),
              Text(
                'Sign in to attach results to a patient record.',
                style: TextStyle(
                  fontSize: 15,
                  height: 1.4,
                  color: palette.textSecondary,
                ),
              ),
              SizedBox(height: XSSpacing.md * s),
              _featureItem(
                  palette, s, accent, 'Search & register patient profiles'),
              _featureItem(palette, s, accent, 'Link scans to patient records'),
              _featureItem(
                  palette, s, accent, 'Export PDF consultation reports'),
            ],
          ),
          SizedBox(height: XSSpacing.xl * s),
          XSButton(
            label: 'STAFF PIN LOGIN',
            icon: Icons.login,
            color: accent,
            height: 64,
            width: double.infinity,
            onPressed: _openStaffLogin,
          ),
        ],
      ),
    );
  }

  Widget _cardHeading(
    XSPalette palette,
    double s, {
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
  }) {
    return Row(
      children: [
        Container(
          padding: EdgeInsets.all(12 * s),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(14 * s),
          ),
          child: Icon(icon, size: 28 * s, color: color),
        ),
        SizedBox(width: 12 * s),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  color: palette.textPrimary,
                ),
              ),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 13,
                  color: palette.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _featureItem(
      XSPalette palette, double s, Color color, String text) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 4 * s),
      child: Row(
        children: [
          Icon(Icons.check_circle_outline, size: 17 * s, color: color),
          SizedBox(width: 8 * s),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 14,
                color: palette.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
