import 'package:flutter/material.dart';

import '../../core/api/emr_client.dart';
import '../../core/theme/xs_colors.dart';
import '../../core/theme/xs_radius.dart';
import '../../core/theme/xs_scale.dart';
import '../../core/theme/xs_spacing.dart';
import '../../core/theme/xs_typography.dart';
import '../../state/kiosk_patient_state.dart';
import '../components/xs_button.dart';
import '../components/xs_card.dart';
import '../components/xs_chip.dart';

/// Full-screen patient selection, shown to staff after login.
///
/// A screen rather than a dialog on purpose: this is a step in the staff flow,
/// not an interruption of it. A modal over a dimmed dashboard reads as "you have
/// a decision blocking you", when in fact picking a patient *is* the task, and
/// registering a new one is a real sub-task that needs room to breathe. It also
/// keeps the kiosk's one-thing-per-screen rhythm and stays reachable from the
/// back button like every other view.
class KioskPatientPickerScreen extends StatefulWidget {
  /// A patient was chosen. The session is already updated when this fires.
  final ValueChanged<Map<String, dynamic>> onSelect;

  /// Staff declined to pick one and want to work without an EMR link.
  final VoidCallback onSkip;

  const KioskPatientPickerScreen({
    super.key,
    required this.onSelect,
    required this.onSkip,
  });

  @override
  State<KioskPatientPickerScreen> createState() =>
      _KioskPatientPickerScreenState();
}

class _KioskPatientPickerScreenState extends State<KioskPatientPickerScreen> {
  final EMRClient _emr = EMRClient();
  final TextEditingController _searchCtrl = TextEditingController();

  List<Map<String, dynamic>> _patients = const [];
  bool _loading = true;

  /// Set when the list came from [_demoPatients] instead of the backend. Shown
  /// in the UI: staff must never mistake demo records for real ones.
  bool _offline = false;

  /// Fallback roster so the picker is still demonstrable with no backend. Kept
  /// obviously fictional.
  static const _demoPatients = <Map<String, dynamic>>[
    {
      'id': 101,
      'name': 'Eleanor Vance',
      'mrn': 'MRN-4091',
      'age': 45,
      'gender': 'Female',
      'condition': 'Stable · routine screening',
    },
    {
      'id': 102,
      'name': 'Marcus Aurelius Vance',
      'mrn': 'MRN-4092',
      'age': 62,
      'gender': 'Male',
      'condition': 'COPD follow-up · dyspnea',
    },
    {
      'id': 103,
      'name': 'Sophia Delgado',
      'mrn': 'MRN-4093',
      'age': 29,
      'gender': 'Female',
      'condition': 'Mild cough · thermal check',
    },
    {
      'id': 104,
      'name': 'David Chen',
      'mrn': 'MRN-4094',
      'age': 54,
      'gender': 'Male',
      'condition': 'Post-pneumonia assessment',
    },
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  /// Guards against overlapping searches. SEARCH is a 56px button next to a
  /// text field on a touch panel, so double-taps are routine; without this, two
  /// requests race and the slower one wins, leaving the list showing results for
  /// a query the staff member has already replaced.
  bool _searching = false;

  Future<void> _load() async {
    if (_searching) return;
    _searching = true;
    setState(() => _loading = true);
    final query = _searchCtrl.text.trim();
    try {
      final raw = query.isEmpty
          ? await _emr.listPatients()
          : await _emr.searchPatients(query);
      if (!mounted) return;
      final list = raw.whereType<Map<String, dynamic>>().toList();
      setState(() {
        // An empty result for a real query is a real answer ("no matches") and
        // must not be papered over with demo records — that would show staff
        // patients who do not exist. Only an outright failure falls back.
        _patients = list;
        _offline = false;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _patients = _filterDemo(query);
        _offline = true;
        _loading = false;
      });
    } finally {
      _searching = false;
    }
  }

  List<Map<String, dynamic>> _filterDemo(String query) {
    if (query.isEmpty) return _demoPatients;
    final q = query.toLowerCase();
    return _demoPatients
        .where((p) =>
            '${p['name']}'.toLowerCase().contains(q) ||
            '${p['mrn']}'.toLowerCase().contains(q) ||
            '${p['id']}'.contains(q))
        .toList();
  }

  void _select(Map<String, dynamic> patient) {
    KioskPatientSession.I.selectPatient(patient);
    widget.onSelect(patient);
  }

  Future<void> _register() async {
    final created = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(builder: (_) => const _RegisterPatientScreen()),
    );
    if (created == null || !mounted) return;
    try {
      final saved = await _emr.createPatient(created);
      if (!mounted) return;
      // Prefer the server's record (it owns the real id), but a failed or empty
      // response must not lose the staff member's typing.
      _select(saved.isNotEmpty ? saved : created);
    } catch (_) {
      if (!mounted) return;
      _select(created);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Saved locally only — patient not written to EMR.'),
          duration: Duration(seconds: 4),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    final s = XSScale.factor;
    // Landscape phones: the fixed chrome (header + search + footer) alone
    // exceeds a ~360 px panel — the footer's two wrapped buttons push the
    // column 48 px past the screen. Trim the decorative parts (hero size,
    // subtitle, paddings, button heights); the search row, patient list and
    // both footer actions all stay.
    final tight = MediaQuery.sizeOf(context).height < 430;
    final gap = (tight ? XSSpacing.xs : XSSpacing.md) * s;

    return Padding(
      padding: tight
          ? const EdgeInsets.fromLTRB(XSSpacing.md, XSSpacing.xs, XSSpacing.md, XSSpacing.xs)
          : EdgeInsets.fromLTRB(XSSpacing.lg, XSSpacing.sm, XSSpacing.lg, XSSpacing.md),
      child: Column(
        children: [
          _header(palette, s, tight: tight),
          SizedBox(height: gap),
          _searchRow(palette, s),
          SizedBox(height: gap),
          Expanded(child: _list(palette, s)),
          SizedBox(height: gap),
          _footer(palette, s, tight: tight),
        ],
      ),
    );
  }

  Widget _header(XSPalette palette, double s, {bool tight = false}) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Who are you screening?',
                style: XSTypography.hero(
                  palette.textPrimary,
                  fontSize: tight ? 22 : 30,
                ).copyWith(letterSpacing: -0.8),
              ),
              if (!tight) ...[
                SizedBox(height: 2 * s),
                Text(
                  'Readings and reports attach to the patient you pick.',
                  style: TextStyle(
                    fontSize: 15,
                    color: palette.textSecondary,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (_offline)
          const XSChip(
            label: 'DEMO RECORDS',
            icon: Icons.cloud_off,
            color: XSColors.accentOrange,
            filled: true,
          ),
      ],
    );
  }

  Widget _searchRow(XSPalette palette, double s) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _searchCtrl,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _load(),
            style: const TextStyle(fontSize: 16),
            decoration: InputDecoration(
              hintText: 'Search by name or MRN',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _searchCtrl.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear search',
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        _searchCtrl.clear();
                        _load();
                      },
                    ),
              filled: true,
              fillColor: palette.surface,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(XSRadius.md),
                borderSide: BorderSide(color: palette.divider),
              ),
            ),
          ),
        ),
        SizedBox(width: XSSpacing.sm * s),
        XSButton(
          label: 'SEARCH',
          icon: Icons.search,
          height: 56,
          onPressed: _load,
        ),
      ],
    );
  }

  Widget _list(XSPalette palette, double s) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_patients.isEmpty) {
      return _emptyState(palette, s);
    }

    return ListView.separated(
      itemCount: _patients.length,
      separatorBuilder: (_, _) => SizedBox(height: XSSpacing.sm * s),
      itemBuilder: (context, i) => _PatientCard(
        patient: _patients[i],
        onTap: () => _select(_patients[i]),
      ),
    );
  }

  Widget _emptyState(XSPalette palette, double s) {
    final searching = _searchCtrl.text.trim().isNotEmpty;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            searching ? Icons.person_search_outlined : Icons.people_outline,
            size: 56 * s,
            color: palette.textSecondary.withValues(alpha: 0.5),
          ),
          SizedBox(height: XSSpacing.sm * s),
          Text(
            searching
                ? 'No patient matches “${_searchCtrl.text.trim()}”.'
                : 'No patients on record yet.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: palette.textPrimary,
            ),
          ),
          SizedBox(height: 4 * s),
          Text(
            'Register a new patient, or continue without an EMR link.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: palette.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _footer(XSPalette palette, double s, {bool tight = false}) {
    // Wrap, not Row: both labels are full sentences and the pair does not fit
    // side by side on an 800px-wide portrait panel. Stacking beats truncating —
    // "CONTINUE WITHOUT PATIENT" is exactly the button staff must read in full.
    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      spacing: XSSpacing.sm * s,
      runSpacing: XSSpacing.sm * s,
      children: [
        XSButton(
          label: 'CONTINUE WITHOUT PATIENT',
          icon: Icons.science_outlined,
          height: tight ? 48 : 56,
          onPressed: widget.onSkip,
        ),
        XSButton(
          label: 'REGISTER NEW PATIENT',
          icon: Icons.person_add_alt_1_outlined,
          color: palette.accent,
          height: tight ? 48 : 56,
          onPressed: _register,
        ),
      ],
    );
  }
}

/// One selectable patient.
class _PatientCard extends StatelessWidget {
  final Map<String, dynamic> patient;
  final VoidCallback onTap;

  const _PatientCard({required this.patient, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    final s = XSScale.factor;

    final name = '${patient['name'] ?? 'Patient #${patient['id']}'}';
    final mrn = '${patient['mrn'] ?? 'MRN-#${patient['id']}'}';
    final age = patient['age'];
    final gender = patient['gender'];
    final condition = patient['condition'];

    return XSCard(
      onTap: onTap,
      soft: true,
      padding: EdgeInsets.symmetric(
        horizontal: XSSpacing.md * s,
        vertical: XSSpacing.md * s,
      ),
      child: Row(
        children: [
          Container(
            width: 48 * s,
            height: 48 * s,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: palette.accent.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Text(
              name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase(),
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: palette.accent,
              ),
            ),
          ),
          SizedBox(width: XSSpacing.md * s),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  name,
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: palette.textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                SizedBox(height: 2 * s),
                Text(
                  [
                    mrn,
                    if (age != null) '$age yrs',
                    if (gender != null) '$gender',
                  ].join(' · '),
                  style: TextStyle(fontSize: 14, color: palette.textSecondary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (condition != null) ...[
                  SizedBox(height: 2 * s),
                  Text(
                    '$condition',
                    style: TextStyle(
                      fontSize: 13,
                      color: palette.textSecondary,
                      fontStyle: FontStyle.italic,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          SizedBox(width: XSSpacing.sm * s),
          Icon(Icons.arrow_forward_ios, size: 16 * s, color: palette.accent),
        ],
      ),
    );
  }
}

/// New-patient registration. A screen, not a dialog: it is a form with four
/// fields on a touch kiosk, and an on-screen keyboard leaves a dialog nowhere
/// to go.
class _RegisterPatientScreen extends StatefulWidget {
  const _RegisterPatientScreen();

  @override
  State<_RegisterPatientScreen> createState() => _RegisterPatientScreenState();
}

class _RegisterPatientScreenState extends State<_RegisterPatientScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _ageCtrl = TextEditingController();
  late final _mrnCtrl = TextEditingController(
    text: 'MRN-${DateTime.now().millisecondsSinceEpoch % 10000}',
  );
  String _gender = 'Female';

  @override
  void dispose() {
    _nameCtrl.dispose();
    _ageCtrl.dispose();
    _mrnCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    Navigator.pop(context, {
      'name': _nameCtrl.text.trim(),
      'mrn': _mrnCtrl.text.trim(),
      'age': int.tryParse(_ageCtrl.text.trim()),
      'gender': _gender,
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    final s = XSScale.factor;

    return Scaffold(
      backgroundColor: palette.surface,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        toolbarHeight: 64 * s,
        title: Text(
          'Register New Patient',
          style: TextStyle(
            fontSize: 21,
            fontWeight: FontWeight.w800,
            color: palette.textPrimary,
          ),
        ),
      ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: EdgeInsets.all(XSSpacing.lg * s),
            children: [
              TextFormField(
                controller: _nameCtrl,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                style: const TextStyle(fontSize: 16),
                decoration: const InputDecoration(
                  labelText: 'Patient full name *',
                  prefixIcon: Icon(Icons.person_outline),
                ),
                // The only genuinely required field: a record with no name is
                // unusable to whoever reads the report later.
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? 'Enter the patient’s name'
                    : null,
              ),
              SizedBox(height: XSSpacing.md * s),
              TextFormField(
                controller: _mrnCtrl,
                style: const TextStyle(fontSize: 16),
                decoration: const InputDecoration(
                  labelText: 'MRN / medical ID',
                  prefixIcon: Icon(Icons.badge_outlined),
                ),
              ),
              SizedBox(height: XSSpacing.md * s),
              TextFormField(
                controller: _ageCtrl,
                keyboardType: TextInputType.number,
                style: const TextStyle(fontSize: 16),
                decoration: const InputDecoration(
                  labelText: 'Age',
                  prefixIcon: Icon(Icons.cake_outlined),
                ),
                validator: (v) {
                  final text = v?.trim() ?? '';
                  if (text.isEmpty) return null;
                  final age = int.tryParse(text);
                  // Bounds rather than just "is a number": a mistyped age feeds
                  // the risk scoring and would skew a triage result.
                  if (age == null || age < 0 || age > 120) {
                    return 'Enter an age between 0 and 120';
                  }
                  return null;
                },
              ),
              SizedBox(height: XSSpacing.md * s),
              DropdownButtonFormField<String>(
                initialValue: _gender,
                style: TextStyle(fontSize: 16, color: palette.textPrimary),
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
                  if (v != null) setState(() => _gender = v);
                },
              ),
              SizedBox(height: XSSpacing.xl * s),
              Row(
                children: [
                  Expanded(
                    child: XSButton(
                      label: 'CANCEL',
                      height: 56,
                      onPressed: () => Navigator.pop(context),
                    ),
                  ),
                  SizedBox(width: XSSpacing.sm * s),
                  Expanded(
                    flex: 2,
                    child: XSButton(
                      label: 'CREATE & SELECT',
                      icon: Icons.check,
                      color: palette.accent,
                      height: 56,
                      onPressed: _submit,
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
}
