import 'package:intl/intl.dart';

import '../l10n/l10n.dart';

enum BiologicalSex { male, female, neutral }

extension BiologicalSexLabel on BiologicalSex {
  /// User-facing label, localized via the ARB.
  ///
  /// Persistence still uses `sex.name`; only the display needs the active
  /// language. Mirrors [MealSlotStyle.label].
  String label(AppLocalizations l10n) => switch (this) {
        BiologicalSex.male => l10n.commonSexLabelMale,
        BiologicalSex.female => l10n.commonSexLabelFemale,
        BiologicalSex.neutral => l10n.commonSexLabelNeutral,
      };
}

/// Work and daily life **excluding walking**. Multiplies BMR into TDEE; steps
/// are added on top separately (`estimateKcalBurnedFromSteps`).
///
/// The ladder excludes walking on purpose (kcal review 2026-08-21): every step
/// should count, so a walking-inclusive ladder would double-count. Base 1.3 =
/// FAO PAR for sitting plus diet-induced thermogenesis, +0.15 per step for
/// standing, physical work and step-free sport — the DGE/FAO ladder minus the
/// ~0.1 walking share (~5000 steps).
///
/// Without a connected step source that share is missing, leaving the
/// requirement ~0.1 × BMR low. Kept: underestimating is the safe direction
/// while cutting.
enum ActivityLevel { sedentary, light, moderate, active, athlete }

extension ActivityLevelInfo on ActivityLevel {
  /// Physical Activity Level (PAL) excluding walking — a BMR multiplier.
  /// 1.3 sitting · 1.45 mostly standing · 1.6 physically demanding ·
  /// 1.75 heavy work or daily training · 1.9 heavy work plus training.
  double get palFactor => switch (this) {
        ActivityLevel.sedentary => 1.3,
        ActivityLevel.light => 1.45,
        ActivityLevel.moderate => 1.6,
        ActivityLevel.active => 1.75,
        ActivityLevel.athlete => 1.9,
      };

  String label(AppLocalizations l10n) => switch (this) {
        ActivityLevel.sedentary => l10n.commonActivityLabelSedentary,
        ActivityLevel.light => l10n.commonActivityLabelLight,
        ActivityLevel.moderate => l10n.commonActivityLabelModerate,
        ActivityLevel.active => l10n.commonActivityLabelActive,
        ActivityLevel.athlete => l10n.commonActivityLabelAthlete,
      };

  String description(AppLocalizations l10n) => switch (this) {
        ActivityLevel.sedentary => l10n.commonActivityDescSedentary,
        ActivityLevel.light => l10n.commonActivityDescLight,
        ActivityLevel.moderate => l10n.commonActivityDescModerate,
        ActivityLevel.active => l10n.commonActivityDescActive,
        ActivityLevel.athlete => l10n.commonActivityDescAthlete,
      };
}

/// Diet preference. Drives which recipes are recommended; default [none]
/// recommends everything so existing profiles and tests stay unchanged.
/// A recommendation filter, not an allergy guarantee — every recipe stays
/// reachable through the category filter.
enum DietPreference { none, vegetarian, vegan, pescetarian }

extension DietPreferenceInfo on DietPreference {
  String label(AppLocalizations l10n) => switch (this) {
        DietPreference.none => l10n.commonDietLabelNone,
        DietPreference.vegetarian => l10n.commonDietLabelVegetarian,
        DietPreference.vegan => l10n.commonDietLabelVegan,
        DietPreference.pescetarian => l10n.commonDietLabelPescetarian,
      };

  String description(AppLocalizations l10n) => switch (this) {
        DietPreference.none => l10n.commonDietDescNone,
        DietPreference.vegetarian => l10n.commonDietDescVegetarian,
        DietPreference.vegan => l10n.commonDietDescVegan,
        DietPreference.pescetarian => l10n.commonDietDescPescetarian,
      };
}

/// Energy content of one kilogram of body mass (Wishnofsky rule of thumb).
///
/// The **only** kcal ↔ kg conversion in the project: both
/// [WeightGoalInfo.weeklyRateKg] (promised pace) and
/// `KcalTargets.effectiveWeeklyRateKg` (achievable pace) go through it.
const int kcalPerKgBodyMass = 7700;

/// Below this weekly rate a difference is pure rounding noise.
///
/// `KcalCalculator` rounds the daily target to 50 kcal, shifting the rate by up
/// to 0.023 kg/week; 0.05 sits safely above that and far below the smallest
/// real pace ([WeightGoal.lose025kg]). Used for the "stable" label, the
/// promise check and whether a forecast makes sense at all.
const double weeklyRateNoiseKg = 0.05;

/// Weight goal as a weekly rate (kg/week). Sets the kcal delta on the
/// maintenance requirement; steps are credited separately, see
/// [KcalCalculator]. Assumes ~7700 kcal per kg → 1100 kcal/day ≙ 1 kg/week.
///
/// This is the *wish*. Achievability is decided by `KcalCalculator.calculate`,
/// whose safety floor caps the deficit — anything shown to the user must use
/// `KcalTargets.effectiveWeeklyRateKg`, not [kcalDelta].
enum WeightGoal {
  lose1kg,
  lose075kg,
  lose05kg,
  lose025kg,
  maintain,
  gain025kg,
  gain05kg,
}

/// Loss paces from gentle to ambitious (picker order).
const List<WeightGoal> lossPaceGoals = <WeightGoal>[
  WeightGoal.lose025kg,
  WeightGoal.lose05kg,
  WeightGoal.lose075kg,
  WeightGoal.lose1kg,
];

/// Gain paces from gentle to ambitious.
const List<WeightGoal> gainPaceGoals = <WeightGoal>[
  WeightGoal.gain025kg,
  WeightGoal.gain05kg,
];

extension WeightGoalInfo on WeightGoal {
  /// kcal delta on the maintenance requirement (1100 kcal/day ≙ 1 kg/week).
  int get kcalDelta => switch (this) {
        WeightGoal.lose1kg => -1100,
        WeightGoal.lose075kg => -825,
        WeightGoal.lose05kg => -550,
        WeightGoal.lose025kg => -275,
        WeightGoal.maintain => 0,
        WeightGoal.gain025kg => 275,
        WeightGoal.gain05kg => 550,
      };

  bool get isLoss => kcalDelta < 0;
  bool get isGain => kcalDelta > 0;

  /// Weekly kg change (≈ 7700 kcal per kg). Unsigned.
  double get weeklyRateKg => kcalDelta.abs() * 7 / kcalPerKgBodyMass;

  /// Same rate signed: negative when losing, positive when gaining.
  /// Counterpart to `KcalTargets.effectiveWeeklyRateKg` for direct comparison.
  double get signedWeeklyRateKg => kcalDelta * 7 / kcalPerKgBodyMass;

  /// Direction label without pace, localized via the ARB — see
  /// [BiologicalSexLabel.label].
  String label(AppLocalizations l10n) {
    if (kcalDelta == 0) return l10n.commonWeightGoalLabelMaintain;
    return isGain ? l10n.commonWeightGoalLabelGain : l10n.commonWeightGoalLabelLose;
  }

  /// Signed pace, e.g. "−1 kg/Woche". This is the **chosen** pace, right for
  /// pickers and menus; wherever a concrete profile is involved use
  /// `KcalTargets.effectivePaceLabel`, which knows the safety floor.
  ///
  /// [l10n] is optional (default German, [deL10n]) so context-free tests keep
  /// working — that is why this is a method, not a getter.
  String paceLabel([AppLocalizations? l10n]) =>
      paceLabelForWeeklyRateKg(signedWeeklyRateKg, l10n);

  /// Combined menu label, e.g. "Abnehmen · −1 kg/Woche".
  String menuLabel(AppLocalizations l10n) => kcalDelta == 0
      ? l10n.commonWeightGoalLabelMaintain
      : '${label(l10n)} · ${paceLabel(l10n)}';

  /// Signed delta label, e.g. "−1100 kcal" / "±0".
  String get deltaLabel {
    if (kcalDelta == 0) return '±0';
    final sign = kcalDelta > 0 ? '+' : '−';
    return '$sign${kcalDelta.abs()} kcal';
  }
}

/// Label for an **actual** weekly rate (signed, negative = losing),
/// e.g. −0.7545 → "−0,75 kg/Woche".
///
/// Rounded to the 0.05 grid ([_formatRateKg]): the 50-kcal rounding of the
/// daily target shifts the rate by up to ±0.023 kg/week, so more digits would
/// be false precision on a ±10 % formula. Anything below [weeklyRateNoiseKg]
/// reads as stable; non-finite values cannot occur but are caught so no
/// "NaN kg/Woche" reaches a widget.
///
/// [l10n] is optional (default German, [deL10n]); the number itself follows the
/// locale too, so an English label never carries a German decimal comma.
String paceLabelForWeeklyRateKg(double signedRateKg, [AppLocalizations? l10n]) {
  final t = l10n ?? deL10n;
  if (!signedRateKg.isFinite || signedRateKg.abs() < weeklyRateNoiseKg) {
    return t.commonPaceStable;
  }
  final sign = signedRateKg > 0 ? '+' : '−';
  return t.commonPaceRateLabel(
    '$sign${_formatRateKg(signedRateKg.abs(), t.localeName)}',
  );
}

/// Formats a kg rate onto the 0.05 grid, locale-aware (`de` 0.4818 → "0,5",
/// `en` → "0.5").
///
/// Expects an unsigned value; the caller adds the sign. Round first, then
/// format: [NumberFormat]'s own rounding on the unrounded rate could differ
/// from `(kg * 20).round() / 20`, so it only renders the already-rounded value.
/// The grid equals [weeklyRateNoiseKg], so the promise check and the displayed
/// number agree.
String _formatRateKg(double kg, String localeName) {
  final gerundet = (kg.abs() * 20).round() / 20;
  return NumberFormat('0.##', localeName).format(gerundet);
}

class UserProfile {
  const UserProfile({
    this.weightKg = 78,
    this.heightCm = 178,
    this.ageYears = 30,
    this.sex = BiologicalSex.neutral,
    this.activityLevel = ActivityLevel.sedentary,
    this.targetWeightKg = 78,
    this.dailyStepsGoal = 8000,
    this.dailyKcalGoal = 2200,
    this.dailyWaterGoalMl = 2500,
    this.dailySleepGoalMinutes = 7 * 60 + 30,
    this.proteinGoalG = 130,
    this.carbsGoalG = 240,
    this.fatGoalG = 70,
    this.weightGoal = WeightGoal.maintain,
    this.diet = DietPreference.none,
    this.onboardingCompleted = false,
  });

  final int weightKg;
  final int heightCm;
  final int ageYears;
  final BiologicalSex sex;

  /// Work/daily life excluding walking, for the PAL. Default sitting (1.3);
  /// when in doubt pick one level lower — steps are added on top anyway.
  final ActivityLevel activityLevel;

  /// Target weight. Drives only the time forecast, not the daily target —
  /// that follows the chosen pace ([weightGoal]).
  final int targetWeightKg;

  final int dailyStepsGoal;
  final int dailyKcalGoal;
  final int dailyWaterGoalMl;
  final int dailySleepGoalMinutes;
  final int proteinGoalG;
  final int carbsGoalG;
  final int fatGoalG;
  final WeightGoal weightGoal;

  /// Diet preference for recipe recommendations. Default
  /// [DietPreference.none]. Mirrored to public.profiles.diet_preference.
  final DietPreference diet;

  /// True once the mandatory onboarding is done. Drives the gate in
  /// [EatovaHomePage]; mirrored to public.profiles.onboarding_completed.
  final bool onboardingCompleted;

  UserProfile copyWith({
    int? weightKg,
    int? heightCm,
    int? ageYears,
    BiologicalSex? sex,
    ActivityLevel? activityLevel,
    int? targetWeightKg,
    int? dailyStepsGoal,
    int? dailyKcalGoal,
    int? dailyWaterGoalMl,
    int? dailySleepGoalMinutes,
    int? proteinGoalG,
    int? carbsGoalG,
    int? fatGoalG,
    WeightGoal? weightGoal,
    DietPreference? diet,
    bool? onboardingCompleted,
  }) {
    return UserProfile(
      weightKg: weightKg ?? this.weightKg,
      heightCm: heightCm ?? this.heightCm,
      ageYears: ageYears ?? this.ageYears,
      sex: sex ?? this.sex,
      activityLevel: activityLevel ?? this.activityLevel,
      targetWeightKg: targetWeightKg ?? this.targetWeightKg,
      dailyStepsGoal: dailyStepsGoal ?? this.dailyStepsGoal,
      dailyKcalGoal: dailyKcalGoal ?? this.dailyKcalGoal,
      dailyWaterGoalMl: dailyWaterGoalMl ?? this.dailyWaterGoalMl,
      dailySleepGoalMinutes:
          dailySleepGoalMinutes ?? this.dailySleepGoalMinutes,
      proteinGoalG: proteinGoalG ?? this.proteinGoalG,
      carbsGoalG: carbsGoalG ?? this.carbsGoalG,
      fatGoalG: fatGoalG ?? this.fatGoalG,
      weightGoal: weightGoal ?? this.weightGoal,
      diet: diet ?? this.diet,
      onboardingCompleted: onboardingCompleted ?? this.onboardingCompleted,
    );
  }
}
