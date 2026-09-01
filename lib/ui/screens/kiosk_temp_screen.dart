import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import '../../core/sensor/esp32_serial_client.dart';
import '../../core/voice/voice_guide.dart';
import '../../core/theme/xs_colors.dart';
import '../../core/theme/xs_scale.dart';
import '../../core/theme/xs_spacing.dart';
import '../../core/theme/xs_typography.dart';
import '../components/xs_button.dart';
import '../components/xs_card.dart';
import '../components/xs_chip.dart';
import '../components/xs_dial_gauge.dart';
import '../components/xs_finger_guide.dart';
import '../components/xs_sensor_scan_panel.dart';
import '../../state/kiosk_patient_state.dart';

/// Dedicated Kiosk Temperature screening screen (GY-906 / MLX90614 IR sensor).
class KioskTempScreen extends StatefulWidget {
  const KioskTempScreen({super.key});

  @override
  State<KioskTempScreen> createState() => _KioskTempScreenState();
}

class _KioskTempScreenState extends State<KioskTempScreen> {
  final Esp32SerialClient _esp32 = Esp32SerialClient.shared;
  double _tempC = 0.0;

  /// The timed reading window, in seconds.
  ///
  /// Much shorter than the pulse station's 20s, and deliberately so: the MLX90614
  /// settles in about 100ms, so the window is here to prove the aim was held
  /// steady rather than to accumulate samples. Holding a thermometer against a
  /// fingertip in place for 20s would buy nothing.
  static const _scanSeconds = 5;

  XSScanPhase _phase = XSScanPhase.guide;
  int _secondsLeft = _scanSeconds;
  Timer? _countdown;

  /// Set once the reading is finalised. Swaps the guided panel for the result.
  bool _complete = false;

  /// True when the value on screen stood in for an absent sensor. Surfaced as a
  /// badge here and carried into the session, so it is labelled as demo data
  /// wherever it resurfaces.
  bool _simulated = false;
  final Random _rng = Random();
  final List<({double tempC, DateTime time})> _history = [];

  @override
  void initState() {
    super.initState();
    _esp32.addListener(_onEsp32Data);
    final connectFuture = _esp32.connected
        ? Future<bool>.value(true)
        : _esp32.connect();
    connectFuture.then((ok) {
      if (mounted && ok) _beginHardwareScan();
    });
  }

  void _beginHardwareScan() {
    _esp32.beginTempScan();
    _esp32.sendCommand('START_TEMP');
  }

  @override
  void dispose() {
    _countdown?.cancel();
    _esp32.removeListener(_onEsp32Data);
    super.dispose();
  }

  void _onEsp32Data() {
    if (!mounted) return;
    _syncScanPhase();
    final latest = _esp32.latest;
    if (latest != null && latest.temp > 0) {
      if (mounted) {
        setState(() {
          _tempC = latest.temp;
          // Keyboard-emulated readings carry the SIMULATED badge into the
          // session, so they never pass as a measurement wherever they
          // resurface.
          _simulated = _esp32.simulating;
          if (_history.isEmpty || _history.first.time != latest.ts) {
            _history.insert(0, (tempC: latest.temp, time: latest.ts));
            if (_history.length > 10) _history.removeLast();
          }
        });
      }
    }
  }

  /// Derive the scan phase from what the module reports.
  ///
  /// The module owns the presence check — it compares the reading against the
  /// sensor's own ambient channel and reports `ERR:TEMP` rather than a
  /// temperature when nothing warm is on it — so a reading arriving here is
  /// already one the firmware was willing to stand behind.
  void _syncScanPhase() {
    if (_complete) return;
    final state = _esp32.tempState;

    if (state == 'DONE') {
      _completeScan();
      return;
    }

    // A reading present and in range means the aim is good; start the window.
    final t = _esp32.latest?.temp ?? 0;
    if (t > 0) {
      if (_phase != XSScanPhase.scanning && _phase != XSScanPhase.finishing) {
        _startCountdown();
      }
      return;
    }

    // Armed but aimed at the room. Back to coaching, and the window restarts
    // rather than resuming: a reading held across a break in aim is two readings.
    if (_phase == XSScanPhase.scanning) {
      _stopCountdown();
      setState(() {
        _phase = XSScanPhase.acquiring;
        _secondsLeft = _scanSeconds;
      });
      return;
    }
    if (state == 'ACTIVE' && _phase == XSScanPhase.guide) {
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

  /// With a module attached the firmware sends `TEMP_DONE:1` on its own clock, so
  /// this waits for it rather than claiming a result. With nothing attached, stand
  /// in for the sensor so the station can complete in a software-only demo —
  /// tagged simulated, so it never passes as a measurement. A module that *is*
  /// connected and did not answer is left alone: that is a fault worth showing,
  /// and inventing a temperature would hide it.
  void _onWindowElapsed() {
    if (!mounted) return;
    setState(() => _secondsLeft = 0);
    if (_esp32.connected || _tempC > 0) {
      setState(() => _phase = XSScanPhase.finishing);
      return;
    }
    final t = 36.4 + _rng.nextDouble();
    setState(() {
      _simulated = true;
      _tempC = t;
      _history.insert(0, (tempC: t, time: DateTime.now()));
      if (_history.length > 10) _history.removeLast();
    });
    _completeScan();
  }

  void _completeScan() {
    if (_complete) return;
    _stopCountdown();
    if (_tempC > 0) {
      KioskPatientSession.I.recordTemp(_tempC, simulated: _simulated);
    }
    setState(() {
      _complete = true;
      _secondsLeft = 0;
    });
  }

  /// Stand the module down and go back to coaching.
  void _cancelScan() {
    _stopCountdown();
    _esp32.sendCommand('STOP_TEMP');
    _esp32.beginTempScan();
    setState(() {
      _tempC = 0;
      _phase = XSScanPhase.guide;
      _secondsLeft = _scanSeconds;
    });
  }

  /// Re-arm for another reading. A redo, not a step: nothing in the flow requires
  /// pressing it, and the station completes on its own without it.
  void _measureAgain() {
    _stopCountdown();
    VoiceGuide.I.say(XSVoiceCue.tempPlace);
    setState(() {
      _complete = false;
      _tempC = 0;
      _phase = XSScanPhase.guide;
      _secondsLeft = _scanSeconds;
    });
    _beginHardwareScan();
  }

  double get _tempF => _tempC > 0 ? (_tempC * 9 / 5) + 32 : 0.0;

  String get _statusLabel {
    if (_tempC <= 0) return 'NO READING';
    if (_tempC < 37.5) return 'NORMAL';
    if (_tempC < 38.2) return 'LOW-GRADE FEVER';
    return 'HIGH FEVER';
  }

  Color get _statusColor {
    if (_tempC <= 0) return XSColors.sage;
    if (_tempC < 37.5) return XSColors.accentGreen;
    if (_tempC < 38.2) return XSColors.accentOrange;
    return XSColors.accentRed;
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
              Icon(
                Icons.thermostat_outlined,
                size: 26 * s,
                color: _statusColor,
              ),
              SizedBox(width: XSSpacing.xs * s),
              Expanded(
                child: Text(
                  'Body Temperature',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.3,
                    color: palette.textPrimary,
                  ),
                ),
              ),
              if (_simulated) ...[
                const XSChip(
                  label: 'SIMULATED',
                  icon: Icons.science_outlined,
                  color: Colors.amber,
                ),
                SizedBox(width: XSSpacing.xs * s),
              ],
              XSChip(
                label: _statusLabel,
                icon: _tempC <= 0
                    ? Icons.hourglass_empty
                    : (_tempC < 37.5
                          ? Icons.check_rounded
                          : Icons.warning_amber_rounded),
                color: _statusColor,
                filled: _tempC >= 37.5,
              ),
            ],
          ),
          SizedBox(height: XSSpacing.lg * s),
          Expanded(
            child: _complete
                ? _result(palette, s)
                : XSSensorScanPanel(
                    phase: _phase,
                    // Same finger guide as the pulse station, in the thermal
                    // accent: the IR sensor sits beside the pulse sensor and
                    // reads the same fingertip, so the placement a walk-in has
                    // to learn is identical.
                    guide: (size) => XSFingerGuide(
                      size: size,
                      accentColor: XSColors.moduleTemp,
                    ),
                    guideMessage: 'Rest your fingertip on the sensor',
                    acquiringMessage: 'Keep your fingertip in place',
                    secondsLeft: _secondsLeft,
                    totalSeconds: _scanSeconds,
                    accent: XSColors.moduleTemp,
                    live: [
                      (
                        label: 'TEMPERATURE',
                        value: _tempC > 0 ? _tempC.toStringAsFixed(1) : '--',
                        unit: '\u00B0C',
                      ),
                    ],
                    onCancel: _cancelScan,
                  ),
          ),
        ],
      ),
    );
  }

  /// Gauge and history: what the station shows once the reading is in.
  Widget _result(XSPalette palette, double s) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 900;
        final gauge = _gaugePanel(palette, s, wide);
        final history = _historyPanel(palette, s);

        return wide
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(flex: 6, child: gauge),
                  SizedBox(width: XSSpacing.lg * s),
                  Expanded(flex: 5, child: history),
                ],
              )
            : Column(
                children: [
                  Expanded(flex: 6, child: gauge),
                  SizedBox(height: XSSpacing.md * s),
                  Expanded(flex: 4, child: history),
                ],
              );
      },
    );
  }

  Widget _gaugePanel(XSPalette palette, double s, bool wide) {
    return XSCard(
      padding: EdgeInsets.all(XSSpacing.xl * s),
      // The gauge glows only once there's an actual reading to look at.
      glow: _tempC > 0 ? _statusColor : null,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.sensors, size: 17 * s, color: palette.textSecondary),
              SizedBox(width: 6 * s),
              Text(
                'MLX90614 INFRARED',
                style: XSTypography.eyebrow(
                  palette.textSecondary,
                ).copyWith(fontSize: 13),
              ),
            ],
          ),
          SizedBox(height: XSSpacing.lg * s),
          Flexible(
            child: FittedBox(
              child: XSDialGauge(
                // 34-42C spans hypothermia to high fever, so the needle
                // position itself carries the clinical read.
                value: _tempC,
                min: 34,
                max: 42,
                label: _tempC > 0 ? _tempC.toStringAsFixed(1) : '--.-',
                unit: '\u00B0C',
                status: _tempF > 0
                    ? '${_tempF.toStringAsFixed(1)} \u00B0F'
                    : 'awaiting reading',
                color: _statusColor,
                size: wide ? 280 : 230,
              ),
            ),
          ),
          SizedBox(height: XSSpacing.xl * s),
          XSButton(
            label: 'MEASURE AGAIN',
            icon: Icons.refresh,
            color: XSColors.moduleTemp,
            height: 64,
            width: 320,
            onPressed: _measureAgain,
          ),
        ],
      ),
    );
  }

  Widget _historyPanel(XSPalette palette, double s) {
    return XSCard(
      padding: EdgeInsets.all(XSSpacing.lg * s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.history, size: 19 * s, color: palette.textSecondary),
              SizedBox(width: 6 * s),
              Text(
                'RECENT READINGS',
                style: XSTypography.eyebrow(
                  palette.textSecondary,
                ).copyWith(fontSize: 13),
              ),
            ],
          ),
          SizedBox(height: XSSpacing.md * s),
          Expanded(
            child: _history.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.thermostat_auto,
                          size: 42 * s,
                          color: palette.divider,
                        ),
                        SizedBox(height: 8 * s),
                        Text(
                          'No temperature records yet',
                          style: TextStyle(
                            fontSize: 14,
                            color: palette.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.separated(
                    itemCount: _history.length,
                    separatorBuilder: (_, _) => Divider(height: 1 * s),
                    itemBuilder: (context, i) {
                      final rec = _history[i];
                      final isFever = rec.tempC >= 37.5;
                      final color = isFever
                          ? XSColors.accentRed
                          : XSColors.accentGreen;
                      final timeStr =
                          '${rec.time.hour.toString().padLeft(2, '0')}:'
                          '${rec.time.minute.toString().padLeft(2, '0')}:'
                          '${rec.time.second.toString().padLeft(2, '0')}';
                      return Padding(
                        padding: EdgeInsets.symmetric(vertical: 11 * s),
                        child: Row(
                          children: [
                            Container(
                              width: 30 * s,
                              height: 30 * s,
                              decoration: BoxDecoration(
                                color: color.withValues(alpha: 0.14),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                isFever
                                    ? Icons.warning_amber_rounded
                                    : Icons.check_rounded,
                                size: 18 * s,
                                color: color,
                              ),
                            ),
                            SizedBox(width: 10 * s),
                            Text(
                              '${rec.tempC.toStringAsFixed(1)} \u00B0C',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                                color: palette.textPrimary,
                              ),
                            ),
                            SizedBox(width: 8 * s),
                            Text(
                              '(${((rec.tempC * 9 / 5) + 32).toStringAsFixed(1)} \u00B0F)',
                              style: TextStyle(
                                fontSize: 13,
                                color: palette.textSecondary,
                              ),
                            ),
                            const Spacer(),
                            Text(
                              timeStr,
                              style: TextStyle(
                                fontSize: 13,
                                color: palette.textSecondary,
                              ),
                            ),
                          ],
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
