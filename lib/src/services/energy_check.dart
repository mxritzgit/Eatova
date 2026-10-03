import 'dart:math' as math;

import '../models/user_profile.dart';
import '../models/weight_log.dart';
import 'day_math.dart';
import 'kcal_calculator.dart';

/// A weekly-check proposal (docs/WEIGHT-TREND.md, stage 2): move the
/// maintenance offset by [stepKcal], so the daily goal goes from
/// [currentGoalKcal] to [newGoalKcal].
class EnergyCheckProposal {
  const EnergyCheckProposal({
    required this.stepKcal,
    required this.newAdjustmentKcal,
    required this.currentGoalKcal,
    required this.newGoalKcal,
    required this.observedKcal,
    required this.modelledKcal,
    required this.weeklyRateKg,
    required this.loggedDays,
    required this.weighInDays,
  });

  /// Change of [UserProfile.energyAdjustmentKcal]; never 0.
  final int stepKcal;
  final int newAdjustmentKcal;
  final int currentGoalKcal;
  final int newGoalKcal;

  /// Expenditure estimated from intake and weight change, kcal/day.
  final double observedKcal;

  /// Expenditure the calculator assumes, steps included, kcal/day.
  final double modelledKcal;

  /// Weight change over the window, kg/week (negative = losing).
  final double weeklyRateKg;
  final int loggedDays;
  final int weighInDays;
}

/// The weekly expenditure check (docs/WEIGHT-TREND.md, stage 2), pure.
///
/// Compares the expenditure the logged intake and the weight change imply
/// with the one the calculator models, and proposes a bounded step on the
/// maintenance offset. Never applies anything itself.
class EnergyCheck {
  const EnergyCheck();

  /// Local days before today that form the window; today is incomplete.
  static const int windowDays = 21;

  /// A day counts as logged from this share of the current daily goal on.
  static const double loggedDayShare = 0.5;
  static const int minLoggedDays = 14;
  static const int minWeighInDays = 4;
  static const int minWeighInSpanDays = 14;

  /// Weigh-in days further than this share from the window median are typos.
  static const double weighInOutlierShare = 0.05;

  /// Days between two answered checks.
  static const int recheckDays = 7;
  static const int minDifferenceKcal = 100;

  /// The difference must also exceed this many standard errors of the
  /// weight slope (× 7700): water swings alone move a 3-week slope by ±100
  /// kcal/day and more, and must not propose anything.
  static const double minDifferenceStandardErrors = 2;

  /// Lower bound for the day-to-day weight noise behind that standard error:
  /// with a few weigh-ins the fitted residuals can be tiny by chance, while
  /// real daily swings are about half a kilo.
  static const double weighInNoiseFloorKg = 0.5;
  static const int stepGranularityKcal = 50;
  static const int maxStepKcal = 150;
  static const int maxAdjustmentKcal = 500;

  /// The proposal for [today] (local midnight), or null when there is none.
  ///
  /// [intakeKcal] gives the logged intake of a local day, [burnedKcal] its
  /// credited step kcal, or null when the device holds no step value for it.
  /// With a step source ([stepSourceToday] or any step value in the window),
  /// only days WITH a step value count: a day without one (before the
  /// permission, a new device — the values are not synced) would model 0
  /// steps and push the goal up for walking the budget already credits.
  EnergyCheckProposal? evaluate({
    required UserProfile profile,
    required DateTime today,
    required int Function(DateTime day) intakeKcal,
    required int? Function(DateTime day) burnedKcal,
    required WeightLog weightLog,
    bool stepSourceToday = false,
  }) {
    if (profile.manualEnergy || !profile.onboardingCompleted) return null;
    final checkedOn = profile.energyCheckedOn;
    if (checkedOn != null && daysBetween(today, checkedOn) < recheckDays) {
      return null;
    }

    const calculator = KcalCalculator();
    final targets = calculator.calculate(profile);
    final days = [for (var n = windowDays; n >= 1; n--) addDays(today, -n)];

    final threshold = targets.kcal * loggedDayShare;
    final steps = stepSourceToday || days.any((day) => burnedKcal(day) != null);
    final logged = [
      for (final day in days)
        if (intakeKcal(day) >= threshold && (!steps || burnedKcal(day) != null))
          day,
    ];
    if (logged.length < minLoggedDays) return null;

    final weighIns = _weighInDays(weightLog, days.first, days.last);
    if (weighIns.length < minWeighInDays ||
        daysBetween(weighIns.last.$1, weighIns.first.$1) < minWeighInSpanDays) {
      return null;
    }
    final (slopeKgPerDay, slopeError) = _slope(weighIns);

    double mean(Iterable<int> values) =>
        values.fold<int>(0, (sum, v) => sum + v) / logged.length;
    final observed =
        mean(logged.map(intakeKcal)) - slopeKgPerDay * kcalPerKgBodyMass;
    final modelled =
        targets.maintenanceKcal + mean(logged.map((day) => burnedKcal(day) ?? 0));
    final difference = observed - modelled;
    final noise = minDifferenceStandardErrors * slopeError * kcalPerKgBodyMass;
    if (difference.abs() < math.max(minDifferenceKcal.toDouble(), noise)) {
      return null;
    }

    final rounded =
        (difference / stepGranularityKcal).round() * stepGranularityKcal;
    final step = rounded.clamp(-maxStepKcal, maxStepKcal);
    final current = profile.energyAdjustmentKcal;
    final next = (current + step).clamp(-maxAdjustmentKcal, maxAdjustmentKcal);
    if (next == current) return null;
    final newGoal = calculator
        .calculate(profile.copyWith(energyAdjustmentKcal: next))
        .kcal;
    // Held by the floor or the ceiling: nothing the user would see changes.
    if (newGoal == targets.kcal) return null;

    return EnergyCheckProposal(
      stepKcal: next - current,
      newAdjustmentKcal: next,
      currentGoalKcal: targets.kcal,
      newGoalKcal: newGoal,
      observedKcal: observed,
      modelledKcal: modelled,
      weeklyRateKg: slopeKgPerDay * 7,
      loggedDays: logged.length,
      weighInDays: weighIns.length,
    );
  }

  /// The last weigh-in of each local day in [first]..[last], typos dropped:
  /// days further than [weighInOutlierShare] from the median.
  static List<(DateTime, double)> _weighInDays(
    WeightLog log,
    DateTime first,
    DateTime last,
  ) {
    final byDay = <DateTime, double>{};
    final sorted = [...log.entries]
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    for (final entry in sorted) {
      final day = startOfDay(entry.timestamp.toLocal());
      if (daysBetween(day, first) < 0 || daysBetween(day, last) > 0) continue;
      byDay[day] = entry.weightKg;
    }
    if (byDay.isEmpty) return const [];
    final values = byDay.values.toList()..sort();
    final mid = values.length ~/ 2;
    final median = values.length.isOdd
        ? values[mid]
        : (values[mid - 1] + values[mid]) / 2;
    return [
      for (final MapEntry(key: day, value: kg) in byDay.entries)
        if ((kg - median).abs() <= median * weighInOutlierShare) (day, kg),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
  }

  /// Least-squares slope in kg per day and its standard error.
  static (double, double) _slope(List<(DateTime, double)> points) {
    final origin = points.first.$1;
    final xs = [for (final (day, _) in points) daysBetween(day, origin).toDouble()];
    final ys = [for (final (_, kg) in points) kg];
    final n = points.length;
    final meanX = xs.reduce((a, b) => a + b) / n;
    final meanY = ys.reduce((a, b) => a + b) / n;
    var sxy = 0.0;
    var sxx = 0.0;
    for (var i = 0; i < n; i++) {
      sxy += (xs[i] - meanX) * (ys[i] - meanY);
      sxx += math.pow(xs[i] - meanX, 2);
    }
    if (sxx == 0) return (0.0, double.infinity);
    final slope = sxy / sxx;
    // Residual variance with n − 2 degrees of freedom (n >= 4 here).
    var sse = 0.0;
    for (var i = 0; i < n; i++) {
      sse += math.pow(ys[i] - (meanY + slope * (xs[i] - meanX)), 2);
    }
    final noise = math.max(math.sqrt(sse / (n - 2)), weighInNoiseFloorKg);
    return (slope, noise / math.sqrt(sxx));
  }
}
