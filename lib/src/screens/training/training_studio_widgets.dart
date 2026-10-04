import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/app_tokens.dart';

const trainingStudioImage = 'assets/training/nightstudio.png';

/// Pixel size of [trainingStudioImage].
const Size _studioImageSize = Size(1536, 1024);

/// Decode width for the artwork in [constraints]: what the cover fit paints,
/// instead of the full 1536 x 1024 bitmap (6 MB) for a 190 px band. A box
/// narrower than the image's aspect is covered by height, so that width
/// counts then.
int _decodeWidth(BoxConstraints constraints, double dpr) {
  final width = constraints.maxWidth.isFinite ? constraints.maxWidth : 400.0;
  final height = constraints.maxHeight.isFinite ? constraints.maxHeight : 0.0;
  final aspect = _studioImageSize.width / _studioImageSize.height;
  final logical = math.max(width, height * aspect);
  return (logical * dpr).ceil().clamp(1, _studioImageSize.width.toInt());
}

/// Luminance gain of [studioDuotone]: the night-studio photo is mostly
/// shadow, so its luminance is stretched before it is mapped onto the ramp.
const double kStudioDuotoneGain = 2;

/// A duotone: each pixel's luminance (times [kStudioDuotoneGain], clamped)
/// picks a tone on the ramp from [shadow] to [highlight].
ColorFilter studioDuotone(Color shadow, Color highlight) {
  List<double> row(double from, double to) {
    final span = (to - from) * kStudioDuotoneGain;
    return [span * 0.2126, span * 0.7152, span * 0.0722, 0, from * 255];
  }

  return ColorFilter.matrix(<double>[
    ...row(shadow.r, highlight.r),
    ...row(shadow.g, highlight.g),
    ...row(shadow.b, highlight.b),
    ...<double>[0, 0, 0, 1, 0],
  ]);
}

/// Bundled editorial artwork; it never represents a user's exercise or result.
///
/// The photo is a dark night studio. Faded into a light backdrop it turned
/// into a grey fog, so on a light backdrop it is re-toned as a duotone from
/// the hero-glow lavender (`arcStart`) to the backdrop itself: the plate
/// stays a soft lavender print and the fades blend into the card. A dark
/// backdrop shows the photo as shot.
class TrainingStudioArtwork extends StatelessWidget {
  const TrainingStudioArtwork({super.key, this.backgroundColor});

  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final backdrop = backgroundColor ?? t.bg;
    final toned =
        ThemeData.estimateBrightnessForColor(backdrop) == Brightness.light;
    Widget photo = LayoutBuilder(
      builder: (context, constraints) => Image.asset(
        trainingStudioImage,
        fit: BoxFit.cover,
        alignment: Alignment.centerRight,
        cacheWidth: _decodeWidth(
          constraints,
          MediaQuery.devicePixelRatioOf(context),
        ),
        errorBuilder: (_, _, _) => ColoredBox(color: backdrop),
      ),
    );
    if (toned) {
      photo = ColorFiltered(
        key: const ValueKey('training-studio-duotone'),
        colorFilter: studioDuotone(t.arcStart, backdrop),
        child: photo,
      );
    }
    return ExcludeSemantics(
      child: Stack(
        fit: StackFit.expand,
        children: [
          photo,
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  backdrop,
                  backdrop.withValues(alpha: 0.65),
                  backdrop.withValues(alpha: 0),
                ],
                stops: const [0, 0.35, 1],
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  backdrop.withValues(alpha: 0.2),
                  backdrop.withValues(alpha: 0),
                  backdrop,
                ],
                stops: const [0, 0.65, 1],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The design's primary pill (54 px, accent fill, soft violet glow): Start,
/// Resume and Review on the workout card, Coach on the empty state.
class TrainingStartButton extends StatelessWidget {
  const TrainingStartButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon = Icons.play_arrow_rounded,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(rButton),
        boxShadow: onPressed == null
            ? null
            : [
                BoxShadow(
                  color: t.accentGlow,
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ],
      ),
      child: SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: onPressed,
          icon: Icon(icon, size: 20),
          label: Text(label, style: AppType.ui(16, weight: FontWeight.w800)),
          style: FilledButton.styleFrom(
            backgroundColor: t.accentFill,
            foregroundColor: t.onAccentFill,
            disabledBackgroundColor: t.accentFill.withValues(alpha: 0.38),
            disabledForegroundColor: t.onAccentFill.withValues(alpha: 0.8),
            minimumSize: const Size(0, kPrimaryButtonHeight),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(rButton),
            ),
          ),
        ),
      ),
    );
  }
}
