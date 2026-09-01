import 'package:flutter/material.dart';
import '../../core/theme/xs_colors.dart';
import '../../core/theme/xs_radius.dart';
import '../../core/theme/xs_scale.dart';
import '../../core/theme/xs_shadows.dart';
import '../../core/theme/xs_spacing.dart';
import '../../core/theme/xs_typography.dart';
import '../../state/kiosk_patient_state.dart';
import '../components/xs_chip.dart';
import '../components/xs_stepper.dart';

/// Triage-intake idle screen — the kiosk's front door.
///
/// This is the *unauthenticated* station: an aide, or the patient with staff
/// present, collects readings here and nothing reaches the EMR until a clinician
/// logs in and links a record. The copy says so, because the promise is real —
/// `_initGuestPatient` leaves `id` null, so every upload from this session omits
/// `patient_id`.
///
/// One unmistakable target: a large pulsing START disc that both the module's
/// OK button and a fingertip can trigger. Below it, the assessment journey is
/// laid out as a labelled rail so the operator can see how many stations
/// remain. The hardware button map is demoted to a hint, because touch alone
/// must be enough to begin.
class KioskGuestDashboardScreen extends StatefulWidget {
  /// Starts the session. Wired to the same handler as the module's OK button;
  /// when null the disc is inert and only hardware can begin.
  final VoidCallback? onBegin;

  /// Jump straight to a station. Index matches the shell's menu order.
  final ValueChanged<int>? onOpenStation;

  /// Attached to the START disc's painted circle so the shell's module menu can
  /// grow out of it. The disc is the kiosk's one primary target, so the menu
  /// expanding from it keeps a single point of focus.
  final GlobalKey? startKey;

  /// Staff wants in. The shell owns the PIN prompt and the patient picker that
  /// follows, so this screen only reports the intent.
  final VoidCallback? onStaffLogin;

  /// User or operator wants to reset and exit the session back to guest entry.
  final VoidCallback? onStopSession;

  const KioskGuestDashboardScreen({
    super.key,
    this.onBegin,
    this.onOpenStation,
    this.startKey,
    this.onStaffLogin,
    this.onStopSession,
  });

  @override
  State<KioskGuestDashboardScreen> createState() =>
      _KioskGuestDashboardScreenState();
}

class _KioskGuestDashboardScreenState extends State<KioskGuestDashboardScreen> {
  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    final session = KioskPatientSession.I;
    final s = XSScale.factor;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        XSSpacing.lg,
        XSSpacing.md,
        XSSpacing.lg,
        XSSpacing.md,
      ),
      child: Column(
        children: [
          _buildHeader(palette, s),
          Expanded(
            child: Center(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final wide = constraints.maxWidth >= 760;
                  final start = _StartDisc(
                    onTap: widget.onBegin,
                    size: (wide ? 260 : 210) * s,
                    discKey: widget.startKey,
                  );
                  final copy = _buildCopy(palette, s, wide);

                  return SingleChildScrollView(
                    child: wide
                        ? Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              start,
                              SizedBox(width: XSSpacing.xxxl * s),
                              Flexible(child: copy),
                            ],
                          )
                        : Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              start,
                              SizedBox(height: XSSpacing.xl * s),
                              copy,
                            ],
                          ),
                  );
                },
              ),
            ),
          ),
          _buildJourney(session, s),
          SizedBox(height: XSSpacing.md * s),
          _buildFooter(context, session, s),
        ],
      ),
    );
  }

  // ─── Header ─────────────────────────────────────────────────────
  Widget _buildHeader(XSPalette palette, double s) {
    return Row(
      children: [
        Container(
          width: 44 * s,
          height: 44 * s,
          decoration: BoxDecoration(
            color: palette.accent.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(12 * s),
          ),
          child: Icon(
            Icons.monitor_heart_outlined,
            size: 24 * s,
            color: palette.accent,
          ),
        ),
        SizedBox(width: XSSpacing.sm * s),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'XSIGHT Triage Intake',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.3,
                  color: palette.textPrimary,
                ),
              ),
              Text(
                'Unauthenticated station',
                style: TextStyle(fontSize: 13, color: palette.textSecondary),
              ),
            ],
          ),
        ),
        const XSChip(
          label: 'TRIAGE INTAKE',
          icon: Icons.assignment_ind_outlined,
          color: Colors.amber,
        ),
        if (widget.onStopSession != null &&
            KioskPatientSession.I.isIntakeOpen) ...[
          SizedBox(width: 8 * s),
          InkWell(
            onTap: widget.onStopSession,
            borderRadius: BorderRadius.circular(XSRadius.sm),
            child: Container(
              padding: EdgeInsets.symmetric(
                horizontal: 10 * s,
                vertical: 6 * s,
              ),
              decoration: BoxDecoration(
                color: XSColors.accentRed.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(XSRadius.sm),
                border: Border.all(
                  color: XSColors.accentRed.withValues(alpha: 0.3),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.stop_circle_outlined,
                    size: 14 * s,
                    color: XSColors.accentRed,
                  ),
                  SizedBox(width: 4 * s),
                  Text(
                    'STOP SESSION',
                    style: TextStyle(
                      fontSize: 10.5 * s,
                      fontWeight: FontWeight.w800,
                      color: XSColors.accentRed,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  // ─── Hero copy / session status ─────────────────────────────────
  Widget _buildCopy(XSPalette palette, double s, bool wide) {
    final session = KioskPatientSession.I;
    // Once a session is open the invitation is over: show who it belongs to and
    // how far it has got, rather than asking a user who is already mid-assessment
    // to start one. Keyed on the session, not on a name or a reading — a session
    // where check-in was skipped has neither and is still underway, and showing
    // it "Start your screening" while END SESSION sat in the footer told the user
    // two different things at once.
    if (session.isIntakeOpen) {
      return _buildSessionStatus(palette, s, wide, session);
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: wide
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.center,
      children: [
        Text(
          'Start your\nscreening',
          textAlign: wide ? TextAlign.left : TextAlign.center,
          style: XSTypography.hero(
            palette.textPrimary,
            fontSize: (wide ? 52 : 38),
          ).copyWith(height: 1.05, letterSpacing: -1.5),
        ),
        SizedBox(height: XSSpacing.sm * s),
        Text(
          'Touch the button, or press OK on the module.',
          textAlign: wide ? TextAlign.left : TextAlign.center,
          style: TextStyle(
            fontSize: 17,
            height: 1.4,
            color: palette.textSecondary,
          ),
        ),
        SizedBox(height: XSSpacing.md * s),
        Wrap(
          spacing: XSSpacing.xs * s,
          runSpacing: XSSpacing.xs * s,
          alignment: wide ? WrapAlignment.start : WrapAlignment.center,
          children: const [
            XSChip(
              label: 'Not saved to records',
              icon: Icons.lock_outline,
              color: XSColors.sage,
            ),
            XSChip(
              label: 'About 5 minutes',
              icon: Icons.schedule,
              color: XSColors.teal,
            ),
          ],
        ),
      ],
    );
  }

  /// Live session panel: who this is, since when, how far along, and the values
  /// held so far.
  ///
  /// Reads straight from [KioskPatientSession] rather than caching, so a reading
  /// arriving from the ESP32 shows up on the next rebuild the shell's
  /// `ListenableBuilder` triggers.
  Widget _buildSessionStatus(
    XSPalette palette,
    double s,
    bool wide,
    KioskPatientSession session,
  ) {
    final started = session.sessionStartedAt;
    final measured = session.measuredStationCount;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: wide
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.center,
      children: [
        Text(
          'IN SESSION',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.6,
            color: palette.accent,
          ),
        ),
        SizedBox(height: 6 * s),
        Text(
          session.patientDisplayName,
          textAlign: wide ? TextAlign.left : TextAlign.center,
          style: XSTypography.hero(
            palette.textPrimary,
            fontSize: (wide ? 34 : 26),
          ).copyWith(height: 1.1, letterSpacing: -0.8),
        ),
        SizedBox(height: 4 * s),
        Text(
          [
            if (started != null) 'Started ${_hhmm(started)}',
            '$measured of 4 stations',
          ].join('  ·  '),
          textAlign: wide ? TextAlign.left : TextAlign.center,
          style: TextStyle(fontSize: 15, color: palette.textSecondary),
        ),
        SizedBox(height: XSSpacing.md * s),
        Wrap(
          spacing: XSSpacing.lg * s,
          runSpacing: XSSpacing.sm * s,
          alignment: wide ? WrapAlignment.start : WrapAlignment.center,
          children: [
            _StatusTile(
              label: 'HR',
              value: session.guestHr?.round().toString(),
              unit: 'bpm',
              color: XSColors.moduleVitals,
              simulated: session.guestVitalsSimulated,
            ),
            _StatusTile(
              label: 'SpO₂',
              value: session.guestSpo2?.round().toString(),
              unit: '%',
              color: XSColors.moduleVitals,
              simulated: session.guestVitalsSimulated,
            ),
            _StatusTile(
              label: 'Temp',
              value: session.guestTemp?.toStringAsFixed(1),
              unit: '°C',
              color: XSColors.moduleTemp,
              simulated: session.guestTempSimulated,
            ),
            _StatusTile(
              label: 'Lungs',
              value: session.guestStethFinding,
              color: XSColors.moduleSteth,
            ),
          ],
        ),
        SizedBox(height: XSSpacing.md * s),
        Wrap(
          spacing: XSSpacing.xs * s,
          runSpacing: XSSpacing.xs * s,
          alignment: wide ? WrapAlignment.start : WrapAlignment.center,
          children: [
            // Stated plainly next to the numbers, because this panel is the one
            // place a clinician sees the whole session at a glance and a
            // stood-in value must not read as a measurement.
            if (session.hasSimulatedReadings)
              const XSChip(
                label: 'DEMO DATA — no sensor',
                icon: Icons.science_outlined,
                color: Colors.amber,
              ),
            const XSChip(
              label: 'Not saved to records',
              icon: Icons.lock_outline,
              color: XSColors.sage,
            ),
          ],
        ),
      ],
    );
  }

  /// 24-hour clock, hand-formatted: `intl` is a declared dependency but nothing
  /// in `lib/` imports it, and one timestamp is not a reason to start.
  static String _hhmm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  // ─── Journey rail ───────────────────────────────────────────────
  Widget _buildJourney(KioskPatientSession session, double s) {
    // Order and colors match the shell's module list so a station looks the
    // same here as it does when opened.
    final steps = [
      XSStep(
        label: 'Pulse',
        icon: Icons.monitor_heart_outlined,
        color: XSColors.moduleVitals,
        done: session.hasGuestVitals,
        simulated: session.guestVitalsSimulated,
      ),
      XSStep(
        label: 'Temp',
        icon: Icons.thermostat_outlined,
        color: XSColors.moduleTemp,
        done: session.hasGuestTemp,
        simulated: session.guestTempSimulated,
      ),
      XSStep(
        label: 'Lungs',
        icon: Icons.graphic_eq,
        color: XSColors.moduleSteth,
        done: session.hasGuestSteth,
      ),
      XSStep(
        label: 'X-Ray',
        icon: Icons.medical_services_outlined,
        color: XSColors.moduleXray,
        done: session.hasGuestXray,
      ),
    ];

    // The guest orbit is ordered to match this rail (pulse → temp → lungs →
    // x-ray), so step index and orbit slot are the same number. Kept as an
    // explicit list rather than passing `i` straight through, because the two
    // orders agreeing is a fact about the shell's guest module list and not
    // something this screen can rely on silently — see the test that pins it.
    const menuIndexForStep = [0, 1, 2, 3];

    return XSStepper(
      steps: steps,
      onStepTap: widget.onOpenStation == null
          ? null
          : (i) => widget.onOpenStation!(menuIndexForStep[i]),
    );
  }

  // ─── Footer ─────────────────────────────────────────────────────
  Widget _buildFooter(
    BuildContext context,
    KioskPatientSession session,
    double s,
  ) {
    // Keyed on the session being open rather than on readings existing. A person
    // who checked in and then thought better of it had no way to clear their name
    // off the screen: the old condition only counted measurements, so the button
    // that ends a session was hidden for exactly the session that had produced
    // nothing to look at.
    return Row(
      children: [
        // Flexible so a narrow kiosk drops the hint's label rather than
        // overflowing the footer.
        const Flexible(child: _HardwareHint()),
        const Spacer(),
        if (session.isIntakeOpen) ...[
          _FooterButton(
            label: 'END SESSION',
            icon: Icons.logout,
            onTap: () {
              final stop = widget.onStopSession;
              if (stop != null) {
                stop();
              } else {
                session.resetGuestSession();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Session ended. Ready for the next person.'),
                    duration: Duration(seconds: 2),
                  ),
                );
              }
            },
          ),
          SizedBox(width: XSSpacing.sm * s),
        ],
        _FooterButton(
          label: 'STAFF LOGIN',
          icon: Icons.badge_outlined,
          onTap: widget.onStaffLogin,
        ),
      ],
    );
  }
}

/// One measured value on the session panel, or an em dash when its station has
/// not run yet.
///
/// Absence is rendered, not hidden: a walk-in and the staff member reviewing the
/// session both need to see which stations are still outstanding, and a missing
/// tile reads as "nothing to measure here".
class _StatusTile extends StatelessWidget {
  final String label;
  final String? value;
  final String? unit;
  final Color color;

  /// Drawn in the demo colour instead of the module colour, so a stood-in value
  /// is distinguishable from a measured one without reading the chip below.
  final bool simulated;

  const _StatusTile({
    required this.label,
    required this.value,
    this.unit,
    required this.color,
    this.simulated = false,
  });

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    final s = XSScale.factor;
    final has = value != null && value!.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.1,
            color: palette.textSecondary,
          ),
        ),
        SizedBox(height: 2 * s),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              has ? value! : '—',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: has
                    ? (simulated ? Colors.amber.shade800 : color)
                    : palette.textSecondary,
              ),
            ),
            if (has && unit != null) ...[
              const SizedBox(width: 3),
              Text(
                unit!,
                style: TextStyle(fontSize: 13, color: palette.textSecondary),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

/// The single primary target: a large pulsing disc reading START.
///
/// Sized well past the 48px minimum because a walk-up user does not aim.
class _StartDisc extends StatefulWidget {
  final VoidCallback? onTap;
  final double size;

  /// Marks the painted circle — not the ring padding around it — so callers can
  /// measure the disc's true bounds.
  final GlobalKey? discKey;

  const _StartDisc({required this.onTap, required this.size, this.discKey});

  @override
  State<_StartDisc> createState() => _StartDiscState();
}

class _StartDiscState extends State<_StartDisc>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;
  bool _pressed = false;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..repeat();
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    final s = XSScale.factor;
    const accent = XSColors.teal;

    return Semantics(
      button: true,
      label: 'Start screening',
      child: GestureDetector(
        onTapDown: widget.onTap == null
            ? null
            : (_) => setState(() => _pressed = true),
        onTapCancel: () => setState(() => _pressed = false),
        onTapUp: (_) => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _pressed ? 0.96 : 1.0,
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          child: SizedBox(
            // Room for the outermost expanding ring.
            width: widget.size * 1.5,
            height: widget.size * 1.5,
            child: AnimatedBuilder(
              animation: _pulse,
              builder: (context, _) {
                return Stack(
                  alignment: Alignment.center,
                  children: [
                    // Two sonar rings, half a loop apart, radiating outward.
                    for (final phase in [0.0, 0.5])
                      _ring((_pulse.value + phase) % 1.0, accent),
                    Container(
                      key: widget.discKey,
                      width: widget.size,
                      height: widget.size,
                      decoration: BoxDecoration(
                        color: accent,
                        shape: BoxShape.circle,
                        boxShadow: _pressed
                            ? XSShadows.pressed(palette)
                            : XSShadows.glow(accent, intensity: 1.4),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.touch_app_rounded,
                            size: widget.size * 0.30,
                            color: Colors.white,
                          ),
                          SizedBox(height: 6 * s),
                          Text(
                            'START',
                            style: TextStyle(
                              fontSize: widget.size * 0.14,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 2,
                              color: Colors.white,
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
    );
  }

  /// One expanding, fading ring. [t] is 0..1 through its own life.
  Widget _ring(double t, Color color) {
    final size = widget.size * (1.0 + t * 0.5);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: color.withValues(alpha: (1 - t) * 0.45),
          width: 2.5 * (1 - t) + 0.5,
        ),
      ),
    );
  }
}

/// Inline reminder that the module's four buttons mirror the on-screen UI.
class _HardwareHint extends StatelessWidget {
  const _HardwareHint();

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    final s = XSScale.factor;

    const keys = [
      (icon: Icons.arrow_upward_rounded, color: XSColors.sage),
      (icon: Icons.arrow_downward_rounded, color: XSColors.sage),
      (icon: Icons.check_rounded, color: XSColors.teal),
      (icon: Icons.arrow_back_rounded, color: XSColors.slate),
    ];

    // The key circles are fixed-width, so the [Flexible] the footer wraps this
    // in cannot shrink them — with RESET also on the row the pill overflowed by
    // the difference. Measure instead, and vanish when even the icons will not
    // fit: the on-screen button dock shows the same four buttons, so losing the
    // hint costs nothing, and an overflow stripe on a clinical screen does.
    final iconsWidth = keys.length * (30 * s + 6 * s) + 2 * s + 24 * s;

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < iconsWidth) return const SizedBox.shrink();
        return _pill(palette, s, keys, iconsWidth);
      },
    );
  }

  Widget _pill(
    XSPalette palette,
    double s,
    List<({Color color, IconData icon})> keys,
    double iconsWidth,
  ) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12 * s, vertical: 8 * s),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(XSRadius.pill),
        border: Border.all(color: palette.divider),
        boxShadow: XSShadows.soft(palette),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final k in keys)
            Container(
              width: 30 * s,
              height: 30 * s,
              margin: EdgeInsets.only(right: 6 * s),
              decoration: BoxDecoration(
                color: k.color.withValues(alpha: 0.14),
                shape: BoxShape.circle,
              ),
              child: Icon(k.icon, size: 16 * s, color: k.color),
            ),
          SizedBox(width: 2 * s),
          // Drops out first when the footer is tight; the icons alone still
          // convey that the module's buttons work.
          Flexible(
            child: Text(
              'Module buttons also work',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: palette.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Low-emphasis pill for secondary actions (staff login, reset).
class _FooterButton extends StatefulWidget {
  final String label;
  final IconData icon;

  /// Null renders the button inert rather than hiding it, so the footer's layout
  /// does not shift when an action is unavailable.
  final VoidCallback? onTap;

  const _FooterButton({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  @override
  State<_FooterButton> createState() => _FooterButtonState();
}

class _FooterButtonState extends State<_FooterButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    final s = XSScale.factor;
    final enabled = widget.onTap != null;
    final fg = enabled
        ? palette.textPrimary
        : palette.textSecondary.withValues(alpha: 0.5);

    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.label,
      child: GestureDetector(
        onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
        onTapCancel: () => setState(() => _pressed = false),
        onTapUp: (_) => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _pressed ? 0.97 : 1.0,
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            height: 52 * s,
            padding: EdgeInsets.symmetric(horizontal: XSSpacing.lg * s),
            decoration: BoxDecoration(
              color: palette.surface,
              borderRadius: BorderRadius.circular(XSRadius.pill),
              boxShadow: _pressed
                  ? XSShadows.pressed(palette)
                  : XSShadows.convex(palette),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(widget.icon, size: 19 * s, color: fg),
                SizedBox(width: 8 * s),
                Text(
                  widget.label,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5,
                    color: fg,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
