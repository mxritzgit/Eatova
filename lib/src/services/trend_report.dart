import 'dart:math' as math;

import '../models/weight_log.dart';
import 'day_math.dart';
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

  @override
  bool operator ==(Object other) =>
      other is TrendBar &&
      other.start == start &&
      other.days == days &&
      other.value == value &&
      other.goal == goal;

  @override
  int get hashCode => Object.hash(start, days, value, goal);
}

/// Weigh-ins inside a trend window.
class TrendWeight {
  const TrendWeight({required this.points});

  /// Last weigh-in of each local day in the window, oldest first.
  final List<({DateTime day, double kg})> points;

  ({DateTime day, double kg}) get first => points.first;
  ({DateTime day, double kg}) get last => points.last;

  /// Change from the first to the last weigh-in day; null below two days.
  double? get changeKg => points.length < 2 ? null : last.kg - first.kg;

  /// [changeKg] per week over the days between the two; null below a week,
  /// where a rate would amplify day-to-day water swings.
  double? get kgPerWeek {
    final change = changeKg;
    if (change == null) return null;
    final span = daysBetween(last.day, first.day);
    return span < 7 ? null : change / span * 7;
  }
}

/// Everything the trends page shows for one range. Pure: built from the
/// day totals (server plus local overlay), the step history, the weight log
/// and the finished workouts.
///
/// B6 holds for every average: the running day is excluded, or a single
/// breakfast would count as a whole day. The charts still show today.
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
    required this.loggedDays,
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
    if (goals.proteinG > 0) {
      for (final day in completed) {
        if (day != null && day.proteinG >= goals.proteinG) proteinGoalDays++;
      }
    }

    return TrendReport._(
      range: range,
      firstDay: firstDay,
      window: window,
      goalPerDay: goalPerDay,
      kcalBars: _bars(
        range: range,
        days: days,
        values: [for (final day in window) day?.kcal],
        goals: goalPerDay,
      ),
      avgKcal: averageKcalOf(completed),
      hits: goalHitsOf(
        completed,
        goalKcal: goals.kcal,
        burnedKcalFor: goals.burnedKcalFor,
      ),
      macros: averageMacrosOf(completed),
      proteinGoalDays: proteinGoalDays,
      loggedDays: trackedDaysOf(completed),
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

  /// Average kcal over the logged completed days.
  final double? avgKcal;

  /// Logged completed days inside the goal corridor.
  final ({int hit, int tracked}) hits;

  /// Average macros over the logged completed days.
  final ({double proteinG, double carbsG, double fatG})? macros;

  /// Logged completed days that reached the protein goal.
  final int proteinGoalDays;

  /// Completed days with at least one entry.
  final int loggedDays;

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
  /// value averages its measured COMPLETED days, so today's partial value
  /// never drags its week down; its goal averages all of its days.
  static List<TrendBar> _bars({
    required TrendRange range,
    required List<DateTime> days,
    required List<int?> values,
    required List<int> goals,
  }) {
    if (!range.weekly) {
      return [
        for (var i = 0; i < days.length; i++)
          TrendBar(start: days[i], days: 1, value: values[i], goal: goals[i]),
      ];
    }
    final bars = <TrendBar>[];
    final last = days.length - 1;
    for (var end = days.length; end > 0; end -= 7) {
      final start = math.max(0, end - 7);
      var sum = 0;
      var measured = 0;
      var goalSum = 0;
      for (var i = start; i < end; i++) {
        goalSum += goals[i];
        final value = values[i];
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
    return TrendWeight(points: points);
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
