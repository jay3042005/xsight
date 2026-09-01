import 'package:flutter/material.dart';

import '../../core/theme/xs_colors.dart';
import '../../core/theme/xs_radius.dart';
import '../../core/theme/xs_scale.dart';
import '../../core/theme/xs_shadows.dart';
import '../../core/theme/xs_spacing.dart';
import 'xs_button.dart';

/// Consent gate for a session pushed from the local web portal.
///
/// Staff at a laptop can send a patient profile to this kiosk, but the person
/// standing in front of it is the one who has to agree — so nothing is linked to
/// an EMR record until this resolves true.
///
/// Kiosk-shaped rather than a stock [AlertDialog]:
///
///  * Actions are a full-width column, not an [AlertDialog.actions] row. The row
///    silently overflowed once the accept action became a 44px [XSButton],
///    wrapping "Decline" on top of it.
///  * Colours come from [XSPalette], not the `*Dark` tokens. Hardcoding those
///    put a dark card on a light kiosk.
///  * Every dimension is multiplied by [XSScale.factor] like the rest of the
///    kiosk, so the copy stays legible at arm's length on a large panel.
///  * [onAccept] is exposed so the hub's OK button can confirm it. A modal with
///    no hardware path is a dead end on a kiosk driven by physical buttons.
class XSRemoteSessionDialog extends StatefulWidget {
  /// Patient payload as it arrived over `/ws/kiosk/events`.
  final Map<String, dynamic> patient;

  const XSRemoteSessionDialog({super.key, required this.patient});

  /// The mounted prompt, or null when none is up.
  ///
  /// Lets the sensor hub move the highlight and confirm the answer on a dialog it
  /// did not build — the same escape hatch `XSIntakeCheckInDialog` uses. Without
  /// it the hub's UP/DOWN would have nothing to act on and the prompt would be
  /// touch-only, on a kiosk whose whole navigation model is four buttons.
  static XSRemoteSessionDialogState? activeState;

  /// Shows the dialog and resolves true only on an explicit accept.
  ///
  /// Hardware reaches the mounted prompt through [activeState] rather than
  /// through a captured context: the hub needs to *move the highlight*, not just
  /// pop the route, so it needs the state object either way.
  static Future<bool?> show(
    BuildContext context, {
    required Map<String, dynamic> patient,
  }) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => XSRemoteSessionDialog(patient: patient),
    );
  }

  @override
  State<XSRemoteSessionDialog> createState() => XSRemoteSessionDialogState();
}

/// Which action the prompt will take if confirmed now.
enum XSConsentChoice { accept, decline }

class XSRemoteSessionDialogState extends State<XSRemoteSessionDialog> {
  XSConsentChoice _choice = XSConsentChoice.accept;

  /// What the hub would confirm right now. Exposed for tests and for the caller
  /// that mirrors the highlight back to the hub.
  XSConsentChoice get choice => _choice;

  @override
  void initState() {
    super.initState();
    XSRemoteSessionDialog.activeState = this;
  }

  @override
  void dispose() {
    if (XSRemoteSessionDialog.activeState == this) {
      XSRemoteSessionDialog.activeState = null;
    }
    super.dispose();
  }

  /// Move the highlight. There are two options, so either direction toggles.
  void moveSelection() {
    if (!mounted) return;
    setState(() {
      _choice = _choice == XSConsentChoice.accept
          ? XSConsentChoice.decline
          : XSConsentChoice.accept;
    });
  }

  /// Put the highlight on a specific option — used when the hub reports where
  /// *its* highlight went, so the two displays cannot drift apart.
  void select(XSConsentChoice choice) {
    if (!mounted || _choice == choice) return;
    setState(() => _choice = choice);
  }

  /// Answer with whatever is highlighted.
  void confirm() => _resolve(_choice == XSConsentChoice.accept);

  /// Answer decline regardless of the highlight — the hub's BACK button.
  void decline() => _resolve(false);

  void _resolve(bool accepted) {
    if (!mounted) return;
    Navigator.of(context).pop(accepted);
  }

  String get _name {
    final raw = widget.patient['name']?.toString().trim();
    return (raw == null || raw.isEmpty) ? 'Unnamed record' : raw;
  }

  /// Profile line built only from fields that actually arrived.
  ///
  /// The old version read `dob ?? age` into a slot labelled "age" and defaulted
  /// the rest, so a record with neither rendered "Unknown · Adult" — two
  /// invented facts about a patient. Absent details are now simply absent.
  String? get _profile {
    final parts = <String>[];

    final sex = widget.patient['sex']?.toString().trim();
    if (sex != null && sex.isNotEmpty && sex.toLowerCase() != 'unknown') {
      parts.add(sex);
    }

    final age = widget.patient['age']?.toString().trim();
    if (age != null && age.isNotEmpty) {
      parts.add('$age yrs');
    } else {
      final dob = widget.patient['dob']?.toString().trim();
      if (dob != null && dob.isNotEmpty) parts.add('DOB $dob');
    }

    return parts.isEmpty ? null : parts.join('  ·  ');
  }

  String? get _record {
    final id = widget.patient['id'];
    return id == null ? null : 'MRN-${10000 + (int.tryParse('$id') ?? 0)}';
  }

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    final s = XSScale.factor;
    final profile = _profile;
    final record = _record;

    return Dialog(
      backgroundColor: palette.surface,
      surfaceTintColor: Colors.transparent,
      insetPadding: EdgeInsets.all(XSSpacing.lg * s),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(XSRadius.xl),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 460 * s),
        child: SingleChildScrollView(
          padding: EdgeInsets.all(XSSpacing.xl * s),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── Header ────────────────────────────────────────────
              Row(
                children: [
                  Container(
                    width: 44 * s,
                    height: 44 * s,
                    decoration: BoxDecoration(
                      color: palette.surface,
                      borderRadius: BorderRadius.circular(XSRadius.sm),
                      boxShadow: XSShadows.soft(palette),
                    ),
                    child: Icon(
                      Icons.laptop_chromebook_rounded,
                      color: XSColors.teal,
                      size: 22 * s,
                    ),
                  ),
                  SizedBox(width: XSSpacing.sm * s),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'FROM THE WEB PORTAL',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.0,
                            color: palette.textSecondary,
                          ),
                        ),
                        SizedBox(height: 2 * s),
                        Text(
                          'Start this screening?',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.3,
                            color: palette.textPrimary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              SizedBox(height: XSSpacing.lg * s),

              // ── Who the readings will be filed against ────────────
              Container(
                width: double.infinity,
                padding: EdgeInsets.all(XSSpacing.md * s),
                decoration: BoxDecoration(
                  color: palette.highlight,
                  borderRadius: BorderRadius.circular(XSRadius.md),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _name,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: palette.textPrimary,
                      ),
                    ),
                    if (profile != null || record != null) ...[
                      SizedBox(height: 5 * s),
                      Text(
                        [profile, record].whereType<String>().join('  ·  '),
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: palette.textSecondary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              SizedBox(height: XSSpacing.md * s),

              Text(
                'Readings taken from now on are saved to this record. Decline to '
                'stay in guest mode, where nothing is filed.',
                style: TextStyle(
                  fontSize: 13.5,
                  height: 1.45,
                  color: palette.textSecondary,
                ),
              ),
              SizedBox(height: XSSpacing.xl * s),

              // ── Actions ──────────────────────────────────────────
              // A column, so neither can overlap the other, and each wrapped in
              // a highlight the hub's UP/DOWN moves. Touch still works: tapping
              // either row answers directly.
              _action(
                palette,
                s,
                choice: XSConsentChoice.accept,
                label: 'ACCEPT  ·  START',
                icon: Icons.check_rounded,
                height: 58,
                fill: XSColors.teal,
              ),
              SizedBox(height: XSSpacing.sm * s),
              _action(
                palette,
                s,
                choice: XSConsentChoice.decline,
                label: 'DECLINE',
                icon: Icons.close_rounded,
                height: 52,
              ),
              SizedBox(height: XSSpacing.md * s),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.swap_vert_rounded,
                      size: 15 * s, color: palette.textSecondary),
                  SizedBox(width: 6 * s),
                  // Flexible, not fixed: the global textScaler grows this line
                  // with XSScale on a large panel, and a hint is the one thing
                  // here that may shrink rather than overflow.
                  Flexible(
                    child: Text(
                      'UP / DOWN choose  ·  OK confirms',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.3,
                        color: palette.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// One answer, ringed when it is the one OK would confirm.
  ///
  /// The ring rather than a colour swap: DECLINE is a plain button and ACCEPT is
  /// filled teal, so recolouring to show focus would make the two look like each
  /// other. An outline reads as "this is selected" on both.
  Widget _action(
    XSPalette palette,
    double s, {
    required XSConsentChoice choice,
    required String label,
    required IconData icon,
    required double height,
    Color? fill,
  }) {
    final selected = _choice == choice;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 130),
      curve: Curves.easeOut,
      padding: EdgeInsets.all(selected ? 4 * s : 0),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(XSRadius.md + 4),
        border: Border.all(
          color: selected ? XSColors.teal : Colors.transparent,
          width: selected ? 2.5 : 0,
        ),
      ),
      child: XSButton(
        label: label,
        icon: icon,
        height: height * s,
        color: fill,
        onPressed: () {
          // A tap both moves the highlight and answers, so the two input paths
          // cannot leave the hub pointing at something else.
          select(choice);
          _resolve(choice == XSConsentChoice.accept);
        },
      ),
    );
  }
}
