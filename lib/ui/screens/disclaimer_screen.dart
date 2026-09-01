import 'package:flutter/material.dart';
import '../../core/theme/xs_colors.dart';
import '../../core/theme/xs_spacing.dart';
import '../components/xs_button.dart';
import '../components/xs_card.dart';
import '../../core/voice/voice_guide.dart';

class DisclaimerScreen extends StatefulWidget {
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  const DisclaimerScreen({
    super.key,
    required this.onAccept,
    required this.onDecline,
  });

  @override
  State<DisclaimerScreen> createState() => _DisclaimerScreenState();
}

class _DisclaimerScreenState extends State<DisclaimerScreen> {
  @override
  void initState() {
    super.initState();
    // Read aloud as well as shown. Someone who cannot read the screen is
    // exactly who most needs to hear that this is not a diagnosis.
    VoiceGuide.I.say(XSVoiceCue.disclaimer);
  }

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    return Scaffold(
      backgroundColor: palette.surface,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(XSSpacing.lg),
          child: Column(
            children: [
              const SizedBox(height: XSSpacing.xl),
              Icon(Icons.info_outline,
                  size: 36, color: palette.textPrimary),
              const SizedBox(height: XSSpacing.lg),
              Text(
                'Medical Disclaimer',
                style: Theme.of(context).textTheme.displayLarge,
              ),
              const SizedBox(height: XSSpacing.lg),
              Expanded(
                child: SingleChildScrollView(
                  child: XSCard(
                    child: Text(
                      'XSIGHT is an AI-assisted screening and educational support tool. '
                      'It does not provide a medical diagnosis and should not replace '
                      'consultation with licensed healthcare professionals.\n\n'
                      'All readings, classifications, and risk levels produced by this '
                      'app are preliminary and intended only to support clinical workflow. '
                      'Always seek professional advice for any medical concern.\n\n'
                      'By continuing, you acknowledge that you have read and understood '
                      'this disclaimer.',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: XSSpacing.lg),
              Row(
                children: [
                  Expanded(
                    child: XSButton(
                      label: 'Decline',
                      onPressed: widget.onDecline,
                    ),
                  ),
                  const SizedBox(width: XSSpacing.md),
                  Expanded(
                    child: XSButton(
                      label: 'Agree',
                      inverted: true,
                      onPressed: widget.onAccept,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
