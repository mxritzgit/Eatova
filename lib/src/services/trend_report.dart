import 'dart:math' as math;

import '../models/weight_log.dart';
import 'day_math.dart';
import 'energy_check.dart';
import 'local_day.dart';
import 'trend_service.dart';

/// No step bonus: the trend goal is the base goal on every day.
int noTrendStepBonus(DateTime _) => 0;

/// The ranges of the trends page.
enum TrendRange {
  week(7),
  month(30),
  quarter(90),
  halfYear(182);

  const TrendRange(this.days);

  /// Calendar days in the window, today included.
  final int days;

  /// From three months on, a chart shows one bar per week: 90 or 182 daily
  /// bars would be thinner than a hairline on a phone.
  bool get weekly => days >= 90;

  static TrendRange ofDays(int days) => TrendRange.values.firstWhere(
    (range) => range.days == days,
    orElse: () => TrendRange.month,
  );
}

/// The targets a trend window is measured against.
class TrendGoals {
  const TrendGoals({
    required this.kcal,
    this.proteinG = 0,
    this.stepsPerDay = 0,
    this.burnedKcalFor = noTrendStepBonus,
  });

  /// Base daily kcal goal.
  final int kcal;
  final int proteinG;
  final int stepsPerDay;

  /// Step bonus per local day, the Today tab's model B (F7-05).
  final int Function(DateTime day) burnedKcalFor;
}

/// One chart slot: a day, or a week from [TrendRange.weekly] on.
class TrendBar {
  const TrendBar({
    required this.start,
    required this.days,
    required this.value,
    required this.goal,
    this.partial = false,
  });

  /// First local day of the slot.
  final DateTime start;

  /// Days in the slot: 1, or up to 7 for a week (the oldest week of a range
  /// that is not a multiple of seven is shorter).
  final int days;

  /// Day value, or the average over the slot's measured completed days;
  /// null when there is none.
  final int? value;

  /// Goal for the slot (average over its days for a week); 0 draws none.
  final int goal;

  /// A completed day below the complete-day rule, left out of the averages;
  /// the chart draws it faded. Never set on today or on a week.
  final bool partial;

  @override
  bool operator ==(Object other) =>
      other is TrendBar &&
      other.start == start &&
      other.days == days &&
      other.value == value &&
      other.goal == goal &&
      other.partial == partial;

  @override
  int get hashCode => Object.hash(start, days, value, goal, partial);
}

/// Weigh-ins inside a trend window.
class TrendWeight {
  const TrendWeight({required this.points, this.line});

  /// Last weigh-in of each local day in the window, oldest first.
  final List<({DateTime day, double kg})> points;

  /// The weekly check's line through the window's weigh-ins, typos dropped
  /// (`EnergyCheck.weightLine`); null below its minimum.
  final WeightTrendLine? line;

  ({DateTime day, double kg}) get first => points.first;
  ({DateTime day, double kg}) get last => points.last;

  /// Change from the first to the last weigh-in day; null below two days.
  double? get changeKg => points.length < 2 ? null : last.kg - first.kg;

  /// The weekly rate as the Monday card and the Coach measure it, over this
  /// window (2026-10-22): the slope of [line], not first to last weigh-in,
  /// which a single water swing at either end could turn around.
  double? get kgPerWeek => line?.kgPerWeek;
}

/// Everything the trends page shows for one range. Pure: built from the
/// day totals (server plus local overlay), the step history, the weight log
/// and the finished workouts.
///
/// B6 holds for every average: the running day is excluded, or a single
/// breakfast would count as a whole day. The charts still show today.
///
/// The kcal and macro averages, the goal rate and the protein days count
/// complete days only ([isCompleteDay] against the base goal, 2026-10-19);
/// [partialDays] says how many logged days they left out.
class TrendReport {
  TrendReport._({
    required this.range,
    required this.firstDay,
    required this.window,
    required this.goalPerDay,
    required this.kcalBars,
    required this.avgKcal,
    required this.hits,
    required this.macros,
    required this.proteinGoalDays,
    required this.proteinUnknownDays,
    required this.loggedDays,
    required this.fullDays,
    required this.stepBars,
    required this.avgSteps,
    required this.stepDays,
    required this.bestStepDay,
    required this.stepGoalDays,
    required this.weight,
    required this.workouts,
  });

  factory TrendReport.build({
    required TrendRange range,
    required DateTime today,
    required List<TrendDayTotals> totals,
    required TrendGoals goals,
    Map<String, int> stepsByDay = const <String, int>{},
    int? stepsToday,
    List<WeightLogEntry> weighIns = const <WeightLogEntry>[],
    Iterable<DateTime> workoutsFinishedAt = const <DateTime>[],
  }) {
    final day0 = startOfDay(today);
    final window = denseTrendWindow(totals, today: day0, days: range.days);
    final firstDay = addDays(day0, -(range.days - 1));
    final days = [for (var i = 0; i < range.days; i++) addDays(firstDay, i)];
    final goalPerDay = [
      for (final day in days) goals.kcal + goals.burnedKcalFor(day),
    ];
    final completed = completedDaysOf(window);
    // The averages' days: completed AND complete.
    final full = fullyLoggedDaysOf(completed, goalKcal: goals.kcal);

    final steps = <int?>[
      for (final day in days)
        daysBetween(day, day0) == 0 ? stepsToday : stepsByDay[localDayKey(day)],
    ];
    final completedSteps = steps.sublist(0, steps.length - 1);
    var stepSum = 0;
    var stepDays = 0;
    var stepGoalDays = 0;
    ({DateTime day, int steps})? best;
    for (var i = 0; i < completedSteps.length; i++) {
      final value = completedSteps[i];
      if (value == null) continue;
      stepSum += value;
      stepDays++;
      if (goals.stepsPerDay > 0 && value >= goals.stepsPerDay) stepGoalDays++;
      if (best == null || value > best.steps) {
        best = (day: days[i], steps: value);
      }
    }

    var proteinGoalDays = 0;
    var proteinUnknownDays = 0;
    if (goals.proteinG > 0) {
      for (final day in full) {
        if (day == null) continue;
        if (day.proteinG >= goals.proteinG) {
          proteinGoalDays++;
        } else if (day.proteinMissing > 0) {
          proteinUnknownDays++;
        }
      }
    }
    final last = window.length - 1;

    return TrendReport._(
      range: range,
      firstDay: firstDay,
      window: window,
      goalPerDay: goalPerDay,
      kcalBars: _bars(
        range: range,
        days: days,
        values: [for (final day in window) day?.kcal],
        // A week averages its complete days, like the stat under the chart;
        // today's slot is never averaged.
        weekValues: [for (final day in full) day?.kcal, null],
        partial: [
          for (var i = 0; i < window.length; i++)
            i != last && window[i] != null && full[i] == null,
        ],
        goals: goalPerDay,
      ),
      avgKcal: averageKcalOf(full),
      hits: goalHitsOf(
        full,
        goalKcal: goals.kcal,
        burnedKcalFor: goals.burnedKcalFor,
      ),
      macros: averageMacrosOf(full),
      proteinGoalDays: proteinGoalDays,
      proteinUnknownDays: proteinUnknownDays,
      loggedDays: trackedDaysOf(completed),
      fullDays: trackedDaysOf(full),
      stepBars: _bars(
        range: range,
        days: days,
        values: steps,
        goals: [for (final _ in days) goals.stepsPerDay],
      ),
      avgSteps: stepDays == 0 ? null : stepSum / stepDays,
      stepDays: stepDays,
      bestStepDay: best,
      stepGoalDays: stepGoalDays,
      weight: _weight(weighIns, firstDay: firstDay, today: day0),
      workouts: workoutsFinishedAt.where((at) {
        final local = at.toLocal();
        return daysBetween(local, firstDay) >= 0 &&
            daysBetween(local, day0) <= 0;
      }).length,
    );
  }

  final TrendRange range;

  /// Oldest local day of the window; the newest is today.
  final DateTime firstDay;

  /// Day totals, oldest first, null for a day without entries; today last.
  final List<TrendDayTotals?> window;

  /// kcal goal per window day: base plus that day's step bonus.
  final List<int> goalPerDay;

  /// The kcal chart: one bar per day, or per week from three months on.
  final List<TrendBar> kcalBars;

  /// Average kcal over the complete completed days.
  final double? avgKcal;

  /// Complete completed days inside the goal corridor.
  final ({int hit, int tracked}) hits;

  /// Average macros over the complete completed days.
  final ({double proteinG, double carbsG, double fatG})? macros;

  /// Complete completed days that reached the protein goal.
  final int proteinGoalDays;

  /// Complete completed days below the protein goal with entries of unknown
  /// protein: they may have reached it, so [proteinGoalDays] is a lower
  /// bound.
  final int proteinUnknownDays;

  /// Completed days with at least one entry.
  final int loggedDays;

  /// Completed days that pass the complete-day rule: the averages' days.
  final int fullDays;

  /// Logged completed days below the rule, left out of the averages.
  int get partialDays => loggedDays - fullDays;

  /// Completed days in the window: every day but today.
  int get completedDays => range.days - 1;

  /// The step chart, slotted like [kcalBars].
  final List<TrendBar> stepBars;

  /// Average steps over the completed days that have a step value.
  final double? avgSteps;

  /// Completed days with a step value (a measured 0 counts).
  final int stepDays;
  final ({DateTime day, int steps})? bestStepDay;

  /// Completed days at or above the step goal.
  final int stepGoalDays;

  /// Weigh-ins in the window; null without any.
  final TrendWeight? weight;

  /// Workouts finished in the window, today included.
  final int workouts;

  /// [workouts] per seven days of the window.
  double get workoutsPerWeek => workouts / range.days * 7;

  /// Slots [values] per day, or per week counted back from today. A week's
  /// value averages its measured COMPLETED days of [weekValues] (default
  /// [values]), so today's partial value never drags its week down; its goal
  /// averages all of its days. [partial] marks day bars to draw faded.
  static List<TrendBar> _bars({
    required TrendRange range,
    required List<DateTime> days,
    required List<int?> values,
    required List<int> goals,
    List<int?>? weekValues,
    List<bool>? partial,
  }) {
    if (!range.weekly) {
      return [
        for (var i = 0; i < days.length; i++)
          TrendBar(
            start: days[i],
            days: 1,
            value: values[i],
            goal: goals[i],
            partial: partial?[i] ?? false,
          ),
      ];
    }
    final averaged = weekValues ?? values;
    final bars = <TrendBar>[];
    final last = days.length - 1;
    for (var end = days.length; end > 0; end -= 7) {
      final start = math.max(0, end - 7);
      var sum = 0;
      var measured = 0;
      var goalSum = 0;
      for (var i = start; i < end; i++) {
        goalSum += goals[i];
        final value = averaged[i];
        if (i == last || value == null) continue;
        sum += value;
        measured++;
      }
      bars.add(
        TrendBar(
          start: days[start],
          days: end - start,
          value: measured == 0 ? null : (sum / measured).round(),
          goal: (goalSum / (end - start)).round(),
        ),
      );
    }
    return bars.reversed.toList(growable: false);
  }

  static TrendWeight? _weight(
    List<WeightLogEntry> entries, {
    required DateTime firstDay,
    required DateTime today,
  }) {
    final byDay = <String, ({DateTime day, double kg})>{};
    for (final entry in entries) {
      final local = entry.timestamp.toLocal();
      if (daysBetween(local, firstDay) < 0 || daysBetween(local, today) > 0) {
        continue;
      }
      // Entries are ascending, so the day's last weigh-in wins.
      byDay[localDayKey(local)] = (day: startOfDay(local), kg: entry.weightKg);
    }
    if (byDay.isEmpty) return null;
    final points = byDay.values.toList()
      ..sort((a, b) => a.day.compareTo(b.day));
    return TrendWeight(
      points: points,
      line: EnergyCheck.weightLine(
        WeightLog(entries: entries),
        first: firstDay,
        last: today,
      ),
    );
  }
}

/// Day totals for the trends page: the server's window, with every day the
/// local store knows completely ([local]) taken from there. Those include
/// writes still waiting in the outbox (TRN-9); a known day without entries
/// ([local] maps it to null) drops a server day a pending delete removed.
List<TrendDayTotals> overlayTrendTotals(
  List<TrendDayTotals> server,
  Map<String, TrendDayTotals?> local,
) {
  final byKey = <String, TrendDayTotals>{
    for (final day in server)
      if (!local.containsKey(localDayKey(day.day))) localDayKey(day.day): day,
  };
  for (final entry in local.entries) {
    final day = entry.value;
    if (day != null) byKey[entry.key] = day;
  }
  return byKey.values.toList()..sort((a, b) => a.day.compareTo(b.day));
}
