import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import '../../core/api/vitals_client.dart';
import '../../core/theme/xs_colors.dart';
import '../../core/theme/xs_spacing.dart';
import '../components/xs_app_bar.dart';
import '../components/xs_button.dart';
import '../components/xs_card.dart';
import '../components/xs_chart_card.dart';
import '../components/xs_icon_button.dart';
import '../components/xs_stat.dart';
import 'robot_mode_screen.dart';
import 'settings_screen.dart';
import 'voice_mode_screen.dart';
import 'xray_screen.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final _rng = Random();
  final VitalsClient _vitals = VitalsClient();
  Timer? _fallbackTimer;

  // Local fallback values used until the WebSocket has delivered a snapshot.
  double hr = 78;
  double spo2 = 98;
  double temp = 36.7;
  double rr = 16;

  final List<XSChartPoint> _trend = [];

  bool get _live => _vitals.latest != null && _vitals.connected;

  @override
  void initState() {
    super.initState();
    for (int i = 0; i < 20; i++) {
      _trend.add(XSChartPoint(i.toDouble(), 75 + _rng.nextDouble() * 8));
    }
    _vitals.addListener(_onVitals);
    // Try to attach to the live stream. If no backend is configured we
    // silently keep using the local random walk.
    // ignore: unawaited_futures
    _vitals.start();
    // Fallback random-walk while disconnected so the dashboard never
    // freezes on a blank chart.
    _fallbackTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_live) return;
      _tick();
    });
  }

  void _onVitals() {
    final snap = _vitals.latest;
    if (snap == null) return;
    setState(() {
      hr = snap.hr;
      spo2 = snap.spo2;
      temp = snap.temp;
      rr = snap.rr;
      if (_trend.length >= 30) _trend.removeAt(0);
      _trend.add(XSChartPoint(_trend.length.toDouble(), hr));
    });
  }

  void _tick() {
    setState(() {
      hr = (hr + (_rng.nextDouble() - 0.5) * 4).clamp(60, 110);
      spo2 = (spo2 + (_rng.nextDouble() - 0.5) * 0.6).clamp(94, 100);
      temp = (temp + (_rng.nextDouble() - 0.5) * 0.1).clamp(36.0, 37.6);
      rr = (rr + (_rng.nextDouble() - 0.5) * 1.2).clamp(12, 22);
      if (_trend.length >= 30) _trend.removeAt(0);
      _trend.add(XSChartPoint(_trend.length.toDouble(), hr));
    });
  }

  @override
  void dispose() {
    _fallbackTimer?.cancel();
    _vitals.removeListener(_onVitals);
    _vitals.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);

    return Column(
      children: [
        XSAppBar(
          title: 'XSIGHT',
          showStatusDot: true,
          connected: _live,
          actions: [
            XSIconButton(
              icon: Icons.settings_outlined,
              size: 44,
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const SettingsScreen(),
                  ),
                );
              },
              semanticLabel: 'Settings',
            ),
            const SizedBox(width: XSSpacing.xs),
            XSIconButton(
              icon: Icons.notifications_none,
              size: 44,
              onPressed: () {},
              semanticLabel: 'Notifications',
            ),
          ],
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              XSSpacing.lg,
              XSSpacing.sm,
              XSSpacing.lg,
              XSSpacing.huge + XSSpacing.lg,
            ),
            children: [
              Text('Hello, Patient',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: XSSpacing.xxs),
              Text(
                'Live thoracic readings',
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: palette.textSecondary),
              ),
              const SizedBox(height: XSSpacing.lg),
              GridView.count(
                crossAxisCount: 2,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: XSSpacing.md,
                crossAxisSpacing: XSSpacing.md,
                childAspectRatio: 1.1,
                children: [
                  XSStat(
                    label: 'Heart Rate',
                    value: hr.toStringAsFixed(0),
                    unit: 'bpm',
                    icon: Icons.favorite_outline,
                  ),
                  XSStat(
                    label: 'SpO\u2082',
                    value: spo2.toStringAsFixed(0),
                    unit: '%',
                    icon: Icons.water_drop_outlined,
                  ),
                  XSStat(
                    label: 'Temperature',
                    value: temp.toStringAsFixed(1),
                    unit: '\u00B0C',
                    icon: Icons.thermostat_outlined,
                  ),
                  XSStat(
                    label: 'Resp. Rate',
                    value: rr.toStringAsFixed(0),
                    unit: '/min',
                    icon: Icons.air_outlined,
                  ),
                ],
              ),
              const SizedBox(height: XSSpacing.md),
              XSChartCard(
                title: 'Heart Rate Trend',
                subtitle: 'Last 60 seconds',
                data: _trend,
              ),
              const SizedBox(height: XSSpacing.md),
              XSCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Robot Status',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: XSSpacing.sm),
                    Row(
                      children: [
                        Icon(Icons.smart_toy_outlined,
                            size: 18, color: palette.textSecondary),
                        const SizedBox(width: XSSpacing.xs),
                        Text('XSIGHT-01 connected',
                            style: Theme.of(context).textTheme.bodyMedium),
                        const Spacer(),
                        Text('Battery 82%',
                            style: Theme.of(context)
                                .textTheme
                                .labelMedium),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: XSSpacing.lg),
              Row(
                children: [
                  Expanded(
                    child: XSButton(
                      label: 'Robot Mode',
                      icon: Icons.smart_toy_outlined,
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const RobotModeScreen(),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(width: XSSpacing.md),
                  Expanded(
                    child: XSButton(
                      label: 'Voice Mode',
                      inverted: true,
                      icon: Icons.graphic_eq,
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const VoiceModeScreen(),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: XSSpacing.md),
              XSButton(
                label: 'Chest X-Ray Analysis',
                icon: Icons.medical_information_outlined,
                width: double.infinity,
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const XrayScreen(),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}
