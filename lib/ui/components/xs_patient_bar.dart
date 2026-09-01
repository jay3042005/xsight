import 'package:flutter/material.dart';
import '../../core/theme/xs_colors.dart';
import '../../core/theme/xs_radius.dart';
import '../../core/theme/xs_spacing.dart';
import '../../state/kiosk_patient_state.dart';
import 'xs_staff_dialogs.dart';

/// Top Status Bar displaying:
/// 1. Current Mode (Guest Testing vs Staff Mode)
/// 2. Active Patient Context / Testing Badge
/// 3. Action Buttons (Staff Login, Search Patient, Add Patient, Exit Staff Mode)
class XSPatientBar extends StatefulWidget {
  final bool isCompact;

  const XSPatientBar({super.key, this.isCompact = false});

  @override
  State<XSPatientBar> createState() => _XSPatientBarState();
}

class _XSPatientBarState extends State<XSPatientBar> {
  @override
  void initState() {
    super.initState();
    KioskPatientSession.I.addListener(_onStateChange);
  }

  @override
  void dispose() {
    KioskPatientSession.I.removeListener(_onStateChange);
    super.dispose();
  }

  void _onStateChange() {
    if (mounted) setState(() {});
  }

  Future<void> _handleStaffAuth() async {
    final session = KioskPatientSession.I;
    if (session.isStaffMode) {
      // Open Patient Search / Selection Modal
      await XSPatientSearchModal.show(context);
    } else {
      // Prompt Staff Login PIN
      final ok = await XSStaffLoginDialog.show(context);
      if (ok == true && mounted) {
        // Automatically open patient search after login
        await XSPatientSearchModal.show(context);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    final session = KioskPatientSession.I;
    final isStaff = session.isStaffMode;

    final bgColor = isStaff
        ? XSColors.moduleXray.withValues(alpha: 0.12)
        : Colors.amber.withValues(alpha: 0.12);

    final borderColor = isStaff
        ? XSColors.moduleXray.withValues(alpha: 0.3)
        : Colors.amber.withValues(alpha: 0.4);

    final badgeColor = isStaff ? XSColors.moduleXray : const Color(0xFFD84315);

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: XSSpacing.md,
        vertical: widget.isCompact ? XSSpacing.xs : XSSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(XSRadius.md),
        border: Border.all(color: borderColor, width: 1),
      ),
      child: Row(
        children: [
          // Mode Badge Indicator
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: badgeColor,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isStaff ? Icons.badge_outlined : Icons.science_outlined,
                  size: 13,
                  color: Colors.white,
                ),
                const SizedBox(width: 5),
                Text(
                  isStaff ? 'STAFF MODE' : 'GUEST MODE',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),

          // Active Patient / Testing Details
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Text(
                      'Patient Context:',
                      style: TextStyle(
                        fontSize: 13,
                        color: palette.textSecondary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        session.patientDisplayName,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: palette.textPrimary,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                if (!widget.isCompact)
                  Text(
                    isStaff
                        ? 'Authorized Operator: ${session.staffName}'
                        : 'Temporary anonymous clinical triage testing session.',
                    style: TextStyle(fontSize: 13, color: palette.textSecondary),
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),

          // Action Buttons
          if (isStaff) ...[
            TextButton.icon(
              onPressed: _handleStaffAuth,
              icon: const Icon(Icons.search, size: 16),
              label: const Text('Change Patient', style: TextStyle(fontSize: 14)),
              style: TextButton.styleFrom(
                foregroundColor: XSColors.moduleXray,
              ),
            ),
            const SizedBox(width: 6),
            IconButton(
              tooltip: 'Exit Staff Mode',
              icon: const Icon(Icons.logout, size: 18, color: XSColors.accentRed),
              onPressed: () {
                session.logoutStaff();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Switched back to Guest Testing Mode'),
                    duration: Duration(seconds: 2),
                  ),
                );
              },
            ),
          ],
        ],
      ),
    );
  }
}
