import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/common/motion.dart';
import '../../widgets/design/design.dart';
import '../../widgets/shared/eatova_wordmark.dart';

// ---------------------------------------------------------------------------
// The onboarding's frame: header with back and progress, the per-step title
// block and the section captions inside a step.
// ---------------------------------------------------------------------------

/// The step's progress through the visible questions.
const Duration _kProgress = Duration(milliseconds: 260);

/// Largest text scale of a step title: a 30 px heading is large text already,
/// and at 2.0 it would push the question off a 320 px phone (same reasoning
/// as [AppType.pageTitleMaxScale]).
const double _kTitleMaxScale = 1.6;

/// Top bar: the wordmark on the first step, the round back button after it,
/// the step count, and a segmented progress bar.
///
/// The progress is announced as ONE live region ("Your goal, step 2 of 8"),
/// so a screen reader hears where it landed after every Next and Back.
class OnboardingHeader extends StatelessWidget {
  const OnboardingHeader({
    super.key,
    required this.index,
    required this.count,
    required this.phaseLabel,
    this.onBack,
  });

  final int index;
  final int count;
  final String phaseLabel;

  /// Null on the first step: the root route's system Back closes the app,
  /// and an arrow that does nothing would lie.
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: HeaderIconButton.size),
          child: Row(
            children: <Widget>[
              if (onBack != null)
                HeaderIconButton(
                  key: const ValueKey('onboarding-back'),
                  icon: Icons.chevron_left_rounded,
                  semanticLabel: l10n.onboardingBackSemanticLabel,
                  onTap: onBack,
                )
              else
                // A logotype keeps its size (WCAG 1.4.4 exempts it); scaled
                // to 2.0 it would crowd the counter on a narrow phone.
                MediaQuery.withNoTextScaling(
                  child: EatovaWordmark(
                    fontSize: 22,
                    textColor: t.ink,
                    ringColor: t.accent,
                  ),
                ),
              const Spacer(),
              ExcludeSemantics(
                child: Text(
                  '${index + 1} / $count',
                  style: AppType.ui(13, weight: FontWeight.w700, color: t.ink3),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Semantics(
          label: '$phaseLabel, ${l10n.onboardingStepProgress(index + 1, count)}',
          liveRegion: true,
          child: ExcludeSemantics(
            child: _ProgressBar(index: index, count: count),
          ),
        ),
      ],
    );
  }
}

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.index, required this.count});

  final int index;
  final int count;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final duration = motionDuration(context, _kProgress);
    return Row(
      key: const ValueKey('onboarding-progress'),
      children: <Widget>[
        for (var i = 0; i < count; i++) ...<Widget>[
          if (i > 0) const SizedBox(width: 4),
          Expanded(
            child: AnimatedContainer(
              duration: duration,
              curve: kMotionCurve,
              height: 4,
              decoration: BoxDecoration(
                color: i <= index ? t.accent : t.surf2,
                borderRadius: BorderRadius.circular(rPill),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// One question screen: eyebrow, title (heading level 1), subtitle, answer.
class OnboardingStepFrame extends StatelessWidget {
  const OnboardingStepFrame({
    super.key,
    required this.eyebrow,
    required this.title,
    required this.child,
    this.subtitle,
    this.badge,
  });

  final String eyebrow;
  final String title;
  final String? subtitle;

  /// Quiet tag next to the eyebrow, e.g. "Optional".
  final String? badge;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Wrap(
          spacing: 10,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            Text(
              eyebrow.toUpperCase(),
              semanticsLabel: eyebrow,
              style: AppType.sectionEyebrow(t.accentText),
            ),
            if (badge != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                decoration: BoxDecoration(
                  color: t.surf2,
                  borderRadius: BorderRadius.circular(rPill),
                ),
                child: Text(
                  badge!,
                  style: AppType.ui(
                    11.5,
                    weight: FontWeight.w700,
                    color: t.inkMuted,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        HeadingSemantics(
          level: 1,
          child: Text(
            title,
            textScaler: MediaQuery.textScalerOf(
              context,
            ).clamp(maxScaleFactor: _kTitleMaxScale),
            style: AppType.display(30, color: t.ink, height: 1.1),
          ),
        ),
        if (subtitle != null) ...<Widget>[
          const SizedBox(height: 10),
          Text(
            subtitle!,
            style: AppType.ui(
              15,
              weight: FontWeight.w500,
              color: t.ink2,
              height: 1.45,
            ),
          ),
        ],
        const SizedBox(height: 26),
        child,
      ],
    );
  }
}

/// The caption above one answer inside a step ("AGE"), heading level 2 —
/// the settings group caption's style, read in its own case.
class OnboardingSectionLabel extends StatelessWidget {
  const OnboardingSectionLabel(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 4, bottom: 10),
    child: HeadingSemantics(
      level: 2,
      child: Text(
        label.toUpperCase(),
        semanticsLabel: label,
        style: AppType.sectionEyebrow(context.t.ink2),
      ),
    ),
  );
}

/// A quiet sentence under an answer (why we ask, what a default means).
class OnboardingHint extends StatelessWidget {
  const OnboardingHint(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
    child: Text(
      text,
      style: AppType.ui(13, color: context.t.ink2, height: 1.4),
    ),
  );
}
