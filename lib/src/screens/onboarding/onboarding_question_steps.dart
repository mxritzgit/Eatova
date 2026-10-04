import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/model_limits.dart';
import '../../models/user_profile.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/design/design.dart';
import '../../widgets/shared/target_bmi_hint.dart';
import 'onboarding_chrome.dart';
import 'onboarding_controls.dart';
import 'onboarding_models.dart';

// ---------------------------------------------------------------------------
// The question screens, one decision each. They only render answers and
// report changes; the flow, the defaults and every rule that ties answers
// together live in onboarding_screen.dart.
// ---------------------------------------------------------------------------

/// Space between two option cards.
const double _kOptionGap = 10;

List<Widget> _spaced(List<Widget> cards) => <Widget>[
  for (var i = 0; i < cards.length; i++) ...<Widget>[
    if (i > 0) const SizedBox(height: _kOptionGap),
    cards[i],
  ],
];

/// Step 1: the direction. Motivation first; it also decides whether target
/// and pace are asked at all.
class OnboardingGoalStep extends StatelessWidget {
  const OnboardingGoalStep({
    super.key,
    required this.firstName,
    required this.value,
    required this.onChanged,
  });

  final String firstName;
  final OnboardingDirection value;
  final ValueChanged<OnboardingDirection> onChanged;

  static IconData _icon(OnboardingDirection direction) => switch (direction) {
    OnboardingDirection.lose => Icons.trending_down_rounded,
    OnboardingDirection.maintain => Icons.trending_flat_rounded,
    OnboardingDirection.gain => Icons.trending_up_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return OnboardingStepFrame(
      eyebrow: OnboardingStep.goal.phaseLabel(l10n),
      title: l10n.onboardingGoalTitle(firstName),
      subtitle: l10n.onboardingGoalSubtitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: _spaced(<Widget>[
          for (final direction in OnboardingDirection.values)
            OptionCard(
              actionKey: ValueKey('onboarding-goal-${direction.name}'),
              selected: value == direction,
              onTap: () => onChanged(direction),
              title: direction.label(l10n),
              subtitle: direction.description(l10n),
              leading: OptionGlyphTile(icon: _icon(direction)),
            ),
        ]),
      ),
    );
  }
}

/// Sex and age: the two personal inputs of the resting energy formula.
class OnboardingBasicsStep extends StatelessWidget {
  const OnboardingBasicsStep({
    super.key,
    required this.sex,
    required this.onSex,
    required this.age,
    required this.onAge,
  });

  final BiologicalSex sex;
  final ValueChanged<BiologicalSex> onSex;
  final int age;
  final ValueChanged<int> onAge;

  static IconData _icon(BiologicalSex sex) => switch (sex) {
    BiologicalSex.male => Icons.male_rounded,
    BiologicalSex.female => Icons.female_rounded,
    BiologicalSex.neutral => Icons.person_outline_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return OnboardingStepFrame(
      eyebrow: OnboardingStep.basics.phaseLabel(l10n),
      title: l10n.onboardingBasicsTitle,
      subtitle: l10n.onboardingBasicsSubtitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          OnboardingSectionLabel(l10n.onboardingSexLabel),
          OnboardingChoiceTiles<BiologicalSex>(
            values: BiologicalSex.values,
            selected: sex,
            onChanged: onSex,
            labelOf: (value) => onboardingSexLabel(l10n, value),
            iconOf: _icon,
            keyOf: (value) => ValueKey('onboarding-sex-${value.name}'),
          ),
          OnboardingHint(l10n.onboardingSexHint),
          const SizedBox(height: 26),
          OnboardingSectionLabel(l10n.onboardingAgeLabel),
          OnboardingNumberPicker(
            field: 'age',
            value: age,
            min: ProfileLimits.ageYearsMin,
            max: ProfileLimits.ageYearsMax,
            unit: l10n.onboardingUnitYears,
            onChanged: onAge,
          ),
        ],
      ),
    );
  }
}

/// Height and current weight.
class OnboardingBodyStep extends StatelessWidget {
  const OnboardingBodyStep({
    super.key,
    required this.height,
    required this.onHeight,
    required this.weight,
    required this.onWeight,
  });

  final int height;
  final ValueChanged<int> onHeight;
  final int weight;
  final ValueChanged<int> onWeight;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return OnboardingStepFrame(
      eyebrow: OnboardingStep.body.phaseLabel(l10n),
      title: l10n.onboardingBodyTitle,
      subtitle: l10n.onboardingBodySubtitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          OnboardingSectionLabel(l10n.onboardingHeightLabel),
          OnboardingNumberPicker(
            field: 'height',
            value: height,
            min: ProfileLimits.heightCmMin,
            max: ProfileLimits.heightCmMax,
            unit: l10n.commonUnitCm,
            onChanged: onHeight,
          ),
          const SizedBox(height: 22),
          OnboardingSectionLabel(l10n.onboardingWeightLabel),
          OnboardingNumberPicker(
            field: 'weight',
            value: weight,
            min: ProfileLimits.weightKgMin,
            max: ProfileLimits.weightKgMax,
            unit: l10n.commonUnitKg,
            onChanged: onWeight,
          ),
        ],
      ),
    );
  }
}

/// The PAL level, work and daily life without walking.
class OnboardingActivityStep extends StatelessWidget {
  const OnboardingActivityStep({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final ActivityLevel value;
  final ValueChanged<ActivityLevel> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    const levels = ActivityLevel.values;
    return OnboardingStepFrame(
      eyebrow: OnboardingStep.activity.phaseLabel(l10n),
      title: l10n.onboardingActivityStepTitle,
      subtitle: l10n.onboardingActivityStepSubtitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: _spaced(<Widget>[
          for (final (i, level) in levels.indexed)
            OptionCard(
              actionKey: ValueKey('onboarding-activity-${level.name}'),
              selected: value == level,
              onTap: () => onChanged(level),
              title: level.label(l10n),
              subtitle: level.description(l10n),
              badge: '×${formatPalFactor(level, l10n)}',
              leading: OnboardingIntensityMark(level: i + 1, of: levels.length),
            ),
        ]),
      ),
    );
  }
}

/// The target weight, inside the window the direction leaves open.
///
/// Built only for a nonempty window (the flow drops the step otherwise), so
/// the picker never sees an inverted range.
class OnboardingTargetStep extends StatelessWidget {
  const OnboardingTargetStep({
    super.key,
    required this.direction,
    required this.weight,
    required this.height,
    required this.target,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final OnboardingDirection direction;
  final int weight;
  final int height;

  /// The target in play, already inside [min] .. [max].
  final int target;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final delta = (weight - target).abs();
    return OnboardingStepFrame(
      eyebrow: OnboardingStep.target.phaseLabel(l10n),
      title: l10n.onboardingTargetStepTitle,
      subtitle: l10n.onboardingTargetStepSubtitle(weight),
      child: Column(
        key: const ValueKey('onboarding-target-section'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          OnboardingNumberPicker(
            field: 'target',
            value: target,
            min: min,
            max: max,
            unit: l10n.commonUnitKg,
            onChanged: onChanged,
            footnote: direction == OnboardingDirection.lose
                ? l10n.onboardingTargetFootnoteLose(delta)
                : l10n.onboardingTargetFootnoteGain(delta),
          ),
          TargetBmiHint(
            margin: const EdgeInsets.only(top: 14),
            heightCm: height,
            targetWeightKg: target,
          ),
        ],
      ),
    );
  }
}

/// The pace. Every option names the plan it yields for THIS body, and the
/// forecast under the list follows the selection.
class OnboardingPaceStep extends StatelessWidget {
  const OnboardingPaceStep({
    super.key,
    required this.direction,
    required this.value,
    required this.outcomeFor,
    required this.forecast,
    required this.onChanged,
  });

  final OnboardingDirection direction;
  final WeightGoal value;

  /// Subtitle of an option: its daily target and effective pace.
  final String Function(WeightGoal) outcomeFor;

  /// The time-to-target sentence for the selected pace.
  final String forecast;
  final ValueChanged<WeightGoal> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final options = direction.paceOptions;
    return OnboardingStepFrame(
      eyebrow: OnboardingStep.pace.phaseLabel(l10n),
      title: l10n.onboardingPaceStepTitle,
      subtitle: direction == OnboardingDirection.lose
          ? l10n.onboardingPaceStepSubtitleLose
          : l10n.onboardingPaceStepSubtitleGain,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          ..._spaced(<Widget>[
            // No leading mark: the consequence line ("Ergibt 1550 kcal/Tag ·
            // −0,5 kg/Woche") needs the width to stay on one line.
            for (final goal in options)
              OptionCard(
                actionKey: ValueKey('onboarding-pace-${goal.name}'),
                selected: value == goal,
                onTap: () => onChanged(goal),
                // Title = the choice (its name), subtitle = its consequence.
                title: l10n.onboardingPaceOptionTitle(
                  onboardingPaceName(l10n, goal),
                  goal.paceLabel(l10n),
                ),
                subtitle: outcomeFor(goal),
              ),
          ]),
          const SizedBox(height: 16),
          Container(
            key: const ValueKey('onboarding-pace-forecast'),
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            decoration: BoxDecoration(
              color: t.surf2,
              borderRadius: BorderRadius.circular(rTile),
            ),
            child: MergeSemantics(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Icon(
                      Icons.flag_outlined,
                      size: 18,
                      color: t.accentText,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      forecast,
                      style: AppType.ui(
                        14,
                        weight: FontWeight.w600,
                        color: t.ink,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The optional diet preference: recipe suggestions only, never the plan.
class OnboardingDietStep extends StatelessWidget {
  const OnboardingDietStep({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final DietPreference value;
  final ValueChanged<DietPreference> onChanged;

  static IconData _icon(DietPreference diet) => switch (diet) {
    DietPreference.none => Icons.restaurant_rounded,
    DietPreference.vegetarian => Icons.spa_outlined,
    DietPreference.vegan => Icons.eco_outlined,
    DietPreference.pescetarian => Icons.set_meal_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return OnboardingStepFrame(
      eyebrow: OnboardingStep.diet.phaseLabel(l10n),
      badge: l10n.onboardingOptionalBadge,
      title: l10n.onboardingDietStepTitle,
      subtitle: l10n.onboardingDietOptionalSubtitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: _spaced(<Widget>[
          for (final diet in DietPreference.values)
            OptionCard(
              actionKey: ValueKey('onboarding-diet-${diet.name}'),
              selected: value == diet,
              onTap: () => onChanged(diet),
              title: diet.label(l10n),
              subtitle: diet.description(l10n),
              leading: OptionGlyphTile(icon: _icon(diet)),
            ),
        ]),
      ),
    );
  }
}
