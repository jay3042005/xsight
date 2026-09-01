import 'package:flutter/material.dart';
import '../../core/theme/xs_colors.dart';
import '../../core/theme/xs_radius.dart';
import '../../core/theme/xs_scale.dart';
import '../../core/theme/xs_shadows.dart';
import '../../core/theme/xs_spacing.dart';
import '../../core/theme/xs_typography.dart';
import '../components/xs_card.dart';
import '../components/xs_chip.dart';
import '../components/xs_dial_gauge.dart';
import '../../state/kiosk_patient_state.dart';
import '../../core/voice/voice_guide.dart';

/// Kiosk CDSS — Clinical Decision Support dashboard.
///
/// This is the payoff screen: it answers "what did the kiosk find?". The risk
/// level gets a single hero gauge; the four station readings sit beneath it and
/// state plainly when a station has not been measured, so an incomplete
/// assessment can never read as a clean bill of health.
class KioskCDSSScreen extends StatefulWidget {
  const KioskCDSSScreen({super.key});

  @override
  State<KioskCDSSScreen> createState() => _KioskCDSSScreenState();
}

class _KioskCDSSScreenState extends State<KioskCDSSScreen> {


  @override
  void initState() {
    super.initState();
    KioskPatientSession.I.addListener(_onSession);
    _announceTriage();
  }

  void _onSession() {
    if (!mounted) return;
    setState(() {});
    _announceTriage();
  }

  /// The triage band this screen has already read aloud, or null for none.
  ///
  /// Guards against re-announcing on every session notification: a reading
  /// landing at another station notifies this one too, and most of those leave
  /// the band exactly where it was.
  String? _spokenBand;

  /// Read the current standing out loud: what is still outstanding, then the
  /// band, then the reminder that this is a screening aid.
  ///
  /// Fired from here rather than from [_triage], which is a getter called during
  /// build — audio must not be a side effect of painting a frame.
  void _announceTriage() {
    final t = KioskPatientSession.I.sessionTriage;
    final done = _completed;
    final key = '${t.level}:$done';
    if (key == _spokenBand) return;
    _spokenBand = key;

    if (t.level == 'notAssessed') {
      VoiceGuide.I.say(XSVoiceCue.summaryNone);
      return;
    }
    final band = switch (t.level) {
      'high' => XSVoiceCue.summaryHigh,
      'moderate' => XSVoiceCue.summaryModerate,
      _ => XSVoiceCue.summaryLow,
    };
    VoiceGuide.I.sayAll([
      // Only worth saying while stations remain; at four of four it would be
      // telling the user to go back for something they have already done.
      if (done < 4) XSVoiceCue.summaryPartial,
      band,
      XSVoiceCue.summaryDisclaimer,
    ]);
  }

  @override
  void dispose() {
    KioskPatientSession.I.removeListener(_onSession);
    super.dispose();
  }

  // ─── Local triage read from captured readings ────────────────────

  /// How many of the four stations have data.
  int get _completed {
    final s = KioskPatientSession.I;
    return [s.hasGuestVitals, s.hasGuestTemp, s.hasGuestSteth, s.hasGuestXray]
        .where((e) => e)
        .length;
  }

  /// Presentation wrapper over [KioskPatientSession.sessionTriage].
  ///
  /// The thresholds moved into the session so this screen and the AI
  /// assistant's risk card cannot band the same readings differently; only the
  /// label text and colour are decided here.
  ({String label, Color color, double score}) get _triage {
    final t = KioskPatientSession.I.sessionTriage;
    return switch (t.level) {
      'high' => (label: 'HIGH', color: XSColors.accentRed, score: t.score),
      'moderate' => (
          label: 'MODERATE',
          color: XSColors.accentOrange,
          score: t.score
        ),
      'low' => (label: 'LOW', color: XSColors.accentGreen, score: t.score),
      _ => (label: 'NOT ASSESSED', color: XSColors.sage, score: 0),
    };
  }

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    final s = XSScale.factor;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        XSSpacing.xl * s,
        XSSpacing.md * s,
        XSSpacing.xl * s,
        XSSpacing.md * s,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _header(palette, s),
          SizedBox(height: XSSpacing.lg * s),
          Expanded(
            // No spinner: everything on this screen comes from
            // KioskPatientSession, which is already in memory. The old loading
            // state was waiting on two /emr fetches that have been removed.
            child: LayoutBuilder(
                    builder: (context, constraints) {
                      final wide = constraints.maxWidth >= 1000;
                      return wide
                          ? Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Expanded(flex: 3, child: _resultPanel(palette, s)),
                                SizedBox(width: XSSpacing.md * s),
                                Expanded(
                                  flex: 2,
                                  child: Column(
                                    children: [
                                      Expanded(
                                          flex: 3,
                                          child: _findingsPanel(palette, s)),
                                      SizedBox(height: XSSpacing.sm * s),
                                      Expanded(
                                          flex: 2,
                                          child: _nextStepsPanel(palette, s)),
                                    ],
                                  ),
                                ),
                              ],
                            )
                          : SingleChildScrollView(
                              child: Column(
                                children: [
                                  _resultPanel(palette, s),
                                  SizedBox(height: XSSpacing.md * s),
                                  SizedBox(
                                      height: 320 * s,
                                      child: _findingsPanel(palette, s)),
                                  SizedBox(height: XSSpacing.md * s),
                                  SizedBox(
                                      height: 300 * s,
                                      child: _nextStepsPanel(palette, s)),
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

  Widget _header(XSPalette palette, double s) {
    final session = KioskPatientSession.I;
    return Row(
      children: [
        Icon(Icons.psychology_outlined,
            size: 26 * s, color: XSColors.moduleSummary),
        SizedBox(width: XSSpacing.sm * s),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Readings Summary',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.3,
                  color: palette.textPrimary,
                ),
              ),
              Text(
                session.patientDisplayName,
                style: TextStyle(
                  fontSize: 14,
                  color: palette.textSecondary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        XSChip(
          label: session.isGuest ? 'GUEST SESSION' : 'PATIENT RECORD',
          icon: session.isGuest ? Icons.science_outlined : Icons.folder_shared_outlined,
          color: session.isGuest ? XSColors.accentOrange : XSColors.moduleXray,
        ),
      ],
    );
  }

  // ─── RESULT PANEL: hero risk + four station readings ────────────
  Widget _resultPanel(XSPalette palette, double s) {
    final session = KioskPatientSession.I;
    final t = _triage;
    final complete = _completed == 4;

    return XSCard(
      padding: EdgeInsets.all(XSSpacing.lg * s),
      glow: _completed > 0 ? t.color : null,
      borderColor: _completed > 0 ? t.color.withValues(alpha: 0.4) : null,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                XSDialGauge(
                  value: t.score,
                  min: 0,
                  max: 1,
                  label: t.label == 'NOT ASSESSED' ? '--' : t.label[0],
                  status: '$_completed of 4 stations',
                  color: t.color,
                  size: 170,
                ),
                SizedBox(width: XSSpacing.lg * s),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'RISK LEVEL',
                        style: XSTypography.eyebrow(palette.textSecondary)
                            .copyWith(fontSize: 13),
                      ),
                      Text(
                        t.label,
                        style: XSTypography.hero(t.color, fontSize: 40),
                      ),
                      SizedBox(height: 6 * s),
                      Text(
                        // An incomplete assessment must never read as a clean
                        // result, so the copy leads with what's missing.
                        complete
                            ? 'All stations measured. This is an AI-assisted '
                                'screening, not a diagnosis.'
                            : 'Incomplete — finish the remaining stations for a '
                                'meaningful result.',
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.4,
                          color: palette.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            SizedBox(height: XSSpacing.lg * s),
            Text(
              'STATION READINGS',
              style: XSTypography.eyebrow(palette.textSecondary)
                  .copyWith(fontSize: 13),
            ),
            SizedBox(height: XSSpacing.sm * s),
            Wrap(
              spacing: XSSpacing.sm * s,
              runSpacing: XSSpacing.sm * s,
              children: [
                _readingTile(
                  palette, s,
                  icon: Icons.monitor_heart,
                  label: 'Heart rate',
                  // Never substitute a plausible-looking default for a missing
                  // clinical value.
                  value: session.guestHr != null
                      ? '${session.guestHr!.toStringAsFixed(0)} bpm'
                      : null,
                  color: XSColors.moduleVitals,
                ),
                _readingTile(
                  palette, s,
                  icon: Icons.bloodtype,
                  label: 'SpO\u2082',
                  value: session.guestSpo2 != null
                      ? '${session.guestSpo2!.toStringAsFixed(0)}%'
                      : null,
                  color: XSColors.moduleXray,
                ),
                _readingTile(
                  palette, s,
                  icon: Icons.thermostat,
                  label: 'Temperature',
                  value: session.guestTemp != null
                      ? '${session.guestTemp!.toStringAsFixed(1)} \u00B0C'
                      : null,
                  color: XSColors.moduleTemp,
                ),
                _readingTile(
                  palette, s,
                  icon: Icons.graphic_eq,
                  label: 'Lung sound',
                  value: session.guestStethFinding,
                  color: XSColors.moduleSteth,
                ),
                _readingTile(
                  palette, s,
                  icon: Icons.medical_services_outlined,
                  label: 'Chest X-ray',
                  value: session.guestXrayFinding,
                  color: XSColors.moduleSummary,
                ),
              ],
            ),
            SizedBox(height: XSSpacing.lg * s),
            _disclaimer(palette, s),
          ],
        ),
      ),
    );
  }

  /// One station reading. A null [value] renders as an explicit
  /// "not measured" state rather than a placeholder number.
  Widget _readingTile(
    XSPalette palette,
    double s, {
    required IconData icon,
    required String label,
    required String? value,
    required Color color,
  }) {
    final measured = value != null && value.isNotEmpty;
    return Container(
      width: 200 * s,
      padding: EdgeInsets.all(XSSpacing.sm * s),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(XSRadius.md),
        border: Border.all(
          color: measured ? color.withValues(alpha: 0.35) : palette.divider,
        ),
        boxShadow: XSShadows.soft(palette),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon,
                  size: 16 * s,
                  color: measured ? color : palette.textSecondary),
              SizedBox(width: 5 * s),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: palette.textSecondary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          SizedBox(height: 4 * s),
          Text(
            measured ? value : 'Not measured',
            style: TextStyle(
              fontSize: measured ? 20 : 15,
              fontWeight: measured ? FontWeight.w800 : FontWeight.w500,
              fontStyle: measured ? FontStyle.normal : FontStyle.italic,
              color: measured ? palette.textPrimary : palette.textSecondary,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _disclaimer(XSPalette palette, double s) {
    return Container(
      padding: EdgeInsets.all(XSSpacing.sm * s),
      decoration: BoxDecoration(
        color: XSColors.accentOrange.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(XSRadius.md),
        border:
            Border.all(color: XSColors.accentOrange.withValues(alpha: 0.30)),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 19 * s, color: XSColors.accentOrange),
          SizedBox(width: 8 * s),
          Expanded(
            child: Text(
              'AI-assisted screening only — not a diagnosis. See a licensed '
              'clinician to interpret these results, and seek emergency care '
              'for severe or worsening symptoms.',
              style: TextStyle(
                fontSize: 13,
                height: 1.4,
                fontWeight: FontWeight.w600,
                color: palette.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ─── FINDINGS: what this session actually measured ──────────────
  /// Why the band reads the way it does, from this session's own readings.
  ///
  /// Replaces an "active alerts" panel that polled `/emr/notifications` with no
  /// patient filter, so a walk-in's summary listed other patients by number. A
  /// kiosk station shows the person standing at it their own results; it is not a
  /// ward alerting board.
  ///
  /// The reasons come from [KioskPatientSession.sessionTriageFactors], the same
  /// list the gauge score is summed from, so the two cannot disagree.
  Widget _findingsPanel(XSPalette palette, double s) {
    final factors = KioskPatientSession.I.sessionTriageFactors;

    return XSCard(
      padding: EdgeInsets.all(XSSpacing.md * s),
      soft: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.fact_check_outlined,
                  size: 18 * s, color: palette.textSecondary),
              SizedBox(width: 6 * s),
              Text(
                'WHAT RAISED THIS',
                style: XSTypography.eyebrow(palette.textSecondary)
                    .copyWith(fontSize: 13),
              ),
              const Spacer(),
              if (factors.isNotEmpty)
                XSChip(
                  label: '${factors.length}',
                  color: _triage.color,
                  filled: true,
                ),
            ],
          ),
          SizedBox(height: XSSpacing.sm * s),
          Expanded(
            child: _completed == 0
                ? _emptyNote(
                    palette,
                    s,
                    icon: Icons.pending_outlined,
                    text: 'Nothing measured yet. Visit a station and its '
                        'reading appears here.',
                  )
                : factors.isEmpty
                    ? _emptyNote(
                        palette,
                        s,
                        icon: Icons.check_circle_outline,
                        color: XSColors.accentGreen,
                        text: 'Every reading taken so far is inside the ranges '
                            'this kiosk screens for.',
                      )
                    : ListView.separated(
                        padding: EdgeInsets.zero,
                        itemCount: factors.length,
                        separatorBuilder: (context, index) => SizedBox(height: 8 * s),
                        itemBuilder: (ctx, i) {
                          final f = factors[i];
                          return Container(
                            padding: EdgeInsets.all(XSSpacing.sm * s),
                            decoration: BoxDecoration(
                              color: palette.highlight,
                              borderRadius: BorderRadius.circular(XSRadius.sm),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  f.station,
                                  style: TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w800,
                                    color: palette.textPrimary,
                                  ),
                                ),
                                SizedBox(height: 2 * s),
                                Text(
                                  f.detail,
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

  // ─── NEXT STEPS ────────────────────────────────────────────────
  /// What to do now: finish the remaining stations, then who to show this to.
  ///
  /// The station list is derived from the session rather than written out, so it
  /// cannot fall out of step with what was actually measured. Replaces a "how
  /// this works" card whose contents were a hardcoded feature list.
  Widget _nextStepsPanel(XSPalette palette, double s) {
    final session = KioskPatientSession.I;
    final remaining = <String>[
      if (!session.hasGuestVitals) 'Pulse & SpO₂',
      if (!session.hasGuestTemp) 'Temperature',
      if (!session.hasGuestSteth) 'Breath sounds',
      if (!session.hasGuestXray) 'Chest X-ray',
    ];

    return XSCard(
      padding: EdgeInsets.all(XSSpacing.md * s),
      soft: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.flag_outlined,
                  size: 18 * s, color: palette.textSecondary),
              SizedBox(width: 6 * s),
              Text(
                'WHAT TO DO NEXT',
                style: XSTypography.eyebrow(palette.textSecondary)
                    .copyWith(fontSize: 13),
              ),
            ],
          ),
          SizedBox(height: XSSpacing.sm * s),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (remaining.isNotEmpty)
                    _stepRow(
                      palette,
                      s,
                      Icons.playlist_add_check,
                      XSColors.moduleSummary,
                      'Still to measure',
                      remaining.join(', '),
                    )
                  else
                    _stepRow(
                      palette,
                      s,
                      Icons.done_all,
                      XSColors.accentGreen,
                      'All four stations done',
                      'Nothing further to measure at this kiosk.',
                    ),
                  _stepRow(
                    palette,
                    s,
                    Icons.medical_information_outlined,
                    XSColors.moduleXray,
                    'Show this to a clinician',
                    'These readings are a screening aid. A licensed clinician '
                        'interprets them and decides what follows.',
                  ),
                  _stepRow(
                    palette,
                    s,
                    Icons.emergency_outlined,
                    XSColors.accentRed,
                    'Emergency care now if',
                    'chest pain, severe breathlessness, blue lips, confusion '
                        'or fainting — do not wait for this result.',
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyNote(
    XSPalette palette,
    double s, {
    required IconData icon,
    required String text,
    Color? color,
  }) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(XSSpacing.sm * s),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon,
                size: 40 * s,
                color:
                    (color ?? palette.textSecondary).withValues(alpha: 0.35)),
            SizedBox(height: XSSpacing.xs * s),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13.5, color: palette.textSecondary),
            ),
          ],
        ),
      ),
    );
  }

  Widget _stepRow(XSPalette palette, double s, IconData icon, Color color,
      String title, String desc) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 6 * s),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 30 * s,
            height: 30 * s,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(8 * s),
            ),
            child: Icon(icon, size: 16 * s, color: color),
          ),
          SizedBox(width: 8 * s),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: palette.textPrimary,
                  ),
                ),
                Text(
                  desc,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.35,
                    color: palette.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
