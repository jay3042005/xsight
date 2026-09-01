import 'package:flutter/material.dart';

import '../../core/api/intake_handoff_client.dart';
import '../../core/theme/xs_colors.dart';
import '../../core/theme/xs_scale.dart';
import '../../core/theme/xs_spacing.dart';
import '../components/xs_ambient_background.dart';
import '../components/xs_button.dart';
import '../components/xs_handwritten_word.dart';
import '../components/xs_intake_qr_panel.dart';
import '../components/xs_staff_dialogs.dart';

/// What check-in resolved to.
///
/// [name] alone is the kiosk-typed path; [details] carries a phone submission,
/// which may also contain a name. Both null means the person chose to start
/// without giving anything, which is a valid answer — see
/// `KioskPatientSession.openIntakeSession`.
@immutable
class KioskCheckInResult {
  final String? name;
  final Map<String, dynamic>? details;

  const KioskCheckInResult({this.name, this.details});

  /// Started without giving any details.
  static const skipped = KioskCheckInResult();
}

/// The kiosk's front door: a greeting that writes itself, then a QR that moves
/// the typing onto a phone.
///
/// Replaces the old typed check-in dialog. The kiosk is button-driven and
/// deliberately not a typing surface — a soft keyboard on a shared clinical
/// panel is slow, unhygienic, and unreadable at arm's length — so the one step
/// that genuinely needs a keyboard happens in a browser on the patient's own
/// phone, and the kiosk only collects the result.
///
/// A full-screen route rather than a fourth `_View` in the shell: the ESP32
/// state machine has fixed ordinals (0 dashboard, 1 menu, 2+ modules) that
/// `test/firmware_protocol_test.dart` pins to `XSModules.espStates`, so a new
/// view would need a firmware ordinal or would leave the OLED pointing at a
/// station the screen is not showing. As a route it needs no firmware change:
/// the hub's OK press still arrives as `MENU_READY`, which the shell turns into
/// "close check-in and open the orbit".
class KioskCheckInScreen extends StatefulWidget {
  /// Mint an intake session on mount. Off in widget tests, which have no backend
  /// and must not leave the relay's countdown timer pending.
  final bool autoStartHandoff;

  const KioskCheckInScreen({super.key, this.autoStartHandoff = true});

  /// The mounted screen, or null when check-in is not up.
  ///
  /// Lets the shell close check-in *with* whatever has been collected when the
  /// hardware opens its own menu mid-check-in, instead of popping the route
  /// blind. Same pattern as `VoiceModeScreen.activeState`.
  static KioskCheckInScreenState? activeState;

  /// [onRouteContext] hands this route's own context back to the caller so
  /// hardware can dismiss exactly this screen — see `_dismissCheckIn` in the
  /// kiosk shell.
  static Future<KioskCheckInResult?> show(
    BuildContext context, {
    ValueChanged<BuildContext>? onRouteContext,
  }) {
    return Navigator.of(context).push<KioskCheckInResult>(
      PageRouteBuilder<KioskCheckInResult>(
        transitionDuration: const Duration(milliseconds: 360),
        reverseTransitionDuration: const Duration(milliseconds: 240),
        pageBuilder: (ctx, animation, secondaryAnimation) {
          onRouteContext?.call(ctx);
          return const KioskCheckInScreen();
        },
        transitionsBuilder: (context, animation, secondaryAnimation, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    );
  }

  @override
  State<KioskCheckInScreen> createState() => KioskCheckInScreenState();
}

class KioskCheckInScreenState extends State<KioskCheckInScreen>
    with TickerProviderStateMixin {
  /// One controller for the whole intro, sliced with intervals, so the greeting
  /// and the panel are staged without a bare `Future.delayed` — a pending timer
  /// would fail every widget test that mounts this screen.
  late final AnimationController _intro;
  late final Animation<double> _pen;
  late final Animation<double> _settle;

  /// Runs once details arrive, so the confirmation is legible before the route
  /// pops. Timer-free for the same reason.
  late final AnimationController _confirm;

  late final IntakeHandoffClient _handoff;
  bool _popped = false;

  @override
  void initState() {
    super.initState();
    KioskCheckInScreen.activeState = this;

    _intro = AnimationController(
      duration: const Duration(milliseconds: 1900),
      vsync: this,
    );
    _pen = CurvedAnimation(
      parent: _intro,
      curve: const Interval(0.0, 0.58, curve: Curves.easeInOut),
    );
    _settle = CurvedAnimation(
      parent: _intro,
      curve: const Interval(0.70, 1.0, curve: Curves.easeOutCubic),
    );
    _confirm = AnimationController(
      duration: const Duration(milliseconds: 850),
      vsync: this,
    )..addStatusListener((s) {
        if (s == AnimationStatus.completed) {
          _finish(KioskCheckInResult(
            name: _nameFromDetails,
            details: _handoff.details,
          ));
        }
      });

    _handoff = IntakeHandoffClient()..addListener(_onHandoff);
    if (widget.autoStartHandoff) _handoff.start();

    _intro.forward();
  }

  @override
  void dispose() {
    if (KioskCheckInScreen.activeState == this) {
      KioskCheckInScreen.activeState = null;
    }
    _handoff.removeListener(_onHandoff);
    _handoff.dispose();
    _confirm.dispose();
    _intro.dispose();
    super.dispose();
  }

  String? get _nameFromDetails {
    final raw = _handoff.details?['name'];
    if (raw is! String) return null;
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  void _onHandoff() {
    if (!mounted) return;
    if (_handoff.state == IntakeHandoffState.received &&
        !_confirm.isAnimating &&
        _confirm.value == 0) {
      _confirm.forward();
    }
    setState(() {});
  }

  /// Pop once, whatever the route in. Guarded because hardware and the touch
  /// buttons can both land here on the same press.
  void _finish(KioskCheckInResult result) {
    if (_popped || !mounted) return;
    _popped = true;
    Navigator.of(context).pop(result);
  }

  /// Close as though the person had chosen to start, keeping anything already
  /// collected. Called by the shell when hardware advances past check-in.
  void submitAndClose() {
    _finish(
      _handoff.details == null
          ? KioskCheckInResult.skipped
          : KioskCheckInResult(
              name: _nameFromDetails,
              details: _handoff.details,
            ),
    );
  }

  /// Fallback for someone who will not or cannot use a phone. Reuses the
  /// existing typed dialog rather than growing a second name form — a skipped
  /// dialog still starts the session, which is the long-standing behaviour.
  Future<void> _enterOnKiosk() async {
    final name = await XSIntakeCheckInDialog.show(context);
    if (!mounted) return;
    _finish(KioskCheckInResult(name: name));
  }

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);

    return Scaffold(
      backgroundColor: palette.surface,
      body: XSAmbientBackground(
        intensity: 0.7,
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              // Side by side only when there is genuinely room for both halves.
              // Portrait tablets stack instead: the greeting parks at the top and
              // the panel sits beneath it.
              final wide = constraints.maxWidth >= 900;
              return AnimatedBuilder(
                animation: Listenable.merge([_intro, _confirm]),
                builder: (context, _) => Stack(
                  children: [
                    _greeting(palette, constraints, wide),
                    _panelLayer(palette, constraints, wide),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  /// The greeting: centred while it writes itself, parked aside afterwards.
  Widget _greeting(XSPalette palette, BoxConstraints c, bool wide) {
    final v = _settle.value;
    final parked = wide ? const Alignment(0.66, 0) : const Alignment(0, -0.74);

    return Align(
      alignment: Alignment.lerp(Alignment.center, parked, v)!,
      child: SizedBox(
        width: wide ? c.maxWidth * 0.38 : c.maxWidth * 0.86,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment:
              wide ? CrossAxisAlignment.start : CrossAxisAlignment.center,
          children: [
            XSHandwrittenWord(
              text: 'Hello',
              progress: _pen,
              color: palette.textPrimary,
              fontSize: wide ? 132 : 96,
              // The nib is only honest while the word is being written; once it
              // parks, a dot resting on the final letter reads as a smudge.
              showNib: v < 0.02,
            ),
            // Everything under the greeting belongs to the parked state, so it
            // fades in with the panel rather than crowding the writing.
            Opacity(
              opacity: v,
              child: Padding(
                padding: EdgeInsets.only(top: XSSpacing.md * XSScale.factor),
                child: Column(
                  crossAxisAlignment: wide
                      ? CrossAxisAlignment.start
                      : CrossAxisAlignment.center,
                  children: [
                    Text(
                      'Welcome to XSIGHT',
                      textAlign: wide ? TextAlign.start : TextAlign.center,
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.5,
                        color: palette.textPrimary,
                      ),
                    ),
                    SizedBox(height: 6 * XSScale.factor),
                    Text(
                      'Add your details on your phone, then the kiosk will guide '
                      'you through each station. This is an assisted screening, '
                      'not a diagnosis.',
                      textAlign: wide ? TextAlign.start : TextAlign.center,
                      style: TextStyle(
                        fontSize: 15,
                        height: 1.45,
                        color: palette.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The action side: the code, or the reason there isn't one, plus the ways past
  /// it.
  Widget _panelLayer(XSPalette palette, BoxConstraints c, bool wide) {
    final v = _settle.value;
    final parked = wide ? const Alignment(-0.66, 0) : const Alignment(0, 0.62);

    return IgnorePointer(
      // Nothing here is hittable until it has substantially arrived, so a press
      // landing during the intro cannot activate a button that is still moving.
      ignoring: v < 0.5,
      child: Align(
        alignment: parked,
        child: Opacity(
          opacity: v,
          child: Transform.translate(
            offset: wide ? Offset(-34 * (1 - v), 0) : Offset(0, 28 * (1 - v)),
            child: SizedBox(
              width: wide ? c.maxWidth * 0.38 : c.maxWidth * 0.86,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    XSIntakeQrPanel(
                      handoff: _handoff,
                      onRetry: _handoff.restart,
                      receivedName: _nameFromDetails,
                    ),
                    SizedBox(height: XSSpacing.md * XSScale.factor),
                    _actions(palette),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _actions(XSPalette palette) {
    // Hidden once details land: the screen is already leaving, and offering a
    // skip mid-exit invites a press that races the pop.
    if (_handoff.state == IntakeHandoffState.received) {
      return const SizedBox.shrink();
    }
    return Column(
      children: [
        XSButton(
          label: 'ENTER DETAILS ON THE KIOSK',
          icon: Icons.keyboard_alt_outlined,
          color: XSColors.moduleSettings,
          height: 56,
          width: double.infinity,
          onPressed: _enterOnKiosk,
        ),
        SizedBox(height: XSSpacing.xs * XSScale.factor),
        TextButton(
          onPressed: () => _finish(KioskCheckInResult.skipped),
          child: Text(
            'Start without giving details',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: palette.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}
