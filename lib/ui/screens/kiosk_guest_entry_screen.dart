import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api/kiosk_hub_client.dart';
import '../../core/api/server_discovery.dart';
import '../../core/sensor/esp32_serial_client.dart';
import '../../core/theme/xs_colors.dart';
import '../../core/theme/xs_radius.dart';
import '../../core/theme/xs_scale.dart';
import '../../core/theme/xs_spacing.dart';
import '../../state/xs_settings.dart';
import '../components/xs_ambient_background.dart';
import '../components/xs_button.dart';
import '../components/xs_card.dart';
import '../components/xs_remote_session_dialog.dart';

/// Screen displayed after the medical disclaimer: allows walk-ins to press OK on
/// the ESP32 to enter Guest Mode directly, or accept an incoming remote session
/// triggered from the local web dashboard.
class KioskGuestEntryScreen extends StatefulWidget {
  final VoidCallback onEnterGuestMode;
  final ValueChanged<Map<String, dynamic>> onEnterRemoteSession;
  final bool autoConnectHub;

  /// Sweep the LAN for the backend here too. The splash already runs one, but
  /// this screen is where a walk-in lands after the disclaimer — if the venue
  /// changed between launch and now, this is the last automatic chance to
  /// reconnect before every station starts failing.
  final bool autoDiscoverServer;

  /// Bring the ESP32 link up on this screen, before any mode is chosen.
  ///
  /// Both paths forward — START AS GUEST and an accepted web-portal session —
  /// land on stations that need the module, so the BT/USB handshake should be
  /// done (or already retrying) by the time they tap. The shell re-issues
  /// [Esp32SerialClient.connect] idempotently on mount.
  final bool autoConnectSensor;

  const KioskGuestEntryScreen({
  super.key,
  required this.onEnterGuestMode,
  required this.onEnterRemoteSession,
  this.autoConnectHub = true,
  this.autoDiscoverServer = true,
  this.autoConnectSensor = true,
  });

  @override
  State<KioskGuestEntryScreen> createState() => _KioskGuestEntryScreenState();
}

class _KioskGuestEntryScreenState extends State<KioskGuestEntryScreen> {
  final FocusNode _focusNode = FocusNode();
  final Esp32SerialClient _esp32 = Esp32SerialClient.shared;
  bool _dialogOpen = false;

  @override
  void initState() {
  super.initState();
  _esp32.onMenuReady = _onEsp32Ok;
  // UP/DOWN move the prompt's highlight, SELECT answers it, and the hub tells
  // us where its own highlight went so the two displays stay in step.
  _esp32.onConsentSelect = _onConsentSelect;
  _esp32.onConsent = _onConsentAnswer;

  // Listener first: the reconnect loop only runs while somebody is watching
  // the client, and this screen is the first place the link is wanted.
  _esp32.addListener(_onEsp32Status);
  if (widget.autoConnectSensor) _esp32.connect();

  if (widget.autoConnectHub) {
  final hub = KioskHubClient.instance;
  hub.connect();
  hub.onRemoteSessionRequest = _onRemoteSessionReceived;
  }
  }

  @override
  void dispose() {
    // Drop only *this screen's* callback, never the socket.
    //
    // Disconnecting here killed the hub the moment the shell opened, which took
    // the whole portal integration with it: station changes went nowhere (so the
    // web dashboard never popped its X-ray upload), `kiosks_online` fell to zero
    // (so the dashboard reported the kiosk offline mid-session), and Stop Session
    // broadcast to nobody (so the kiosk never returned to guest mode). The socket
    // is app-lifetime and reconnects itself; the screens only rent callbacks.
    if (widget.autoConnectHub &&
        KioskHubClient.instance.onRemoteSessionRequest ==
            _onRemoteSessionReceived) {
      KioskHubClient.instance.onRemoteSessionRequest = null;
    }
  if (identical(_esp32.onConsentSelect, _onConsentSelect)) {
  _esp32.onConsentSelect = null;
  }
  if (identical(_esp32.onConsent, _onConsentAnswer)) {
  _esp32.onConsent = null;
  }
  _esp32.removeListener(_onEsp32Status);
  _focusNode.dispose();
  super.dispose();
  }

  /// Rebuild the sensor badge on every client notification.
  void _onEsp32Status() {
  if (mounted) setState(() {});
  }

  /// OK on the sensor hub.
  ///
  /// While a remote-session prompt is up it accepts that prompt rather than
  /// being swallowed: this kiosk is driven by physical buttons, so a modal the
  /// hub cannot answer would strand anyone who will not touch the screen.
  void _onEsp32Ok() {
    if (!mounted) return;
    // While the prompt is up, OK confirms whatever it has highlighted — which is
    // not always accept, now that UP/DOWN can reach decline.
    final prompt = XSRemoteSessionDialog.activeState;
    if (prompt != null) {
      prompt.confirm();
      return;
    }
    if (_dialogOpen) return;
    widget.onEnterGuestMode();
  }

  /// The hub moved its own highlight; mirror it.
  void _onConsentSelect(String action) {
    if (!mounted) return;
    XSRemoteSessionDialog.activeState?.select(
      action == 'DECLINE' ? XSConsentChoice.decline : XSConsentChoice.accept,
    );
  }

  /// The hub answered outright — SELECT on its highlight, or BACK to decline.
  void _onConsentAnswer(String action) {
    if (!mounted) return;
    final prompt = XSRemoteSessionDialog.activeState;
    if (prompt == null) return;
    if (action == 'DECLINE') {
      prompt.decline();
    } else {
      prompt.select(XSConsentChoice.accept);
      prompt.confirm();
    }
  }

  /// Ask the person at the kiosk before adopting a profile pushed from the
  /// portal. Reachable from the hub through [XSRemoteSessionDialog.activeState] —
  /// see [_onEsp32Ok].
  Future<void> _onRemoteSessionReceived(Map<String, dynamic> patient) async {
    if (!mounted || _dialogOpen) return;
    _dialogOpen = true;

    // Mirror the prompt onto the hub: STATE:9 puts up its consent screen and
    // PATIENT: names the subject, so someone looking at the module — not the
    // kiosk screen — can still see who they are being asked about.
    final name = patient['name']?.toString().trim();
    _esp32.sendCommand('PATIENT:${name == null || name.isEmpty ? 'Web patient' : name}');
    _esp32.sendCommand('STATE:9');

    final accepted = await XSRemoteSessionDialog.show(
      context,
      patient: patient,
    );

    _dialogOpen = false;
    // Take the prompt back off the OLED. On an accept the shell will drive the
    // module screens from here; on a decline this screen is what stays up.
    _esp32.sendCommand('STATE:0');
    if (!mounted) return;
    if (accepted == true) widget.onEnterRemoteSession(patient);
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;

    // Desktop stand-ins for the four hub buttons, so the prompt is testable
    // without hardware attached.
    final prompt = XSRemoteSessionDialog.activeState;
    if (prompt != null) {
      if (key == LogicalKeyboardKey.arrowUp ||
          key == LogicalKeyboardKey.arrowDown) {
        prompt.moveSelection();
        // Report the move so the OLED follows the screen, the same way the hub
        // reports its own moves back to us.
        _esp32.sendCommand(
          'CONSENT_SEL:${prompt.choice == XSConsentChoice.decline ? 'DECLINE' : 'ACCEPT'}',
        );
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.escape ||
          key == LogicalKeyboardKey.backspace) {
        prompt.decline();
        return KeyEventResult.handled;
      }
    }

    if (key == LogicalKeyboardKey.space || key == LogicalKeyboardKey.enter) {
      _onEsp32Ok();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    final s = XSScale.factor;

    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _handleKey,
      child: Scaffold(
        backgroundColor: palette.surface,
        body: XSAmbientBackground(
          child: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: EdgeInsets.symmetric(
                  horizontal: XSSpacing.xl * s,
                  vertical: XSSpacing.lg * s,
                ),
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: 680 * s),
                  // Rebuild when auto-discovery adopts a new server address:
                  // the portal URL below is derived from XSSettings and would
                  // otherwise keep showing the stale host for this session.
                  child: AnimatedBuilder(
                    animation: XSSettings.I,
                    builder: (context, _) {
                      final backendUrl = XSSettings.I.backendUrl;
                      final webUrl =
                          '${backendUrl.replaceAll('10.0.2.2', 'localhost')}/web';
  return Column(
  mainAxisAlignment: MainAxisAlignment.center,
  children: [
  // Live connection state; taps off a rescan.
  if (widget.autoDiscoverServer) _ServerAutoConnectBadge(scale: s),
  if (widget.autoConnectSensor) ...[
  SizedBox(height: XSSpacing.xs * s),
  _SensorLinkBadge(scale: s, client: _esp32),
  ],
  SizedBox(height: XSSpacing.lg * s),

                          // Title
                          Text(
                            'Thoracic Screening Station',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 32 * s,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.5,
                              color: palette.textPrimary,
                            ),
                          ),
                          SizedBox(height: 8 * s),
                          Text(
                            'Press OK on the sensor hub or tap below to begin screening.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 14 * s,
                              color: palette.textSecondary,
                            ),
                          ),
                          SizedBox(height: XSSpacing.xl * s),

                          // Main Action Card: Enter Guest Mode
                          XSCard(
                            padding: EdgeInsets.all(24 * s),
                            glow: XSColors.teal,
                            child: Column(
                              children: [
                                Icon(
                                  Icons.touch_app_rounded,
                                  size: 48 * s,
                                  color: XSColors.teal,
                                ),
                                SizedBox(height: 12 * s),
                                Text(
                                  'Enter Guest Mode',
                                  style: TextStyle(
                                    fontSize: 20 * s,
                                    fontWeight: FontWeight.w800,
                                    color: palette.textPrimary,
                                  ),
                                ),
                                SizedBox(height: 6 * s),
                                Text(
                                  'Start direct walk-in assessment across Vitals, Lungs, Temperature, and X-Ray stations.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 13 * s,
                                    color: palette.textSecondary,
                                  ),
                                ),
                                SizedBox(height: 20 * s),
                                SizedBox(
                                  width: double.infinity,
                                  child: XSButton(
                                    label: 'START SCREENING  (OK)',
                                    height: 54 * s,
                                    inverted: true,
                                    onPressed: widget.onEnterGuestMode,
                                  ),
                                ),
                              ],
                            ),
                          ),

                          SizedBox(height: XSSpacing.lg * s),

                          // Local Web Portal Info
                          Container(
                            padding: EdgeInsets.all(14 * s),
                            decoration: BoxDecoration(
                              color: palette.surface.withValues(alpha: 0.6),
                              borderRadius:
                                  BorderRadius.circular(XSRadius.md),
                              border: Border.all(color: palette.divider),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.laptop_chromebook_rounded,
                                  size: 22 * s,
                                  color: XSColors.teal,
                                ),
                                SizedBox(width: 12 * s),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Patient Web Dashboard Available',
                                        style: TextStyle(
                                          fontSize: 12.5 * s,
                                          fontWeight: FontWeight.w700,
                                          color: palette.textPrimary,
                                        ),
                                      ),
                                      SizedBox(height: 2 * s),
                                      Text(
                                        'Connect phone/browser to $webUrl to register or start session remotely.',
                                        style: TextStyle(
                                          fontSize: 11.5 * s,
                                          color: palette.textSecondary,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                         ],
                       );
                     },
                   ),
                 ),
               ),
             ),
           ),
         ),
       ),
     );
   }
}

/// Live ESP32 link pill: transport + readiness, tap to force a connect.
///
/// The parent rebuilds it on every [Esp32SerialClient] notification, so no
/// subscription of its own — one listener on the screen drives both states.
class _SensorLinkBadge extends StatelessWidget {
  const _SensorLinkBadge({required this.scale, required this.client});

  final double scale;
  final Esp32SerialClient client;

  @override
  Widget build(BuildContext context) {
  final palette = XSPalette.of(context);
  final s = scale;
  final linked = client.connected;
  final ready = client.deviceReady;
  final color = !linked
  ? XSColors.accentOrange
  : ready
  ? XSColors.accentGreen
  : XSColors.teal;
  final label = !linked
  ? 'SENSOR LINKING… TAP TO RETRY'
  : ready
  ? 'SENSOR READY · ${client.transportLabel}'
  : 'SENSOR ${client.transportLabel}';

  return InkWell(
  onTap: linked ? null : () => client.connect(),
  borderRadius: BorderRadius.circular(XSRadius.pill),
  child: Container(
  padding: EdgeInsets.symmetric(horizontal: 14 * s, vertical: 6 * s),
  decoration: BoxDecoration(
  color: color.withValues(alpha: 0.15),
  borderRadius: BorderRadius.circular(XSRadius.pill),
  border: Border.all(color: color.withValues(alpha: 0.3)),
  ),
  child: Row(
  mainAxisSize: MainAxisSize.min,
  children: [
  if (linked && !ready)
  SizedBox(
  width: 12 * s,
  height: 12 * s,
  child:
  CircularProgressIndicator(strokeWidth: 2, color: color),
  )
  else
  Icon(
  linked ? Icons.sensors_rounded : Icons.bluetooth_searching,
  size: 14 * s,
  color: color,
  ),
  SizedBox(width: 8 * s),
  Text(
  label,
  style: TextStyle(
  fontSize: 11 * s,
  fontWeight: FontWeight.w800,
  letterSpacing: 1.0,
  color: palette.textPrimary,
  ),
  ),
  ],
  ),
  ),
  );
  }
}

/// Live server-connection pill for the guest entry screen.
///
/// On mount it probes the configured address; when nothing answers it sweeps
/// the /24 and adopts the first XSIGHT backend it finds — the same contract as
/// the splash, repeated here because this is the screen a walk-up operator
/// actually stares at while things are being plugged in. Tapping forces a
/// rescan, which covers "I just started the server on the laptop".
class _ServerAutoConnectBadge extends StatefulWidget {
  const _ServerAutoConnectBadge({required this.scale});

  final double scale;

  @override
  State<_ServerAutoConnectBadge> createState() =>
      _ServerAutoConnectBadgeState();
}

class _ServerAutoConnectBadgeState extends State<_ServerAutoConnectBadge> {
  bool _scanning = false;
  double _progress = 0;
  String? _found; // "192.168.1.10:8000"
  StreamSubscription<XSServerCandidate>? _sub;

  @override
  void initState() {
    super.initState();
    _autoConnect();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  /// Quick probe of whatever is configured right now; sweep only when that
  /// fails. A kiosk whose address has not changed should not pay for a scan.
  Future<void> _autoConnect() async {
    final url = XSSettings.I.backendUrl;
    final uri = Uri.tryParse(url);
    if (uri != null && uri.host.isNotEmpty) {
      final candidate = await XSServerDiscovery.probe(
        uri.host,
        uri.hasPort ? uri.port : 8000,
      );
      if (!mounted) return;
      if (candidate != null) {
        setState(() {
          _found = '${candidate.host}:${candidate.port}';
          _scanning = false;
        });
        return;
      }
    }
    await _scan();
  }

  Future<void> _scan() async {
    await _sub?.cancel();
    if (!mounted) return;
    setState(() {
      _scanning = true;
      _progress = 0;
      _found = null;
    });

    XSServerCandidate? found;
    _sub = XSServerDiscovery.scan(
      preferred: XSSettings.I.backendUrl,
      onProgress: (probed, total) {
        if (!mounted || total == 0) return;
        setState(() => _progress = probed / total);
      },
    ).listen(
      (candidate) async {
        if (found != null) return; // first answer wins
        found = candidate;
        await _sub?.cancel();
        // Adopt before displaying so the rest of the app (clients read
        // XSSettings lazily) talks to the server we just confirmed.
        await XSSettings.I.setBackendUrl(candidate.baseUrl);
        if (!mounted) return;
        setState(() {
          _found = '${candidate.host}:${candidate.port}';
          _scanning = false;
        });
      },
      onDone: () {
        if (!mounted || found != null) return;
        setState(() => _scanning = false);
      },
      onError: (Object e) {
        if (!mounted) return;
        setState(() => _scanning = false);
      },
      cancelOnError: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    final s = widget.scale;
    final connected = _found != null;
    final color = connected ? XSColors.accentGreen : XSColors.teal;

    return InkWell(
      onTap: _scanning ? null : _scan,
      borderRadius: BorderRadius.circular(XSRadius.pill),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 14 * s, vertical: 6 * s),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(XSRadius.pill),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_scanning)
              SizedBox(
                width: 12 * s,
                height: 12 * s,
                child: CircularProgressIndicator(strokeWidth: 2, color: color),
              )
            else
              Icon(
                connected ? Icons.dns_rounded : Icons.wifi_find,
                size: 14 * s,
                color: color,
              ),
            SizedBox(width: 8 * s),
            Text(
              connected
                  ? 'SERVER $_found'
                  : _scanning
                      ? 'FINDING SERVER… ${(_progress * 100).round()}%'
                      : 'NO SERVER · TAP TO RESCAN',
              style: TextStyle(
                fontSize: 11 * s,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.0,
                color: palette.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
