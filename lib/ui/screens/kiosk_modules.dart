import 'package:flutter/material.dart';

import '../../core/theme/xs_colors.dart';

/// Stable identity for a kiosk module, independent of where it sits in any menu.
///
/// The radial orbit is filtered per mode, so a module's *position* is not a
/// usable identifier: guest slot 4 and staff slot 4 are different modules.
/// Screens, ESP32 state numbers, and `NAV:` tokens all key off this enum
/// instead, so hiding or reordering a module cannot silently launch the wrong
/// one.
enum XSModule { xray, steth, vitals, temp, summary, assistant, settings }

/// Presentation data for one module in the radial cockpit.
typedef XSModuleInfo = ({
  IconData icon,
  String label,
  String sub,
  String tag,
  String sensor,
  List<String> details,
  Color color,
});

/// The kiosk's module catalogue and the per-mode views of it.
///
/// Lives apart from the shell widget so the index mapping — the part with a real
/// failure mode — is testable without mounting a screen that needs serial and
/// audio plugins.
class XSModules {
  XSModules._();

  /// Every module the kiosk can open. Complete regardless of mode, so a
  /// module's identity, colour, and copy never depend on who is looking.
  static const catalogue = <XSModule, XSModuleInfo>{
    XSModule.xray: (
      icon: Icons.medical_services_outlined,
      label: 'Upload X-Ray',
      sub: 'Chest radiograph AI analysis',
      tag: 'RADIOLOGY DIAGNOSTICS',
      sensor: 'DICOM / Image AI Pipeline',
      details: [
        'Multi-pathology detection (Pneumonia, TB, Effusion)',
        'Heatmap visualization & confidence scoring',
        'Instant triage report integration',
      ],
      color: XSColors.moduleXray,
    ),
    XSModule.steth: (
      icon: Icons.graphic_eq,
      label: 'Digital Stethoscope',
      sub: 'Lung & heart auscultation',
      tag: 'ACOUSTIC ANALYSIS',
      sensor: 'MAX9814 20Hz–800Hz Bandpassed Mic',
      details: [
        'Real-time 2kHz acoustic waveform streaming',
        'Spectral lung sound classification',
        'High / low frequency audio filtering',
      ],
      color: XSColors.moduleSteth,
    ),
    XSModule.vitals: (
      icon: Icons.monitor_heart_outlined,
      label: 'Heart Rate & SpO\u2082',
      sub: 'Pulse oximetry reading',
      tag: 'BIOMETRIC MONITORING',
      sensor: 'MAX30102 Optical Pulse Sensor',
      details: [
        'Continuous pulse waveform tracking',
        'SpO2 blood oxygen saturation measurement',
        'Real-time arrhythmia indicator',
      ],
      color: XSColors.moduleVitals,
    ),
    XSModule.temp: (
      icon: Icons.thermostat_outlined,
      label: 'Temperature',
      sub: 'Infrared thermal sensing',
      tag: 'THERMAL SENSING',
      sensor: 'GY-906 / MLX90614 Non-contact IR',
      details: [
        'Infrared reading from your fingertip',
        'Celsius & Fahrenheit telemetry',
        'Fever threshold alert classifier',
      ],
      color: XSColors.moduleTemp,
    ),
    XSModule.summary: (
      icon: Icons.summarize_outlined,
      label: 'Readings Summary',
      sub: 'Clinical decision support',
      tag: 'CLINICAL REPORTING',
      sensor: 'CDSS Aggregation Engine',
      details: [
        'Consolidated thoracic assessment score',
        'Automated Triage Risk Level calculation',
        'One-click PDF patient report generation',
      ],
      color: XSColors.moduleSummary,
    ),
    XSModule.assistant: (
      icon: Icons.psychology_outlined,
      label: 'AI Assistant',
      sub: 'Voice & text clinical companion',
      tag: 'NEURAL CONVERSATIONAL AI',
      sensor: 'Streaming LLM + Kokoro Voice Engine',
      details: [
        'Interactive clinical Q&A & guidelines',
        'Hands-free voice mode with hardware OK trigger',
        'Pre-send quick-reply clinical chips',
      ],
      color: XSColors.moduleAssistant,
    ),
    XSModule.settings: (
      icon: Icons.settings_outlined,
      label: 'Settings',
      sub: 'Server IP & system configuration',
      tag: 'SYSTEM CONFIGURATION',
      sensor: 'FastAPI Backend & Network Telemetry',
      details: [
        'Backend server IP / URL configuration',
        'Real-time server connectivity health test',
        'Sensor & display telemetry settings',
      ],
      color: XSColors.moduleSettings,
    ),
  };

  /// Orbit a walk-up guest sees, ordered to match the guest dashboard's journey
  /// rail (pulse → temp → lungs → x-ray) so a station's position is the same in
  /// both places.
  ///
  /// Settings is staff-only: it exposes the backend URL and device telemetry,
  /// which a walk-up user has no reason to reach. The AI assistant stays —
  /// "what does this reading mean" is the main thing a guest wants that no
  /// sensor provides.
  static const guest = [
    XSModule.vitals,
    XSModule.temp,
    XSModule.steth,
    XSModule.xray,
    XSModule.summary,
    XSModule.assistant,
  ];

  /// Staff reach everything, in clinical-workflow order.
  static const staff = [
    XSModule.xray,
    XSModule.steth,
    XSModule.vitals,
    XSModule.temp,
    XSModule.summary,
    XSModule.assistant,
    XSModule.settings,
  ];

  static List<XSModule> forMode({required bool isGuest}) =>
      isGuest ? guest : staff;

  /// The single OLED menu that firmware predating `MENU_SEL:` had, in its
  /// original order.
  ///
  /// This is the coordinate system `MENU_INDEX:<n>` spoke in. Current firmware
  /// carries two menus — [guest] and [staff] order, of different lengths — so a
  /// bare position no longer names one station, and the module now leads with
  /// `MENU_SEL:<token>` instead. [Esp32SerialClient] stops honouring
  /// `MENU_INDEX:` as soon as it sees a token, which leaves this list meaning
  /// exactly one thing: where an old build's index pointed.
  ///
  /// It excludes [XSModule.settings], which the old menu had no entry for, and
  /// it is *not* the same order as [guest]. Reading a raw index straight out of
  /// [guest] is what made the OLED highlight "UPLOAD XRAY" while the screen
  /// focused Vitals, so the legacy path still goes through
  /// [moduleForFirmwareIndex] rather than indexing a mode list.
  static const firmwareMenu = [
    XSModule.xray,
    XSModule.steth,
    XSModule.vitals,
    XSModule.temp,
    XSModule.summary,
    XSModule.assistant,
  ];

  /// Which module the OLED highlight at [index] refers to, or null if the
  /// firmware sent an index outside its own menu.
  static XSModule? moduleForFirmwareIndex(int index) =>
      index >= 0 && index < firmwareMenu.length ? firmwareMenu[index] : null;

  /// Where [module] sits in the OLED menu, or null for modules the OLED has no
  /// entry for (currently only settings).
  static int? firmwareIndexOf(XSModule module) {
    final i = firmwareMenu.indexOf(module);
    return i < 0 ? null : i;
  }

  /// Modules a walk-up guest is not allowed to reach, whatever route asks for
  /// them. The orbit already hides these, but the serial link is a second
  /// entrance: the firmware menu is fixed, so a `NAV:SETTINGS` or `STATE:8`
  /// arriving in guest mode would otherwise open the backend configuration
  /// screen for a member of the public.
  static bool isAllowed(XSModule module, {required bool isGuest}) =>
      !isGuest || guest.contains(module);

  /// Screen title per module.
  static const titles = {
    XSModule.xray: 'X-Ray',
    XSModule.steth: 'Lung Sounds',
    XSModule.vitals: 'Vitals',
    XSModule.temp: 'Temperature',
    XSModule.summary: 'Summary',
    XSModule.assistant: 'AI Assistant',
    XSModule.settings: 'Settings',
  };

  /// Firmware's `NAV:` token per module. Fixed by the ESP32 protocol — these are
  /// wire names and must not be renamed to match UI copy.
  static const navNames = {
    XSModule.xray: 'XRAY',
    XSModule.steth: 'SOUNDS',
    XSModule.vitals: 'VITALS',
    XSModule.temp: 'TEMP',
    XSModule.summary: 'SUMMARY',
    XSModule.assistant: 'ASSIST',
    XSModule.settings: 'SETTINGS',
  };

  /// Firmware's `STATE:` number per module. 0 is the dashboard and 1 the menu,
  /// so modules start at 2. Also fixed by the protocol.
  static const espStates = {
    XSModule.xray: 2,
    XSModule.steth: 3,
    XSModule.vitals: 4,
    XSModule.temp: 5,
    XSModule.summary: 6,
    XSModule.assistant: 7,
    XSModule.settings: 8,
  };

  static XSModule? forNav(String dest) => switch (dest) {
        'XRAY' => XSModule.xray,
        'SOUNDS' => XSModule.steth,
        'VITALS' => XSModule.vitals,
        'TEMP' => XSModule.temp,
        'SUMMARY' => XSModule.summary,
        'ASSIST' => XSModule.assistant,
        'SETTINGS' => XSModule.settings,
        _ => null,
      };

  static XSModule? forEspState(int state) => espStates.entries
      .where((e) => e.value == state)
      .map((e) => e.key)
      .firstOrNull;
}
