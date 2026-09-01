import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:record/record.dart' show InputDevice;

import '../../core/voice/voice_client.dart';
import '../../core/voice/voice_guide.dart';
import '../../core/api/server_discovery.dart';
import '../../state/xs_settings.dart';
import '../../core/theme/xs_colors.dart';
import '../../core/theme/xs_scale.dart';
import '../../core/theme/xs_radius.dart';
import '../../core/theme/xs_spacing.dart';
import '../../core/theme/xs_typography.dart';
import '../components/xs_card.dart';
import '../components/xs_button.dart';
import '../components/xs_chip.dart';

/// Kiosk settings — server IP and connectivity check.
class KioskSettingsScreen extends StatefulWidget {
  const KioskSettingsScreen({super.key});
  @override
  State<KioskSettingsScreen> createState() => _KioskSettingsScreenState();
}

class _KioskSettingsScreenState extends State<KioskSettingsScreen> {
  final _ipCtrl = TextEditingController();
  bool _saved = false;
  bool _testing = false;
  bool? _testOk;
  String? _testResult;

  bool _scanning = false;
  double _scanProgress = 0;
  String? _scanResult;
  StreamSubscription<XSServerCandidate>? _scanSub;

  @override
  void initState() {
    super.initState();
    // Load current value from XSSettings (trims http:// and :8000 for display)
    final url = XSSettings.I.backendUrl;
    if (url.isNotEmpty) {
      // Show clean IP without protocol/port for convenience
      final cleaned = url.replaceAll('http://', '').replaceAll('https://', '');
      final withoutPort = cleaned.endsWith(':8000')
          ? cleaned.substring(0, cleaned.length - 5)
          : cleaned;
      _ipCtrl.text = withoutPort;
    }
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    _ipCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final ip = _ipCtrl.text.trim();
    await XSSettings.I.setBackendUrl(ip);
    if (!mounted) return;
    setState(() => _saved = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _saved = false);
    });
  }

  /// Sweep the LAN for the backend and adopt the first one that answers.
  ///
  /// The address is the one setting nobody at the kiosk can guess — it moves with
  /// the venue's DHCP, and the kiosk has no keyboard to type it on. Adopting the
  /// first hit rather than presenting a list because a clinic LAN has one of
  /// these; the found URL is written into the field either way, so an operator can
  /// see and change it.
  Future<void> _scan() async {
    await _scanSub?.cancel();
    setState(() {
      _scanning = true;
      _scanProgress = 0;
      _scanResult = 'Looking for the server on this network…';
      _testResult = null;
      _testOk = null;
    });

    XSServerCandidate? found;
    _scanSub = XSServerDiscovery.scan(
      preferred: XSSettings.I.backendUrl,
      onProgress: (probed, total) {
        if (!mounted || total == 0) return;
        setState(() => _scanProgress = probed / total);
      },
    ).listen(
      (candidate) async {
        if (found != null) return;   // first answer wins; stop looking
        found = candidate;
        await _scanSub?.cancel();
        if (!mounted) return;
        await XSSettings.I.setBackendUrl(candidate.baseUrl);
        if (!mounted) return;
        setState(() {
          _ipCtrl.text = '${candidate.host}:${candidate.port}';
          _scanning = false;
          _scanProgress = 1;
          _scanResult = 'Found ${candidate.host}:${candidate.port} '
              '(${candidate.latency.inMilliseconds} ms) · ${candidate.summary}';
          _testOk = true;
          _testResult = 'Connected';
        });
      },
      onDone: () {
        if (!mounted || found != null) return;
        setState(() {
          _scanning = false;
          _scanResult = 'No XSIGHT server found on this network. Check the '
              'server is running and that both devices are on the same Wi-Fi.';
        });
      },
      onError: (Object e) {
        if (!mounted) return;
        setState(() {
          _scanning = false;
          _scanResult = 'Scan failed: $e';
        });
      },
      cancelOnError: true,
    );
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _testResult = null;
      _testOk = null;
    });
    try {
      final url = '${XSSettings.I.backendUrl}/health';
      final resp = await _httpGet(Uri.parse(url));
      if (!mounted) return;
      setState(() {
        _testing = false;
        _testOk = resp == 200;
        _testResult =
            resp == 200 ? 'Connected' : 'Server returned status $resp';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testing = false;
        _testOk = false;
        _testResult = 'Cannot reach server: $e';
      });
    }
  }

  Future<int> _httpGet(Uri uri) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      final req = await client.getUrl(uri);
      final resp = await req.close().timeout(const Duration(seconds: 5));
      return resp.statusCode;
    } finally {
      client.close();
    }
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
              Icon(Icons.settings_outlined,
                  size: 26 * s, color: XSColors.moduleSettings),
              SizedBox(width: XSSpacing.sm * s),
              Text(
                'Settings',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.3,
                  color: palette.textPrimary,
                ),
              ),
            ],
          ),
          SizedBox(height: XSSpacing.lg * s),
          Expanded(
            child: SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: 620 * s),
                child: XSCard(
                  padding: EdgeInsets.all(XSSpacing.xl * s),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'SERVER CONNECTION',
                        style: XSTypography.eyebrow(palette.textSecondary)
                            .copyWith(fontSize: 13),
                      ),
                      SizedBox(height: 6 * s),
                      Text(
                        'Enter the backend IP address. Protocol and port are '
                        'filled in automatically.',
                        style: TextStyle(
                          fontSize: 14,
                          color: palette.textSecondary,
                        ),
                      ),
                      SizedBox(height: XSSpacing.md * s),
                      TextField(
                        controller: _ipCtrl,
                        style: TextStyle(fontSize: 18),
                        keyboardType: TextInputType.url,
                        decoration: InputDecoration(
                          labelText: 'Backend IP / URL',
                          hintText: '192.168.1.100',
                          prefixIcon: const Icon(Icons.dns_outlined),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14 * s),
                          ),
                        ),
                        onSubmitted: (_) => _save(),
                      ),
                      SizedBox(height: XSSpacing.md * s),
                      // Labelled buttons: tooltips are unusable on a kiosk with
                      // no pointer to hover.
                      Wrap(
                        spacing: XSSpacing.sm * s,
                        runSpacing: XSSpacing.xs * s,
                        children: [
                          XSButton(
                            label: _saved ? 'SAVED' : 'SAVE',
                            icon: _saved ? Icons.check : Icons.save_outlined,
                            color: XSColors.moduleSettings,
                            height: 60,
                            width: 190,
                            onPressed: _save,
                          ),
                          XSButton(
                            label: _testing ? 'TESTING...' : 'TEST CONNECTION',
                            icon: _testing
                                ? Icons.hourglass_top
                                : Icons.wifi_find,
                            height: 60,
                            width: 250,
                            onPressed: _testing ? null : _test,
                          ),
                          XSButton(
                            label: _scanning ? 'SCANNING...' : 'FIND SERVER',
                            icon: _scanning
                                ? Icons.radar
                                : Icons.travel_explore_outlined,
                            height: 60,
                            width: 230,
                            onPressed: _scanning ? null : _scan,
                          ),
                        ],
                      ),
                      if (_scanning || _scanResult != null) ...[
                        SizedBox(height: XSSpacing.md * s),
                        if (_scanning)
                          ClipRRect(
                            borderRadius: BorderRadius.circular(XSRadius.xs),
                            child: LinearProgressIndicator(
                              // Determinate: the sweep knows how many addresses
                              // are left, and a spinner on a multi-second scan
                              // reads as a hang.
                              value: _scanProgress == 0 ? null : _scanProgress,
                              minHeight: 8 * s,
                              backgroundColor: palette.divider,
                              color: XSColors.moduleSettings,
                            ),
                          ),
                        if (_scanResult != null) ...[
                          SizedBox(height: XSSpacing.xs * s),
                          Text(
                            _scanResult!,
                            style: TextStyle(
                              fontSize: 14,
                              height: 1.4,
                              color: palette.textSecondary,
                            ),
                          ),
                        ],
                      ],
                      if (_testResult != null) ...[
                        SizedBox(height: XSSpacing.md * s),
                        XSChip(
                          label: _testResult!,
                          icon: _testOk == true
                              ? Icons.check_circle_outline
                              : Icons.error_outline,
                          color: _testOk == true
                              ? XSColors.accentGreen
                              : XSColors.accentRed,
                          filled: _testOk != true,
                        ),
                      ],
                      SizedBox(height: XSSpacing.lg * s),
                      Divider(color: palette.divider),
                      SizedBox(height: XSSpacing.sm * s),
                      Text(
                        'Current: ${XSSettings.I.backendUrl.isEmpty ? "not configured" : XSSettings.I.backendUrl}',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: palette.textSecondary,
                        ),
                      ),
                      SizedBox(height: XSSpacing.xl * s),
                      Divider(color: palette.divider),
                      SizedBox(height: XSSpacing.lg * s),
                      _buildMicSection(palette, s),
                      SizedBox(height: XSSpacing.xl * s),
                      Divider(color: palette.divider),
                      SizedBox(height: XSSpacing.lg * s),
                      _buildGuideSection(palette, s),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ─── Microphone ─────────────────────────────────────────────────
  /// Input devices the platform reported, or null before the first scan.
  List<InputDevice>? _mics;
  bool _scanningMics = false;
  String? _micError;

  Future<void> _scanMics() async {
    setState(() {
      _scanningMics = true;
      _micError = null;
    });
    final found = await VoiceClient.listInputDevices();
    if (!mounted) return;
    setState(() {
      _scanningMics = false;
      _mics = found;
      // Enumeration is genuinely unsupported on some platforms rather than
      // merely empty, so say which happened instead of showing a blank list.
      _micError = found.isEmpty
          ? 'No selectable inputs reported. This platform may only expose the '
              'system default microphone.'
          : null;
    });
  }

  Future<void> _chooseMic(InputDevice? device) async {
    await XSSettings.I.setInputDevice(id: device?.id, label: device?.label);
    if (mounted) setState(() {});
  }

  Widget _buildGuideSection(XSPalette palette, double s) {
    final on = XSSettings.I.voiceGuideEnabled;
    final volume = XSSettings.I.voiceGuideVolume;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'SPOKEN GUIDANCE',
          style: XSTypography.eyebrow(palette.textSecondary)
              .copyWith(fontSize: 13),
        ),
        SizedBox(height: 6 * s),
        Text(
          'Speaks each step aloud for walk-up users. Coaching and results are '
          'guest-mode only — in staff mode the kiosk only announces stations '
          'and faults, and never reads a linked patient’s readings aloud.',
          style: TextStyle(fontSize: 14, color: palette.textSecondary),
        ),
        SizedBox(height: XSSpacing.md * s),
        SwitchListTile.adaptive(
          value: on,
          onChanged: (next) async {
            await XSSettings.I.setVoiceGuideEnabled(next);
            if (!next) await VoiceGuide.I.stop();
            if (mounted) setState(() {});
          },
          contentPadding: EdgeInsets.zero,
          activeThumbColor: palette.accent,
          title: Text(
            on ? 'Guidance on' : 'Guidance off',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: palette.textPrimary,
            ),
          ),
          subtitle: Text(
            on
                ? 'The kiosk talks the user through each station'
                : 'Silent — on-screen instructions only',
            style: TextStyle(fontSize: 13, color: palette.textSecondary),
          ),
        ),
        SizedBox(height: XSSpacing.sm * s),
        Row(
          children: [
            Icon(Icons.volume_down_rounded,
                size: 22 * s, color: palette.textSecondary),
            Expanded(
              child: Slider.adaptive(
                value: volume,
                // Coarse on purpose: this is set once per room with a
                // fingertip, not tuned.
                divisions: 10,
                label: '${(volume * 100).round()}%',
                activeColor: palette.accent,
                // Disabled rather than hidden, so the level a muted kiosk will
                // come back at is still visible.
                onChanged: on
                    ? (v) async {
                        await XSSettings.I.setVoiceGuideVolume(v);
                        if (mounted) setState(() {});
                      }
                    : null,
              ),
            ),
            Icon(Icons.volume_up_rounded,
                size: 22 * s, color: palette.textSecondary),
            SizedBox(width: XSSpacing.sm * s),
            XSButton(
              label: 'TEST',
              icon: Icons.play_arrow_rounded,
              height: 52,
              width: 130,
              // Plays the welcome line, which is the clip a passer-by hears
              // first and so the one worth levelling against.
              onPressed: on
                  ? () {
                      VoiceGuide.I.resetHistory();
                      VoiceGuide.I.say(XSVoiceCue.welcome);
                    }
                  : null,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildMicSection(XSPalette palette, double s) {
    final selectedId = XSSettings.I.inputDeviceId;
    final mics = _mics;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'MICROPHONE',
          style: XSTypography.eyebrow(palette.textSecondary)
              .copyWith(fontSize: 13),
        ),
        SizedBox(height: 6 * s),
        Text(
          'Which input the voice assistant records from. The system default is '
          'often the tablet\u2019s own far-field mic even with a headset attached, '
          'so pick the one actually connected.',
          style: TextStyle(fontSize: 14, color: palette.textSecondary),
        ),
        SizedBox(height: XSSpacing.md * s),
        XSButton(
          label: _scanningMics ? 'SCANNING...' : 'SCAN FOR MICROPHONES',
          icon: _scanningMics ? Icons.hourglass_top : Icons.mic_none_outlined,
          height: 60,
          width: 290,
          onPressed: _scanningMics ? null : _scanMics,
        ),
        if (_micError != null) ...[
          SizedBox(height: XSSpacing.sm * s),
          Text(
            _micError!,
            style: TextStyle(fontSize: 13, color: palette.textSecondary),
          ),
        ],
        SizedBox(height: XSSpacing.md * s),
        // "System default" is always offered, so a wrong pick is always
        // recoverable without a rescan.
        _micOption(
          palette: palette,
          scale: s,
          label: 'System default',
          sublabel: 'Let the OS choose',
          selected: selectedId.isEmpty,
          onTap: () => _chooseMic(null),
        ),
        if (mics != null)
          for (final d in mics)
            _micOption(
              palette: palette,
              scale: s,
              label: d.label.isEmpty ? d.id : d.label,
              sublabel: d.id,
              selected: d.id == selectedId,
              onTap: () => _chooseMic(d),
            ),
        // A device chosen on a previous run is shown even before a scan, so the
        // active setting is never invisible.
        if (mics == null && selectedId.isNotEmpty)
          _micOption(
            palette: palette,
            scale: s,
            label: XSSettings.I.inputDeviceLabel,
            sublabel: 'saved \u2014 scan to confirm it is still attached',
            selected: true,
            onTap: () {},
          ),
      ],
    );
  }

  Widget _micOption({
    required XSPalette palette,
    required double scale,
    required String label,
    required String sublabel,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: EdgeInsets.only(bottom: XSSpacing.xs * scale),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12 * scale),
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: XSSpacing.md * scale,
            vertical: XSSpacing.sm * scale,
          ),
          decoration: BoxDecoration(
            color: selected
                ? XSColors.moduleSettings.withValues(alpha: 0.10)
                : palette.surface,
            borderRadius: BorderRadius.circular(12 * scale),
            border: Border.all(
              color: selected ? XSColors.moduleSettings : palette.divider,
              width: selected ? 2 : 1,
            ),
          ),
          child: Row(
            children: [
              Icon(
                selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: 20 * scale,
                color:
                    selected ? XSColors.moduleSettings : palette.textSecondary,
              ),
              SizedBox(width: XSSpacing.sm * scale),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: palette.textPrimary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      sublabel,
                      style: TextStyle(
                        fontSize: 13,
                        color: palette.textSecondary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
