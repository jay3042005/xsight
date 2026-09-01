import 'package:flutter/material.dart';
import '../../core/api/emr_client.dart';
import '../../core/theme/xs_colors.dart';
import '../../core/theme/xs_scale.dart';
import '../../core/theme/xs_spacing.dart';
import '../components/xs_card.dart';


/// Patient detail view — vitals history, X-ray history, lung sounds, consultations.
class KioskPatientDetailScreen extends StatefulWidget {
  final int patientId;
  final String patientName;
  const KioskPatientDetailScreen({super.key, required this.patientId, required this.patientName});

  @override
  State<KioskPatientDetailScreen> createState() => _KioskPatientDetailScreenState();
}

class _KioskPatientDetailScreenState extends State<KioskPatientDetailScreen> {
  final EMRClient _emr = EMRClient();
  Map<String, dynamic>? _patient;
  List<dynamic> _vitals = [];
  List<dynamic> _xrays = [];
  List<dynamic> _lungSounds = [];
  List<dynamic> _consultations = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final p = await _emr.getPatient(widget.patientId);
      final v = await _emr.getVitals(widget.patientId);
      final x = await _emr.getXrayHistory(widget.patientId);
      final l = await _emr.getLungHistory(widget.patientId);
      final c = await _emr.getConsultations(widget.patientId);
      setState(() {
        _patient = p;
        _vitals = v;
        _xrays = x;
        _lungSounds = l;
        _consultations = c;
        _loading = false;
      });
    } catch (e) {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    return Scaffold(
      backgroundColor: palette.surface,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(XSSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header
                  Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_back),
                        onPressed: () => Navigator.pop(context),
                      ),
                      const SizedBox(width: XSSpacing.xs),
                      Flexible(
                        child: Text(widget.patientName,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: palette.textPrimary)),
                      ),
                      const SizedBox(width: XSSpacing.sm),
                      if (_patient != null) ...[
                        Flexible(
                          child: Text('DOB: ${_patient!['dob'] ?? 'N/A'}',
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 14, color: palette.textSecondary)),
                        ),
                        const SizedBox(width: XSSpacing.md),
                        Flexible(
                          child: Text('Sex: ${_patient!['sex'] ?? 'N/A'}',
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 14, color: palette.textSecondary)),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: XSSpacing.md),
                  // Content
                  Expanded(
                    child: Row(
                      children: [
                        // Left: Vitals + Consultations
                        Expanded(
                          flex: 2,
                          child: Column(
                            children: [
                              Expanded(child: _sectionCard('VITALS HISTORY', _buildVitalsList(), palette)),
                              const SizedBox(height: XSSpacing.sm),
                              Expanded(child: _sectionCard('CONSULTATIONS', _buildConsultationsList(), palette)),
                            ],
                          ),
                        ),
                        const SizedBox(width: XSSpacing.md),
                        // Right: X-Rays + Lung Sounds
                        Expanded(
                          flex: 2,
                          child: Column(
                            children: [
                              Expanded(child: _sectionCard('X-RAY HISTORY', _buildXrayList(), palette)),
                              const SizedBox(height: XSSpacing.sm),
                              Expanded(child: _sectionCard('LUNG SOUNDS', _buildLungList(), palette)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _sectionCard(String title, Widget content, dynamic palette) {
    return XSCard(
      padding: EdgeInsets.all(XSSpacing.md * XSScale.factor),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: palette.textSecondary, letterSpacing: 0.5)),
          const SizedBox(height: XSSpacing.xs),
          Expanded(child: content),
        ],
      ),
    );
  }

  Widget _buildVitalsList() {
    if (_vitals.isEmpty) return Center(child: Text('No vitals recorded', style: TextStyle(fontSize: 14, color: Colors.grey.shade500)));
    return ListView.builder(
      itemCount: _vitals.length,
      itemBuilder: (ctx, i) {
        final v = _vitals[i];
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('${v['recorded_at'] ?? ''}', style: TextStyle(fontSize: 13, color: Colors.grey.shade500)),
                const SizedBox(width: XSSpacing.sm),
                _vitalChip('HR', '${v['hr'] ?? 0}', Icons.favorite, XSColors.accentRed),
                _vitalChip('SpO₂', '${v['spo2'] ?? 0}', Icons.air, XSColors.accentGreen),
                _vitalChip('T', '${v['temp'] ?? 0}°', Icons.thermostat, XSColors.moduleXray),
                _vitalChip('RR', '${v['rr'] ?? 0}', Icons.speed, XSColors.moduleXray),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _vitalChip(String label, String value, IconData icon, Color color) {
    return Container(
      margin: const EdgeInsets.only(right: 6),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10, color: color),
          const SizedBox(width: 2),
          Text('$label: $value', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: color)),
        ],
      ),
    );
  }

  Widget _buildXrayList() {
    if (_xrays.isEmpty) return Center(child: Text('No X-rays', style: TextStyle(fontSize: 14, color: Colors.grey.shade500)));
    return ListView.builder(
      itemCount: _xrays.length,
      itemBuilder: (ctx, i) {
        final x = _xrays[i];
        return ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.medical_services, size: 16, color: x['prediction'] == 'normal' ? XSColors.accentGreen : XSColors.accentOrange),
          title: Text('${x['prediction']}', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          subtitle: Text('${x['created_at'] ?? ''}', style: TextStyle(fontSize: 13, color: Colors.grey.shade500)),
          trailing: Text('${((x['confidence'] ?? 0) * 100).toStringAsFixed(0)}%', style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
        );
      },
    );
  }

  Widget _buildLungList() {
    if (_lungSounds.isEmpty) return Center(child: Text('No recordings', style: TextStyle(fontSize: 14, color: Colors.grey.shade500)));
    return ListView.builder(
      itemCount: _lungSounds.length,
      itemBuilder: (ctx, i) {
        final l = _lungSounds[i];
        return ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.graphic_eq, size: 16, color: l['label'] == 'normal' ? XSColors.accentGreen : XSColors.accentOrange),
          title: Text('${l['label']}', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          subtitle: Text('${l['duration_s'] ?? 0}s • ${l['created_at'] ?? ''}', style: TextStyle(fontSize: 13, color: Colors.grey.shade500)),
          trailing: Text('${((l['confidence'] ?? 0) * 100).toStringAsFixed(0)}%', style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
        );
      },
    );
  }

  Widget _buildConsultationsList() {
    if (_consultations.isEmpty) return Center(child: Text('No consultations', style: TextStyle(fontSize: 14, color: Colors.grey.shade500)));
    return ListView.builder(
      itemCount: _consultations.length,
      itemBuilder: (ctx, i) {
        final c = _consultations[i];
        final riskColor = c['risk_level'] == 'critical' ? XSColors.accentRed : c['risk_level'] == 'high' ? XSColors.accentOrange : XSColors.accentGreen;
        return ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.description, size: 16, color: riskColor),
          title: Text('${c['diagnosis'] ?? 'Assessment'}', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          subtitle: Text('${c['physician'] ?? 'AI'} • ${c['created_at'] ?? ''}', style: TextStyle(fontSize: 13, color: Colors.grey.shade500)),
          trailing: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(color: riskColor.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(4)),
            child: Text('${c['risk_level'] ?? 'low'}', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: riskColor)),
          ),
        );
      },
    );
  }
}
