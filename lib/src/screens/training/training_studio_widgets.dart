import 'package:flutter/material.dart';

import '../../theme/app_tokens.dart';

const trainingStudioImage = 'assets/training/nightstudio.png';

/// Bundled editorial artwork; it never represents a user's exercise or result.
class TrainingStudioArtwork extends StatelessWidget {
  const TrainingStudioArtwork({super.key, this.backgroundColor});

  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final backdrop = backgroundColor ?? t.bg;
    return ExcludeSemantics(
      child: Stack(
        fit: StackFit.expand,
        children: [
          Image.asset(
            trainingStudioImage,
            fit: BoxFit.cover,
            alignment: Alignment.centerRight,
            errorBuilder: (_, _, _) => ColoredBox(color: backdrop),
          ),
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
