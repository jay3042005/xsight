import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../../core/sensor/esp32_serial_client.dart';
import '../../core/theme/xs_colors.dart';
import '../../core/theme/xs_radius.dart';
import '../../core/theme/xs_scale.dart';
import '../../core/theme/xs_spacing.dart';
import '../../core/theme/xs_shadows.dart';
import '../../core/theme/xs_typography.dart';
import '../components/xs_card.dart';
import '../components/xs_chip.dart';
import '../../state/xs_settings.dart';
import '../../state/kiosk_patient_state.dart';
import 'kiosk_analytics_screen.dart';
import 'kiosk_notifications_screen.dart';
import 'kiosk_patient_list_screen.dart';
import 'kiosk_report_screen.dart';

/// Kiosk Dashboard Screen — staff-facing command center.
/// Displays real-time patient metrics, server health telemetry, hardware status,
/// recent screening activity stream, and X-ray findings distribution.
class KioskDashboardScreen extends StatefulWidget {
  /// Opens the module navigator. Same handler as the module's OK button, so
  /// staff can start a session by touch when no hardware is attached.
  final VoidCallback? onBegin;

  /// Attached to the navigator call-to-action card so the shell's module menu
  /// can grow out of it, matching the guest dashboard's START disc.
  final GlobalKey? startKey;

  /// Open the patient picker. Staff-only, so the shell owns it.
  final VoidCallback? onChangePatient;

  /// Hand the kiosk back to a walk-up guest. The mirror of the guest
  /// dashboard's STAFF LOGIN, and placed in the same bottom-right corner so the
  /// way out sits where the way in did.
  ///
  /// This screen confirms first — the control lives in a row of navigation
  /// launchers and ending the session discards the current readings — so the
  /// callback fires only on a deliberate yes and must not prompt again.
  final VoidCallback? onEndSession;

  const KioskDashboardScreen({
    super.key,
    this.onBegin,
    this.startKey,
    this.onChangePatient,
    this.onEndSession,
  });

  @override
  State<KioskDashboardScreen> createState() => _KioskDashboardScreenState();
}

typedef KioskDashboard = KioskDashboardScreen;

class _KioskDashboardScreenState extends State<KioskDashboardScreen>
    with SingleTickerProviderStateMixin {
  Timer? _clockTimer;
  Timer? _refreshTimer;
  DateTime _now = DateTime.now();

  int _totalPatients = 0;
  int _totalXrays = 0;
  int _totalConsults = 0;
  int _unreadAlerts = 0;
  List<dynamic> _recentNotifications = [];
  List<dynamic> _diseaseDistribution = [];
  bool _loading = true;
  bool _connected = false;
  bool _xrayModelOk = false;
  String? _error;

  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);

    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
    _refreshTimer = Timer.periodic(const Duration(seconds: 15), (_) => _load());
    _load();
  }

  Future<void> _load() async {
    final base = XSSettings.I.backendUrl;
    if (base.isEmpty) {
      if (!mounted) return;
      setState(() {
        _connected = false;
        _loading = false;
        _error = 'No server configured. Set backend IP in Settings.';
      });
      return;
    }
    try {
      final analyticsResp = await http
          .get(Uri.parse('$base/emr/analytics'))
          .timeout(const Duration(seconds: 5));

      final notifResp = await http
          .get(Uri.parse('$base/emr/notifications?limit=10'))
          .timeout(const Duration(seconds: 5));

      bool xrayOk = false;
      try {
        final healthResp = await http
            .get(Uri.parse('$base/health'))
            .timeout(const Duration(seconds: 5));
        if (healthResp.statusCode == 200) {
          final health = jsonDecode(healthResp.body);
          final xray = health['xray_local'];
          xrayOk = xray is Map && xray['available'] == true;
        }
      } catch (_) {
        // Non-fatal: leave xrayOk false.
      }

      if (!mounted) return;
      if (analyticsResp.statusCode == 200 && notifResp.statusCode == 200) {
        final analytics = jsonDecode(analyticsResp.body);
        final notifs = jsonDecode(notifResp.body);
        setState(() {
          _totalPatients = analytics['total_patients'] ?? 0;
          _totalXrays = analytics['total_xrays'] ?? 0;
          _totalConsults = analytics['total_consultations'] ?? 0;
          _unreadAlerts = analytics['unread_notifications'] ?? 0;
          _diseaseDistribution = analytics['disease_distribution'] ?? [];
          _recentNotifications = notifs;
          _connected = true;
          _xrayModelOk = xrayOk;
          _loading = false;
          _error = null;
        });
      } else {
        setState(() {
          _connected = false;
          _loading = false;
          _error = 'Server responded ${analyticsResp.statusCode}';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _connected = false;
        _loading = false;
        _error = 'Connection failed: $e';
      });
    }
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    _refreshTimer?.cancel();
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    final timeStr =
        '${_now.hour.toString().padLeft(2, '0')}:'
        '${_now.minute.toString().padLeft(2, '0')}:'
        '${_now.second.toString().padLeft(2, '0')}';
    final dateStr =
        '${_now.day.toString().padLeft(2, '0')}/'
        '${_now.month.toString().padLeft(2, '0')}/'
        '${_now.year}';

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        XSSpacing.lg,
        XSSpacing.md,
        XSSpacing.lg,
        XSSpacing.md,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final narrow = constraints.maxWidth < 900;
          return Column(
            children: [
              _buildHeader(palette, timeStr, dateStr),
              if (!_connected && !_loading && _error != null) ...[
                const SizedBox(height: XSSpacing.xs),
                _errorBanner(palette, _error!),
              ],
              const SizedBox(height: XSSpacing.md),
              Expanded(
                child: narrow ? _narrowBody(palette) : _wideBody(palette),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _errorBanner(XSPalette palette, String message) {
    final s = XSScale.factor;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(
        horizontal: XSSpacing.md * s,
        vertical: XSSpacing.sm * s,
      ),
      decoration: BoxDecoration(
        color: XSColors.accentRed.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(XSRadius.md),
        border: Border.all(color: XSColors.accentRed.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 19 * s, color: XSColors.accentRed),
          SizedBox(width: 8 * s),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: XSColors.accentRed,
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildStatCards(XSPalette palette) => [
    _statCard(
      palette: palette,
      label: 'TOTAL PATIENTS',
      value: '$_totalPatients',
      subtitle: 'Registered EMR records',
      icon: Icons.people_alt_outlined,
      color: XSColors.moduleXray,
    ),
    _statCard(
      palette: palette,
      label: 'X-RAYS SCREENED',
      value: '$_totalXrays',
      subtitle: 'Analyzed by AI classifier',
      icon: Icons.medical_services_outlined,
      color: XSColors.accentGreen,
    ),
    _statCard(
      palette: palette,
      label: 'CDSS ASSESSMENTS',
      value: '$_totalConsults',
      subtitle: 'Decision support triage',
      icon: Icons.psychology_outlined,
      color: XSColors.moduleSummary,
    ),
    _statCard(
      palette: palette,
      label: 'CLINICAL ALERTS',
      value: '$_unreadAlerts',
      subtitle: 'Unread notifications',
      icon: Icons.notifications_active_outlined,
      color: _unreadAlerts > 0 ? XSColors.accentRed : XSColors.sage,
      alarming: _unreadAlerts > 0,
    ),
  ];

  Widget _wideBody(XSPalette palette) {
    final cards = _buildStatCards(palette);
    final s = XSScale.factor;
    Widget statRow() => Row(
      children: [
        for (var i = 0; i < cards.length; i++) ...[
          if (i > 0) SizedBox(width: XSSpacing.md * s),
          Expanded(child: cards[i]),
        ],
      ],
    );

    Widget middleRow() => Row(
      children: [
        Expanded(flex: 3, child: _activityCard(palette)),
        SizedBox(width: XSSpacing.md * s),
        Expanded(
          flex: 2,
          child: LayoutBuilder(
            builder: (context, c) {
              // The two summary cards are intrinsically sized, so their column
              // scrolls independently instead of squeezing the distribution
              // chart below its usable height.
              final chartHeight = 180 * s;
              return SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: c.maxHeight),
                  child: Column(
                    children: [
                      _ctaCard(palette),
                      SizedBox(height: XSSpacing.sm * s),
                      _healthCard(palette),
                      SizedBox(height: XSSpacing.sm * s),
                      SizedBox(
                        height: chartHeight,
                        child: _diseaseCard(palette),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxHeight < 560) {
          // Xiaomi Pad 6 landscape leaves roughly 525 logical pixels here
          // after the app header. Give each dashboard section a stable height
          // and let the page scroll instead of compressing every card.
          return SingleChildScrollView(
            child: Column(
              children: [
                SizedBox(height: 148 * s, child: statRow()),
                SizedBox(height: XSSpacing.md * s),
                SizedBox(height: 310 * s, child: middleRow()),
                SizedBox(height: XSSpacing.sm * s),
                _staffToolsRow(palette),
              ],
            ),
          );
        }

        return Column(
          children: [
            Expanded(flex: 3, child: statRow()),
            SizedBox(height: XSSpacing.md * s),
            Expanded(flex: 7, child: middleRow()),
            SizedBox(height: XSSpacing.sm * s),
            _staffToolsRow(palette),
          ],
        );
      },
    );
  }

  Widget _narrowBody(XSPalette palette) {
    final cards = _buildStatCards(palette);
    final s = XSScale.factor;
    return SingleChildScrollView(
      child: Column(
        children: [
          Row(
            children: [
              Expanded(child: cards[0]),
              SizedBox(width: XSSpacing.md * s),
              Expanded(child: cards[1]),
            ],
          ),
          SizedBox(height: XSSpacing.md * s),
          Row(
            children: [
              Expanded(child: cards[2]),
              SizedBox(width: XSSpacing.md * s),
              Expanded(child: cards[3]),
            ],
          ),
          SizedBox(height: XSSpacing.md * s),
          _ctaCard(palette),
          SizedBox(height: XSSpacing.md * s),
          _staffToolsRow(palette),
          SizedBox(height: XSSpacing.md * s),
          SizedBox(height: 320 * s, child: _activityCard(palette)),
          SizedBox(height: XSSpacing.md * s),
          _healthCard(palette),
          SizedBox(height: XSSpacing.md * s),
          SizedBox(height: 280 * s, child: _diseaseCard(palette)),
        ],
      ),
    );
  }

  /// Bottom action bar: touch-only entry points for the staff screens that have
  /// no hardware button mapping, plus the exit from staff mode.
  ///
  /// The module's menu indices are fixed by the firmware (7 entries, mapped in
  /// `kiosk_shell`), so adding these to the radial navigator would desync
  /// `MENU_INDEX` / `STATE:n`. Reaching them by touch from the staff dashboard
  /// keeps that contract intact.
  Widget _staffToolsRow(XSPalette palette) {
    final s = XSScale.factor;
    final tools = [
      (
        label: 'Patients',
        icon: Icons.people_alt_outlined,
        color: XSColors.moduleXray,
        builder: () => const KioskPatientListScreen(),
      ),
      (
        label: 'Reports',
        icon: Icons.description_outlined,
        color: XSColors.moduleSummary,
        builder: () => const KioskReportScreen(),
      ),
      (
        label: 'Analytics',
        icon: Icons.insights_outlined,
        color: XSColors.moduleSteth,
        builder: () => const KioskAnalyticsScreen(),
      ),
      (
        label: 'Alerts',
        icon: Icons.notifications_active_outlined,
        color: _unreadAlerts > 0 ? XSColors.accentRed : XSColors.sage,
        builder: () => const KioskNotificationsScreen(),
      ),
    ];

    final endSession = widget.onEndSession == null
        ? null
        : _endSessionButton(s);

    final launchers = <Widget>[
      for (var i = 0; i < tools.length; i++) ...[
        if (i > 0) SizedBox(width: XSSpacing.sm * s),
        Expanded(
          child: _StaffToolButton(
            label: tools[i].label,
            icon: tools[i].icon,
            color: tools[i].color,
            badge: tools[i].label == 'Alerts' && _unreadAlerts > 0
                ? '$_unreadAlerts'
                : null,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => _StaffToolPage(
                  title: tools[i].label,
                  accent: tools[i].color,
                  child: tools[i].builder(),
                ),
              ),
            ),
          ),
        ),
      ],
    ];

    return LayoutBuilder(
      builder: (context, c) {
        if (endSession == null) return Row(children: launchers);

        // A launcher needs roughly 150*s to show its label without truncating
        // (icon, gap, padding, and the longest word, "Analytics"). If squeezing
        // the exit button onto the same line would take them below that, give it
        // its own line instead: five items fit on a 1280 panel and not on an 800
        // one, and four buttons reading "P…" "R…" "A…" "A…" is a worse trade
        // than one extra row on a surface that has the height to spare.
        final inlineNeeds =
            4 * 150 * s + 3 * XSSpacing.sm * s + 168 * s + XSSpacing.md * s;
        if (c.maxWidth >= inlineNeeds) {
          return Row(
            children: [
              ...launchers,
              SizedBox(width: XSSpacing.md * s),
              endSession,
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: launchers),
            SizedBox(height: XSSpacing.sm * s),
            // Right-aligned, matching where STAFF LOGIN sits in the guest
            // dashboard's footer: the mode switch is always in that corner.
            Row(children: [const Spacer(), endSession]),
          ],
        );
      },
    );
  }

  /// The exit from staff mode.
  ///
  /// A fixed width rather than a fifth [Expanded]: an equal share of the row
  /// would read as a fifth destination, and the red accent against four
  /// cool-toned launchers is the only thing marking it as an action instead of a
  /// place.
  Widget _endSessionButton(double s) => SizedBox(
    width: 168 * s,
    child: _StaffToolButton(
      label: 'End Session',
      icon: Icons.logout_rounded,
      color: XSColors.accentRed,
      onTap: _confirmEndSession,
    ),
  );

  /// Confirms before handing the panel back to the public.
  ///
  /// Worth a stop: the tap target sits next to four harmless launchers, and
  /// leaving staff mode clears the session's readings along with the EMR link,
  /// so a mis-tap mid-assessment would cost the whole set.
  Future<void> _confirmEndSession() async {
    final palette = XSPalette.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: palette.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(XSRadius.lg),
        ),
        title: Row(
          children: [
            const Icon(
              Icons.logout_rounded,
              color: XSColors.accentRed,
              size: 24,
            ),
            const SizedBox(width: 10),
            Text(
              'End staff session?',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: palette.textPrimary,
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 340,
          child: Text(
            'The kiosk returns to walk-in guest mode. The linked patient is '
            'unlinked, this session’s readings are cleared, and staff tools '
            'and Settings will need the PIN again.',
            style: TextStyle(fontSize: 15, color: palette.textSecondary),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Stay signed in'),
          ),
          ElevatedButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.logout_rounded, size: 18),
            label: const Text('End session'),
            style: ElevatedButton.styleFrom(
              backgroundColor: XSColors.accentRed,
              foregroundColor: Colors.white,
            ),
          ),
        ],
      ),
    );
    if (ok == true && mounted) widget.onEndSession?.call();
  }

  // ─── HEADER BAR ──────────────────────────────────────────────────
  Widget _buildHeader(XSPalette palette, String timeStr, String dateStr) {
    final esp32 = Esp32SerialClient.shared;
    final s = XSScale.factor;

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: XSSpacing.lg * s,
        vertical: (XSSpacing.sm + 2) * s,
      ),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(XSRadius.lg),
        boxShadow: XSShadows.soft(palette),
        border: Border.all(color: palette.divider),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 1100;
          final serverColor = _connected
              ? XSColors.accentGreen.withValues(
                  alpha: 0.55 + _pulseController.value * 0.45,
                )
              : XSColors.accentRed;
          final moduleLabel = esp32.connected
              ? (esp32.deviceReady ? 'MODULE READY' : 'MODULE CONNECTED')
              : 'NO MODULE';
          final moduleColor = esp32.connected
              ? XSColors.moduleXray
              : XSColors.accentOrange;

          return Row(
            children: [
              Container(
                width: 42 * s,
                height: 42 * s,
                decoration: BoxDecoration(
                  color: XSColors.moduleXray.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(11 * s),
                ),
                child: Icon(
                  Icons.monitor_heart,
                  size: 25 * s,
                  color: XSColors.moduleXray,
                ),
              ),
              SizedBox(width: XSSpacing.sm * s),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'XSIGHT',
                      style: TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.5,
                        color: palette.textPrimary,
                      ),
                    ),
                    if (!compact)
                      Text(
                        'THORACIC ASSESSMENT COMMAND CENTER',
                        style: XSTypography.eyebrow(
                          palette.textSecondary,
                        ).copyWith(fontSize: 13),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              if (widget.onChangePatient != null) ...[
                Flexible(
                  flex: 2,
                  child: ListenableBuilder(
                    listenable: KioskPatientSession.I,
                    builder: (context, _) =>
                        _PatientContextChip(onTap: widget.onChangePatient!),
                  ),
                ),
                SizedBox(width: XSSpacing.sm * s),
              ],
              AnimatedBuilder(
                animation: _pulseController,
                builder: (context, _) => compact
                    ? _headerStatusIcon(
                        label: _connected ? 'Server online' : 'Server offline',
                        icon: _connected
                            ? Icons.cloud_done_outlined
                            : Icons.cloud_off,
                        color: serverColor,
                      )
                    : XSChip(
                        label: _connected ? 'SERVER ONLINE' : 'SERVER OFFLINE',
                        icon: _connected
                            ? Icons.cloud_done_outlined
                            : Icons.cloud_off,
                        color: serverColor,
                        filled: !_connected,
                      ),
              ),
              SizedBox(width: XSSpacing.xs * s),
              if (compact)
                _headerStatusIcon(
                  label: moduleLabel,
                  icon: esp32.connected ? Icons.usb : Icons.usb_off,
                  color: moduleColor,
                )
              else
                XSChip(
                  label: moduleLabel,
                  icon: esp32.connected ? Icons.usb : Icons.usb_off,
                  color: moduleColor,
                ),
              SizedBox(width: compact ? XSSpacing.sm * s : XSSpacing.md * s),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    compact ? timeStr.substring(0, 5) : timeStr,
                    style: XSTypography.hero(
                      palette.textPrimary,
                      fontSize: compact ? 21 : 26,
                    ),
                  ),
                  if (!compact)
                    Text(
                      dateStr,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: palette.textSecondary,
                      ),
                    ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _headerStatusIcon({
    required String label,
    required IconData icon,
    required Color color,
  }) {
    final s = XSScale.factor;
    return Tooltip(
      message: label,
      child: Semantics(
        label: label,
        child: Container(
          width: 38 * s,
          height: 38 * s,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10 * s),
            border: Border.all(color: color.withValues(alpha: 0.35)),
          ),
          child: Icon(icon, size: 20 * s, color: color),
        ),
      ),
    );
  }

  // ─── STAT CARD ─────────────────────────────────────────────────
  Widget _statCard({
    required XSPalette palette,
    required String label,
    required String value,
    required String subtitle,
    required IconData icon,
    required Color color,
    bool alarming = false,
  }) {
    final s = XSScale.factor;
    return XSCard(
      padding: EdgeInsets.all(XSSpacing.sm * s),
      soft: true,
      // Only the alert card lights up, and only when there is an alert.
      glow: alarming ? color : null,
      borderColor: alarming ? color : palette.divider,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final valueWidget = FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(value, style: XSTypography.hero(color, fontSize: 46)),
          );
          return Column(
            mainAxisSize: constraints.hasBoundedHeight
                ? MainAxisSize.max
                : MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 34 * s,
                    height: 34 * s,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10 * s),
                    ),
                    child: Icon(icon, size: 19 * s, color: color),
                  ),
                  SizedBox(width: 8 * s),
                  Expanded(
                    child: Text(
                      label,
                      style: XSTypography.eyebrow(color).copyWith(fontSize: 13),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              if (constraints.hasBoundedHeight)
                Expanded(child: valueWidget)
              else
                SizedBox(height: 52 * s, child: valueWidget),
              Text(
                subtitle,
                style: TextStyle(fontSize: 13, color: palette.textSecondary),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          );
        },
      ),
    );
  }

  // ─── ACTIVITY CARD ─────────────────────────────────────────────
  Widget _activityCard(XSPalette palette) {
    final s = XSScale.factor;
    return XSCard(
      padding: EdgeInsets.all(XSSpacing.md * s),
      soft: true,
      borderColor: palette.divider,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.dynamic_feed,
                size: 18 * s,
                color: palette.textSecondary,
              ),
              SizedBox(width: 6 * s),
              Text(
                'LIVE CLINICAL FEED',
                style: XSTypography.eyebrow(
                  palette.textSecondary,
                ).copyWith(fontSize: 13),
              ),
              const Spacer(),
              XSChip(
                label: '${_recentNotifications.length} events',
                color: palette.textSecondary,
              ),
            ],
          ),
          SizedBox(height: XSSpacing.sm * s),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                : _recentNotifications.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.inbox_outlined,
                          size: 48 * s,
                          color: palette.textSecondary.withValues(alpha: 0.3),
                        ),
                        SizedBox(height: XSSpacing.sm * s),
                        Text(
                          'No recent activity',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: palette.textSecondary,
                          ),
                        ),
                        SizedBox(height: 2 * s),
                        Text(
                          'Activity appears here as patients are assessed',
                          style: TextStyle(
                            fontSize: 13,
                            color: palette.textSecondary.withValues(alpha: 0.7),
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.separated(
                    itemCount: _recentNotifications.length.clamp(0, 10),
                    separatorBuilder: (_, _) =>
                        Divider(height: 1, color: palette.divider),
                    itemBuilder: (ctx, i) {
                      final n = _recentNotifications[i];
                      final severity = n['severity'] ?? 'info';
                      final color = severity == 'critical'
                          ? XSColors.accentRed
                          : severity == 'high'
                          ? XSColors.accentOrange
                          : XSColors.moduleXray;
                      final title = (n['title'] ?? '').toLowerCase();
                      final icon =
                          title.contains('xray') || title.contains('x-ray')
                          ? Icons.medical_services
                          : title.contains('patient')
                          ? Icons.person
                          : title.contains('lung') || title.contains('sound')
                          ? Icons.hearing
                          : title.contains('cdss') || title.contains('assess')
                          ? Icons.psychology
                          : title.contains('vital')
                          ? Icons.favorite
                          : title.contains('alert') ||
                                title.contains('critical')
                          ? Icons.warning
                          : Icons.notifications;
                      final urgent = severity == 'critical';
                      return Padding(
                        padding: EdgeInsets.symmetric(vertical: 9 * s),
                        child: Row(
                          children: [
                            Container(
                              width: 38 * s,
                              height: 38 * s,
                              decoration: BoxDecoration(
                                color: color.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(10 * s),
                                boxShadow: urgent
                                    ? XSShadows.glow(color, intensity: 0.5)
                                    : null,
                              ),
                              child: Icon(icon, size: 19 * s, color: color),
                            ),
                            SizedBox(width: 10 * s),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    n['message'] ?? n['title'] ?? '',
                                    style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                      color: palette.textPrimary,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  if (n['title'] != null &&
                                      n['message'] != null)
                                    Text(
                                      n['title'],
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
                            SizedBox(width: 8 * s),
                            Text(
                              _hhmm(n['created_at']),
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
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

  // ─── HEALTH TELEMETRY CARD ──────────────────────────────────────
  Widget _healthCard(XSPalette palette) {
    final s = XSScale.factor;
    return XSCard(
      padding: EdgeInsets.all(XSSpacing.md * s),
      soft: true,
      borderColor: palette.divider,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            children: [
              Icon(
                Icons.health_and_safety_outlined,
                size: 17 * s,
                color: palette.textSecondary,
              ),
              SizedBox(width: 5 * s),
              Text(
                'SYSTEM TELEMETRY',
                style: XSTypography.eyebrow(
                  palette.textSecondary,
                ).copyWith(fontSize: 13),
              ),
            ],
          ),
          SizedBox(height: XSSpacing.sm * s),
          Wrap(
            spacing: XSSpacing.md * s,
            runSpacing: XSSpacing.xs * s,
            children: [
              _compactStatus(palette, 'FastAPI', _connected),
              _compactStatus(palette, 'EMR Database', _connected),
              _compactStatus(palette, 'X-Ray Model', _xrayModelOk),
            ],
          ),
        ],
      ),
    );
  }

  Widget _compactStatus(XSPalette palette, String label, bool ok) {
    final s = XSScale.factor;
    final color = ok ? XSColors.accentGreen : XSColors.accentRed;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 11 * s,
          height: 11 * s,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            boxShadow: XSShadows.glow(color, intensity: 0.35),
          ),
        ),
        SizedBox(width: 6 * s),
        Text(
          label,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: palette.textPrimary,
          ),
        ),
      ],
    );
  }

  // ─── HARDWARE CALL TO ACTION ─────────────────────────────────────
  Widget _ctaCard(XSPalette palette) {
    final esp32 = Esp32SerialClient.shared;
    final ready = esp32.connected && esp32.deviceReady;
    final activeColor = ready ? XSColors.moduleXray : XSColors.accentOrange;
    final s = XSScale.factor;

    final card = Container(
      key: widget.startKey,
      padding: EdgeInsets.all(XSSpacing.md * s),
      decoration: BoxDecoration(
        color: activeColor.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(XSRadius.lg),
        border: Border.all(
          color: activeColor.withValues(alpha: 0.3),
          width: 1.5,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 48 * s,
            height: 48 * s,
            decoration: BoxDecoration(
              color: activeColor.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(
              ready ? Icons.adjust_rounded : Icons.usb_off,
              size: 26 * s,
              color: activeColor,
            ),
          ),
          SizedBox(width: XSSpacing.md * s),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ready ? 'Open the module navigator' : 'Connect XSIGHT Module',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: palette.textPrimary,
                  ),
                ),
                SizedBox(height: 2 * s),
                Text(
                  ready
                      // Touch works too — the navigator's on-screen dock mirrors
                      // the module's four buttons.
                      ? 'Tap here, or press OK on the module'
                      : 'Plug in via USB-C, or tap here to browse modules',
                  style: TextStyle(fontSize: 13, color: palette.textSecondary),
                ),
              ],
            ),
          ),
          if (widget.onBegin != null)
            Icon(Icons.chevron_right_rounded, size: 30 * s, color: activeColor),
        ],
      ),
    );

    if (widget.onBegin == null) return card;
    return Semantics(
      button: true,
      label: 'Open module navigator',
      child: GestureDetector(onTap: widget.onBegin, child: card),
    );
  }

  // ─── DISEASE FINDINGS DISTRIBUTION ──────────────────────────────
  Widget _diseaseCard(XSPalette palette) {
    final s = XSScale.factor;
    return XSCard(
      padding: EdgeInsets.all(XSSpacing.md * s),
      soft: true,
      borderColor: palette.divider,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.bar_chart_rounded,
                size: 18 * s,
                color: palette.textSecondary,
              ),
              SizedBox(width: 6 * s),
              Expanded(
                child: Text(
                  'PATHOLOGY DISTRIBUTION',
                  style: XSTypography.eyebrow(
                    palette.textSecondary,
                  ).copyWith(fontSize: 13),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          SizedBox(height: XSSpacing.sm * s),
          Expanded(
            child: _diseaseDistribution.isEmpty
                ? Center(
                    child: Text(
                      'No X-ray findings recorded yet',
                      style: TextStyle(
                        fontSize: 14,
                        color: palette.textSecondary.withValues(alpha: 0.7),
                      ),
                    ),
                  )
                : ListView.builder(
                    itemCount: _diseaseDistribution.length,
                    itemBuilder: (ctx, i) {
                      final d = _diseaseDistribution[i];
                      final count = (d['count'] as num?)?.toInt() ?? 0;
                      final maxCount = _diseaseDistribution.fold<int>(1, (
                        m,
                        r,
                      ) {
                        final c = (r['count'] as num?)?.toInt() ?? 0;
                        return c > m ? c : m;
                      });
                      final label = (d['prediction'] ?? '?').toUpperCase();
                      final color = _diseaseColor(d['prediction'] ?? '');
                      return Padding(
                        padding: EdgeInsets.symmetric(vertical: 5 * s),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 105 * s,
                              child: Text(
                                label,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w800,
                                  color: color,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Expanded(
                              // Animated so the bar grows in on load rather
                              // than appearing fully formed.
                              child: TweenAnimationBuilder<double>(
                                tween: Tween(begin: 0, end: count / maxCount),
                                duration: const Duration(milliseconds: 700),
                                curve: Curves.easeOutCubic,
                                builder: (context, v, _) => Container(
                                  height: 16 * s,
                                  decoration: BoxDecoration(
                                    color: palette.highlight,
                                    borderRadius: BorderRadius.circular(
                                      XSRadius.pill,
                                    ),
                                  ),
                                  child: FractionallySizedBox(
                                    alignment: Alignment.centerLeft,
                                    widthFactor: v.clamp(0.0, 1.0),
                                    child: Container(
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(
                                          colors: [
                                            color.withValues(alpha: 0.65),
                                            color,
                                          ],
                                        ),
                                        borderRadius: BorderRadius.circular(
                                          XSRadius.pill,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            SizedBox(width: 8 * s),
                            Text(
                              '$count',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                                color: palette.textPrimary,
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

  String _hhmm(dynamic raw) {
    final dt = DateTime.tryParse(raw?.toString() ?? '');
    if (dt == null) return '';
    final local = dt.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }

  Color _diseaseColor(String disease) {
    switch (disease.toLowerCase()) {
      case 'pneumonia':
        return XSColors.accentRed;
      case 'tuberculosis':
        return XSColors.accentOrange;
      case 'effusion':
        return XSColors.moduleXray;
      case 'cardiomegaly':
        return XSColors.moduleSummary;
      case 'mass':
        return const Color(0xFF4E342E);
      case 'normal':
        return XSColors.accentGreen;
      default:
        return XSColors.sage;
    }
  }
}

/// Large square launcher for a staff-only tool.
class _StaffToolButton extends StatefulWidget {
  final String label;
  final IconData icon;
  final Color color;
  final String? badge;
  final VoidCallback onTap;

  const _StaffToolButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
    this.badge,
  });

  @override
  State<_StaffToolButton> createState() => _StaffToolButtonState();
}

class _StaffToolButtonState extends State<_StaffToolButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    final s = XSScale.factor;

    return Semantics(
      button: true,
      label: widget.label,
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapCancel: () => setState(() => _pressed = false),
        onTapUp: (_) => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _pressed ? 0.97 : 1.0,
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            height: 64 * s,
            padding: EdgeInsets.symmetric(horizontal: XSSpacing.md * s),
            decoration: BoxDecoration(
              color: palette.surface,
              borderRadius: BorderRadius.circular(XSRadius.lg),
              border: Border.all(color: widget.color.withValues(alpha: 0.30)),
              boxShadow: _pressed
                  ? XSShadows.pressed(palette)
                  : [
                      if (widget.badge != null)
                        ...XSShadows.glow(widget.color, intensity: 0.5),
                      ...XSShadows.soft(palette),
                    ],
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(widget.icon, size: 24 * s, color: widget.color),
                SizedBox(width: 8 * s),
                Flexible(
                  child: Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: palette.textPrimary,
                    ),
                  ),
                ),
                if (widget.badge != null) ...[
                  SizedBox(width: 6 * s),
                  XSChip(
                    label: widget.badge!,
                    color: widget.color,
                    filled: true,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Scaffold wrapper giving a pushed staff tool a titled bar and back button.
class _StaffToolPage extends StatelessWidget {
  final String title;
  final Color accent;
  final Widget child;

  const _StaffToolPage({
    required this.title,
    required this.accent,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    final s = XSScale.factor;

    return XSModuleAccent(
      color: accent,
      child: Scaffold(
        backgroundColor: palette.surface,
        appBar: AppBar(
          backgroundColor: palette.surface,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          toolbarHeight: 64 * s,
          leading: IconButton(
            iconSize: 26 * s,
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          title: Row(
            children: [
              Container(
                width: 5 * s,
                height: 26 * s,
                decoration: BoxDecoration(
                  color: accent,
                  borderRadius: BorderRadius.circular(XSRadius.pill),
                ),
              ),
              SizedBox(width: 10 * s),
              Text(
                title,
                style: TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w800,
                  color: palette.textPrimary,
                ),
              ),
            ],
          ),
        ),
        body: SafeArea(top: false, child: child),
      ),
    );
  }
}

/// Header chip naming the patient the session will file readings against.
///
/// Tapping it reopens the picker. Deliberately loud when no patient is linked:
/// staff collecting sensor readings into a guest session lose them from the EMR,
/// and the only moment that is cheap to fix is before they start.
class _PatientContextChip extends StatelessWidget {
  final VoidCallback onTap;

  const _PatientContextChip({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final s = XSScale.factor;
    final session = KioskPatientSession.I;
    final unlinked = session.isGuest;

    final color = unlinked ? XSColors.accentOrange : XSColors.moduleXray;
    final label = unlinked
        ? 'NO PATIENT LINKED'
        : '${session.selectedPatient?['name'] ?? 'Patient'}';

    return Semantics(
      button: true,
      label: unlinked ? 'Select a patient' : 'Change patient: $label',
      child: Tooltip(
        message: unlinked
            ? 'Readings will not be saved to a record. Tap to pick a patient.'
            : 'Tap to change patient',
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(XSRadius.pill),
          child: Container(
            constraints: BoxConstraints(maxWidth: 260 * s),
            padding: EdgeInsets.symmetric(
              horizontal: XSSpacing.sm * s,
              vertical: 6 * s,
            ),
            decoration: BoxDecoration(
              color: color.withValues(alpha: unlinked ? 0.16 : 0.10),
              borderRadius: BorderRadius.circular(XSRadius.pill),
              border: Border.all(color: color.withValues(alpha: 0.45)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  unlinked
                      ? Icons.person_off_outlined
                      : Icons.folder_shared_outlined,
                  size: 16 * s,
                  color: color,
                ),
                SizedBox(width: 6 * s),
                Flexible(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.3,
                      color: color,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                SizedBox(width: 4 * s),
                Icon(Icons.expand_more, size: 16 * s, color: color),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
