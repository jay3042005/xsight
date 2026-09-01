import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import '../../core/api/kiosk_hub_client.dart';
import '../../core/api/upload_client.dart';
import '../../core/api/xray_handoff_client.dart';
import '../../core/sensor/esp32_serial_client.dart';
import '../../core/voice/voice_guide.dart';
import '../../core/api/cdss_client.dart';
import '../../core/api/emr_client.dart';
import '../../core/theme/xs_colors.dart';
import '../../core/theme/xs_spacing.dart';
import '../../core/theme/xs_radius.dart';
import '../../core/theme/xs_shadows.dart';
import '../../state/kiosk_patient_state.dart';
import '../components/xs_button.dart';
import '../components/xs_scan_overlay.dart';
import '../components/xs_confidence_meter.dart';
import '../components/xs_result_reveal.dart';
import '../components/xs_patient_picker.dart';
import '../components/xs_handoff_panel.dart';
import '../components/ai/xs_ai_card_frame.dart' show XSComparePanel;
import '../components/ai/xs_xray_compare_card.dart' show XSXrayCompareCard;

/// Kiosk X-ray screen — 3-panel comparison (Original / Heatmap / Normal),
/// tabbed image viewer, CDSS integration, patient history.
class KioskXrayScreen extends StatefulWidget {
  const KioskXrayScreen({super.key});

  @override
  State<KioskXrayScreen> createState() => _KioskXrayScreenState();
}

enum _ImageTab { original, heatmap, comparison }

class _KioskXrayScreenState extends State<KioskXrayScreen>
    with SingleTickerProviderStateMixin {
  final ImagePicker _picker = ImagePicker();
  final UploadClient _upload = UploadClient();
  final CDSSClient _cdss = CDSSClient();
  final Esp32SerialClient _esp32 = Esp32SerialClient.shared;

  File? _selectedFile;
  XrayResult? _result;
  List<dynamic> _history = [];
  String? _error;
  bool _busy = false;
  int _resultRevision = 0;
  bool _deviceUploaded = false;
  _ImageTab _activeTab = _ImageTab.original;

  /// Who this upload gets attached to. Read from the session rather than held
  /// locally, so the dashboard's patient chip, the OLED's `PATIENT:` line, and
  /// the id sent with the upload can never disagree.
  int? get _selectedPatientId => KioskPatientSession.I.selectedPatientId;

  @override
  void initState() {
    super.initState();
    _esp32.onXrayStatus = _onXrayStatus;
    // The linked patient can change from the dashboard chip while this screen
    // is up, and the picker below is driven off the session now.
    KioskPatientSession.I.addListener(_onSessionChanged);
    _probeHandoff();
  }

  /// Whether this kiosk can broker a phone handoff.
  ///
  /// Starts false so the local file picker is offered until the backend
  /// confirms otherwise — a kiosk with no relay must never be left with no way
  /// to get a film in at all.
  bool _handoffAvailable = false;

  /// Live transfer session. Owned here rather than by the panel so the code
  /// survives rebuilds, and so a film can arrive while the clinician is looking
  /// at a previous result.
  XrayHandoffClient? _handoff;

  /// Guards against analysing the same delivered film twice, which would happen
  /// on any rebuild that re-reads `handoff.film`.
  bool _consumingFilm = false;

  /// Last capture session announced to the hub, so re-arming publishes the new
  /// one and a rebuild does not republish the old.
  String? _announcedSid;

  Future<void> _probeHandoff() async {
    final ok = await XrayHandoffClient.isAvailable();
    if (!mounted) return;
    setState(() => _handoffAvailable = ok);
    // Mint immediately: the station's resting state should already be scannable.
    // Requiring a tap to reveal a QR was the tap this route exists to remove.
    if (ok) _armHandoff();
  }

  void _armHandoff() {
    _handoff?.removeListener(_onHandoff);
    _handoff?.dispose();
    final client = XrayHandoffClient()..addListener(_onHandoff);
    setState(() => _handoff = client);
    client.start();
  }

  /// A film arriving *is* the instruction to analyse — nothing asks first.
  void _onHandoff() {
    if (!mounted) return;
    final client = _handoff;
    if (client == null) return;

    // Publish the session as soon as it exists, so the portal's upload prompt
    // posts into it rather than to a server-side path whose result would never
    // appear on this screen.
    final sid = client.sid;
    if (sid != null && sid != _announcedSid) {
      _announcedSid = sid;
      KioskHubClient.instance.notifyXraySession(sid);
    }
    if (client.state == XrayHandoffState.received && !_consumingFilm) {
      final film = client.film;
      if (film != null) {
        _consumingFilm = true;
        VoiceGuide.I.say(XSVoiceCue.xrayReceived);
        _consumeFilm(film);
        return;
      }
    }
    setState(() {});
  }

  /// How long the received film stays on the transfer panel before the analyser
  /// takes the slot over.
  ///
  /// Long enough to register as "this is the photo that arrived" — the patient
  /// who just sent it is still looking at the kiosk, and a film that vanished
  /// into a spinner gave them no confirmation it was the right one. Short enough
  /// that it does not feel like a wait.
  static const _filmHandoverDwell = Duration(milliseconds: 1100);

  Future<void> _consumeFilm(Uint8List film) async {
    // Everything downstream — the viewer, the comparison card, the EMR upload —
    // works from a File, so land the bytes in one rather than forking those
    // paths for this route.
    File target;
    try {
      final dir = await getTemporaryDirectory();
      target = File(
        '${dir.path}/xsight_handoff_${DateTime.now().millisecondsSinceEpoch}.jpg',
      );
      await target.writeAsBytes(film, flush: true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not save the received film: $e';
        _consumingFilm = false;
      });
      return;
    }

    // Let the "film received" panel land and be read. The file is already
    // written, so this is dwell time rather than dead time.
    setState(() {});
    await Future.delayed(_filmHandoverDwell);

    if (!mounted) return;
    setState(() {
      _selectedFile = target;
      _result = null;
      _heatmapBytes = null;
      _error = null;
      _activeTab = _ImageTab.original;
    });
    await _analyze();
    if (mounted) _consumingFilm = false;
  }

  /// Put a fresh code on screen for the next patient.
  void _newTransferCode() {
    setState(() {
      _selectedFile = null;
      _result = null;
      _heatmapBytes = null;
      _error = null;
      _activeTab = _ImageTab.original;
      _consumingFilm = false;
    });
    if (_handoffAvailable) _armHandoff();
  }

  void _onSessionChanged() {
    if (mounted) setState(() {});
  }

  void _onXrayStatus(bool uploaded) {
    if (mounted) setState(() => _deviceUploaded = uploaded);
  }

  @override
  void dispose() {
    _handoff?.removeListener(_onHandoff);
    _handoff?.dispose();
    if (_announcedSid != null) {
      KioskHubClient.instance.notifyXraySession(null);
    }
    KioskPatientSession.I.removeListener(_onSessionChanged);
    if (identical(_esp32.onXrayStatus, _onXrayStatus)) {
      _esp32.onXrayStatus = null;
    }
    super.dispose();
  }

  Future<void> _pickImage({bool camera = false}) async {
    try {
      final XFile? f = await _picker.pickImage(
        source: camera ? ImageSource.camera : ImageSource.gallery,
        imageQuality: 92,
        maxWidth: 1600,
      );
      if (f == null) return;
      setState(() {
        _selectedFile = File(f.path);
        _result = null;
        _error = null;
        _activeTab = _ImageTab.original;
      });
      // A picked film is the same instruction to analyse as a delivered one —
      // without this the local path just parked on "Awaiting analysis" and the
      // only trigger left was the re-run button. See _consumeFilm.
      await _analyze();
    } catch (e) {
      setState(() => _error = 'Failed: $e');
    }
  }

  /// The scan overlay animation needs at least one full sweep cycle to read
  /// as a deliberate "analysis" rather than a flicker — the local ONNX
  /// model often responds in well under a second, so we pad the busy state
  /// out to this floor before revealing the result.
  static const _minAnalyzeDuration = Duration(milliseconds: 2200);

  Future<void> _waitOutMinDuration(Stopwatch stopwatch) async {
    final remaining = _minAnalyzeDuration - stopwatch.elapsed;
    if (remaining > Duration.zero) {
      await Future.delayed(remaining);
    }
  }

  Future<void> _analyze() async {
    final file = _selectedFile;
    if (file == null) return;
    setState(() { _busy = true; _error = null; _result = null; });
    VoiceGuide.I.say(XSVoiceCue.xrayReading);
    final stopwatch = Stopwatch()..start();
    try {
      final res = await _upload.uploadXray(file: file, patientId: _selectedPatientId);
      _esp32.sendCommand('XRAY_UPLOADED:1');
      await _waitOutMinDuration(stopwatch);
      if (!mounted) return;
      setState(() {
        _result = res;
        _busy = false;
        _resultRevision++;
        // Heatmap cache belongs to this result, not the last one.
        _heatmapBytes = null;
        // Auto-switch to the heatmap tab only when there is genuinely a heatmap
        // to show. `raw` is non-empty on the vision-fallback path too, where it
        // holds prose rather than base64 — switching on that alone landed the
        // clinician on a tab that could not render.
        if (_safeHeatmapBytes() != null) _activeTab = _ImageTab.heatmap;
      });
      VoiceGuide.I.say(XSVoiceCue.xrayDone);
      // Recorded in both modes. This used to be gated on `isGuest`, so a staff
      // member's chest film never reached the CDSS summary, the AI assistant's
      // patient context, or the PDF report — the three places that consolidate a
      // session — even though vitals and temperature always did.
      KioskPatientSession.I.recordXray(
        _selectedFile?.path ?? '',
        res.findings.isNotEmpty ? res.findings : res.label,
        _confidenceValue(res.confidence),
        // Only a real base64 overlay reaches the session, so the assistant's
        // compare card can trust it.
        heatmapB64: _safeHeatmapBytes() != null ? res.raw : null,
      );
      _runCDSS(res);
    } catch (e) {
      await _waitOutMinDuration(stopwatch);
      if (!mounted) return;
      setState(() { _error = '$e'; _busy = false; });
      VoiceGuide.I.say(XSVoiceCue.xrayFailed);
    }
  }

  Future<void> _runCDSS(XrayResult res) async {
    try {
      await _cdss.assess(
        xrayPrediction: res.label,
        xrayConfidence: CDSSClient.parseConfidence(res.confidence),
        patientId: _selectedPatientId ?? 0,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('CDSS unavailable: $e')),
      );
    }
  }

  Future<void> _loadHistory() async {
    final pid = _selectedPatientId;
    if (pid == null) {
      setState(() => _history = []);
      return;
    }
    try {
      final h = await EMRClient().getXrayHistory(pid);
      if (!mounted) return;
      setState(() => _history = h);
    } catch (_) {
      if (!mounted) return;
      setState(() => _history = []);
    }
  }

  /// Maps the backend's categorical confidence string to a 0..1 value for
  /// the animated meter.
  double _confidenceValue(String confidence) {
    switch (confidence.toLowerCase()) {
      case 'high':
        return 0.9;
      case 'moderate':
        return 0.65;
      default:
        return 0.35;
    }
  }

  Uint8List? _heatmapBytes;

  /// Decoded Grad-CAM overlay, or null when this result has none.
  ///
  /// `XrayResult.raw` carries two different things: base64 PNG when the local
  /// classifier ran, and the vision provider's prose when it fell back. Callers
  /// must treat a heatmap as optional and let the decode fail.
  Uint8List? _safeHeatmapBytes() {
    if (_heatmapBytes != null) return _heatmapBytes;
    final raw = _result?.raw;
    if (raw == null || raw.trim().isEmpty) return null;
    _heatmapBytes = XSXrayCompareCard.tryDecodeHeatmap(raw);
    return _heatmapBytes;
  }

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    return Padding(
      padding: const EdgeInsets.all(XSSpacing.lg),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final narrow = constraints.maxWidth < 900;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildTopBar(palette),
              const SizedBox(height: XSSpacing.md),
              Expanded(
                child: narrow ? _buildNarrowBody(palette) : _buildWideBody(palette),
              ),
            ],
          );
        },
      ),
    );
  }

  // ─── Top Bar ─────────────────────────────────────────────────────
  Widget _buildTopBar(XSPalette palette) {
    return Row(
      children: [
        Text('Chest X-Ray Analytics',
            style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w700,
                color: palette.textPrimary)),
        const SizedBox(width: XSSpacing.sm),
        // Unstable badge
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: Colors.amber.shade900.withValues(alpha: 0.25),
            border: Border.all(color: Colors.amber.shade700, width: 1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.warning_amber_rounded, size: 12, color: Colors.amber.shade400),
              const SizedBox(width: 4),
              Text(
                'UNSTABLE MODEL',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: Colors.amber.shade400,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: XSSpacing.md),
        // Module status
        Text(_deviceUploaded ? 'MODULE: XRAY READY' : 'MODULE: WAITING',
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: _deviceUploaded
                    ? XSColors.accentGreen
                    : palette.textSecondary)),
        const SizedBox(width: XSSpacing.md),
        XSPatientPicker(
          selectedPatientId: _selectedPatientId,
          onChanged: (patient) {
            if (patient == null) {
              KioskPatientSession.I.unlinkPatient();
            } else {
              KioskPatientSession.I.selectPatient(patient);
            }
            _loadHistory();
          },
        ),
        const Spacer(),
        Wrap(
          spacing: XSSpacing.sm,
          runSpacing: XSSpacing.xs,
          children: [
            // No QR button: the code is already on screen whenever no film is
            // loaded. What is left here are the exceptions — swap the film,
            // re-run a failed analysis, or clear down for the next patient.
            if (!_handoffAvailable || _selectedFile != null)
              XSButton(
                icon: Icons.photo_library,
                tooltip: 'Use a file instead',
                onPressed: _busy ? null : () => _pickImage(camera: false),
              ),
            // Analysis runs itself when a film arrives, so this is only a manual
            // re-run for one that failed or was replaced.
            if (_selectedFile != null)
              XSButton(
                icon: _busy ? Icons.hourglass_empty : Icons.refresh,
                tooltip: _busy ? 'Analyzing...' : 'Re-analyze',
                onPressed: _busy ? null : _analyze,
              ),
            if (_selectedFile != null && _handoffAvailable)
              XSButton(
                icon: Icons.qr_code_2,
                tooltip: 'New transfer code',
                inverted: true,
                onPressed: _busy ? null : _newTransferCode,
              ),
          ],
        ),
      ],
    );
  }

  // ─── Wide Layout (≥ 900px) ──────────────────────────────────────
  Widget _buildWideBody(XSPalette palette) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Left: Image Viewer with tabs
        Expanded(
          flex: 5,
          child: _buildImageViewer(palette),
        ),
        const SizedBox(width: XSSpacing.md),
        // Right: Results + History
        Expanded(
          flex: 3,
          child: _buildResultsPanel(palette),
        ),
      ],
    );
  }

  // ─── Narrow Layout (< 900px) ────────────────────────────────────
  Widget _buildNarrowBody(XSPalette palette) {
    return SingleChildScrollView(
      child: Column(
        children: [
          SizedBox(height: 400, child: _buildImageViewer(palette)),
          const SizedBox(height: XSSpacing.md),
          SizedBox(height: 500, child: _buildResultsPanel(palette)),
        ],
      ),
    );
  }

  // ─── Image Viewer with Tabbed Comparison ────────────────────────
  Widget _buildImageViewer(XSPalette palette) {
    final hasResult = _result != null && _result!.raw.isNotEmpty;

    return Column(
      children: [
        // Tab bar for switching views
        if (_selectedFile != null) _buildImageTabs(palette, hasResult),
        if (_selectedFile != null) const SizedBox(height: XSSpacing.sm),
        // Image display area
        Expanded(
          child: _buildImagePanel(palette, hasResult),
        ),
      ],
    );
  }

  Widget _buildImageTabs(XSPalette palette, bool hasResult) {
    // HEATMAP needs a decodable overlay, not merely a result: on the
    // vision-fallback path `raw` is prose, and enabling the tab on that let the
    // clinician open a view that threw a FormatException mid-build.
    final hasHeatmap = _safeHeatmapBytes() != null;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: palette.highlight,
        borderRadius: BorderRadius.circular(XSRadius.sm),
        border: Border.all(color: palette.divider),
      ),
      child: Row(
        children: [
          _tabButton(palette, _ImageTab.original, Icons.image_outlined, 'ORIGINAL'),
          const SizedBox(width: 2),
          _tabButton(palette, _ImageTab.heatmap, Icons.thermostat_outlined, 'HEATMAP',
              enabled: hasHeatmap),
          const SizedBox(width: 2),
          _tabButton(palette, _ImageTab.comparison, Icons.compare_outlined,
              'COMPARISON', enabled: hasResult),
        ],
      ),
    );
  }

  Widget _tabButton(XSPalette palette, _ImageTab tab, IconData icon, String label,
      {bool enabled = true}) {
    final active = _activeTab == tab;
    return Expanded(
      child: GestureDetector(
        onTap: enabled ? () => setState(() => _activeTab = tab) : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: active
                ? palette.surface
                : Colors.transparent,
            borderRadius: BorderRadius.circular(XSRadius.xs),
            boxShadow: active ? XSShadows.soft(palette) : [],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon,
                  size: 14,
                  color: !enabled
                      ? palette.divider
                      : active
                          ? XSColors.moduleXray
                          : palette.textSecondary),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                  letterSpacing: 0.5,
                  color: !enabled
                      ? palette.divider
                      : active
                          ? palette.textPrimary
                          : palette.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildImagePanel(XSPalette palette, bool hasResult) {
    // One switcher across the whole slot, so the transfer panel handing over to
    // the viewer animates too. Previously the empty state returned early and the
    // film appeared with a hard cut; now the received film scales up out of the
    // panel and into the scanning view, which is the same box on screen.
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 420),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: ScaleTransition(
          // Grows in from just under full size; paired with the outgoing
          // panel's fade it reads as the film moving forward into analysis.
          scale: Tween<double>(begin: 0.94, end: 1.0).animate(
            CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
          ),
          child: child,
        ),
      ),
      layoutBuilder: (current, previous) => Stack(
        fit: StackFit.expand,
        children: [...previous, ?current],
      ),
      child: _selectedFile == null
          ? KeyedSubtree(
              key: const ValueKey('transfer'),
              child: _buildEmptyState(palette),
            )
          : KeyedSubtree(
              key: ValueKey(_activeTab),
              child: switch (_activeTab) {
                _ImageTab.original => _buildOriginalView(palette),
                _ImageTab.heatmap => _buildHeatmapView(palette, hasResult),
                _ImageTab.comparison => _buildComparisonView(palette, hasResult),
              },
            ),
    );
  }

  /// The station at rest.
  ///
  /// A live transfer code rather than "Select a chest X-ray image" — the QR is
  /// generated when the station opens, so the resting state is already
  /// actionable from a phone. Falls back to prompting for a file only where no
  /// relay is configured, which is the one case a code could never work.
  /// Ask the clinician's web portal to raise its upload box.
  ///
  /// The portal polls kiosk state, so this is a request rather than a push and
  /// lands on its next tick — hence the immediate on-kiosk confirmation, so
  /// nobody presses it twice wondering whether it registered.
  void _askWebPortalForFilm() {
    KioskHubClient.instance.requestXrayUpload();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Upload box opened on the web portal.'),
        duration: Duration(seconds: 3),
      ),
    );
  }

  Widget _buildEmptyState(XSPalette palette) {
    final handoff = _handoff;
    if (_handoffAvailable && handoff != null) {
      final hub = KioskHubClient.instance;
      return XSHandoffPanel(
        handoff: handoff,
        onUseFile: () => _pickImage(camera: false),
        // Null when no portal socket is up, so the route renders as unavailable
        // instead of as a button whose event goes nowhere.
        onUseWebPortal: hub.canReachWebPortal ? _askWebPortalForFilm : null,
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(XSRadius.lg),
        boxShadow: XSShadows.soft(palette),
        border: Border.all(color: palette.divider),
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: palette.highlight,
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.medical_services_outlined,
                  size: 40,
                  color: palette.textSecondary.withValues(alpha: 0.4)),
            ),
            const SizedBox(height: XSSpacing.lg),
            Text('Select a chest X-ray image',
                style: TextStyle(
                    color: palette.textSecondary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: XSSpacing.xs),
            Text(
              // Says why the phone route is missing rather than leaving a
              // clinician wondering where the code went.
              'Phone transfer is not configured on this server',
              style: TextStyle(
                  color: palette.textSecondary.withValues(alpha: 0.6),
                  fontSize: 14),
            ),
            const SizedBox(height: XSSpacing.lg),
            XSButton(
              label: 'CHOOSE A FILE',
              icon: Icons.folder_open,
              height: 56,
              width: 240,
              onPressed: () => _pickImage(camera: false),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Original View ──────────────────────────────────────────────
  Widget _buildOriginalView(XSPalette palette) {
    return _imageCard(
      palette: palette,
      label: 'PATIENT X-RAY',
      labelColor: XSColors.moduleXray,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(
            borderRadius: const BorderRadius.vertical(bottom: Radius.circular(XSRadius.lg)),
            child: Image.file(_selectedFile!, fit: BoxFit.contain),
          ),
          // Scanning animation while the backend analyzes
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: _busy
                ? const XSScanOverlay(
                    key: ValueKey('scanning'),
                    label: 'Analyzing X-ray...',
                  )
                : const SizedBox.shrink(key: ValueKey('idle')),
          ),
          // Confidence badge
          if (_result != null)
            Positioned(
              top: 12,
              right: 12,
              child: XSResultReveal(
                trigger: _resultRevision,
                child: _buildConfidenceBadge(),
              ),
            ),
        ],
      ),
    );
  }

  // ─── Heatmap View ───────────────────────────────────────────────
  Widget _buildHeatmapView(XSPalette palette, bool hasResult) {
    // Gate on a decodable overlay rather than on `hasResult`. The tab is also
    // disabled without one, but a stale `_activeTab` can still route here after
    // a re-analysis returns a result with no heatmap.
    final heat = _safeHeatmapBytes();
    if (!hasResult || heat == null) {
      return _imageCard(
        palette: palette,
        label: 'HEATMAP',
        labelColor: Colors.deepOrange,
        child: Center(
          child: Text(
            hasResult
                ? 'This result has no heatmap — the local classifier was not '
                    'used for it.'
                : 'Analyze an X-ray first to see heatmap',
            textAlign: TextAlign.center,
            style: TextStyle(color: palette.textSecondary),
          ),
        ),
      );
    }

    return _imageCard(
      palette: palette,
      label: 'GRAD-CAM HEATMAP',
      labelColor: Colors.deepOrange,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Base X-ray
          ClipRRect(
            borderRadius: const BorderRadius.vertical(bottom: Radius.circular(XSRadius.lg)),
            child: Image.file(_selectedFile!, fit: BoxFit.contain),
          ),
          // Heatmap overlay
          ClipRRect(
            borderRadius: const BorderRadius.vertical(bottom: Radius.circular(XSRadius.lg)),
            child: TweenAnimationBuilder<double>(
              key: ValueKey('heatmap-$_resultRevision'),
              tween: Tween(begin: 0, end: 1.0),
              duration: const Duration(milliseconds: 700),
              curve: Curves.easeOut,
              builder: (context, opacity, _) => Opacity(
                opacity: opacity,
                child: Image.memory(
                  heat,
                  fit: BoxFit.contain,
                ),
              ),
            ),
          ),
          // Confidence badge
          Positioned(
            top: 12,
            right: 12,
            child: _buildConfidenceBadge(),
          ),
          // Legend
          Positioned(
            bottom: 16,
            left: 16,
            child: _buildHeatmapLegend(),
          ),
        ],
      ),
    );
  }

  // ─── Comparison View (Side-by-Side-by-Side) ─────────────────────
  Widget _buildComparisonView(XSPalette palette, bool hasResult) {
    if (!hasResult) {
      return _imageCard(
        palette: palette,
        label: 'COMPARISON',
        labelColor: XSColors.accentGreen,
        child: Center(
          child: Text('Analyze an X-ray first to compare',
              style: TextStyle(color: palette.textSecondary)),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(XSRadius.lg),
        boxShadow: XSShadows.soft(palette),
        border: Border.all(color: palette.divider),
      ),
      child: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: XSSpacing.md, vertical: XSSpacing.sm),
            decoration: BoxDecoration(
              color: palette.highlight,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(XSRadius.lg)),
            ),
            child: Row(
              children: [
                Icon(Icons.compare_outlined, size: 16, color: XSColors.accentGreen),
                const SizedBox(width: 8),
                Text('SIDE-BY-SIDE COMPARISON',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: palette.textSecondary,
                        letterSpacing: 0.8)),
                const Spacer(),
                _buildConfidenceBadge(compact: true),
              ],
            ),
          ),
          // 3-panel comparison. Panels come from the shared [XSComparePanel] so
          // the AI assistant's compare card renders the identical treatment.
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(XSSpacing.sm),
              child: Row(
                children: [
                  // Panel 1: Normal Reference
                  Expanded(child: XSComparePanel(
                    label: 'NORMAL REFERENCE',
                    sublabel: 'Healthy lung baseline',
                    borderColor: XSColors.accentGreen,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(XSRadius.sm),
                      child: Image.asset(
                        'assets/images/normal_chest_xray.jpg',
                        fit: BoxFit.contain,
                      ),
                    ),
                  )),
                  const SizedBox(width: XSSpacing.sm),
                  // Panel 2: Patient X-Ray
                  Expanded(child: XSComparePanel(
                    label: 'PATIENT X-RAY',
                    sublabel: _result!.label.toUpperCase(),
                    borderColor: _result!.label.toLowerCase() == 'normal'
                        ? XSColors.accentGreen
                        : XSColors.accentOrange,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(XSRadius.sm),
                      child: Image.file(_selectedFile!, fit: BoxFit.contain),
                    ),
                  )),
                  // Panel 3: Heatmap — only when the result actually carried
                  // one. `raw` holds base64 PNG from the local classifier but
                  // free-form prose from the multimodal fallback, so decoding
                  // it is allowed to fail and this panel is dropped instead.
                  if (_safeHeatmapBytes() case final heat?) ...[
                    const SizedBox(width: XSSpacing.sm),
                    Expanded(child: XSComparePanel(
                      label: 'AI HEATMAP',
                      sublabel: 'Regions of interest',
                      borderColor: Colors.deepOrange,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(XSRadius.sm),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Image.file(_selectedFile!, fit: BoxFit.contain),
                            Opacity(
                              opacity: 0.55,
                              child: Image.memory(heat, fit: BoxFit.contain),
                            ),
                          ],
                        ),
                      ),
                    )),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ─── Shared Image Card Container ────────────────────────────────
  Widget _imageCard({
    required XSPalette palette,
    required String label,
    required Color labelColor,
    required Widget child,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(XSRadius.lg),
        boxShadow: XSShadows.soft(palette),
        border: Border.all(color: palette.divider),
      ),
      child: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: XSSpacing.md, vertical: XSSpacing.sm),
            decoration: BoxDecoration(
              color: palette.highlight,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(XSRadius.lg)),
            ),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: labelColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Text(label,
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: palette.textSecondary,
                        letterSpacing: 0.8)),
              ],
            ),
          ),
          // Image
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: const BorderRadius.vertical(bottom: Radius.circular(XSRadius.lg)),
              ),
              child: child,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConfidenceBadge({bool compact = false}) {
    if (_result == null) return const SizedBox.shrink();
    final isNormal = _result!.label.toLowerCase() == 'normal';
    final color = isNormal ? XSColors.accentGreen : XSColors.accentOrange;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 8 : 12,
        vertical: compact ? 4 : 6,
      ),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.4),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isNormal ? Icons.check_circle : Icons.warning_amber_rounded,
            size: compact ? 11 : 13,
            color: Colors.white,
          ),
          const SizedBox(width: 4),
          Text(
            compact
                ? '${_result!.label.toUpperCase()} · ${_result!.confidence.toUpperCase()}'
                : '${_result!.confidence} confidence',
            style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: compact ? 10 : 12),
          ),
        ],
      ),
    );
  }

  Widget _buildHeatmapLegend() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Gradient bar
          Container(
            width: 60,
            height: 8,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(4),
              gradient: const LinearGradient(
                colors: [
                  Color(0xFF0000FF), // blue (low)
                  Color(0xFF00FF00), // green
                  Color(0xFFFFFF00), // yellow
                  Color(0xFFFF0000), // red (high)
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          const Text('Low',
              style: TextStyle(color: Colors.white60, fontSize: 13)),
          const SizedBox(width: 4),
          const Text('→',
              style: TextStyle(color: Colors.white38, fontSize: 13)),
          const SizedBox(width: 4),
          const Text('High',
              style: TextStyle(color: Colors.white60, fontSize: 13)),
        ],
      ),
    );
  }

  // ─── Results Panel ──────────────────────────────────────────────
  Widget _buildResultsPanel(XSPalette palette) {
    return Column(
      children: [
        // Main results card
        Expanded(
          flex: 5,
          child: _buildFindingsCard(palette),
        ),
        const SizedBox(height: XSSpacing.sm),
        // History card
        Expanded(
          flex: 3,
          child: _buildHistoryCard(palette),
        ),
      ],
    );
  }

  Widget _buildFindingsCard(XSPalette palette) {
    return Container(
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(XSRadius.lg),
        boxShadow: XSShadows.soft(palette),
        border: Border.all(color: palette.divider),
      ),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        child: _busy
            ? _AnalyzingPlaceholder(key: const ValueKey('busy'))
            : _result == null
                ? Center(
                    key: const ValueKey('empty'),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.analytics_outlined,
                            size: 36,
                            color: palette.textSecondary.withValues(alpha: 0.3)),
                        const SizedBox(height: XSSpacing.sm),
                        Text(_error ?? 'Awaiting analysis',
                            style: TextStyle(color: palette.textSecondary, fontSize: 13)),
                      ],
                    ),
                  )
                : XSResultReveal(
                    key: ValueKey('result-$_resultRevision'),
                    trigger: _resultRevision,
                    child: _buildResultContent(palette),
                  ),
      ),
    );
  }

  Widget _buildResultContent(XSPalette palette) {
    final res = _result!;
    final isInvalid = res.label.toLowerCase().contains('invalid') ||
        res.label.toLowerCase().contains('not_xray');
    final isNormal = res.label.toLowerCase() == 'normal';
    final labelColor = isInvalid
        ? XSColors.accentRed
        : (isNormal ? XSColors.accentGreen : XSColors.accentOrange);

    return Padding(
      padding: const EdgeInsets.all(XSSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: labelColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  isInvalid
                      ? Icons.cancel_outlined
                      : (isNormal ? Icons.check_circle : Icons.warning_amber_rounded),
                  color: labelColor,
                  size: 22,
                ),
              ),
              const SizedBox(width: XSSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('AI FINDING',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: palette.textSecondary,
                            letterSpacing: 0.5)),
                    Text(res.label.replaceAll('_', ' ').toUpperCase(),
                        style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w800,
                            color: labelColor)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: XSSpacing.md),

          // Confidence meter
          XSConfidenceMeter(
            value: _confidenceValue(res.confidence),
            color: labelColor,
          ),
          const SizedBox(height: XSSpacing.sm),

          // Model info
          Row(
            children: [
              Icon(Icons.memory, size: 12, color: palette.textSecondary),
              const SizedBox(width: 4),
              Text('${res.model}  •  ${res.tookMs}ms',
                  style: TextStyle(fontSize: 13, color: palette.textSecondary)),
            ],
          ),

          // Unstable warning
          if (res.unstable) ...[
            const SizedBox(height: XSSpacing.sm),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.amber.shade900.withValues(alpha: 0.2),
                border: Border.all(color: Colors.amber.shade700, width: 0.8),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  Icon(Icons.warning_amber_rounded, size: 12, color: Colors.amber.shade400),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'UNSTABLE MODEL — Retrained 5-class classifier.',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Colors.amber.shade300,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: XSSpacing.md),

          // Summary
          Text('SUMMARY',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: palette.textSecondary,
                  letterSpacing: 0.5)),
          const SizedBox(height: XSSpacing.xs),
          Expanded(
            child: SingleChildScrollView(
              child: Text(res.findings,
                  style: TextStyle(
                      fontSize: 13,
                      height: 1.5,
                      color: palette.textPrimary)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHistoryCard(XSPalette palette) {
    return Container(
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(XSRadius.lg),
        boxShadow: XSShadows.soft(palette),
        border: Border.all(color: palette.divider),
      ),
      child: Padding(
        padding: const EdgeInsets.all(XSSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.history, size: 14, color: palette.textSecondary),
                const SizedBox(width: 6),
                Text('PATIENT X-RAY HISTORY',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: palette.textSecondary,
                        letterSpacing: 0.5)),
              ],
            ),
            const SizedBox(height: XSSpacing.sm),
            Expanded(
              child: _history.isEmpty
                  ? Center(
                      child: Text('No previous X-rays for this patient',
                          style: TextStyle(
                              fontSize: 14,
                              color: palette.textSecondary.withValues(alpha: 0.6))),
                    )
                  : ListView.separated(
                      itemCount: _history.length.clamp(0, 5),
                      separatorBuilder: (_, _) => Divider(
                        height: 1,
                        color: palette.divider,
                      ),
                      itemBuilder: (ctx, i) {
                        final h = _history[i];
                        final prediction = h['prediction'] ?? 'Unknown';
                        final isHistNormal = prediction.toLowerCase() == 'normal';
                        final conf = (h['confidence'] ?? 0);
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(
                            children: [
                              Container(
                                width: 28,
                                height: 28,
                                decoration: BoxDecoration(
                                  color: (isHistNormal ? XSColors.accentGreen : XSColors.accentOrange)
                                      .withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Icon(
                                  isHistNormal ? Icons.check : Icons.warning_amber_rounded,
                                  size: 14,
                                  color: isHistNormal ? XSColors.accentGreen : XSColors.accentOrange,
                                ),
                              ),
                              const SizedBox(width: XSSpacing.sm),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(prediction,
                                        style: TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w600,
                                            color: palette.textPrimary)),
                                    Text(h['created_at'] ?? '',
                                        style: TextStyle(
                                            fontSize: 13,
                                            color: palette.textSecondary)),
                                  ],
                                ),
                              ),
                              Text(
                                '${(conf * 100).toStringAsFixed(0)}%',
                                style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                    color: palette.textPrimary),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown in the result panel while a request is in flight — mirrors the
/// scanning motif on the image with a lightweight shimmer skeleton so the
/// panel doesn't look frozen while waiting.
class _AnalyzingPlaceholder extends StatefulWidget {
  const _AnalyzingPlaceholder({super.key});

  @override
  State<_AnalyzingPlaceholder> createState() => _AnalyzingPlaceholderState();
}

class _AnalyzingPlaceholderState extends State<_AnalyzingPlaceholder>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        final glow = 0.35 + _ctrl.value * 0.35;
        return Padding(
          padding: const EdgeInsets.all(XSSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation(
                        palette.textPrimary.withValues(alpha: glow),
                      ),
                    ),
                  ),
                  const SizedBox(width: XSSpacing.sm),
                  Text('ANALYZING',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.6,
                          color: palette.textSecondary.withValues(alpha: glow))),
                ],
              ),
              const SizedBox(height: XSSpacing.lg),
              _shimmerBar(palette, glow, width: 140, height: 22),
              const SizedBox(height: XSSpacing.sm),
              _shimmerBar(palette, glow, width: double.infinity, height: 10),
              const SizedBox(height: XSSpacing.md),
              _shimmerBar(palette, glow, width: 90, height: 11),
              const SizedBox(height: XSSpacing.sm),
              _shimmerBar(palette, glow, width: double.infinity, height: 13),
              const SizedBox(height: 6),
              _shimmerBar(palette, glow, width: double.infinity, height: 13),
              const SizedBox(height: 6),
              _shimmerBar(palette, glow, width: 200, height: 13),
            ],
          ),
        );
      },
    );
  }

  Widget _shimmerBar(XSPalette palette, double glow,
      {required double width, required double height}) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: palette.divider.withValues(alpha: glow * 0.6),
        borderRadius: BorderRadius.circular(6),
      ),
    );
  }
}
