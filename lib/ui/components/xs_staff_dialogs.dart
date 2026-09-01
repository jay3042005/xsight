import 'package:flutter/material.dart';
import '../../core/api/emr_client.dart';
import '../../core/theme/xs_colors.dart';
import '../../core/theme/xs_radius.dart';
import '../../core/theme/xs_scale.dart';
import '../../core/theme/xs_spacing.dart';
import '../../state/kiosk_patient_state.dart';
import 'xs_pin_pad.dart';

/// Walk-in check-in for the triage-intake station.
///
/// Asks for a name so the summary and PDF report say who the readings belong to
/// instead of "Walk-In Guest". Skippable on purpose: the station must stay usable
/// by someone who will not or cannot type, and the generated intake id already
/// identifies the session.
///
/// Resolves to the trimmed name, or null when skipped.
class XSIntakeCheckInDialog extends StatefulWidget {
  const XSIntakeCheckInDialog({super.key});

  /// The mounted dialog, or null when none is up.
  ///
  /// Lets the kiosk shell close this dialog *with* whatever has been typed when
  /// the hardware module opens its own menu mid-check-in, instead of popping the
  /// route blind and throwing the name away. Same pattern as
  /// `VoiceModeScreen.activeState`.
  static XSIntakeCheckInDialogState? activeState;

  /// [onDialogContext] hands the route's own context back to the caller so
  /// hardware can dismiss exactly this dialog — see `_dismissCheckIn` in the
  /// kiosk shell.
  static Future<String?> show(
    BuildContext context, {
    ValueChanged<BuildContext>? onDialogContext,
  }) {
    return showDialog<String>(
      context: context,
      builder: (ctx) {
        onDialogContext?.call(ctx);
        return const XSIntakeCheckInDialog();
      },
    );
  }

  @override
  State<XSIntakeCheckInDialog> createState() => XSIntakeCheckInDialogState();
}

class XSIntakeCheckInDialogState extends State<XSIntakeCheckInDialog> {
  final _nameCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    XSIntakeCheckInDialog.activeState = this;
  }

  @override
  void dispose() {
    if (XSIntakeCheckInDialog.activeState == this) {
      XSIntakeCheckInDialog.activeState = null;
    }
    _nameCtrl.dispose();
    super.dispose();
  }

  /// Close as though START had been pressed. Called by the shell when hardware
  /// advances past check-in on its own.
  void submitAndClose() {
    if (mounted) _submit();
  }

  /// Pops with the name, or with null when the field is blank — so pressing
  /// START on an empty field behaves as a skip rather than storing "".
  void _submit() {
    final name = _nameCtrl.text.trim();
    Navigator.pop(context, name.isEmpty ? null : name);
  }

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    return AlertDialog(
      backgroundColor: palette.surface,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(XSRadius.lg)),
      title: Row(
        children: [
          Icon(Icons.assignment_ind_outlined, color: palette.accent, size: 24),
          const SizedBox(width: 10),
          Text(
            'Triage Intake Check-In',
            style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: palette.textPrimary),
          ),
        ],
      ),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Who is being assessed? The name appears on this session\'s summary '
              'and report.',
              style: TextStyle(fontSize: 14, color: palette.textSecondary),
            ),
            const SizedBox(height: XSSpacing.md),
            TextField(
              controller: _nameCtrl,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.done,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              decoration: InputDecoration(
                labelText: 'Patient name',
                prefixIcon: const Icon(Icons.person_outline),
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: palette.highlight,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.lock_outline,
                      size: 14, color: palette.textSecondary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Held for this session only. Nothing is written to patient '
                      'records until staff link a record.',
                      style: TextStyle(
                          fontSize: 13, color: palette.textSecondary),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, null),
          child: const Text('Skip'),
        ),
        ElevatedButton(
          onPressed: _submit,
          style: ElevatedButton.styleFrom(
            backgroundColor: palette.accent,
            foregroundColor: Colors.white,
          ),
          child: const Text('Start Intake'),
        ),
      ],
    );
  }
}

/// Staff PIN sign-in.
///
/// The one staff-login surface in the app. It is reached from the mode-selection
/// screen at startup, from the guest dashboard's STAFF LOGIN, and from the
/// patient chip in the staff header — those used to be two separate
/// implementations whose copy had already drifted apart ("Try 1234 or 8888"
/// against "Demo PIN: 1234 or 8888"), so the PIN rules now live here only.
///
/// Resolves true once [KioskPatientSession.authenticateStaff] accepts the PIN,
/// and false on cancel.
class XSStaffLoginDialog extends StatefulWidget {
  const XSStaffLoginDialog({super.key});

  static Future<bool?> show(BuildContext context) {
    return showDialog<bool>(
      context: context,
      builder: (_) => const XSStaffLoginDialog(),
    );
  }

  @override
  State<XSStaffLoginDialog> createState() => _XSStaffLoginDialogState();
}

class _XSStaffLoginDialogState extends State<XSStaffLoginDialog> {
  final _idCtrl = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _idCtrl.dispose();
    super.dispose();
  }

  void _submit(String pin) {
    // Taken verbatim. Prefixing "Dr. " produced "Dr. DR-4091" from the staff-ID
    // placeholder this field used to carry, and the name reaches the hub's OLED
    // and the consultation record.
    final who = _idCtrl.text.trim();
    final ok = KioskPatientSession.I.authenticateStaff(
      pin,
      name: who.isEmpty ? null : who,
    );
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context, true);
    } else {
      setState(() => _error = 'PIN not recognised. Try again.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    final s = XSScale.factor;

    return AlertDialog(
      backgroundColor: palette.surface,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(XSRadius.lg)),
      titlePadding: EdgeInsets.fromLTRB(
          XSSpacing.xl * s, XSSpacing.xl * s, XSSpacing.xl * s, 0),
      contentPadding: EdgeInsets.fromLTRB(
          XSSpacing.xl * s, XSSpacing.md * s, XSSpacing.xl * s, 0),
      title: Row(
        children: [
          Container(
            padding: EdgeInsets.all(9 * s),
            decoration: BoxDecoration(
              color: palette.accent.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(XSRadius.sm),
            ),
            child: Icon(Icons.admin_panel_settings_outlined,
                color: palette.accent, size: 22 * s),
          ),
          SizedBox(width: XSSpacing.sm * s),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Staff sign-in',
                  style: TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.2,
                      color: palette.textPrimary),
                ),
                Text(
                  'Unlocks patient records \u00B7 demo PIN 1234',
                  style:
                      TextStyle(fontSize: 13, color: palette.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 320 * s,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _idCtrl,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.done,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              decoration: InputDecoration(
                labelText: 'Your name or staff ID (optional)',
                isDense: true,
                prefixIcon: const Icon(Icons.badge_outlined),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(XSRadius.sm)),
              ),
            ),
            SizedBox(height: XSSpacing.lg * s),
            // Loose Flexible, not a scroll view: the pad hands the whole PIN in
            // one gesture sequence, so a key that needs scrolling into reach is a
            // key the user will not find. This bounds the pad's height to what is
            // left in the dialog and lets it scale itself down to fit, while a
            // loose fit means a tall panel does not stretch it into blank space.
            //
            // The pad takes focus rather than the name field, so a desktop
            // keyboard can type the PIN straight away — the fallback the rest of
            // the kiosk offers for development. Tapping the field above hands
            // focus over, so the two do not compete.
            Flexible(
              child: XSPinPad(
                onCompleted: _submit,
                errorText: _error,
                accent: palette.accent,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

/// Patient Search & Select Modal Dialog (with Add Patient integration)
class XSPatientSearchModal extends StatefulWidget {
  const XSPatientSearchModal({super.key});

  static Future<Map<String, dynamic>?> show(BuildContext context) {
    return showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => const XSPatientSearchModal(),
    );
  }

  @override
  State<XSPatientSearchModal> createState() => _XSPatientSearchModalState();
}

class _XSPatientSearchModalState extends State<XSPatientSearchModal> {
  /// Decide what happens to readings the intake station is still holding, and
  /// push them into [patient]'s record when the clinician says to.
  ///
  /// Returns whether [KioskPatientSession.selectPatient] should keep them.
  /// Discarding is the default and the answer whenever anything is unclear: the
  /// kiosk cannot tell whether the record being linked belongs to the person who
  /// just used the station, and attaching the wrong session writes a stranger's
  /// heart rate, fever, and x-ray finding into a real chart. That is a bug this
  /// codebase has already had once — see the clearing note in [selectPatient].
  Future<bool> _resolveHeldReadings(Map<String, dynamic> patient) async {
    final session = KioskPatientSession.I;
    if (!session.hasHeldIntakeReadings) return false;

    final rawId = patient['id'];
    final pid = rawId is int ? rawId : int.tryParse('$rawId');
    if (pid == null) return false;

    final who = '${patient['name'] ?? 'this patient'}';
    final attach = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final palette = XSPalette.of(ctx);
        return AlertDialog(
          backgroundColor: palette.surface,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(XSRadius.lg)),
          title: Text(
            'Attach intake readings?',
            style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: palette.textPrimary),
          ),
          content: SizedBox(
            width: 360,
            child: Text(
              'This station is holding ${session.measuredStationCount} of 4 readings '
              'for ${session.patientDisplayName}.\n\n'
              'Attach them to $who only if this is the same person. '
              'Otherwise discard them.'
              '${session.hasSimulatedReadings ? '\n\nWarning: some values were simulated with no sensor attached. Attaching files them to the record as demo data, not measurements.' : ''}',
              style: TextStyle(
                  fontSize: 14, height: 1.45, color: palette.textSecondary),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Discard'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: palette.accent,
                foregroundColor: Colors.white,
              ),
              child: const Text('Attach to record'),
            ),
          ],
        );
      },
    );

    if (attach != true) return false;
    await _pushHeldReadings(pid, session);
    return true;
  }

  /// Write the held intake readings into [pid]'s record.
  ///
  /// Sends the measured values and the findings *as text*, and deliberately does
  /// not re-upload the film or the audio: `/xray` re-runs the classifier on
  /// upload, so an archived record could disagree with the finding the intake
  /// actually displayed. Filing what was shown keeps the chart and the report
  /// consistent.
  Future<void> _pushHeldReadings(int pid, KioskPatientSession session) async {
    if (session.hasGuestVitals || session.hasGuestTemp) {
      try {
        await _emr.recordVitals(pid, {
          'hr': session.guestHr ?? 0,
          'spo2': session.guestSpo2 ?? 0,
          'temp': session.guestTemp ?? 0,
          // The vitals row has no free-text field, so provenance rides on
          // `source` — the one place a chart reader can see that a value stood in
          // for an absent sensor rather than being measured.
          'source': session.hasSimulatedReadings
              ? 'triage-intake-simulated'
              : 'triage-intake',
        });
      } catch (_) {
        // Non-fatal: the reading stays visible in the session either way, and a
        // failed sync must not block the clinician from linking the record.
      }
    }

    final findings = <String>[
      if (session.hasGuestXray)
        'Chest x-ray: ${session.guestXrayFinding}'
            '${session.guestXrayConfidence != null ? ' (${(session.guestXrayConfidence! * 100).round()}% confidence)' : ''}',
      if (session.hasGuestSteth) 'Lung sounds: ${session.guestStethFinding}',
    ];
    if (findings.isEmpty) return;

    try {
      await _emr.createConsultation(pid, {
        'physician': session.staffName,
        'summary': 'Captured at the triage-intake station as '
            '${session.patientDisplayName}, then attached on staff review.'
            '${session.hasSimulatedReadings ? ' NOTE: one or more physiological values were SIMULATED with no sensor attached and are not measurements.' : ''}',
        'diagnosis': findings.join(' • '),
        // Not 'low': an unreviewed intake carrying a pneumonia finding must not
        // be filed as low risk just because nothing scored it yet.
        'risk_level': 'unassessed',
        'vitals_snapshot': [
          if (session.guestHr != null) 'HR ${session.guestHr!.round()}',
          if (session.guestSpo2 != null) 'SpO2 ${session.guestSpo2!.round()}%',
          if (session.guestTemp != null)
            'Temp ${session.guestTemp!.toStringAsFixed(1)}C',
        ].join(' • '),
      });
    } catch (_) {}
  }

  final EMRClient _emr = EMRClient();
  final _searchCtrl = TextEditingController();
  List<dynamic> _patients = [];
  bool _loading = true;

  // Static fallback patient list if offline/demo
  static final List<Map<String, dynamic>> _demoPatients = [
    {
      'id': 101,
      'name': 'Eleanor Vance',
      'mrn': 'MRN-4091',
      'age': 45,
      'gender': 'Female',
      'condition': 'Stable - Routine Screening',
    },
    {
      'id': 102,
      'name': 'Marcus Aurelius Vance',
      'mrn': 'MRN-4092',
      'age': 62,
      'gender': 'Male',
      'condition': 'Copd Followup / Dyspnea',
    },
    {
      'id': 103,
      'name': 'Sophia Delgado',
      'mrn': 'MRN-4093',
      'age': 29,
      'gender': 'Female',
      'condition': 'Mild Cough / Thermal Check',
    },
    {
      'id': 104,
      'name': 'David Chen',
      'mrn': 'MRN-4094',
      'age': 54,
      'gender': 'Male',
      'condition': 'Post-Pneumonia Assessment',
    },
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
    });
    try {
      final q = _searchCtrl.text.trim();
      final list = q.isEmpty ? await _emr.listPatients() : await _emr.searchPatients(q);
      if (!mounted) return;
      setState(() {
        _patients = list.isNotEmpty ? list : _filterDemo(q);
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _patients = _filterDemo(_searchCtrl.text.trim());
        _loading = false;
      });
    }
  }

  List<Map<String, dynamic>> _filterDemo(String query) {
    if (query.isEmpty) return _demoPatients;
    final q = query.toLowerCase();
    return _demoPatients
        .where((p) =>
            p['name'].toString().toLowerCase().contains(q) ||
            p['mrn'].toString().toLowerCase().contains(q) ||
            p['id'].toString().contains(q))
        .toList();
  }

  Future<void> _showAddPatientDialog() async {
    final nameCtrl = TextEditingController();
    final ageCtrl = TextEditingController();
    final mrnCtrl = TextEditingController(text: 'MRN-${DateTime.now().millisecondsSinceEpoch % 10000}');
    String gender = 'Female';

    final created = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.person_add_alt_1_outlined, size: 22),
              SizedBox(width: 8),
              Text('Register New Patient'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Patient Full Name *',
                  prefixIcon: Icon(Icons.person_outline),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: mrnCtrl,
                      decoration: const InputDecoration(
                        labelText: 'MRN / Medical ID',
                        prefixIcon: Icon(Icons.badge_outlined),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: ageCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Age',
                        prefixIcon: Icon(Icons.cake_outlined),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                value: gender,
                decoration: const InputDecoration(
                  labelText: 'Gender',
                  prefixIcon: Icon(Icons.wc_outlined),
                ),
                items: const [
                  DropdownMenuItem(value: 'Female', child: Text('Female')),
                  DropdownMenuItem(value: 'Male', child: Text('Male')),
                  DropdownMenuItem(value: 'Other', child: Text('Other')),
                ],
                onChanged: (v) {
                  if (v != null) setDialogState(() => gender = v);
                },
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () {
                final name = nameCtrl.text.trim();
                if (name.isEmpty) return;
                final newP = {
                  'id': DateTime.now().millisecondsSinceEpoch % 1000,
                  'name': name,
                  'mrn': mrnCtrl.text.trim(),
                  'age': int.tryParse(ageCtrl.text) ?? 35,
                  'gender': gender,
                  'condition': 'Newly Admitted Patient',
                };
                Navigator.pop(ctx, newP);
              },
              child: const Text('Create & Select Patient'),
            ),
          ],
        ),
      ),
    );

    if (created != null && mounted) {
      try {
        await _emr.createPatient(created);
      } catch (_) {}
      Navigator.pop(context, created);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    return AlertDialog(
      backgroundColor: palette.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(XSRadius.lg)),
      title: Row(
        children: [
          Icon(Icons.people_alt_outlined, color: palette.accent, size: 24),
          const SizedBox(width: 10),
          Text(
            'Select Patient Context',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: palette.textPrimary),
          ),
          const Spacer(),
          ElevatedButton.icon(
            onPressed: _showAddPatientDialog,
            icon: const Icon(Icons.add, size: 16),
            label: const Text('Add Patient', style: TextStyle(fontSize: 14)),
            style: ElevatedButton.styleFrom(
              backgroundColor: palette.accent,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 520,
        height: 400,
        child: Column(
          children: [
            // Search Input Bar
            TextField(
              controller: _searchCtrl,
              onChanged: (_) => _load(),
              decoration: InputDecoration(
                hintText: 'Search by patient name, MRN, or ID...',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchCtrl.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () {
                          _searchCtrl.clear();
                          _load();
                        },
                      )
                    : null,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              ),
            ),
            const SizedBox(height: XSSpacing.sm),

            // Patient List View
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _patients.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.person_search_outlined, size: 48, color: palette.textSecondary),
                              const SizedBox(height: 8),
                              Text('No patients found matching "${_searchCtrl.text}"',
                                  style: TextStyle(color: palette.textSecondary)),
                              const SizedBox(height: 12),
                              ElevatedButton.icon(
                                onPressed: _showAddPatientDialog,
                                icon: const Icon(Icons.person_add, size: 16),
                                label: const Text('Register This Patient Now'),
                              ),
                            ],
                          ),
                        )
                      : ListView.separated(
                          itemCount: _patients.length + 1,
                          separatorBuilder: (_, __) => const SizedBox(height: 8),
                          itemBuilder: (ctx, i) {
                            if (i == 0) {
                              // Option for Guest Session
                              return ListTile(
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                  side: BorderSide(color: palette.divider),
                                ),
                                tileColor: palette.highlight,
                                leading: CircleAvatar(
                                  backgroundColor: Colors.amber.withValues(alpha: 0.2),
                                  child: const Icon(Icons.science_outlined, color: Colors.amber),
                                ),
                                title: const Text('Guest Mode (No EMR Link)',
                                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                                subtitle: const Text('For quick walk-in tests and anonymous screening'),
                                trailing: const Icon(Icons.arrow_forward_ios, size: 14),
                                onTap: () {
                                  // Unlink, don't sign out. This modal opens
                                  // immediately after a staff PIN is accepted,
                                  // and it used to call `setGuestMode()` — one
                                  // tap on a tile labelled "No EMR Link" threw
                                  // away the staff session that had just been
                                  // authenticated, taking Settings out of the
                                  // orbit with it.
                                  KioskPatientSession.I.unlinkPatient();
                                  Navigator.pop(context, null);
                                },
                              );
                            }

                            final p = _patients[i - 1];
                            final isMap = p is Map<String, dynamic>;
                            final name = isMap ? (p['name'] ?? 'Patient #${p['id']}') : 'Patient #$p';
                            final mrn = isMap ? (p['mrn'] ?? 'MRN-#${p['id']}') : 'MRN-#$p';
                            final age = isMap ? (p['age'] ?? 40) : 40;
                            final gender = isMap ? (p['gender'] ?? 'Unspecified') : 'Unspecified';

                            return ListTile(
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                                side: BorderSide(color: palette.divider),
                              ),
                              leading: CircleAvatar(
                                backgroundColor: palette.accent.withValues(alpha: 0.15),
                                child: Text(
                                  name.substring(0, 1).toUpperCase(),
                                  style: TextStyle(color: palette.accent, fontWeight: FontWeight.bold),
                                ),
                              ),
                              title: Text(name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                              subtitle: Text('$mrn • $age yrs • $gender',
                                  style: TextStyle(fontSize: 14, color: palette.textSecondary)),
                              trailing: Icon(Icons.check_circle_outline, color: palette.accent),
                              onTap: () async {
                                final mapData = isMap
                                    ? Map<String, dynamic>.from(p)
                                    : {'id': p, 'name': name, 'mrn': mrn};
                                final attach =
                                    await _resolveHeldReadings(mapData);
                                if (!context.mounted) return;
                                KioskPatientSession.I.selectPatient(
                                  mapData,
                                  attachHeldReadings: attach,
                                );
                                Navigator.pop(context, mapData);
                              },
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }
}
