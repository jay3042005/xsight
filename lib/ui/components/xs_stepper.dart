import 'package:flutter/material.dart';
import '../../core/theme/xs_colors.dart';
import '../../core/theme/xs_radius.dart';
import '../../core/theme/xs_scale.dart';
import '../../core/theme/xs_shadows.dart';

/// One station in the assessment journey.
class XSStep {
  final String label;
  final IconData icon;
  final Color color;
  final bool done;

  /// The reading that completed this step stood in for an absent sensor.
  ///
  /// The rail is the fastest read of session progress, so it has to carry the
  /// distinction too: a filled node otherwise says "measured" for a value no
  /// sensor produced.
  final bool simulated;

  const XSStep({
    required this.label,
    required this.icon,
    required this.color,
    required this.done,
    this.simulated = false,
  });

  /// Colour to draw this step in — the module colour normally, the demo colour
  /// once a simulated reading has completed it.
  Color get accent => done && simulated ? Colors.amber.shade800 : color;
}

/// Horizontal progress rail for the multi-station assessment.
///
/// A walk-up user needs to know how many stations remain and which one is next
/// without being told. Completed steps fill with their module color and check;
/// the next incomplete step pulses. Replaces the unlabelled 8x8px dot row.
class XSStepper extends StatefulWidget {
  final List<XSStep> steps;

  /// Called when a step is tapped, if the kiosk allows jumping stations.
  final ValueChanged<int>? onStepTap;

  const XSStepper({super.key, required this.steps, this.onStepTap});

  @override
  State<XSStepper> createState() => _XSStepperState();
}

class _XSStepperState extends State<XSStepper>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  /// First incomplete step, or -1 when the journey is finished.
  int get _nextIndex => widget.steps.indexWhere((s) => !s.done);

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    final s = XSScale.factor;
    final next = _nextIndex;
    final doneCount = widget.steps.where((e) => e.done).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            for (var i = 0; i < widget.steps.length; i++) ...[
              if (i > 0)
                Expanded(
                  child: Container(
                    height: 3 * s,
                    margin: EdgeInsets.symmetric(horizontal: 6 * s),
                    decoration: BoxDecoration(
                      // The connector fills once the step it leads *into* is
                      // done, so the rail reads as a filling progress bar.
                      color: widget.steps[i].done
                          ? widget.steps[i].accent
                          : palette.divider,
                      borderRadius: BorderRadius.circular(XSRadius.pill),
                    ),
                  ),
                ),
              _node(palette, i, i == next, s),
            ],
          ],
        ),
        SizedBox(height: 8 * s),
        Text(
          next < 0
              ? 'All stations complete — open Readings Summary'
              : 'Step ${doneCount + 1} of ${widget.steps.length} · next: '
                  '${widget.steps[next].label}',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: palette.textSecondary,
          ),
        ),
      ],
    );
  }

  Widget _node(XSPalette palette, int i, bool isNext, double s) {
    final step = widget.steps[i];
    final size = 44.0 * s;

    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, _) {
        // Only the next station pulses; everything else is still.
        final p = isNext ? _pulse.value : 0.0;
        final node = AnimatedContainer(
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: step.done ? step.accent : palette.surface,
            shape: BoxShape.circle,
            border: Border.all(
              color: step.done || isNext ? step.accent : palette.divider,
              width: (isNext ? 2.5 : 1.5) * s,
            ),
            boxShadow: [
              if (isNext) ...XSShadows.glow(step.color, intensity: 0.4 + p * 0.6),
              ...XSShadows.soft(palette),
            ],
          ),
          child: Center(
            child: Icon(
              step.done ? Icons.check_rounded : step.icon,
              size: 21 * s,
              color: step.done ? Colors.white : step.color,
            ),
          ),
        );

        final labelled = Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            node,
            SizedBox(height: 5 * s),
            Text(
              step.label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: isNext ? FontWeight.w800 : FontWeight.w600,
                color: step.done || isNext ? step.color : palette.textSecondary,
              ),
            ),
          ],
        );

        if (widget.onStepTap == null) return labelled;
        return Semantics(
          button: true,
          label: '${step.label}${step.done ? ", complete" : ""}',
          child: GestureDetector(
            onTap: () => widget.onStepTap!(i),
            child: labelled,
          ),
        );
      },
    );
  }
}
