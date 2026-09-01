import 'package:flutter/material.dart';

import '../../core/api/risk_client.dart';
import '../../core/api/vitals_client.dart';
import '../../core/theme/xs_colors.dart';
import '../../core/theme/xs_spacing.dart';
import '../components/xs_app_bar.dart';
import '../components/xs_button.dart';
import '../components/xs_card.dart';
import '../components/xs_risk_meter.dart';

/// Live clinical decision support summary.
///
/// - Streams the latest vitals from the backend's WebSocket.
/// - Calls `/vitals` to fetch a rule-based risk level + reasons.
/// - Shows live values, the risk meter, and supporting reasons.
class SummaryScreen extends StatefulWidget {
  const SummaryScreen({super.key});

  @override
  State<SummaryScreen> createState() => _SummaryScreenState();
}

class _SummaryScreenState extends State<SummaryScreen> {
  final VitalsClient _vitals = VitalsClient();
  final RiskClient _risk = RiskClient();

  XSRiskLevel _level = XSRiskLevel.low;
  List<String> _reasons = const [];
  String? _error;
  bool _refreshing = false;
  DateTime _lastScored = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _vitals.addListener(_onVitals);
    // ignore: unawaited_futures
    _vitals.start();
  }

  void _onVitals() {
    final snap = _vitals.latest;
    if (snap == null) return;
    // Throttle risk scoring to once every 4s to avoid hammering the
    // backend while vitals tick every second.
    if (DateTime.now().difference(_lastScored).inSeconds < 4) {
      setState(() {});
      return;
    }
    _lastScored = DateTime.now();
    _refresh();
  }

  Future<void> _refresh() async {
    final snap = _vitals.latest;
    if (snap == null || _refreshing) return;
    setState(() => _refreshing = true);
    try {
      final r = await _risk.scoreVitals(
        hr: snap.hr,
        spo2: snap.spo2,
        temp: snap.temp,
        rr: snap.rr,
      );
      if (!mounted) return;
      setState(() {
        _level = _toLevel(r.level);
        _reasons = r.reasons;
        _refreshing = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _refreshing = false;
      });
    }
  }

  XSRiskLevel _toLevel(String s) {
    switch (s) {
      case 'high':
        return XSRiskLevel.high;
      case 'moderate':
        return XSRiskLevel.moderate;
      default:
        return XSRiskLevel.low;
    }
  }

  String _levelHeading() {
    switch (_level) {
      case XSRiskLevel.low:
        return 'Low Risk';
      case XSRiskLevel.moderate:
        return 'Moderate Risk';
      case XSRiskLevel.high:
        return 'High Risk';
    }
  }

  @override
  void dispose() {
    _vitals.removeListener(_onVitals);
    _vitals.dispose();
    _risk.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    final snap = _vitals.latest;

    return Column(
      children: [
        const XSAppBar(title: 'Summary'),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              XSSpacing.lg,
              XSSpacing.sm,
              XSSpacing.lg,
              XSSpacing.huge + XSSpacing.lg,
            ),
            children: [
              XSCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          _vitals.connected ? 'LIVE SESSION' : 'OFFLINE',
                          style: Theme.of(context).textTheme.labelMedium,
                        ),
                        const Spacer(),
                        if (_refreshing)
                          SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation(
                                palette.textPrimary,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: XSSpacing.xs),
                    Text(
                      _levelHeading(),
                      style: Theme.of(context).textTheme.displayLarge,
                    ),
                    const SizedBox(height: XSSpacing.lg),
                    XSRiskMeter(level: _level),
                  ],
                ),
              ),
              const SizedBox(height: XSSpacing.md),
              XSCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Reasons',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: XSSpacing.sm),
                    if (_reasons.isEmpty)
                      Text(
                        snap == null
                            ? 'Waiting for first vitals reading...'
                            : 'All vitals are within normal limits.',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    for (final r in _reasons)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(Icons.warning_amber_outlined,
                                size: 16,
                                color: palette.textPrimary),
                            const SizedBox(width: XSSpacing.xs),
                            Expanded(
                              child: Text(r,
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodyMedium),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: XSSpacing.md),
              XSCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Live Vitals',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: XSSpacing.sm),
                    _factor(
                      context,
                      'Heart Rate',
                      snap == null ? '—' : '${snap.hr.toStringAsFixed(0)} bpm',
                    ),
                    _factor(
                      context,
                      'SpO\u2082',
                      snap == null
                          ? '—'
                          : '${snap.spo2.toStringAsFixed(0)} %',
                    ),
                    _factor(
                      context,
                      'Temperature',
                      snap == null
                          ? '—'
                          : '${snap.temp.toStringAsFixed(1)} \u00B0C',
                    ),
                    _factor(
                      context,
                      'Respiratory Rate',
                      snap == null
                          ? '—'
                          : '${snap.rr.toStringAsFixed(0)} /min',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: XSSpacing.md),
              if (_error != null)
                XSCard(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.error_outline,
                          size: 18, color: palette.textPrimary),
                      const SizedBox(width: XSSpacing.sm),
                      Expanded(
                        child: Text(_error!,
                            style: Theme.of(context).textTheme.bodyMedium),
                      ),
                    ],
                  ),
                ),
              if (_error != null) const SizedBox(height: XSSpacing.md),
              XSCard(
                child: Row(
                  children: [
                    Icon(Icons.info_outline,
                        size: 18, color: palette.textSecondary),
                    const SizedBox(width: XSSpacing.sm),
                    Expanded(
                      child: Text(
                        'AI-assisted screening only. Not a medical diagnosis.',
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: XSSpacing.lg),
              Row(
                children: [
                  Expanded(
                    child: XSButton(
                      label: _refreshing ? 'Refreshing...' : 'Refresh',
                      onPressed: _refreshing ? null : _refresh,
                    ),
                  ),
                  const SizedBox(width: XSSpacing.md),
                  Expanded(
                    child: XSButton(
                      label: 'Save Report',
                      inverted: true,
                      onPressed: () {},
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _factor(BuildContext context, String label, String value) {
    final palette = XSPalette.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(label,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: palette.textSecondary)),
          ),
          Text(value,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
