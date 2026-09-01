import 'package:flutter/material.dart';
import '../../core/theme/xs_colors.dart';
import '../../core/theme/xs_spacing.dart';
import '../components/xs_button.dart';
import '../components/xs_card.dart';

class _OnboardPage {
  final String title;
  final String body;
  final IconData icon;
  const _OnboardPage(this.title, this.body, this.icon);
}

/// Three-step onboarding tour.
class OnboardingScreen extends StatefulWidget {
  final VoidCallback onFinish;
  const OnboardingScreen({super.key, required this.onFinish});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _controller = PageController();
  int _index = 0;

  static const _pages = [
    _OnboardPage(
      'AI-Assisted Assessment',
      'XSIGHT combines vitals, lung sounds, and conversational AI to support thoracic screening.',
      Icons.auto_awesome_outlined,
    ),
    _OnboardPage(
      'Connect Your Robot',
      'Pair the XSIGHT robot to collect heart rate, SpO\u2082, temperature, and breath sounds in real time.',
      Icons.bluetooth_searching_outlined,
    ),
    _OnboardPage(
      'Talk, Record, Review',
      'Chat with the AI assistant, record lung sounds, and review your risk summary on demand.',
      Icons.mic_none_outlined,
    ),
  ];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    return Scaffold(
      backgroundColor: palette.surface,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: XSSpacing.lg),
          child: Column(
            children: [
              const SizedBox(height: XSSpacing.lg),
              Expanded(
                child: PageView.builder(
                  controller: _controller,
                  onPageChanged: (i) => setState(() => _index = i),
                  itemCount: _pages.length,
                  itemBuilder: (context, i) {
                    final p = _pages[i];
                    // Center when the viewport is tall enough, but scroll
                    // instead of overflowing on short/landscape screens.
                    return LayoutBuilder(
                      builder: (context, constraints) {
                        return SingleChildScrollView(
                          child: ConstrainedBox(
                            constraints:
                                BoxConstraints(minHeight: constraints.maxHeight),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                XSCard(
                                  padding: const EdgeInsets.all(XSSpacing.xxl),
                                  child: Icon(p.icon,
                                      size: 56, color: palette.textPrimary),
                                ),
                                const SizedBox(height: XSSpacing.xxl),
                                Text(p.title,
                                    textAlign: TextAlign.center,
                                    style: Theme.of(context)
                                        .textTheme
                                        .displayLarge),
                                const SizedBox(height: XSSpacing.md),
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: XSSpacing.lg),
                                  child: Text(
                                    p.body,
                                    textAlign: TextAlign.center,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(
                                            color: palette.textSecondary),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(
                  _pages.length,
                  (i) => AnimatedContainer(
                    duration: const Duration(milliseconds: 240),
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    width: i == _index ? 24 : 8,
                    height: 6,
                    decoration: BoxDecoration(
                      color: i == _index
                          ? palette.textPrimary
                          : palette.divider,
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: XSSpacing.xl),
              XSButton(
                label: _index == _pages.length - 1 ? 'Get Started' : 'Next',
                inverted: true,
                width: double.infinity,
                onPressed: () {
                  if (_index == _pages.length - 1) {
                    widget.onFinish();
                  } else {
                    _controller.nextPage(
                      duration: const Duration(milliseconds: 320),
                      curve: Curves.easeOutCubic,
                    );
                  }
                },
              ),
              const SizedBox(height: XSSpacing.sm),
              TextButton(
                onPressed: widget.onFinish,
                child: Text(
                  'Skip',
                  style: TextStyle(color: palette.textSecondary),
                ),
              ),
              const SizedBox(height: XSSpacing.sm),
            ],
          ),
        ),
      ),
    );
  }
}
