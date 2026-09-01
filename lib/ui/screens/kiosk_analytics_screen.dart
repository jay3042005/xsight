import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import '../../core/api/emr_client.dart';
import '../../core/theme/xs_colors.dart';
import '../../core/theme/xs_spacing.dart';
import '../components/xs_card.dart';
import '../components/xs_button.dart';

/// Kiosk analytics dashboard — disease stats, model performance, utilization.
class KioskAnalyticsScreen extends StatefulWidget {
  const KioskAnalyticsScreen({super.key});
  @override
  State<KioskAnalyticsScreen> createState() => _KioskAnalyticsScreenState();
}

class _KioskAnalyticsScreenState extends State<KioskAnalyticsScreen> {
  final EMRClient _emr = EMRClient();
  Map<String, dynamic> _data = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      _data = await _emr.getAnalytics();
    } catch (_) {}
    setState(() => _loading = false);
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
              Text('Screening totals',
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: palette.textSecondary)),
              const Spacer(),
              XSButton(icon: Icons.refresh, tooltip: 'Refresh', onPressed: _load),
            ],
          ),
          const SizedBox(height: XSSpacing.md),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : Row(
                    children: [
                      // Summary cards
                      SizedBox(
                        width: 200,
                        child: Column(
                          children: [
                            _summaryCard(palette, Icons.people, 'Patients', '${_data['total_patients'] ?? 0}', XSColors.accentBlue),
                            const SizedBox(height: XSSpacing.sm),
                            _summaryCard(palette, Icons.medical_services, 'X-Rays', '${_data['total_xrays'] ?? 0}', XSColors.accentGreen),
                            const SizedBox(height: XSSpacing.sm),
                            _summaryCard(palette, Icons.medical_services, 'Consults', '${_data['total_consultations'] ?? 0}', palette.accent),
                            const SizedBox(height: XSSpacing.sm),
                            _summaryCard(palette, Icons.monitor_heart, 'Vitals', '${_data['total_vitals'] ?? 0}', XSColors.accentOrange),
                          ],
                        ),
                      ),
                      const SizedBox(width: XSSpacing.lg),
                      // Disease distribution chart
                      Expanded(
                        child: XSCard(
                          // XSCard already insets its child by a scaled `lg`;
                          // the nested Padding stacked another 16 on top, so
                          // these charts sat in ~41px of whitespace.
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('DISEASE DISTRIBUTION',
                                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: palette.textSecondary)),
                              const SizedBox(height: XSSpacing.md),
                              Expanded(
                                child: _buildDiseaseChart(),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: XSSpacing.lg),
                      // Risk distribution
                      Expanded(
                        child: XSCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('RISK DISTRIBUTION',
                                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: palette.textSecondary)),
                              const SizedBox(height: XSSpacing.md),
                              Expanded(
                                child: _buildRiskChart(),
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

  Widget _summaryCard(dynamic palette, IconData icon, String label, String value, Color color) {
    return Expanded(
      child: XSCard(
        child: Padding(
          padding: const EdgeInsets.all(XSSpacing.md),
          child: Row(
            children: [
              Icon(icon, size: 24, color: color),
              const SizedBox(width: XSSpacing.sm),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(value, style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: color)),
                  Text(label, style: TextStyle(fontSize: 13, color: palette.textSecondary)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDiseaseChart() {
    final diseases = (_data['disease_distribution'] as List?) ?? [];
    if (diseases.isEmpty) {
      return const Center(child: Text('No data yet', style: TextStyle(fontSize: 14)));
    }
    final colors = [XSColors.accentGreen, XSColors.accentOrange, XSColors.accentRed, XSColors.accentBlue, Colors.purple, Colors.teal, XSColors.sage];
    return PieChart(
      PieChartData(
        sections: List.generate(diseases.length, (i) {
          final d = diseases[i];
          return PieChartSectionData(
            value: (d['count'] as num?)?.toDouble() ?? 0,
            title: '${d['prediction']}\n${d['count']}',
            color: colors[i % colors.length],
            radius: 80,
            titleStyle: const TextStyle(fontSize: 13, color: Colors.white, fontWeight: FontWeight.w600),
          );
        }),
        sectionsSpace: 2,
        centerSpaceRadius: 30,
      ),
    );
  }

  Widget _buildRiskChart() {
    final risks = (_data['risk_distribution'] as List?) ?? [];
    if (risks.isEmpty) {
      return const Center(child: Text('No data yet', style: TextStyle(fontSize: 14)));
    }
    final riskColors = {'low': XSColors.accentGreen, 'moderate': XSColors.accentOrange, 'high': XSColors.accentRed, 'critical': XSColors.accentRed};
    return BarChart(
      BarChartData(
        alignment: BarChartAlignment.spaceAround,
        maxY: risks.fold<double>(0, (m, r) {
          final c = (r['count'] as num?)?.toDouble() ?? 0;
          return c > m ? c : m;
        }) + 5,
        barGroups: List.generate(risks.length, (i) {
          final r = risks[i];
          final count = (r['count'] as num?)?.toDouble() ?? 0;
          return BarChartGroupData(
            x: i,
            barRods: [
              BarChartRodData(
                toY: count,
                color: riskColors[r['risk_level']] ?? XSColors.sage,
                width: 40,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
              ),
            ],
          );
        }),
        titlesData: FlTitlesData(
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              getTitlesWidget: (v, _) {
                final idx = v.toInt();
                if (idx < risks.length) {
                  return Text(risks[idx]['risk_level'] ?? '',
                      style: const TextStyle(fontSize: 13));
                }
                return const Text('');
              },
            ),
          ),
          leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        borderData: FlBorderData(show: false),
        gridData: FlGridData(show: false),
      ),
    );
  }
}
