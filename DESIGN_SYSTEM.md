# XSIGHT App Design System

Neumorphism, monochrome (white + black only). For the XSIGHT IoT AI Chatbot Robot mobile app built in Flutter.

## Design Philosophy

- **Neumorphism**: soft shadows, subtle highlights, extruded surfaces
- **Monochrome**: pure white + pure black + neutral grays only
- **Clinical**: clean, calm, low-noise UI fitting a medical assessment context
- **Accessible**: high contrast text, large tap targets, clear hierarchy

## Theme Modes

Two themes, both monochrome:

1. **Light Mode** (default for clinical demo)
   - Surface: `#E8E8E8`
   - Light shadow: `#FFFFFF`
   - Dark shadow: `#A3A3A3`
   - Primary text: `#0A0A0A`
   - Secondary text: `#5C5C5C`

2. **Dark Mode**
   - Surface: `#1A1A1A`
   - Light shadow: `#2A2A2A`
   - Dark shadow: `#000000`
   - Primary text: `#F5F5F5`
   - Secondary text: `#A3A3A3`

## Color Tokens

```dart
class XSColors {
  // Light
  static const surfaceLight = Color(0xFFE8E8E8);
  static const highlightLight = Color(0xFFFFFFFF);
  static const shadowLight = Color(0xFFA3A3A3);
  static const textPrimaryLight = Color(0xFF0A0A0A);
  static const textSecondaryLight = Color(0xFF5C5C5C);

  // Dark
  static const surfaceDark = Color(0xFF1A1A1A);
  static const highlightDark = Color(0xFF2A2A2A);
  static const shadowDark = Color(0xFF000000);
  static const textPrimaryDark = Color(0xFFF5F5F5);
  static const textSecondaryDark = Color(0xFFA3A3A3);

  // Risk badges (still monochrome, signaled by intensity)
  static const riskLow = Color(0xFFE8E8E8);
  static const riskModerate = Color(0xFF8A8A8A);
  static const riskHigh = Color(0xFF0A0A0A);
}
```

## Typography

Use **Inter** or **SF Pro**. Fallback: `Roboto`.

| Style       | Size | Weight | Use                          |
| ----------- | ---- | ------ | ---------------------------- |
| Display     | 32   | 700    | Risk level, hero numbers     |
| Title       | 22   | 600    | Screen titles                |
| Subtitle    | 18   | 500    | Section headers              |
| Body        | 15   | 400    | Default text                 |
| Caption     | 13   | 500    | Labels, vitals units         |
| Mono Number | 28   | 700    | Live vitals (HR, SpO2, Temp) |

## Spacing Scale

`4 / 8 / 12 / 16 / 20 / 24 / 32 / 40 / 56`

## Radius Scale

- xs: 8
- sm: 12
- md: 16
- lg: 20
- xl: 28
- pill: 999

## Neumorphism Rules

### Convex (raised surface)

- 2 shadows: top-left light, bottom-right dark
- Background equals surface color
- Used for cards, buttons, tiles

### Concave (pressed/inset)

- Inverted shadows
- Used for inputs, sliders, pressed buttons

### Flat (no shadow)

- Used for chip text, helper text

### Shadow Recipe

```dart
// Convex
boxShadow: [
  BoxShadow(
    color: highlightColor,
    offset: Offset(-6, -6),
    blurRadius: 16,
  ),
  BoxShadow(
    color: shadowColor,
    offset: Offset(6, 6),
    blurRadius: 16,
  ),
]
```

For pressed/inset effect use a `Stack` with inner `BoxShadow` workaround through `CustomPainter` or `flutter_neumorphic_plus` package.

## Core Components

### XSCard

- Padding: 20
- Radius: 20
- Convex shadow
- Used for vitals tiles, summary blocks

### XSButton (Primary)

- Height: 56
- Radius: pill
- Convex idle, concave on press
- Label: white text on black surface (inverse) or black text on light surface

### XSIconButton

- 56 x 56 circle
- Convex
- Single icon, monochrome

### XSInputField

- Height: 56
- Radius: 16
- Concave (inset)
- Internal padding: 16
- Placeholder color: textSecondary

### XSChip

- Height: 32
- Radius: pill
- Flat in light mode, subtle outline
- Used for tags, filters

### XSStat

- Convex card
- Top: caption label
- Center: large mono number
- Bottom: small unit text

### XSChartCard

- Convex card
- Padding 16
- Title + line chart (no color, only black/gray strokes)
- Hover/touch indicator: black dot + tooltip

### XSChatBubble

- User: black bubble, white text, right aligned
- Assistant: light surface bubble, black text, left aligned, convex
- Radius: 20 with one corner reduced to 6 for tail

### XSWaveform

- Used for lung sound recording
- Black bars on light surface
- Animated peaks during recording

### XSRiskMeter

- Horizontal track, concave
- Indicator: filled black segment matching risk level
- Label: Low / Moderate / High in display weight

### XSBottomNav

- 4 tabs: Dashboard / Chat / Sound / Summary
- Convex container floating above content
- Active tab: concave well + bold icon
- Inactive: flat icon

### XSAppBar

- 64 height
- Title left, action icons right
- Flat, no elevation, surface color

### XSDialog

- Convex card centered
- Backdrop: 60% black overlay
- Used for medical disclaimer, alerts

### XSToggle

- Track concave
- Knob convex
- Off: knob left, On: knob right

### XSStepper

- Concave track
- Three pill steps: Inactive / Active / Done
- Active uses inverted (black) fill

## Screen Layouts

### 1. Splash Screen

- Centered XSIGHT logotype in black
- Below: thin progress shimmer line
- Background: surfaceLight

### 2. Onboarding (3 screens)

- Top: large illustration placeholder (line art monochrome)
- Middle: Display title
- Body text
- Bottom: XSStepper + XSButton (Next)

### 3. Disclaimer Screen

- XSDialog style content
- Heading: Medical Disclaimer
- Body text: AI-assisted screening only
- Two buttons: Decline / Agree & Continue

### 4. Home / Dashboard

- XSAppBar: title XSIGHT + status dot (connected/disconnected)
- Greeting text: Hello, Patient
- Row of 2x2 XSStat cards: HR, SpO2, Temp, RR
- XSChartCard: live vitals trend
- XSButton: Start Session
- XSBottomNav

### 5. Chatbot Screen

- XSAppBar: title Chat
- Scroll list of XSChatBubble
- Bottom dock:
  - XSInputField (concave)
  - XSIconButton: mic
  - XSIconButton: send
- TTS toggle: XSToggle in app bar

### 6. Lung Sound Screen

- Title: Record Lung Sound
- Center: large circular XSIconButton (record)
- Below: XSWaveform live animation
- Timer display: Mono number style
- Buttons: Stop / Save / Re-record
- Result card after upload: XSCard with label + confidence bar

### 7. Risk Summary Screen

- Hero: XSRiskMeter
- Display text: risk level
- XSCard: AI summary text
- List of contributing factors: XSStat row (vitals + lung sound + xray if any)
- XSButton: Save Report / Share PDF

### 8. History Screen

- List of past sessions
- Each row: XSCard with date, risk level chip, mini chart preview

### 9. Settings Screen

- List of XSCard rows: Profile / Robot Connection / Voice / Theme / About / Disclaimer
- Theme toggle: XSToggle

### 10. Robot Connection Screen

- Status indicator: large pulse circle in black
- Robot name + battery
- Buttons: Reconnect / Disconnect / Test TTS

## Iconography

- Single weight, line style, 2px stroke
- Source: Phosphor Icons (regular) or Material Symbols Outlined
- Color always primary text color, never tinted

## Motion

- Default ease: `Curves.easeOutCubic`
- Durations: 200ms (small), 320ms (default), 480ms (modal)
- Press feedback: scale 0.97 + shadow flatten
- Page transition: fade + 8px slide up
- Vitals number change: counter tween 600ms

## Accessibility

- Min tap area: 48 x 48
- Min text size: 13
- Contrast: AA on body, AAA on display
- Always pair color/state with icon or label (no color-only meaning, fits monochrome)
- VoiceOver/TalkBack labels required on icon-only buttons

## Recommended Flutter Packages

- `flutter_neumorphic_plus` for convex/concave widgets
- `google_fonts` for Inter
- `phosphor_flutter` for icons
- `fl_chart` for monochrome charts (configure stroke colors only)
- `flutter_animate` for subtle motion
- `lottie` optional for monochrome line animations

## File Structure (design layer)

```txt
lib/
  core/
    theme/
      xs_colors.dart
      xs_typography.dart
      xs_spacing.dart
      xs_radius.dart
      xs_shadows.dart
      xs_theme.dart
  ui/
    components/
      xs_card.dart
      xs_button.dart
      xs_icon_button.dart
      xs_input_field.dart
      xs_chip.dart
      xs_stat.dart
      xs_chart_card.dart
      xs_chat_bubble.dart
      xs_waveform.dart
      xs_risk_meter.dart
      xs_bottom_nav.dart
      xs_app_bar.dart
      xs_dialog.dart
      xs_toggle.dart
      xs_stepper.dart
```

## Sample Theme Code

```dart
import 'package:flutter/material.dart';

class XSTheme {
  static ThemeData light() {
    return ThemeData(
      brightness: Brightness.light,
      scaffoldBackgroundColor: const Color(0xFFE8E8E8),
      fontFamily: 'Inter',
      colorScheme: const ColorScheme.light(
        primary: Color(0xFF0A0A0A),
        onPrimary: Color(0xFFE8E8E8),
        surface: Color(0xFFE8E8E8),
        onSurface: Color(0xFF0A0A0A),
        secondary: Color(0xFF5C5C5C),
      ),
      textTheme: const TextTheme(
        displayLarge: TextStyle(fontSize: 32, fontWeight: FontWeight.w700),
        titleLarge:   TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
        titleMedium:  TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
        bodyMedium:   TextStyle(fontSize: 15, fontWeight: FontWeight.w400),
        labelSmall:   TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
      ),
    );
  }

  static ThemeData dark() {
    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xFF1A1A1A),
      fontFamily: 'Inter',
      colorScheme: const ColorScheme.dark(
        primary: Color(0xFFF5F5F5),
        onPrimary: Color(0xFF1A1A1A),
        surface: Color(0xFF1A1A1A),
        onSurface: Color(0xFFF5F5F5),
        secondary: Color(0xFFA3A3A3),
      ),
    );
  }
}
```

## Sample Convex Card Widget

```dart
import 'package:flutter/material.dart';

class XSCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final double radius;

  const XSCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
    this.radius = 20,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surface = isDark ? const Color(0xFF1A1A1A) : const Color(0xFFE8E8E8);
    final highlight = isDark ? const Color(0xFF2A2A2A) : const Color(0xFFFFFFFF);
    final shadow = isDark ? const Color(0xFF000000) : const Color(0xFFA3A3A3);

    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(radius),
        boxShadow: [
          BoxShadow(color: highlight, offset: const Offset(-6, -6), blurRadius: 16),
          BoxShadow(color: shadow, offset: const Offset(6, 6), blurRadius: 16),
        ],
      ),
      child: child,
    );
  }
}
```

## Sample Stat Tile

```dart
class XSStatTile extends StatelessWidget {
  final String label;
  final String value;
  final String unit;
  const XSStatTile({super.key, required this.label, required this.value, required this.unit});

  @override
  Widget build(BuildContext context) {
    return XSCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelSmall),
          const SizedBox(height: 8),
          Text(value, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(unit, style: Theme.of(context).textTheme.labelSmall),
        ],
      ),
    );
  }
}
```

## Demo Color Usage Rules

- No saturated colors anywhere
- Risk = darkness intensity, not hue
- Charts: black stroke + 1px gray grid
- Loading: black shimmer on light surface
- Success/Error states: black icon + bold label, no green/red

## Visual Tone Reference

- Apple Health (clinical, calm) without color
- Linear app (precision typography)
- Things 3 (whitespace, rhythm)
- Tonal Neumorphism Dribbble shots stripped of color

## Final Notes

- Keep contrast strong; neumorphism shadows should never bury text
- Use neumorphism on containers, not on text
- Avoid over-stacking shadows; one convex layer is enough
- Always test light + dark side by side before shipping
