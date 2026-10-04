import '../../l10n/l10n.dart';
import '../../models/user_profile.dart';
import '../../services/kcal_calculator.dart';

// The onboarding's vocabulary, shared by the flow (onboarding_screen.dart) and
// its step widgets. Decisions and their reasons: docs/ONBOARDING-2026-10-04.md.

/// The screens of the onboarding, in flow order. The enum order IS the flow:
/// navigation walks it and skips what [OnboardingStep] visibility rules hide
/// (target and pace exist only for a direction with a reachable target).
enum OnboardingStep { goal, basics, body, activity, target, pace, diet, summary }

/// The first question: where the plan should go. [WeightGoal] mixes direction
/// and pace; the onboarding asks them on separate screens.
enum OnboardingDirection { lose, maintain, gain }

/// The direction a stored [goal] stands for.
OnboardingDirection onboardingDirectionOf(WeightGoal goal) => goal.isLoss
    ? OnboardingDirection.lose
    : goal.isGain
    ? OnboardingDirection.gain
    : OnboardingDirection.maintain;

extension OnboardingDirectionInfo on OnboardingDirection {
  /// Pace options from gentle to ambitious; empty for maintain.
  List<WeightGoal> get paceOptions => switch (this) {
    OnboardingDirection.lose => lossPaceGoals,
    OnboardingDirection.maintain => const <WeightGoal>[],
    OnboardingDirection.gain => gainPaceGoals,
  };

  /// The label of the matching [WeightGoal] direction (same ARB keys).
  String label(AppLocalizations l10n) => switch (this) {
    OnboardingDirection.lose => l10n.commonWeightGoalLabelLose,
    OnboardingDirection.maintain => l10n.commonWeightGoalLabelMaintain,
    OnboardingDirection.gain => l10n.commonWeightGoalLabelGain,
  };

  String description(AppLocalizations l10n) => switch (this) {
    OnboardingDirection.lose => l10n.onboardingGoalDescLose,
    OnboardingDirection.maintain => l10n.onboardingGoalDescMaintain,
    OnboardingDirection.gain => l10n.onboardingGoalDescGain,
  };
}

extension OnboardingStepInfo on OnboardingStep {
  /// The eyebrow above the step title, also spoken with the progress.
  /// Target and pace belong to the goal, so they share its label.
  String phaseLabel(AppLocalizations l10n) => switch (this) {
    OnboardingStep.goal ||
    OnboardingStep.target ||
    OnboardingStep.pace => l10n.onboardingPhaseGoal,
    OnboardingStep.basics => l10n.onboardingPhaseBasics,
    OnboardingStep.body => l10n.onboardingPhaseBody,
    OnboardingStep.activity => l10n.onboardingPhaseActivity,
    OnboardingStep.diet => l10n.onboardingPhaseDiet,
    OnboardingStep.summary => l10n.onboardingPhasePlan,
  };
}

/// Name of a pace option ("Moderat"); the pace label follows it in the title.
String onboardingPaceName(AppLocalizations l10n, WeightGoal goal) =>
    switch (goal) {
      WeightGoal.lose025kg || WeightGoal.gain025kg => l10n.onboardingPaceNameSanft,
      WeightGoal.lose05kg => l10n.onboardingPaceNameModerat,
      WeightGoal.lose075kg => l10n.onboardingPaceNameZuegig,
      WeightGoal.lose1kg || WeightGoal.gain05kg => l10n.onboardingPaceNameAmbitioniert,
      WeightGoal.maintain => l10n.onboardingPaceNameFallback,
    };

/// The sex labels of the onboarding (title case; the profile's
/// [BiologicalSexLabel.label] is lower case for inline use).
String onboardingSexLabel(AppLocalizations l10n, BiologicalSex sex) =>
    switch (sex) {
      BiologicalSex.male => l10n.onboardingSexMale,
      BiologicalSex.female => l10n.onboardingSexFemale,
      BiologicalSex.neutral => l10n.onboardingSexNeutral,
    };

/// The forecast sentence for the plan of [profile] ([targets] computed from
/// exactly it): the pace step shows it for the selected pace, the plan for
/// the finished draft.
///
/// Reads the EFFECTIVE goal: a direction with no reachable target (gaining at
/// the 300 kg column end) plans maintain and says so. A null forecast means
/// there is no honest one (target reached, rate in the rounding noise, or the
/// floor flips the direction): better no number than an invented one; the
/// why sits in [KcalTargets.paceWarning]. Since the kcal review 2026-08-21
/// the forecast is a RANGE, linear to dynamic.
String onboardingTimelineText(
  AppLocalizations l10n,
  UserProfile profile,
  KcalTargets targets,
) {
  if (profile.effectiveWeightGoal == WeightGoal.maintain) {
    return l10n.onboardingTimelineMaintain(profile.weightKg);
  }
  final weeks = const KcalCalculator().weeksToGoalRange(
    profile,
    targets: targets,
  );
  return weeks == null
      ? l10n.onboardingTimelineUnknown
      : timelineEstimateText(
          l10n,
          targetWeightKg: profile.targetWeightKg,
          weeks: weeks,
        );
}
