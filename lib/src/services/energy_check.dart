import 'dart:math' as math;

import '../models/user_profile.dart';
import '../models/weight_log.dart';
import 'complete_day.dart';
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

/// What the weekly check measured for a day with enough data
/// ([EnergyCheck.estimate], 2026-10-19): the numbers behind a proposal, and
/// the week's result when there is none. Nothing here is a new model; it is
/// [EnergyCheck.evaluate]'s own arithmetic, kept instead of dropped.
class EnergyCheckEstimate {
  const EnergyCheckEstimate({
    required this.observedKcal,
    required this.modelledKcal,
    required this.weeklyRateKg,
    required this.planWeeklyRateKg,
    required this.currentGoalKcal,
    required this.loggedDays,
    required this.weighInDays,
    required this.withinNoise,
    this.proposal,
  });

  /// Expenditure estimated from intake and weight change, kcal/day.
  final double observedKcal;

  /// Expenditure the calculator assumes, steps included, kcal/day.
  final double modelledKcal;

  /// Weight change over the window, kg/week (negative = losing).
  final double weeklyRateKg;

  /// The pace the current goal plans for, kg/week
  /// (`KcalTargets.effectiveWeeklyRateKg`).
  final double planWeeklyRateKg;
  final int currentGoalKcal;
  final int loggedDays;
  final int weighInDays;

  /// The difference stays below the minimum or the weight noise: the data
  /// gives no reason to move the goal.
  final bool withinNoise;

  /// The proposal, or null: [withinNoise], or a cap, the floor or the
  /// ceiling holds back a step the data asks for.
  final EnergyCheckProposal? proposal;
}

/// How far the data is from a weekly check, counted from the inputs
/// [EnergyCheck.evaluate] reads and with its rules ([EnergyCheck.progress]).
class EnergyCheckProgress {
  const EnergyCheckProgress({
    required this.today,
    required this.loggedDays,
    required this.weighInDays,
    required this.weighInSpanDays,
    required this.pausedUntil,
    required this.earliestDay,
    required this.loggedDaysToGo,
    required this.weighInsToGo,
  });

  /// The local day this progress was measured on.
  final DateTime today;

  /// Logged days and weigh-in days in today's window, as the check counts
  /// them.
  final int loggedDays;
  final int weighInDays;

  /// Days between the window's first and last weigh-in day; 0 below two.
  final int weighInSpanDays;

  /// The day the pause after an answered check ends, while it lasts.
  final DateTime? pausedUntil;

  /// The earliest day the check can estimate: [today] when [ready].
  ///
  /// Otherwise the best case: every day from today on gets logged and the
  /// user weighs in on the days [weighInsToGo] needs. Weigh-ins still to
  /// come are assumed to be no typos, so this is a lower bound.
  final DateTime earliestDay;

  /// What that best case still needs, today included.
  final int loggedDaysToGo;
  final int weighInsToGo;

  int get missingLoggedDays =>
      math.max(0, EnergyCheck.minLoggedDays - loggedDays);
  int get missingWeighInDays =>
      math.max(0, EnergyCheck.minWeighInDays - weighInDays);
  bool get spanReached => weighInSpanDays >= EnergyCheck.minWeighInSpanDays;

  /// Today's window holds enough data for the estimate.
  bool get dataReady =>
      missingLoggedDays == 0 && missingWeighInDays == 0 && spanReached;

  /// The check estimates today. [EnergyCheck.evaluate] then returns a
  /// proposal unless the goal fits within the noise or a cap holds it.
  bool get ready => dataReady && pausedUntil == null;

  /// Days until [earliestDay]; 0 when [ready].
  int get daysUntil => daysBetween(earliestDay, today);
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

  /// A day counts as logged from this share of the current daily goal on:
  /// the shared complete-day rule ([isCompleteDay]).
  static const double loggedDayShare = completeDayShare;
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

  /// The weekday Today shows the week's result on when there is no
  /// proposal (2026-10-19): once a week, without storing anything.
  static const int resultWeekday = DateTime.monday;

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
  }) => estimate(
    profile: profile,
    today: today,
    intakeKcal: intakeKcal,
    burnedKcal: burnedKcal,
    weightLog: weightLog,
    stepSourceToday: stepSourceToday,
  )?.proposal;

  /// The check's estimate for [today] on [evaluate]'s inputs and gates, or
  /// null when it does not estimate (manual goal, unfinished onboarding,
  /// the pause after an answer, too little data). With a proposal or
  /// without one: [EnergyCheckEstimate.proposal] is [evaluate]'s answer.
  EnergyCheckEstimate? estimate({
    required UserProfile profile,
    required DateTime today,
    required int Function(DateTime day) intakeKcal,
    required int? Function(DateTime day) burnedKcal,
    required WeightLog weightLog,
    bool stepSourceToday = false,
  }) {
    if (profile.manualEnergy || !profile.onboardingCompleted) return null;
    if (_pausedUntil(profile, today) != null) return null;

    // The same window and gates as [progress]: "ready" there is an estimate
    // here.
    final window = _Window.of(
      profile: profile,
      today: today,
      intakeKcal: intakeKcal,
      burnedKcal: burnedKcal,
      weightLog: weightLog,
      stepSourceToday: stepSourceToday,
    );
    if (!window.dataReady) return null;

    const calculator = KcalCalculator();
    final targets = window.targets;
    final logged = window.logged;
    final weighIns = window.weighIns;
    final (slopeKgPerDay, slopeError) = _slope(weighIns);

    double mean(Iterable<int> values) =>
        values.fold<int>(0, (sum, v) => sum + v) / logged.length;
    final observed =
        mean(logged.map(intakeKcal)) - slopeKgPerDay * kcalPerKgBodyMass;
    final modelled =
        targets.maintenanceKcal + mean(logged.map((day) => burnedKcal(day) ?? 0));
    final difference = observed - modelled;
    final noise = minDifferenceStandardErrors * slopeError * kcalPerKgBodyMass;
    EnergyCheckEstimate result({
      required bool withinNoise,
      EnergyCheckProposal? proposal,
    }) => EnergyCheckEstimate(
      observedKcal: observed,
      modelledKcal: modelled,
      weeklyRateKg: slopeKgPerDay * 7,
      planWeeklyRateKg: targets.effectiveWeeklyRateKg,
      currentGoalKcal: targets.kcal,
      loggedDays: logged.length,
      weighInDays: weighIns.length,
      withinNoise: withinNoise,
      proposal: proposal,
    );
    if (difference.abs() < math.max(minDifferenceKcal.toDouble(), noise)) {
      return result(withinNoise: true);
    }

    final rounded =
        (difference / stepGranularityKcal).round() * stepGranularityKcal;
    final step = rounded.clamp(-maxStepKcal, maxStepKcal);
    final current = profile.energyAdjustmentKcal;
    final next = (current + step).clamp(-maxAdjustmentKcal, maxAdjustmentKcal);
    if (next == current) return result(withinNoise: false);
    final newGoal = calculator
        .calculate(profile.copyWith(energyAdjustmentKcal: next))
        .kcal;
    // Held by the floor or the ceiling: nothing the user would see changes.
    if (newGoal == targets.kcal) return result(withinNoise: false);

    return result(
      withinNoise: false,
      proposal: EnergyCheckProposal(
        stepKcal: next - current,
        newAdjustmentKcal: next,
        currentGoalKcal: targets.kcal,
        newGoalKcal: newGoal,
        observedKcal: observed,
        modelledKcal: modelled,
        weeklyRateKg: slopeKgPerDay * 7,
        loggedDays: logged.length,
        weighInDays: weighIns.length,
      ),
    );
  }

  /// The weight change this check measures for [today] (local midnight):
  /// the same window, typo filter, minimum and slope as [evaluate], so other
  /// readers (the Coach's week block) never contradict the check.
  ///
  /// [weighInDays] counts the window's weigh-in days after the typo filter.
  /// Below the minimum ([minWeighInDays] days, [minWeighInSpanDays] apart)
  /// there is no rate. [noiseKgPerWeek] is [minDifferenceStandardErrors]
  /// standard errors of the slope: the band [evaluate] treats as noise.
  static ({int weighInDays, double? kgPerWeek, double? noiseKgPerWeek})
  weightRate(WeightLog weightLog, {required DateTime today}) {
    final weighIns = _weighInDays(
      weightLog,
      addDays(today, -windowDays),
      addDays(today, -1),
    );
    if (!_enoughWeighIns(weighIns)) {
      return (
        weighInDays: weighIns.length,
        kgPerWeek: null,
        noiseKgPerWeek: null,
      );
    }
    final (slopeKgPerDay, slopeError) = _slope(weighIns);
    return (
      weighInDays: weighIns.length,
      kgPerWeek: slopeKgPerDay * 7,
      noiseKgPerWeek: minDifferenceStandardErrors * slopeError * 7,
    );
  }

  static bool _enoughWeighIns(List<(DateTime, double)> weighIns) =>
      weighIns.length >= minWeighInDays &&
      daysBetween(weighIns.last.$1, weighIns.first.$1) >= minWeighInSpanDays;

  /// How far [evaluate] is from an estimate on the same inputs, or null when
  /// the check does not apply (manual goal, unfinished onboarding).
  ///
  /// [EnergyCheckProgress.ready] holds exactly when [evaluate] gets past its
  /// data and pause gates; the thresholds are this class's constants.
  EnergyCheckProgress? progress({
    required UserProfile profile,
    required DateTime today,
    required int Function(DateTime day) intakeKcal,
    required int? Function(DateTime day) burnedKcal,
    required WeightLog weightLog,
    bool stepSourceToday = false,
  }) {
    if (profile.manualEnergy || !profile.onboardingCompleted) return null;
    final pausedUntil = _pausedUntil(profile, today);
    final window = _Window.of(
      profile: profile,
      today: today,
      intakeKcal: intakeKcal,
      burnedKcal: burnedKcal,
      weightLog: weightLog,
      stepSourceToday: stepSourceToday,
    );
    final ready = window.dataReady && pausedUntil == null;
    final best = ready
        ? (days: 0, logged: 0, weighIns: 0)
        : _bestCase(
            today: today,
            window: window,
            weightLog: weightLog,
            notBeforeDays: pausedUntil == null
                ? 1
                : math.max(1, daysBetween(pausedUntil, today)),
          );
    return EnergyCheckProgress(
      today: today,
      loggedDays: window.logged.length,
      weighInDays: window.weighIns.length,
      weighInSpanDays: window.weighInSpanDays,
      pausedUntil: pausedUntil,
      earliestDay: addDays(today, best.days),
      loggedDaysToGo: best.logged,
      weighInsToGo: best.weighIns,
    );
  }

  /// The day the seven-day pause after the last answer ends, or null when
  /// [today] is past it.
  static DateTime? _pausedUntil(UserProfile profile, DateTime today) {
    final checkedOn = profile.energyCheckedOn;
    if (checkedOn == null || daysBetween(today, checkedOn) >= recheckDays) {
      return null;
    }
    return addDays(
      DateTime(checkedOn.year, checkedOn.month, checkedOn.day),
      recheckDays,
    );
  }

  /// The first day, at least [notBeforeDays] after [today], whose window
  /// can hold enough data if every day from today on is logged and the user
  /// weighs in where needed; with what that still takes.
  ///
  /// Logging every open day is the best case for the count. For the
  /// weigh-ins only the count and the span matter, and the latest possible
  /// day (the window's last) gives the widest span.
  static ({int days, int logged, int weighIns}) _bestCase({
    required DateTime today,
    required _Window window,
    required WeightLog weightLog,
    required int notBeforeDays,
  }) {
    final loggedOffsets = [
      for (final day in window.logged) daysBetween(day, today),
    ];
    final loggedToday = window.isLogged(today);
    // Found by day 15 or the first allowed day, whichever is later: from
    // then on the window holds at least 14 new days, whose first and last
    // weigh-in are 14 days apart.
    for (var k = notBeforeDays; k <= notBeforeDays + windowDays; k++) {
      // The window of day today + k: offsets first..k - 1 from today.
      final first = k - windowDays;
      final todayInWindow = first <= 0;
      final open = k - math.max(0, first);

      final keptLogged =
          loggedOffsets.where((o) => o >= first).length +
          (todayInWindow && loggedToday ? 1 : 0);
      final loggedToGo = math.max(0, minLoggedDays - keptLogged);
      if (loggedToGo > open - (todayInWindow && loggedToday ? 1 : 0)) {
        continue;
      }

      final kept = _weighInDays(weightLog, addDays(today, first), today);
      final weighedToday =
          kept.isNotEmpty && daysBetween(kept.last.$1, today) == 0;
      final free = open - (weighedToday ? 1 : 0);
      final int weighInsToGo;
      if (kept.isEmpty) {
        // The first new weigh-in at the window's first open day, the last
        // at its last day.
        if (k - 1 - math.max(0, first) < minWeighInSpanDays) continue;
        weighInsToGo = minWeighInDays;
      } else if (daysBetween(kept.last.$1, kept.first.$1) >=
          minWeighInSpanDays) {
        weighInsToGo = math.max(0, minWeighInDays - kept.length);
      } else {
        // One new weigh-in late enough for the span.
        if (daysBetween(addDays(today, k - 1), kept.first.$1) <
            minWeighInSpanDays) {
          continue;
        }
        weighInsToGo = math.max(1, minWeighInDays - kept.length);
      }
      if (weighInsToGo > free) continue;
      return (days: k, logged: loggedToGo, weighIns: weighInsToGo);
    }
    throw StateError('A full window of new days always qualifies');
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

/// Today's window as the check counts it, shared by [EnergyCheck.evaluate]
/// and [EnergyCheck.progress] so that the two never disagree on the gates.
class _Window {
  _Window._({
    required this.targets,
    required this.isLogged,
    required this.logged,
    required this.weighIns,
  });

  factory _Window.of({
    required UserProfile profile,
    required DateTime today,
    required int Function(DateTime day) intakeKcal,
    required int? Function(DateTime day) burnedKcal,
    required WeightLog weightLog,
    required bool stepSourceToday,
  }) {
    final targets = const KcalCalculator().calculate(profile);
    final days = [
      for (var n = EnergyCheck.windowDays; n >= 1; n--) addDays(today, -n),
    ];
    final steps = stepSourceToday || days.any((day) => burnedKcal(day) != null);
    // The shared complete-day rule; the step value on top is this model's
    // own need, since it subtracts the day's step kcal.
    bool isLogged(DateTime day) =>
        isCompleteDay(intakeKcal: intakeKcal(day), goalKcal: targets.kcal) &&
        (!steps || burnedKcal(day) != null);
    return _Window._(
      targets: targets,
      isLogged: isLogged,
      logged: [for (final day in days) if (isLogged(day)) day],
      weighIns: EnergyCheck._weighInDays(weightLog, days.first, days.last),
    );
  }

  final KcalTargets targets;

  /// Whether a day counts as logged: complete ([isCompleteDay]) and, with a
  /// step source, only with a step value.
  final bool Function(DateTime day) isLogged;
  final List<DateTime> logged;
  final List<(DateTime, double)> weighIns;

  int get weighInSpanDays => weighIns.isEmpty
      ? 0
      : daysBetween(weighIns.last.$1, weighIns.first.$1);

  bool get dataReady =>
      logged.length >= EnergyCheck.minLoggedDays &&
      EnergyCheck._enoughWeighIns(weighIns);
}
