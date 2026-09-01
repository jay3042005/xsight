import 'package:flutter/material.dart';
import '../../core/api/emr_client.dart';
import '../../core/theme/xs_colors.dart';
import '../../core/theme/xs_spacing.dart';
import '../components/xs_button.dart';
import 'kiosk_patient_detail_screen.dart';

/// Kiosk patient list — search, register, view history.
class KioskPatientListScreen extends StatefulWidget {
  const KioskPatientListScreen({super.key});
  @override
  State<KioskPatientListScreen> createState() => _KioskPatientListScreenState();
}

class _KioskPatientListScreenState extends State<KioskPatientListScreen> {
  final EMRClient _emr = EMRClient();
  final _searchCtrl = TextEditingController();
  List<dynamic> _patients = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final q = _searchCtrl.text.trim();
      final list = q.isEmpty ? await _emr.listPatients() : await _emr.searchPatients(q);
      setState(() { _patients = list; _loading = false; });
    } catch (e) {
      setState(() { _error = '$e'; _loading = false; });
    }
  }

  Future<void> _register() async {
    final nameCtrl = TextEditingController();
    final dobCtrl = TextEditingController();
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Register Patient'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Name *')),
            const SizedBox(height: 8),
            TextField(controller: dobCtrl, decoration: const InputDecoration(labelText: 'Date of Birth')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, {'name': nameCtrl.text, 'dob': dobCtrl.text}),
            child: const Text('Register'),
          ),
        ],
      ),
    );
    if (result != null && result['name']!.isNotEmpty) {
      try {
        await _emr.createPatient(result);
        if (!mounted) return;
        _load();
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Register failed: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    return Padding(
      padding: const EdgeInsets.all(XSSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Title lives in the pushing page's app bar.
              Text('Registered',
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: palette.textSecondary)),
              const Spacer(),
              Flexible(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 300),
                  child: TextField(
                    controller: _searchCtrl,
                    decoration: InputDecoration(
                      hintText: 'Search patients...',
                      prefixIcon: const Icon(Icons.search, size: 18),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    ),
                    onSubmitted: (_) => _load(),
                  ),
                ),
              ),
              const SizedBox(width: XSSpacing.sm),
              XSButton(icon: Icons.search, tooltip: 'Search', onPressed: _load),
              const SizedBox(width: XSSpacing.sm),
              XSButton(icon: Icons.person_add, tooltip: 'Register', inverted: true, onPressed: _register),
            ],
          ),
          const SizedBox(height: XSSpacing.md),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(child: Text(_error!, style: TextStyle(color: XSColors.accentRed)))
                    : _patients.isEmpty
                        ? Center(child: Text('No patients found', style: TextStyle(color: palette.textSecondary)))
                        : ListView.builder(
                            itemCount: _patients.length,
                            itemBuilder: (ctx, i) {
                              final p = _patients[i];
                              return Card(
                                child: ListTile(
                                  leading: CircleAvatar(
                                    child: Text((p['name'] ?? '?')[0].toUpperCase()),
                                  ),
                                  title: Text(p['name'] ?? 'Unknown'),
                                  subtitle: Text(
                                    'DOB: ${p['dob'] ?? 'N/A'}  •  Sex: ${p['sex'] ?? 'N/A'}  •  Registered: ${p['created_at'] ?? ''}',
                                    style: TextStyle(fontSize: 13, color: palette.textSecondary),
                                  ),
                                  trailing: const Icon(Icons.chevron_right),
                                  onTap: () {
                                    Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (_) => KioskPatientDetailScreen(
                                          patientId: p['id'],
                                          patientName: p['name'] ?? 'Unknown',
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              );
                            },
                          ),
          ),
        ],
      ),
    );
  }
}
