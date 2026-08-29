import 'dart:math' as math;

import '../l10n/l10n.dart';
import '../models/model_limits.dart';
import '../models/user_profile.dart';

/// Step length in metres from height — pedometer heuristics, not a study.
/// Base of [estimateKcalBurnedFromSteps]: 0.5 kcal/kg/km, the horizontal NET
/// component of the ACSM equation. Net, because `palFactor` covers rest.
double estimateStepLengthMeters({
  required int heightCm,
  BiologicalSex sex = BiologicalSex.neutral,
}) {
  if (heightCm <= 0) return 0;
  final ratio = switch (sex) {
    BiologicalSex.male => 0.415,
    BiologicalSex.female => 0.413,
    BiologicalSex.neutral => 0.414,
  };
  return ((heightCm * ratio) / 100).clamp(0.45, 1.05).toDouble();
}

double estimateWalkingDistanceKm({
  required int steps,
  required int heightCm,
  BiologicalSex sex = BiologicalSex.neutral,
}) {
  if (steps <= 0 || heightCm <= 0) return 0;
  return steps * estimateStepLengthMeters(heightCm: heightCm, sex: sex) / 1000;
}

int estimateKcalBurnedFromSteps({
  required int steps,
  required int weightKg,
  required int heightCm,
  BiologicalSex sex = BiologicalSex.neutral,
}) {
  if (steps <= 0 || weightKg <= 0 || heightCm <= 0) {
    return 0;
  }
  final distanceKm = estimateWalkingDistanceKm(
    steps: steps,
    heightCm: heightCm,
    sex: sex,
  );
  final activeKcal = weightKg * distanceKm * 0.5;
  return activeKcal.clamp(0, 99999).round();
}

/// [linearWeeks] is the optimistic lower bound, [dynamicWeeks] the simulated
/// upper bound (`null` if the deficit runs out first).
typedef WeeksToGoalRange = ({int linearWeeks, int? dynamicWeeks});

/// Forecast sentence for onboarding; degrades to one number or "earliest".
String timelineEstimateText(
  AppLocalizations l10n, {
  required int targetWeightKg,
  required WeeksToGoalRange weeks,
}) {
  final dynamicWeeks = weeks.dynamicWeeks;
  if (dynamicWeeks == null) {
    return l10n.onboardingTimelineEstimateOpen(
      targetWeightKg,
      weeks.linearWeeks,
    );
  }
  if (dynamicWeeks == weeks.linearWeeks) {
    return l10n.onboardingTimelineEstimate(targetWeightKg, dynamicWeeks);
  }
  return l10n.onboardingTimelineEstimateRange(
    targetWeightKg,
    weeks.linearWeeks,
    dynamicWeeks,
  );
}

/// Counterpart to [timelineEstimateText] for the plan card in the profile.
String goalProgressWeeksText(
  AppLocalizations l10n, {
  required int gap,
  required WeeksToGoalRange weeks,
}) {
  final dynamicWeeks = weeks.dynamicWeeks;
  if (dynamicWeeks == null) {
    return l10n.profileGoalProgressWeeksOpen(gap, weeks.linearWeeks);
  }
  if (dynamicWeeks == weeks.linearWeeks) {
    return l10n.profileGoalProgressWeeks(gap, dynamicWeeks);
  }
  return l10n.profileGoalProgressWeeksRange(gap, weeks.linearWeeks, dynamicWeeks);
}

class KcalTargets {
  const KcalTargets({
    required this.kcal,
    required this.uncappedKcal,
    required this.proteinG,
    required this.carbsG,
    required this.fatG,
    required this.bmr,
    required this.maintenanceKcal,
    required this.goal,
    required this.floor,
    required this.appliedKcalDelta,
    required this.maxDeficitKcal,
  });

  /// Daily goal incl. goal delta; the step bonus is added later by the UI.
  final int kcal;

  /// Same goal **before** the safety clamp, rounded and deficit-capped.
  final int uncappedKcal;

  final int proteinG;
  final int carbsG;
  final int fatG;
  final int bmr;

  /// Maintenance need: BMR × PAL of the chosen activity level, no goal delta.
  final int maintenanceKcal;
  final WeightGoal goal;

  /// Floor for this profile ([KcalCalculator.kcalFloorFor]): 1200 female,
  /// 1500 male, 1350 neutral.
  final int floor;

  /// [WeightGoalInfo.kcalDelta], floored at −[maxDeficitKcal] when losing.
  final int appliedKcalDelta;

  /// 1 % body weight per week in kcal/day ([KcalCalculator.maxDeficitKcalPerDay]).
  final int maxDeficitKcal;

  /// The floor raised the goal, so the user loses slower than the chosen pace.
  bool get floorApplied => uncappedKcal < floor;

  /// The ceiling capped the goal — mirror image in the gain direction.
  bool get ceilingApplied => uncappedKcal > KcalCalculator.kcalCeiling;

  /// One of the two safety limits kicked in.
  bool get safetyClampApplied => floorApplied || ceilingApplied;

  /// The 1 % cap shrank the wanted deficit (Review 2026-08-21).
  bool get deficitCapApplied => appliedKcalDelta != goal.kcalDelta;

  /// Actual daily difference from maintenance: **negative = deficit**.
  ///
  /// Display this, not [WeightGoal.kcalDelta] — that is the wish, this the plan.
  int get effectiveKcalDelta => kcal - maintenanceKcal;

  /// Actually achievable weekly rate in kg, signed (negative = losing).
  double get effectiveWeeklyRateKg =>
      effectiveKcalDelta * 7 / kcalPerKgBodyMass;

  /// The rate promised by the chosen goal, same sign.
  double get promisedWeeklyRateKg => goal.signedWeeklyRateKg;

  /// `true` while wish and reality differ only by rounding noise.
  bool get matchesPromisedPace =>
      (effectiveWeeklyRateKg - promisedWeeklyRateKg).abs() < weeklyRateNoiseKg;

  /// Pace label from the **effective** rate. A method, not a getter, because
  /// Dart getters take no parameters.
  String effectivePaceLabel([AppLocalizations? l10n]) =>
      paceLabelForWeeklyRateKg(effectiveWeeklyRateKg, l10n);

  /// UI hint when the daily goal cannot deliver the chosen pace, else `null`.
  /// Order = binding force: floor, ceiling, 1 % deficit cap, pace mismatch.
  String? paceWarning([AppLocalizations? l10n]) {
    if (!safetyClampApplied && !deficitCapApplied && matchesPromisedPace) {
      return null;
    }
    final t = l10n ?? deL10n;
    final effectivePace = effectivePaceLabel(l10n);
    final promisedPace = goal.paceLabel(l10n);
    // A clamp that eats the whole deficit gets its own wording.
    final stable = effectiveWeeklyRateKg.abs() < weeklyRateNoiseKg;
    if (floorApplied) {
      return stable
          ? t.commonPaceWarningFloorStable(floor, uncappedKcal, promisedPace)
          : t.commonPaceWarningFloor(
              floor,
              uncappedKcal,
              effectivePace,
              promisedPace,
            );
    }
    if (ceilingApplied) {
      return stable
          ? t.commonPaceWarningCeilingStable(
              KcalCalculator.kcalCeiling,
              uncappedKcal,
              promisedPace,
            )
          : t.commonPaceWarningCeiling(
              KcalCalculator.kcalCeiling,
              uncappedKcal,
              effectivePace,
              promisedPace,
            );
    }
    if (deficitCapApplied) {
      return t.commonPaceWarningDeficitCap(
        maxDeficitKcal,
        effectivePace,
        promisedPace,
      );
    }
    return t.commonPaceWarningMismatch(effectivePace, promisedPace);
  }
}

class KcalCalculator {
  const KcalCalculator();

  /// Nutritional floor for women and the minimum `calculate` returns.
  /// **Tighter than the DB on purpose:** manual goals may span 800…7000, so
  /// `calculate` (1200…5000) can never raise a `23514`. Costs pace.
  static const int kcalFloor = 1200;

  /// Floor for men (NIH/NHLBI, AHA/ACC/TOS: 1500 kcal).
  static const int kcalFloorMale = 1500;

  /// Floor for "diverse": mean of both guideline values.
  static const int kcalFloorNeutral = 1350;

  /// Ceiling of the automatically computed daily goal, see [kcalFloor].
  static const int kcalCeiling = 5000;

  static int kcalFloorFor(BiologicalSex sex) => switch (sex) {
        BiologicalSex.male => kcalFloorMale,
        BiologicalSex.female => kcalFloor,
        BiologicalSex.neutral => kcalFloorNeutral,
      };

  /// Largest daily deficit: 1 % of body weight per week (ISSN, Garthe 2011),
  /// **rounded down to 0.05 kg/week** so the pace lands on the label grid.
  static int maxDeficitKcalPerDay(int weightKg) {
    // 0.05 kg/week ≙ 7700 × 0.05 ÷ 7 = 55 kcal/day.
    final step = (kcalPerKgBodyMass * weeklyRateNoiseKg / 7).round();
    final floor = WeightGoal.lose025kg.kcalDelta.abs();
    return math.max(floor, (weightKg ~/ 5) * step);
  }

  /// Hall rule: each kg lost drops the daily requirement by ~22 kcal, which
  /// the linear 7700 rule ignores.
  static const int kcalPerDayPerKgChanged = 22;

  /// Simulation cap; beyond this the goal counts as unreachable.
  static const int maxPrognosisWeeks = 520;

  /// Protein per kg **reference weight**; the Morton 2018 breakpoint.
  static const double proteinGPerKg = 1.6;

  /// Only undercut to stay below [proteinHardMaxEnergyShare] (Leidy 2015).
  static const double proteinMinGPerKg = 1.2;

  /// AMDR upper bound for protein (IOM: 10–35 % of energy).
  static const double proteinMaxEnergyShare = 0.35;

  /// Hard ceiling, used when [proteinMinGPerKg] would otherwise be undercut.
  static const double proteinHardMaxEnergyShare = 0.40;

  /// Fat share of energy (AMDR/EFSA 20–35 %).
  static const double fatEnergyShare = 0.25;

  /// Carbs are the remainder: ≥ 35 % of energy, so ≥ 105 g at [kcalFloor],
  /// above the IOM EAR of 100 g.
  static const int carbsMinG = 100;

  /// Mifflin-St Jeor basal metabolic rate; [BiologicalSex.neutral] averages
  /// the offsets (+5 / −161 → −78). Strictly this is resting expenditure.
  double basalMetabolicRate({
    required int weightKg,
    required int heightCm,
    required int ageYears,
    required BiologicalSex sex,
  }) {
    final base = 10 * weightKg + 6.25 * heightCm - 5 * ageYears;
    final offset = switch (sex) {
      BiologicalSex.male => 5,
      BiologicalSex.female => -161,
      BiologicalSex.neutral => -78,
    };
    return base + offset;
  }

  /// Reference weight for the protein goal: actual weight up to BMI 25, then
  /// the ESPEN adjusted weight. Otherwise 130 kg would demand 208 g.
  static double proteinReferenceWeightKg({
    required int weightKg,
    required int heightCm,
  }) {
    if (heightCm <= 0 || weightKg <= 0) {
      return weightKg < 0 ? 0 : weightKg.toDouble();
    }
    final heightM = heightCm / 100;
    final normalKg = 25 * heightM * heightM;
    if (weightKg <= normalKg) return weightKg.toDouble();
    return normalKg + 0.25 * (weightKg - normalKg);
  }

  KcalTargets calculate(UserProfile profile) {
    // P9-08d: the PLAN follows the effective goal, not the stored intent. A
    // direction the two weights no longer support ("lose" at 80 kg with target
    // 90) has nothing left to do, so it yields the maintenance plan. Derived
    // here rather than written into the profile, so this holds for every stored
    // row from the first read on — no save, no migration — while
    // `profile.weightGoal` keeps the user's intent and a new target weight
    // takes the direction up again.
    final goal = profile.effectiveWeightGoal;
    final bmr = basalMetabolicRate(
      weightKg: profile.weightKg,
      heightCm: profile.heightCm,
      ageYears: profile.ageYears,
      sex: profile.sex,
    );
    final maintenance = bmr * profile.activityLevel.palFactor;

    // 1 % cap only when losing; gain steps stay as chosen.
    final maxDeficit = maxDeficitKcalPerDay(profile.weightKg);
    final wishedDelta = goal.kcalDelta;
    final appliedDelta = wishedDelta < -maxDeficit ? -maxDeficit : wishedDelta;

    final goalAdjusted = maintenance + appliedDelta;
    // Round daily kcal to nearest 50 for nicer-looking numbers.
    final uncappedKcal = (goalAdjusted / 50).round() * 50;
    final floor = kcalFloorFor(profile.sex);
    final kcal = uncappedKcal.clamp(floor, kcalCeiling);

    // All three hit DB check constraints; the [ProfileLimits] clamps stay as
    // a last safeguard.
    final refKg = proteinReferenceWeightKg(
      weightKg: profile.weightKg,
      heightCm: profile.heightCm,
    );
    var proteinG = (refKg * proteinGPerKg).round();
    final softCapG = (kcal * proteinMaxEnergyShare / 4).floor();
    if (proteinG > softCapG) {
      final minG = (refKg * proteinMinGPerKg).round();
      proteinG = minG > softCapG
          ? math.min(minG, (kcal * proteinHardMaxEnergyShare / 4).floor())
          : softCapG;
    }
    proteinG = clampProteinGoalG(proteinG);
    final fatG = clampFatGoalG(((kcal * fatEnergyShare) / 9).round());
    final remainingKcal = kcal - proteinG * 4 - fatG * 9;
    final carbsG = clampCarbsGoalG(remainingKcal / 4);

    return KcalTargets(
      kcal: kcal,
      uncappedKcal: uncappedKcal,
      proteinG: proteinG,
      carbsG: carbsG,
      fatG: fatG,
      bmr: bmr.round(),
      maintenanceKcal: maintenance.round(),
      // The EFFECTIVE goal: everything derived from it — `promisedWeeklyRateKg`,
      // `paceWarning`, the pace labels — must describe the plan that is really
      // running, or the card would warn about missing a pace nobody is on.
      goal: goal,
      floor: floor,
      appliedKcalDelta: appliedDelta,
      maxDeficitKcal: maxDeficit,
    );
  }

  /// Live mode self-healing (review 2026-08-27, F7-01): in live mode
  /// ([UserProfile.manualEnergy] false) the calculator is the truth, and the
  /// stored kcal/macros are a cache that goes stale with every calculator
  /// change. Returns the profile with the computed goals, or the SAME instance
  /// when nothing changes (manual mode, onboarding not done, already equal) —
  /// callers use `identical` to decide whether a write-back is due.
  ///
  /// Since P9-08d this also heals the DIRECTION at the load boundary, without
  /// touching [UserProfile.weightGoal]: [calculate] reads
  /// [UserProfileWeightPlan.effectiveWeightGoal], so a stored row whose target
  /// lies on the wrong side of today's weight gets the maintenance kcal here —
  /// the cached deficit never survives the first read.
  UserProfile applyLiveGoals(UserProfile profile) {
    if (profile.manualEnergy || !profile.onboardingCompleted) return profile;
    final t = calculate(profile);
    if (profile.dailyKcalGoal == t.kcal &&
        profile.proteinGoalG == t.proteinG &&
        profile.carbsGoalG == t.carbsG &&
        profile.fatGoalG == t.fatG) {
      return profile;
    }
    return profile.copyWith(
      dailyKcalGoal: t.kcal,
      proteinGoalG: t.proteinG,
      carbsGoalG: t.carbsG,
      fatGoalG: t.fatG,
    );
  }

  /// Weeks to target weight — **optimistic lower bound**; prefer
  /// [weeksToGoalRange] for display. Uses [KcalTargets.effectiveWeeklyRateKg],
  /// not [WeightGoalInfo.weeklyRateKg], which would promise a pace the caps
  /// forbid (B2). `null` on a reached target, noise rate, or wrong direction.
  int? weeksToGoal(UserProfile profile, {KcalTargets? targets}) {
    final diffKg = (profile.weightKg - profile.targetWeightKg).abs();
    if (diffKg == 0) return null;
    final rate = (targets ?? calculate(profile)).effectiveWeeklyRateKg;
    if (!rate.isFinite || rate.abs() < weeklyRateNoiseKg) return null;
    final needsToLose = profile.targetWeightKg < profile.weightKg;
    final planLoses = rate < 0;
    if (needsToLose != planLoses) return null;
    return (diffKg / rate.abs()).ceil();
  }

  /// Forecast as a range: linear ([weeksToGoal]) to dynamic. The dynamic bound
  /// simulates weekly with a requirement moving by [kcalPerDayPerKgChanged] per
  /// changed kg — 46 weeks instead of 30 for 100 → 85 kg.
  WeeksToGoalRange? weeksToGoalRange(
    UserProfile profile, {
    KcalTargets? targets,
  }) {
    final t = targets ?? calculate(profile);
    final linear = weeksToGoal(profile, targets: t);
    if (linear == null) return null;

    final diffKg = (profile.weightKg - profile.targetWeightKg).abs().toDouble();
    final losing = profile.targetWeightKg < profile.weightKg;
    final direction = losing ? -1 : 1;

    var changedKg = 0.0;
    var weeks = 0;
    while (changedKg < diffKg) {
      if (weeks >= maxPrognosisWeeks) {
        return (linearWeeks: linear, dynamicWeeks: null);
      }
      final maintenanceNow =
          t.maintenanceKcal + direction * kcalPerDayPerKgChanged * changedKg;
      final weeklyKg = (t.kcal - maintenanceNow) * 7 / kcalPerKgBodyMass;
      final progress = direction * weeklyKg;
      if (!progress.isFinite || progress < weeklyRateNoiseKg) {
        return (linearWeeks: linear, dynamicWeeks: null);
      }
      changedKg += progress;
      weeks++;
    }
    return (linearWeeks: linear, dynamicWeeks: math.max(weeks, linear));
  }
}
