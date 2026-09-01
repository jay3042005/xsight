import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/xs_colors.dart';
import '../../core/theme/xs_radius.dart';
import '../../core/theme/xs_scale.dart';
import '../../core/theme/xs_shadows.dart';
import '../../core/theme/xs_spacing.dart';

/// Numeric PIN entry sized for a walk-up kiosk.
///
/// XSIGHT is a wall-mounted tablet driven by physical buttons over serial, and
/// nothing guarantees a soft keyboard: Android kiosk mode suppresses it and the
/// desktop build depends on the host having a keyboard attached at all. A plain
/// `TextField` for the staff PIN therefore has a failure mode where the digits
/// cannot be typed — so the pad is the input, not a convenience on top of one.
///
/// Entry is fixed-width and self-submitting: [onCompleted] fires the moment the
/// last slot fills, so signing in is [length] taps with no confirm button to
/// find. Digit keys are also accepted from a real keyboard, matching the
/// keyboard fallback the rest of the kiosk offers for desktop development.
class XSPinPad extends StatefulWidget {
  const XSPinPad({
    super.key,
    required this.onCompleted,
    this.length = 4,
    this.accent,
    this.errorText,
    this.enabled = true,
    this.autofocus = true,
  });

  /// Called with the assembled PIN once [length] digits are entered.
  final ValueChanged<String> onCompleted;

  /// How many digits make a complete PIN.
  final int length;

  /// Slot fill and key highlight. Defaults to the palette accent.
  final Color? accent;

  /// Message shown beneath the slots. Changing it to a non-null value also
  /// empties the pad, so a rejected attempt leaves an empty row to type into
  /// rather than a full one the user must erase first.
  final String? errorText;

  final bool enabled;

  /// Claim keyboard focus on mount. Off when something else on the screen owns
  /// the caret, so typing a name does not also fill the PIN.
  final bool autofocus;

  @override
  State<XSPinPad> createState() => XSPinPadState();
}

class XSPinPadState extends State<XSPinPad> {
  final List<int> _digits = [];
  final FocusNode _focus = FocusNode(debugLabel: 'XSPinPad');

  /// Digits entered so far. Exposed so a host dialog can tell an untouched pad
  /// from a partly filled one.
  int get filled => _digits.length;

  @override
  void didUpdateWidget(XSPinPad oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.errorText != oldWidget.errorText && widget.errorText != null) {
      _digits.clear();
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  /// Give the pad the keyboard again — after the host's text field has had it.
  void requestFocus() => _focus.requestFocus();

  void _push(int digit) {
    if (!widget.enabled || _digits.length >= widget.length) return;
    setState(() => _digits.add(digit));
    if (_digits.length < widget.length) return;

    // Hand the PIN over one frame later so the slot the user just filled is
    // actually painted before the caller tears the dialog down. Without this the
    // pad appears to submit on the third digit.
    final pin = _digits.join();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onCompleted(pin);
    });
  }

  void _backspace() {
    if (!widget.enabled || _digits.isEmpty) return;
    setState(() => _digits.removeLast());
  }

  void _clear() {
    if (!widget.enabled || _digits.isEmpty) return;
    setState(_digits.clear);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;

    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.backspace ||
        key == LogicalKeyboardKey.delete) {
      _backspace();
      return KeyEventResult.handled;
    }

    final ch = event.character;
    if (ch != null && ch.length == 1) {
      final code = ch.codeUnitAt(0);
      if (code >= 0x30 && code <= 0x39) {
        _push(code - 0x30);
        return KeyEventResult.handled;
      }
    }

    // Everything else — Escape above all — belongs to the host, which uses it to
    // dismiss the dialog.
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    final accent = widget.accent ?? palette.accent;
    final s = XSScale.factor;

    return Focus(
      focusNode: _focus,
      autofocus: widget.autofocus,
      onKeyEvent: _onKey,
      // Laid out at its natural size and scaled down as one piece to whatever box
      // it is given. Two properties depend on this being a single scale rather
      // than a per-part measurement:
      //
      // * Nothing scrolls. A pad whose bottom row has to be scrolled into reach
      //   is a row the user will not find, and the PIN is entered in one gesture
      //   sequence with no chance to notice a scrollbar.
      // * It reports intrinsic dimensions. A `LayoutBuilder` here cannot, and
      //   `AlertDialog` asks its content for an intrinsic width — that
      //   combination asserts at layout time.
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _slots(palette, accent, s),
            SizedBox(height: XSSpacing.xs * s),
            SizedBox(
              height: 18 * s,
              child: widget.errorText == null
                  ? null
                  : Text(
                      widget.errorText!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: XSColors.accentRed,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
            ),
            SizedBox(height: XSSpacing.sm * s),
            _keypad(palette, accent, s),
          ],
        ),
      ),
    );
  }

  Widget _slots(XSPalette palette, Color accent, double s) {
    final size = 16 * s;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < widget.length; i++)
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 7 * s),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOutCubic,
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: i < _digits.length ? accent : palette.surface,
                border: Border.all(
                  color: i < _digits.length ? accent : palette.divider,
                  width: 1.4,
                ),
                boxShadow: i < _digits.length
                    ? XSShadows.glow(accent, intensity: 0.5)
                    : XSShadows.pressed(palette),
              ),
            ),
          ),
      ],
    );
  }

  Widget _keypad(XSPalette palette, Color accent, double s) {
    final gap = XSSpacing.sm * s;
    final key = 74.0 * s;

    Widget digit(int d) => _PadKey(
          size: key,
          accent: accent,
          onTap: widget.enabled ? () => _push(d) : null,
          child: Text(
            '$d',
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w700,
              color: palette.textPrimary,
            ),
          ),
        );

    Widget row(List<Widget> keys, {bool last = false}) => Padding(
          padding: EdgeInsets.only(bottom: last ? 0 : gap),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < keys.length; i++) ...[
                if (i > 0) SizedBox(width: gap),
                keys[i],
              ],
            ],
          ),
        );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        row([digit(1), digit(2), digit(3)]),
        row([digit(4), digit(5), digit(6)]),
        row([digit(7), digit(8), digit(9)]),
        row(last: true, [
          _PadKey(
            size: key,
            accent: accent,
            onTap: _digits.isEmpty ? null : _clear,
            child: Text(
              'CLR',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.5,
                color: palette.textSecondary,
              ),
            ),
          ),
          digit(0),
          _PadKey(
            size: key,
            accent: accent,
            onTap: _digits.isEmpty ? null : _backspace,
            child: Icon(
              Icons.backspace_outlined,
              size: 22 * s,
              color: palette.textSecondary,
            ),
          ),
        ]),
      ],
    );
  }
}

/// One round keypad key.
///
/// Its own widget rather than an [XSButton] because the digit has to be legible
/// at arm's length and `XSButton` pins its label to 15px — the design system's
/// text sizes are deliberately fixed, so a bigger glyph needs a different
/// component rather than a parameter.
class _PadKey extends StatefulWidget {
  const _PadKey({
    required this.size,
    required this.child,
    required this.accent,
    this.onTap,
  });

  final double size;
  final Widget child;
  final Color accent;
  final VoidCallback? onTap;

  @override
  State<_PadKey> createState() => _PadKeyState();
}

class _PadKeyState extends State<_PadKey> {
  bool _pressed = false;

  void _set(bool v) {
    if (widget.onTap == null) return;
    setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    final disabled = widget.onTap == null;

    return GestureDetector(
      onTapDown: (_) => _set(true),
      onTapCancel: () => _set(false),
      onTapUp: (_) => _set(false),
      onTap: widget.onTap,
      child: AnimatedScale(
        // The app disables Material ripple, so the press has to read
        // geometrically or the key looks dead. Same trick as XSButton.
        scale: _pressed ? 0.94 : 1.0,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOutCubic,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOutCubic,
          width: widget.size,
          height: widget.size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: palette.surface,
            borderRadius: BorderRadius.circular(XSRadius.pill),
            boxShadow: _pressed
                ? XSShadows.pressed(palette)
                : XSShadows.convex(palette),
          ),
          child: Opacity(opacity: disabled ? 0.35 : 1, child: widget.child),
        ),
      ),
    );
  }
}
