import 'dart:convert';

/// A visual-answer card the AI asked the kiosk to render.
///
/// Cards are *declarative render requests, not data payloads*. The model emits
/// `{"card": "vitals_table"}` — it does not emit the numbers. Every measured
/// value is filled in by the widget from [KioskPatientSession], which is what
/// makes this safe to put in front of a clinician: a card structurally cannot
/// display a heart rate the sensor never produced, and "not measured" stays
/// "not measured" without depending on the model behaving.
///
/// [XSAiCardType.differential] is the one exception — those conditions and
/// confidences are the model's own reasoning, and the card labels them as such.
enum XSAiCardType {
  /// Normal reference / this patient's film / AI heatmap, side by side.
  xrayCompare('xray_compare'),

  /// This session's vitals against reference ranges.
  vitalsTable('vitals_table'),

  /// Overall risk dial.
  riskGauge('risk_gauge'),

  /// Ranked candidate conditions — model-authored.
  differential('differential');

  const XSAiCardType(this.wire);

  /// The name the model and the backend use for this card.
  final String wire;

  static XSAiCardType? fromWire(String? name) {
    if (name == null) return null;
    final key = name.trim().toLowerCase();
    for (final t in values) {
      if (t.wire == key) return t;
    }
    return null;
  }
}

/// Interprets a model-supplied confidence or score.
///
/// Three cases, and no guessing between them:
///   * already `0..1` — used as-is
///   * a whole number in `1..100` — a percentage the model wrote as `85`
///   * anything else (`1.4`, `3.2`, `-1`, `NaN`) — implausible, so `null`
///
/// The tempting shortcut is to rescale everything above 1, but that turns a
/// clamped `1.4` into `0.014` — a near-empty confidence bar for something the
/// model meant as near-certain. Clamping it to `1.0` instead is the opposite
/// error and worse: it would present garbage as full confidence in a clinical
/// tool. Refusing to interpret it is the only honest option.
double? _plausibleUnitValue(Object? raw) {
  if (raw is! num) return null;
  final v = raw.toDouble();
  if (v.isNaN || v.isInfinite) return null;
  if (v >= 0 && v <= 1) return v;
  if (v > 1 && v <= 100 && v == v.roundToDouble()) return v / 100;
  return null;
}

/// One model-proposed condition in an [XSAiCardType.differential] card.
class XSDifferentialItem {
  final String condition;

  /// 0..1. An unusable value from the model becomes 0, which renders as an
  /// empty bar — an honest "no confidence stated" rather than an invented one.
  final double confidence;

  /// Where the model says this came from, e.g. `'chest film'`. May be empty.
  final String source;

  XSDifferentialItem({
    required this.condition,
    required double confidence,
    this.source = '',
  }) : confidence = _plausibleUnitValue(confidence) ?? 0;

  static XSDifferentialItem? _tryParse(Object? raw) {
    if (raw is! Map) return null;
    final condition = (raw['condition'] ?? raw['diagnosis'] ?? '').toString().trim();
    if (condition.isEmpty) return null;
    final conf = raw['confidence'];
    return XSDifferentialItem(
      condition: condition,
      confidence: conf is num ? conf.toDouble() : 0,
      source: (raw['source'] ?? '').toString().trim(),
    );
  }
}

/// A parsed card. [data] holds whatever the model sent alongside `card`.
class XSAiCard {
  final XSAiCardType type;
  final Map<String, dynamic> data;

  const XSAiCard(this.type, [this.data = const {}]);

  /// Region the model wants highlighted, e.g. `'left lower zone'`.
  /// Only meaningful on [XSAiCardType.xrayCompare].
  String? get focus {
    final f = data['focus'];
    if (f is! String) return null;
    final t = f.trim();
    return t.isEmpty ? null : t;
  }

  /// Model-supplied risk score, 0..1, or null to let the widget derive one
  /// from the session. An implausible value is null rather than coerced — see
  /// [_plausibleUnitValue].
  double? get score => _plausibleUnitValue(data['score']);

  /// Model-supplied risk level (`low`/`moderate`/`high`/`critical`), lowercased,
  /// or null.
  String? get level {
    final l = data['level'];
    if (l is! String) return null;
    final t = l.trim().toLowerCase();
    return t.isEmpty ? null : t;
  }

  /// Differential entries, malformed ones dropped.
  List<XSDifferentialItem> get items {
    final raw = data['items'];
    if (raw is! List) return const [];
    return raw
        .map(XSDifferentialItem._tryParse)
        .whereType<XSDifferentialItem>()
        .toList();
  }

  /// Parse the backend's `cards` array.
  ///
  /// Deliberately total: an unknown card name, a non-map entry, or a missing
  /// `card` key is skipped rather than thrown. A malformed card must cost the
  /// clinician one panel, never the whole answer.
  static List<XSAiCard> parseList(Object? raw) {
    if (raw is! List) return const [];
    final out = <XSAiCard>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final type = XSAiCardType.fromWire(entry['card']?.toString());
      if (type == null) continue;
      out.add(XSAiCard(
        type,
        Map<String, dynamic>.from(
          entry.map((k, v) => MapEntry(k.toString(), v)),
        ),
      ));
    }
    return out;
  }

  /// Client-side fallback extraction of ```` ```xsight-card ```` fences.
  ///
  /// The backend normally strips these before the text reaches us. This is the
  /// safety net for an app pointed at an older server: without it the fence
  /// renders as raw JSON in a chat bubble, or gets read aloud by TTS.
  static (String prose, List<XSAiCard> cards) extract(String text) {
    if (!text.toLowerCase().contains('xsight-card')) return (text, const []);
    final re = RegExp(
      r'```[ \t]*xsight-card[ \t]*\r?\n?([\s\S]*?)(?:```|$)',
      caseSensitive: false,
    );
    final cards = <XSAiCard>[];
    final prose = text.replaceAllMapped(re, (m) {
      final payload = (m.group(1) ?? '').trim().replaceAll(RegExp(r'`+$'), '').trim();
      if (payload.isEmpty) return '\n';
      try {
        final obj = jsonDecode(payload);
        cards.addAll(parseList([obj]));
      } catch (_) {
        // Malformed payload — drop the block, keep the prose.
      }
      return '\n';
    });
    return (prose.trim(), cards);
  }
}

/// Reference bands for the vitals table.
///
/// Alarm thresholds match `kiosk_vitals_screen.dart` exactly so an AI card can
/// never contradict the gauge the clinician just looked at. (The backend keeps
/// its own copy in `server/app/cdss.py`; unifying those two is a separate job —
/// this at least stops a third copy appearing.)
enum XSVitalStatus { normal, borderline, alarm, notMeasured }

class XSVitalRange {
  final String label;
  final String unit;

  /// Inclusive normal band, shown in the "reference" column.
  final double normalLow;
  final double normalHigh;

  /// Outside this band is an alarm; between the bands is borderline.
  final double alarmLow;
  final double alarmHigh;

  /// Decimal places for display.
  final int precision;

  const XSVitalRange({
    required this.label,
    required this.unit,
    required this.normalLow,
    required this.normalHigh,
    required this.alarmLow,
    required this.alarmHigh,
    this.precision = 0,
  });

  /// Human-readable reference band, e.g. `'60–100'` or `'≥95'`.
  String get referenceText {
    if (normalHigh >= 100 && label.startsWith('SpO')) {
      return '≥${_fmt(normalLow)}';
    }
    return '${_fmt(normalLow)}–${_fmt(normalHigh)}';
  }

  String _fmt(double v) => v.toStringAsFixed(precision);

  String format(double v) => v.toStringAsFixed(precision);

  /// Classifies a reading. `null` — the station was never measured — is
  /// [XSVitalStatus.notMeasured], never silently treated as zero.
  XSVitalStatus statusOf(double? value) {
    if (value == null || value <= 0) return XSVitalStatus.notMeasured;
    if (value < alarmLow || value > alarmHigh) return XSVitalStatus.alarm;
    if (value < normalLow || value > normalHigh) return XSVitalStatus.borderline;
    return XSVitalStatus.normal;
  }
}

class XSVitalRanges {
  XSVitalRanges._();

  static const hr = XSVitalRange(
    label: 'Heart rate',
    unit: 'bpm',
    normalLow: 60,
    normalHigh: 100,
    alarmLow: 50,
    alarmHigh: 100,
  );

  static const spo2 = XSVitalRange(
    label: 'SpO₂',
    unit: '%',
    normalLow: 95,
    normalHigh: 100,
    alarmLow: 92,
    alarmHigh: 100,
  );

  static const temp = XSVitalRange(
    label: 'Temperature',
    unit: '°C',
    normalLow: 36.1,
    normalHigh: 37.2,
    alarmLow: 35.0,
    alarmHigh: 38.4,
    precision: 1,
  );

  static const rr = XSVitalRange(
    label: 'Respiratory rate',
    unit: '/min',
    normalLow: 12,
    normalHigh: 20,
    alarmLow: 10,
    alarmHigh: 24,
  );
}
