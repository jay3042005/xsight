import 'package:flutter/material.dart';

import '../../core/api/emr_client.dart';
import '../../core/theme/xs_colors.dart';
import '../../core/theme/xs_radius.dart';
import '../../core/theme/xs_spacing.dart';

/// Compact "for patient" selector used on screens that run an analysis
/// (X-ray, lung sounds, ...) and need a `patientId` to persist the result
/// into the EMR / feed the CDSS dashboard. Patient linkage is optional —
/// selecting "No patient (quick test)" keeps the screen usable as a
/// standalone tool that doesn't write anything to a patient record.
///
/// Reports the whole selected record rather than just its id, so the caller can
/// hand it straight to `KioskPatientSession.selectPatient` and keep one notion
/// of who the session is about.
class XSPatientPicker extends StatefulWidget {
  final int? selectedPatientId;
  final ValueChanged<Map<String, dynamic>?> onChanged;

  const XSPatientPicker({
    super.key,
    required this.selectedPatientId,
    required this.onChanged,
  });

  @override
  State<XSPatientPicker> createState() => _XSPatientPickerState();
}

class _XSPatientPickerState extends State<XSPatientPicker> {
  final EMRClient _emr = EMRClient();
  List<dynamic> _patients = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await _emr.listPatients();
      if (!mounted) return;
      setState(() {
        _patients = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);

    if (_loading) {
      return _shell(
        palette,
        child: SizedBox(
          height: 16,
          width: 16,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation(palette.textSecondary),
          ),
        ),
      );
    }

    if (_error != null) {
      return _shell(
        palette,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 14, color: palette.textSecondary),
            const SizedBox(width: 6),
            Text('Patients unavailable',
                style: TextStyle(fontSize: 14, color: palette.textSecondary)),
          ],
        ),
      );
    }

    // Guard against a stale selection if the list changed underneath us.
    final validIds = _patients.map((p) => p['id'] as int).toSet();
    final value =
        widget.selectedPatientId != null && validIds.contains(widget.selectedPatientId)
            ? widget.selectedPatientId
            : null;

    return _shell(
      palette,
      child: DropdownButtonHideUnderline(
        child: DropdownButton<int?>(
          value: value,
          isDense: true,
          icon: Icon(Icons.expand_more, size: 18, color: palette.textSecondary),
          style: TextStyle(fontSize: 13, color: palette.textPrimary),
          dropdownColor: palette.surface,
          hint: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.person_outline, size: 14, color: palette.textSecondary),
              const SizedBox(width: 6),
              Text('No patient (quick test)',
                  style: TextStyle(fontSize: 13, color: palette.textSecondary)),
            ],
          ),
          items: [
            DropdownMenuItem<int?>(
              value: null,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.person_outline, size: 14, color: palette.textSecondary),
                  const SizedBox(width: 6),
                  const Text('No patient (quick test)'),
                ],
              ),
            ),
            for (final p in _patients)
              DropdownMenuItem<int?>(
                value: p['id'] as int,
                child: Text((p['name'] as String?) ?? 'Patient #${p['id']}'),
              ),
          ],
          onChanged: (id) {
            if (id == null) {
              widget.onChanged(null);
              return;
            }
            for (final p in _patients) {
              if (p is Map && p['id'] == id) {
                widget.onChanged(Map<String, dynamic>.from(p));
                return;
              }
            }
          },
        ),
      ),
    );
  }

  Widget _shell(XSPalette palette, {required Widget child}) {
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: XSSpacing.sm, vertical: XSSpacing.xs),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(XSRadius.sm),
        border: Border.all(color: palette.divider, width: 0.6),
      ),
      child: child,
    );
  }
}
