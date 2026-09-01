import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import '../../core/sensor/esp32_serial_client.dart';
import '../../core/theme/xs_colors.dart';
import '../../core/theme/xs_scale.dart';
import '../../core/theme/xs_shadows.dart';
import '../../core/theme/xs_spacing.dart';
import '../../core/theme/xs_typography.dart';
import '../components/xs_card.dart';
import '../components/xs_chart_card.dart';
import '../components/xs_chip.dart';
import '../components/xs_finger_guide.dart';
import '../components/xs_sensor_scan_panel.dart';
import '../../state/kiosk_patient_state.dart';

/// Kiosk vitals monitoring — real-time charts, alert thresholds, history.
/// Readings come from the ESP32 module only; with no module linked the station
/// waits (press P to emulate a finger for hardware-free demos).
class KioskVitalsScreen extends StatefulWidget {
  const KioskVitalsScreen({super.key});
  @override
  State<KioskVitalsScreen> createState() => _KioskVitalsScreenState();
}

class _KioskVitalsScreenState extends State<KioskVitalsScreen> {
  final _rng = Random();
  final Esp32SerialClient _esp32 = Esp32SerialClient.shared;

  // Temperature has its own station, and nothing on this module measures a
  // respiratory rate or blood pressure — all three used to be rendered here
  // as gauges, which put numbers (or a "No cuff connected" apology) on a
  // clinical screen that no sensor behind it produced.
  double hr = 0, spo2 = 0;

  /// The timed reading window, in seconds.
  ///
  /// The module's batch algorithm produces one HR/SpO2 pair per 100-sample
  /// window, so 20s covers several of them — long enough to settle, short enough
  /// that a walk-in will hold still for it.
  static const _scanSeconds = 20;

  XSScanPhase _phase = XSScanPhase.guide;
  int _secondsLeft = _scanSeconds;
  Timer? _countdown;

  /// Set once the reading is finalised, which is what swaps this screen from the
  /// guided panel to the results view. One-way for the life of the screen: a
  /// finished reading must not be reopened by a stray frame.
  bool _complete = false;
  bool _simulated = true;
  String _source = 'waiting for XSIGHT Module';
  final List<XSChartPoint> _hrTrend = [];
  final List<XSChartPoint> _spo2Trend = [];

  /// Last reading published to the session, as a rounded key — see [_persist].
  String? _lastPersistKey;
  DateTime? _lastEsp32VitalsTs;
  bool _showedWaiting = false;

  @override
  void initState() {
    super.initState();
    for (int i = 0; i < 30; i++) {
      _hrTrend.add(XSChartPoint(i.toDouble(), 75 + _rng.nextDouble() * 8));
      _spo2Trend.add(XSChartPoint(i.toDouble(), 96 + _rng.nextDouble() * 3));
    }
    // ESP32 only. The WebSocket `/ws/vitals` fallback and the free-running
    // local drift were removed: both put numbers on a clinical screen with no
    // finger on the sensor, and the station now genuinely waits for contact —
    // real contact, or the keyboard emulator (press P) when no module is
    // linked.
    _esp32.addListener(_onEsp32);
    final connectFuture = _esp32.connected
        ? Future<bool>.value(true)
        : _esp32.connect();
    connectFuture.then((ok) {
      if (mounted && ok) _beginHardwareScan();
    });
  }

  void _beginHardwareScan() {
    _esp32.beginVitalsScan();
    _esp32.sendCommand('READ_VITALS');
  }

  void _onEsp32() {
    if (!mounted) return;
    // Phase first. The client notifies on station-state changes as well as on new
    // readings, and the `_lastEsp32VitalsTs` guard below returns early on those —
    // so a PULSE_ACTIVE or PULSE_DONE arriving without a fresh reading would
    // otherwise never be seen here.
    _syncScanPhase();

    final snap = _esp32.latest;
    if (snap == null) {
      if (_esp32.connected && mounted) {
        if (_showedWaiting) return;
        _showedWaiting = true;
        setState(() {
          _simulated = false;
          _source = 'Module: waiting for reading';
        });
      }
      return;
    }
    if (_lastEsp32VitalsTs == snap.ts) return;
    _lastEsp32VitalsTs = snap.ts;
    _showedWaiting = false;
    setState(() {
      // A keyboard-emulated reading is labelled simulated, exactly like the
      // old WebSocket one was: it is a real transport carrying data no sensor
      // measured.
      _simulated = _esp32.simulating;
      _source = _esp32.simulating
          ? 'Emulated module (P key)'
          : 'Module (${_esp32.portName})';
      hr = snap.hr;
      spo2 = snap.spo2;
      _addTrend(snap.hr, snap.spo2);
    });
  }

  /// Derive the scan phase from what the module reports.
  ///
  /// Never from this screen's own optimism: the module owns contact detection and
  /// owns the decision that a reading is finished, so every transition here is a
  /// consequence of a `PULSE_*` frame or of a reading actually arriving.
  void _syncScanPhase() {
    if (_complete) return;
    final state = _esp32.pulseState;

    if (state == 'DONE') {
      _completeScan();
      return;
    }

    // Contact lost, or the module stood down. The window restarts from scratch
    // rather than resuming — a reading spliced across a break in contact is two
    // readings, and averaging them would hide that.
    if (state == 'WAITING' || state == 'CANCELLED') {
      if (_phase != XSScanPhase.guide) {
        _stopCountdown();
        setState(() {
          _phase = XSScanPhase.guide;
          _secondsLeft = _scanSeconds;
        });
      }
      return;
    }

    // Both values, or nothing. A window where only the heart rate resolved is not
    // a vitals reading, and starting the clock on it would let the countdown run
    // out before an SpO2 ever appeared.
    final snap = _esp32.latest;
    final hasBoth = snap != null && snap.hr > 0 && snap.spo2 > 0;
    if (hasBoth) {
      if (_phase != XSScanPhase.scanning && _phase != XSScanPhase.finishing) {
        _startCountdown();
      }
      return;
    }

    if (state == 'ACTIVE' && _phase != XSScanPhase.acquiring) {
      setState(() => _phase = XSScanPhase.acquiring);
    }
  }

  void _startCountdown() {
    _countdown?.cancel();
    setState(() {
      _phase = XSScanPhase.scanning;
      _secondsLeft = _scanSeconds;
    });
    _countdown = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      if (_secondsLeft <= 1) {
        t.cancel();
        _onWindowElapsed();
        return;
      }
      setState(() => _secondsLeft--);
    });
  }

  void _stopCountdown() {
    _countdown?.cancel();
    _countdown = null;
  }

  /// The countdown ran out. Whether that ends the reading depends on who is
  /// measuring.
  ///
  /// With a module attached the firmware owns the decision and sends
  /// `PULSE_DONE:1` on its own clock, so this only moves to `finishing` and waits
  /// — claiming a result the module has not sent would be inventing one, and the
  /// two clocks are independent. With nothing attached the values on screen came
  /// from the local simulation, and nothing will ever send DONE, so it finalises
  /// here instead.
  void _onWindowElapsed() {
    if (!mounted) return;
    setState(() => _secondsLeft = 0);
    if (_esp32.connected) {
      setState(() => _phase = XSScanPhase.finishing);
    } else {
      _completeScan();
    }
  }

  void _completeScan() {
    if (_complete) return;
    _stopCountdown();
    _persist(hr, spo2, simulated: _simulated);
    setState(() {
      _complete = true;
      _secondsLeft = 0;
    });
  }

  /// Stand the module down and go back to coaching.
  ///
  /// Not a way to finish early — there is no "good enough" reading to keep here,
  /// and offering one would put a partial measurement into the record. Hardware
  /// BACK and the shell's edge swipe are how you leave the station.
  void _cancelScan() {
    _stopCountdown();
    _esp32.sendCommand('STOP_VITALS');
    _esp32.beginVitalsScan();
    setState(() {
      hr = 0;
      spo2 = 0;
      _phase = XSScanPhase.guide;
      _secondsLeft = _scanSeconds;
    });
  }

  /// Push the current reading into the session so it outlives this screen.
  ///
  /// Without this, pressing BACK lost the reading entirely: the session is what
  /// the intake dashboard, the journey rail, the CDSS, and the report all read
  /// from, and only the ESP32 path used to write to it — so a kiosk with no
  /// module attached showed live numbers here and an empty dashboard.
  ///
  /// Rounded values gate the write because emulated `VITALS:` frames arrive at
  /// 1 Hz and every record notifies the session's listeners; re-publishing an
  /// unchanged reading would rebuild the shell chrome once a second for nothing.
  void _persist(double h, double s, {required bool simulated}) {
    if (h <= 0 || s <= 0) return;
    final key = '${h.round()}/${s.round()}';
    if (key == _lastPersistKey) return;
    _lastPersistKey = key;
    KioskPatientSession.I.recordVitals(h, s, simulated: simulated);
  }

  void _addTrend(double h, double s) {
    if (_hrTrend.length >= 30) {
      _hrTrend.removeAt(0);
      _spo2Trend.removeAt(0);
    }
    _hrTrend.add(XSChartPoint(_hrTrend.length.toDouble(), h));
    _spo2Trend.add(XSChartPoint(_spo2Trend.length.toDouble(), s));
  }

  @override
  void dispose() {
    _countdown?.cancel();
    _esp32.removeListener(_onEsp32);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    final s = XSScale.factor;

    return Padding(
      padding: EdgeInsets.all(XSSpacing.lg * s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Physiological Monitoring',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.3,
                    color: palette.textPrimary,
                  ),
                ),
              ),
              // Provenance must be unmissable: a clinician has to know at a
              // glance whether these numbers came from the sensor.
              XSChip(
                label: _simulated ? 'SIMULATED' : 'LIVE · $_source',
                icon: _simulated ? Icons.science_outlined : Icons.sensors,
                color: _simulated
                    ? XSColors.accentOrange
                    : XSColors.accentGreen,
                filled: !_simulated,
              ),
            ],
          ),
          SizedBox(height: XSSpacing.md * s),
          Expanded(
            // The guided panel owns the screen until the reading is finalised.
            // Charts and thresholds only mean something once there is a settled
            // reading to plot, and putting them up during the scan invited
            // someone to read a number that was still moving.
            child: _complete
                ? _monitoring(palette, s)
                : XSSensorScanPanel(
                    phase: _phase,
                    guide: (size) => XSFingerGuide(size: size),
                    guideMessage: 'Place your fingertip on the sensor',
                    acquiringMessage: 'Finding your pulse',
                    secondsLeft: _secondsLeft,
                    totalSeconds: _scanSeconds,
                    accent: XSColors.moduleVitals,
                    // Dashes rather than zeros: a 0 bpm is a reading, and this is
                    // the absence of one.
                    live: [
                      (
                        label: 'HEART RATE',
                        value: hr > 0 ? hr.toStringAsFixed(0) : '--',
                        unit: 'bpm',
                      ),
                      (
                        label: 'SpO\u2082',
                        value: spo2 > 0 ? spo2.toStringAsFixed(0) : '--',
                        unit: '%',
                      ),
                    ],
                    onCancel: _cancelScan,
                  ),
          ),
        ],
      ),
    );
  }

  /// Charts, gauges and thresholds: what the station shows once the reading is in.
  Widget _monitoring(XSPalette palette, double s) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 1000;
        final gauges = _gaugeColumn(palette, s);
        final charts = Column(
          children: [
            Expanded(
              child: XSChartCard(
                title: 'Heart Rate',
                subtitle: 'last 30 samples',
                data: _hrTrend,
                color: XSColors.moduleVitals,
              ),
            ),
            SizedBox(height: XSSpacing.sm * s),
            Expanded(
              child: XSChartCard(
                title: 'SpO\u2082',
                subtitle: 'last 30 samples',
                data: _spo2Trend,
                color: XSColors.moduleXray,
              ),
            ),
          ],
        );

        if (!wide) {
          // Narrow: gauges on top as a scrollable row, charts below.
          return Column(
            children: [
              SizedBox(height: 132 * s, child: _gaugeRow(palette, s)),
              SizedBox(height: XSSpacing.sm * s),
              Expanded(child: charts),
            ],
          );
        }

        return Row(
          children: [
            SizedBox(width: 220 * s, child: gauges),
            SizedBox(width: XSSpacing.md * s),
            Expanded(child: charts),
            SizedBox(width: XSSpacing.md * s),
            SizedBox(width: 250 * s, child: _alertPanel(palette, s)),
          ],
        );
      },
    );
  }

  /// The station's two gauges. `hero` enlarges the primary reading (heart rate).
  List<
    ({
      IconData icon,
      String label,
      String value,
      String unit,
      Color color,
      bool hero,
    })
  >
  _gaugeSpecs(XSPalette palette) => [
    (
      icon: Icons.favorite,
      label: 'HEART RATE',
      value: hr.toStringAsFixed(0),
      unit: 'bpm',
      color: hr > 100 || hr < 50 ? XSColors.accentRed : XSColors.moduleVitals,
      hero: true,
    ),
    (
      icon: Icons.air,
      label: 'SpO\u2082',
      value: spo2.toStringAsFixed(0),
      unit: '%',
      color: spo2 < 92 ? XSColors.accentRed : XSColors.accentGreen,
      hero: false,
    ),
  ];

  Widget _gaugeColumn(XSPalette palette, double s) {
    final specs = _gaugeSpecs(palette);
    return ListView.separated(
      itemCount: specs.length,
      separatorBuilder: (_, _) => SizedBox(height: XSSpacing.sm * s),
      itemBuilder: (context, i) => _vitalGauge(palette, s, specs[i]),
    );
  }

  Widget _gaugeRow(XSPalette palette, double s) {
    final specs = _gaugeSpecs(palette);
    return ListView.separated(
      scrollDirection: Axis.horizontal,
      itemCount: specs.length,
      separatorBuilder: (_, _) => SizedBox(width: XSSpacing.sm * s),
      itemBuilder: (context, i) =>
          SizedBox(width: 190 * s, child: _vitalGauge(palette, s, specs[i])),
    );
  }

  Widget _vitalGauge(
    XSPalette palette,
    double s,
    ({
      IconData icon,
      String label,
      String value,
      String unit,
      Color color,
      bool hero,
    })
    spec,
  ) {
    final alarming =
        spec.color == XSColors.accentRed || spec.color == XSColors.accentOrange;

    return XSCard(
      padding: EdgeInsets.symmetric(
        horizontal: XSSpacing.md * s,
        vertical: XSSpacing.sm * s,
      ),
      // Only an out-of-range reading glows, so the glow means something.
      glow: alarming ? spec.color : null,
      borderColor: alarming ? spec.color : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            children: [
              Icon(spec.icon, size: 18 * s, color: spec.color),
              SizedBox(width: 6 * s),
              Expanded(
                child: Text(
                  spec.label,
                  style: XSTypography.eyebrow(
                    palette.textSecondary,
                  ).copyWith(fontSize: 13),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          SizedBox(height: 4 * s),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    spec.value,
                    style: XSTypography.hero(
                      spec.color,
                      fontSize: (spec.hero ? 52 : 40),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: EdgeInsets.only(bottom: 5 * s, left: 4 * s),
                child: Text(
                  spec.unit,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: palette.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _alertPanel(XSPalette palette, double s) {
    return XSCard(
      child: ListView(
        children: [
          Text(
            'ALERT THRESHOLDS',
            style: XSTypography.eyebrow(
              palette.textSecondary,
            ).copyWith(fontSize: 13),
          ),
          SizedBox(height: XSSpacing.sm * s),
          _alertRow(palette, s, 'HR < 50 or > 100', hr < 50 || hr > 100),
          _alertRow(palette, s, 'SpO\u2082 < 92%', spo2 < 92),
        ],
      ),
    );
  }

  Widget _alertRow(XSPalette palette, double s, String text, bool triggered) {
    final color = triggered ? XSColors.accentRed : XSColors.accentGreen;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 5 * s),
      child: Row(
        children: [
          Container(
            width: 26 * s,
            height: 26 * s,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.14),
              shape: BoxShape.circle,
              boxShadow: triggered
                  ? XSShadows.glow(color, intensity: 0.5)
                  : null,
            ),
            child: Icon(
              triggered ? Icons.warning_amber_rounded : Icons.check_rounded,
              size: 16 * s,
              color: color,
            ),
          ),
          SizedBox(width: 8 * s),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 14,
                fontWeight: triggered ? FontWeight.w700 : FontWeight.w500,
                color: triggered ? color : palette.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
