import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// A word that writes itself, left to right.
///
/// The reveal is a soft-edged mask travelling across a script face, not a
/// stroked bezier outline. Two reasons: the letterforms come from the font, so
/// the greeting stays legible at arm's length and can be re-worded without
/// re-authoring a path; and there is no per-glyph outline data to drift out of
/// shape when [text] or the scale bucket changes.
///
/// A faint nib rides the leading edge. Without it a linear mask reads as a wipe
/// transition rather than as ink being laid down, which is the whole effect.
class XSHandwrittenWord extends StatelessWidget {
  final String text;

  /// 0 = nothing written, 1 = fully written. Driven by the owning screen so the
  /// greeting can be staged against the rest of its intro.
  final Animation<double> progress;

  final double fontSize;
  final Color color;

  /// Hide the travelling nib once the word is parked — a finished greeting
  /// should not keep a dot resting on its last letter.
  final bool showNib;

  const XSHandwrittenWord({
    super.key,
    required this.text,
    required this.progress,
    required this.color,
    this.fontSize = 96,
    this.showNib = true,
  });

  /// Script face, with a graceful degrade.
  ///
  /// `google_fonts` fetches at runtime, exactly as the rest of the app's
  /// typography already does, and falls back to the platform font when the
  /// kiosk is offline. An italic fallback keeps the greeting reading as
  /// handwriting rather than as a heading. Bundling Caveat under `assets/fonts`
  /// would make the effect offline-proof; see the note in DESIGN_SYSTEM.md.
  TextStyle _script() {
    final fallback = TextStyle(
      fontSize: fontSize,
      fontWeight: FontWeight.w600,
      fontStyle: FontStyle.italic,
      color: color,
      height: 1.05,
      letterSpacing: -1,
    );
    try {
      return GoogleFonts.caveat(textStyle: fallback.copyWith(fontStyle: FontStyle.normal));
    } catch (_) {
      return fallback;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: progress,
      builder: (context, _) {
        final p = progress.value.clamp(0.0, 1.0);
        // Softness of the wet edge, as a fraction of the word's width. Clamped
        // below `p` so the gradient stops stay non-decreasing at p == 0.
        const feather = 0.06;
        final soft = (p - feather).clamp(0.0, 1.0);

        final word = ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (bounds) => LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: const [
              Colors.white,
              Colors.white,
              Colors.transparent,
              Colors.transparent,
            ],
            stops: [0.0, soft, p, 1.0],
          ).createShader(bounds),
          child: Text(
            text,
            maxLines: 1,
            softWrap: false,
            style: _script(),
          ),
        );

        // FittedBox rather than a smaller font on narrow windows: the greeting
        // is one line by design, and scaling it down keeps the nib's travel
        // aligned with the glyphs it is supposed to be drawing.
        return FittedBox(
          fit: BoxFit.scaleDown,
          child: Stack(
            alignment: Alignment.centerLeft,
            children: [
              word,
              if (showNib && p > 0.01 && p < 0.995)
                Align(
                  alignment: Alignment(-1 + 2 * p, 0.42),
                  child: Container(
                    width: fontSize * 0.07,
                    height: fontSize * 0.07,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: color.withValues(alpha: 0.55),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
