import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/api/emr_client.dart';
import '../../core/theme/xs_colors.dart';
import '../../core/theme/xs_spacing.dart';
import '../components/xs_card.dart';
import '../components/xs_button.dart';
import '../components/xs_report_qr_sheet.dart';

/// Kiosk report generation — AI-generated diagnostic reports, PDF export.
class KioskReportScreen extends StatefulWidget {
  const KioskReportScreen({super.key});
  @override
  State<KioskReportScreen> createState() => _KioskReportScreenState();
}

class _KioskReportScreenState extends State<KioskReportScreen> {
  final EMRClient _emr = EMRClient();
  List<dynamic> _consultations = [];
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadReports();
  }

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    return Padding(
      padding: const EdgeInsets.all(XSSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Title lives in the pushing page's app bar, so only actions here.
          Row(
            children: [
              Text('Consultation reports',
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: palette.textSecondary)),
              const Spacer(),
              XSButton(
                  icon: Icons.refresh,
                  tooltip: 'Refresh',
                  onPressed: _loadReports),
            ],
          ),
          const SizedBox(height: XSSpacing.md),
          Expanded(
            child: Row(
              children: [
                // Report list
                Expanded(
                  flex: 2,
                  child: XSCard(
                    child: _loading
                        ? const Center(child: CircularProgressIndicator())
                        : _error != null
                        ? Center(child: Text(_error!, style: const TextStyle(color: XSColors.accentRed)))
                        : _consultations.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.description_outlined, size: 48, color: palette.textSecondary.withValues(alpha: 0.3)),
                                const SizedBox(height: XSSpacing.md),
                                Text('No reports yet',
                                    style: TextStyle(color: palette.textSecondary)),
                                const SizedBox(height: XSSpacing.sm),
                                Text('Reports are generated after CDSS assessments',
                                    style: TextStyle(fontSize: 13, color: palette.textSecondary)),
                              ],
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.all(XSSpacing.sm),
                            itemCount: _consultations.length,
                            itemBuilder: (ctx, i) {
                              final c = _consultations[i];
                              return Card(
                                child: ListTile(
                                  leading: Icon(Icons.description, color: palette.accent),
                                  title: Text(c['diagnosis'] ?? 'Assessment',
                                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                                  subtitle: Text(
                                    '${c['patient_name'] ?? 'Patient'} • ${c['risk_level'] ?? 'low'} risk • ${c['created_at'] ?? ''}',
                                    style: TextStyle(fontSize: 13, color: palette.textSecondary),
                                  ),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      IconButton(
                                        icon: const Icon(Icons.picture_as_pdf, size: 18),
                                        onPressed: () => _exportPDF(c),
                                      ),
                                      IconButton(
                                        icon: const Icon(Icons.copy, size: 18),
                                        onPressed: () => _copyReport(c),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ),
                const SizedBox(width: XSSpacing.md),
                // Report preview
                Expanded(
                  flex: 3,
                  child: XSCard(
                    // No inner Padding: XSCard already insets by a scaled `lg`,
                    // and the two stacked to 45px on a kiosk panel.
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('REPORT PREVIEW',
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: palette.textSecondary)),
                        const SizedBox(height: XSSpacing.md),
                        Expanded(
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(XSSpacing.md),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: palette.divider),
                            ),
                            child: const SingleChildScrollView(
                              child: Text(
                                'XSIGHT AI-ASSISTED THORACIC ASSESSMENT REPORT\n\n'
                                'Select a consultation from the list to preview the report.\n\n'
                                'Report sections:\n'
                                '• Patient Information\n'
                                '• Vital Signs Summary\n'
                                '• Chest X-Ray Findings\n'
                                '• Lung Sound Analysis\n'
                                '• AI Risk Assessment\n'
                                '• Clinical Recommendations\n'
                                '• Physician Review',
                                style: TextStyle(fontSize: 14, height: 1.6, color: Colors.black87),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _loadReports() async {
    setState(() { _loading = true; _error = null; });
    try {
      final allConsults = await _emr.listConsultations(limit: 100);
      if (!mounted) return;
      setState(() {
        _consultations = allConsults;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  /// Hand the report to the patient's own phone via a scannable code.
  ///
  /// Was: copy a LAN URL to the clipboard — which a kiosk with no browser and
  /// no keyboard could do nothing useful with, as the old comment admitted.
  Future<void> _exportPDF(dynamic consultation) async {
    final raw = consultation['id'];
    final id = raw is int ? raw : int.tryParse('$raw');
    if (id == null) return;
    await XSReportQrDialog.show(
      context,
      consultationId: id,
      patientName: consultation['patient_name'] as String?,
    );
  }

  void _copyReport(dynamic c) {
    final text = 'XSIGHT Report\n'
        'Patient: ${c['patient_name'] ?? 'N/A'}\n'
        'Diagnosis: ${c['diagnosis'] ?? 'N/A'}\n'
        'Risk: ${c['risk_level'] ?? 'N/A'}\n'
        'Recommendations: ${c['recommendations'] ?? 'N/A'}\n'
        'Date: ${c['created_at'] ?? 'N/A'}';
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Report copied to clipboard')),
    );
  }
}
