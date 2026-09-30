/// Training numbers for the redesigned Today and Training tabs, derived only
/// from the selected plan and the completed-workout history.
///
/// Pure and widget-free; `HomeStore` binds its state to these in
/// `home_store_derivations.dart`. Every calendar rule works on LOCAL days:
/// history timestamps are UTC and are converted with `toLocal()` first.
library;

import '../services/day_math.dart';
import '../services/local_day.dart';
import 'training_history.dart';
import 'training_plan.dart';
import 'training_session.dart';

/// Local midnight of the Monday that starts [date]'s week (weeks run Mon–Sun,
/// as in the design's "This week" strip).
DateTime startOfLocalWeek(DateTime date) {
  final local = date.toLocal();
  return addDays(startOfDay(local), DateTime.monday - local.weekday);
}

DateTime _localDay(DateTime instant) => startOfDay(instant.toLocal());

/// Newest first by finish time; the session id breaks ties deterministically.
int _newestFirst(TrainingHistoryEntry a, TrainingHistoryEntry b) {
  final byTime = b.finishedAt.compareTo(a.finishedAt);
  return byTime != 0 ? byTime : b.id.compareTo(a.id);
}

// ---------------------------------------------------------------------------
// Next workout
// ---------------------------------------------------------------------------

/// The best set of [sets]: heaviest weight, then most reps; the earlier set
/// wins a tie. Bodyweight sets (no weight) rank by reps. Null for no sets.
///
/// Feeds "Last time 75 kg × 8" together with [lastTrainingPerformance].
TrainingSetActual? topTrainingSet(Iterable<TrainingSetActual> sets) {
  TrainingSetActual? best;
  for (final set in sets) {
    if (best == null) {
      best = set;
      continue;
    }
    final weight = set.weightKg ?? 0;
    final bestWeight = best.weightKg ?? 0;
    if (weight > bestWeight ||
        (weight == bestWeight && (set.reps ?? 0) > (best.reps ?? 0))) {
      best = set;
    }
  }
  return best;
}

/// One planned exercise of [TrainingNextWorkout] with its last performance.
final class TrainingExercisePreview {
  const TrainingExercisePreview({required this.exercise, this.lastTopSet});

  /// The prescription: `sets`, then `reps` or `durationSeconds`.
  final TrainingExercise exercise;

  /// [topTrainingSet] of the most recent session of this exercise in this
  /// plan; null when it was never performed.
  final TrainingSetActual? lastTopSet;
}

/// The workout the Today activity card and the Training hero show.
final class TrainingNextWorkout {
  const TrainingNextWorkout({
    required this.plan,
    required this.workoutIndex,
    required this.completedToday,
    required this.exercises,
  });

  final TrainingPlan plan;

  /// Index into `plan.workouts`, e.g. for `onStartWorkout(plan, index)`.
  final int workoutIndex;

  /// True when today's workout is already done: [workout] is then the one
  /// finished today, not the next in the rotation.
  final bool completedToday;

  /// One entry per exercise of [workout], in execution order.
  final List<TrainingExercisePreview> exercises;

  TrainingWorkout get workout => plan.workouts[workoutIndex];
  String get title => workout.title;
  int get exerciseCount => workout.exercises.length;

  /// The app's existing duration estimate (3 s per rep plus rests), rounded
  /// to whole minutes, at least 1.
  int get estimatedMinutes {
    final minutes = (workout.estimatedDurationSeconds / 60).round();
    return minutes < 1 ? 1 : minutes;
  }
}

/// The workout due today for [plan] (the selected plan), or null without one.
///
/// Plans carry no weekdays, so the schedule is a ROTATION through
/// `plan.workouts`: the workout after the one last completed from this plan,
/// wrapping around; the first workout when the plan was never trained. If
/// that last session finished today (local day), today's workout is that one,
/// with [TrainingNextWorkout.completedToday] set.
///
/// A session maps to the current plan by exercise identity (exercise ids
/// survive plan edits and reorders), falling back to its stored workout
/// index; an unmappable session restarts the rotation at the first workout.
TrainingNextWorkout? nextTrainingWorkout({
  required TrainingPlan? plan,
  required List<TrainingHistoryEntry> history,
  required DateTime now,
}) {
  if (plan == null || plan.workouts.isEmpty) return null;
  final ofPlan = history.where((entry) => entry.snapshot.plan.id == plan.id);
  TrainingHistoryEntry? last;
  for (final entry in ofPlan) {
    if (last == null || _newestFirst(entry, last) < 0) last = entry;
  }
  var index = 0;
  var completedToday = false;
  if (last != null) {
    final lastIndex = _workoutIndexInPlan(plan, last);
    if (lastIndex >= 0) {
      completedToday = _localDay(last.finishedAt) == _localDay(now);
      index = completedToday
          ? lastIndex
          : (lastIndex + 1) % plan.workouts.length;
    }
  }
  final workout = plan.workouts[index];
  return TrainingNextWorkout(
    plan: plan,
    workoutIndex: index,
    completedToday: completedToday,
    exercises: List.unmodifiable([
      for (final exercise in workout.exercises)
        TrainingExercisePreview(
          exercise: exercise,
          lastTopSet: exercise.id == null
              ? null
              : topTrainingSet(
                  lastTrainingPerformance(
                    history,
                    plan.id,
                    exercise.id!,
                    isTimed: exercise.isTimed,
                  ),
                ),
        ),
    ]),
  );
}

int _workoutIndexInPlan(TrainingPlan plan, TrainingHistoryEntry entry) {
  final ids = entry.snapshot.workout.exercises
      .map((exercise) => exercise.id)
      .whereType<String>()
      .toSet();
  final match = plan.workouts.indexWhere(
    (workout) => workout.exercises.any((e) => ids.contains(e.id)),
  );
  if (match >= 0) return match;
  final stored = entry.snapshot.workoutIndex;
  return stored < plan.workouts.length ? stored : -1;
}

// ---------------------------------------------------------------------------
// This week
// ---------------------------------------------------------------------------

/// One day of [TrainingWeek].
final class TrainingWeekDay {
  const TrainingWeekDay({
    required this.date,
    required this.isToday,
    required this.sessions,
  });

  /// Local midnight.
  final DateTime date;
  final bool isToday;

  /// Workouts (any plan) that FINISHED on this local day, oldest first.
  final List<TrainingHistoryEntry> sessions;

  bool get done => sessions.isNotEmpty;
}

/// The current local week, Monday to Sunday, for the "This week" strip.
final class TrainingWeek {
  const TrainingWeek({
    required this.start,
    required this.days,
    required this.plannedSessions,
  });

  /// Local Monday midnight ([startOfLocalWeek]).
  final DateTime start;

  /// Exactly seven days, Monday first.
  final List<TrainingWeekDay> days;

  /// Workouts in the selected plan, read as sessions per week ("0 of 3
  /// done"); null without a plan. An ASSUMPTION: plans store no frequency,
  /// and the coach builds one workout per weekly session.
  final int? plannedSessions;

  /// Completed sessions this week, any plan; may exceed [plannedSessions].
  int get doneSessions =>
      days.fold(0, (count, day) => count + day.sessions.length);

  /// Local Sunday midnight (for "Sep 28 – Oct 4").
  DateTime get end => days.last.date;
}

/// [now]'s week with the finished sessions of [history] per day.
///
/// Planned session types per weekday are NOT derivable: a plan has no
/// weekday assignment. [plan] only supplies [TrainingWeek.plannedSessions].
TrainingWeek trainingWeekOf({
  required DateTime now,
  required List<TrainingHistoryEntry> history,
  TrainingPlan? plan,
}) {
  final start = startOfLocalWeek(now);
  final today = _localDay(now);
  final byDay = <String, List<TrainingHistoryEntry>>{};
  for (final entry in history) {
    byDay
        .putIfAbsent(localDayKey(_localDay(entry.finishedAt)), () => [])
        .add(entry);
  }
  final days = <TrainingWeekDay>[];
  for (var i = 0; i < 7; i++) {
    final date = addDays(start, i);
    final sessions = [...?byDay[localDayKey(date)]]
      ..sort((a, b) => _newestFirst(b, a));
    days.add(
      TrainingWeekDay(
        date: date,
        isToday: date == today,
        sessions: List.unmodifiable(sessions),
      ),
    );
  }
  return TrainingWeek(
    start: start,
    days: List.unmodifiable(days),
    plannedSessions: plan?.workouts.length,
  );
}

// ---------------------------------------------------------------------------
// Weekly volume
// ---------------------------------------------------------------------------

/// Total load of one workout in kg: the sum of weight × reps over its
/// performed sets. Sets without a positive weight (bodyweight) or without
/// positive reps (timed or failed sets) carry no load.
double trainingLoadKg(TrainingHistoryEntry entry) {
  var total = 0.0;
  for (final set in entry.snapshot.actualSets) {
    final weight = set.weightKg;
    final reps = set.reps;
    if (weight == null || reps == null || weight <= 0 || reps <= 0) continue;
    total += weight * reps;
  }
  return total;
}

/// One bar of [TrainingVolumeTrend].
final class TrainingVolumeWeek {
  const TrainingVolumeWeek({
    required this.start,
    required this.volumeKg,
    required this.isCurrent,
  });

  /// Local Monday midnight; the bar label ("Sep 21", or "Now" if current).
  final DateTime start;
  final double volumeKg;

  /// The running, partial week.
  final bool isCurrent;

  double get tonnes => volumeKg / 1000;
}

/// The "Weekly volume" chart: full weeks oldest first, then the current week.
final class TrainingVolumeTrend {
  const TrainingVolumeTrend(this.weeks);

  /// Oldest first; the last entry is the current partial week.
  final List<TrainingVolumeWeek> weeks;

  TrainingVolumeWeek get currentWeek => weeks.last;

  /// The newest complete week ("8.6 tonnes last week"), null if none.
  TrainingVolumeWeek? get lastFullWeek =>
      weeks.length < 2 ? null : weeks[weeks.length - 2];

  /// Change of [lastFullWeek] against the week before it in percent ("↑ 9%"),
  /// unrounded; null when that earlier week has no volume or is not charted.
  double? get changePercent {
    if (weeks.length < 3) return null;
    final last = weeks[weeks.length - 2].volumeKg;
    final before = weeks[weeks.length - 3].volumeKg;
    if (before <= 0) return null;
    return (last - before) / before * 100;
  }
}

/// [trainingLoadKg] summed per local week of each workout's finish time, for
/// the last [fullWeeks] complete weeks plus the current partial week.
TrainingVolumeTrend trainingVolumeTrend({
  required List<TrainingHistoryEntry> history,
  required DateTime now,
  int fullWeeks = 5,
}) {
  final current = startOfLocalWeek(now);
  final starts = <DateTime>[
    for (var i = fullWeeks; i >= 0; i--) addDays(current, -7 * i),
  ];
  final totals = <String, double>{
    for (final start in starts) localDayKey(start): 0,
  };
  for (final entry in history) {
    final key = localDayKey(startOfLocalWeek(entry.finishedAt));
    final sum = totals[key];
    if (sum != null) totals[key] = sum + trainingLoadKg(entry);
  }
  return TrainingVolumeTrend(
    List.unmodifiable([
      for (final start in starts)
        TrainingVolumeWeek(
          start: start,
          volumeKg: totals[localDayKey(start)]!,
          isCurrent: start == current,
        ),
    ]),
  );
}

// ---------------------------------------------------------------------------
// Recent workouts and personal records
// ---------------------------------------------------------------------------

/// Estimated one-rep max (Epley): `weight × (1 + reps / 30)`, and the weight
/// itself for a single rep.
double estimatedOneRepMaxKg(double weightKg, int reps) =>
    reps <= 1 ? weightKg : weightKg * (1 + reps / 30);

/// Personal records per workout, keyed by [TrainingHistoryEntry.id].
///
/// PR rule: an exercise scores ONE record in a workout when that workout's
/// best set beats every EARLIER workout (by finish time) of the same exercise
/// on either
///  * estimated load — [estimatedOneRepMaxKg] of its best set, or
///  * actual load — its heaviest weight.
/// A tie is no record, and the first time an exercise is performed sets the
/// baseline without a record. Only sets with weight > 0 and reps > 0 count
/// (bodyweight, timed and failed sets are skipped). "Same exercise" is the
/// plan-scoped identity (plan id + exercise id) that "Last time" uses too
/// ([lastTrainingPerformance]); a copied plan starts fresh records.
Map<String, int> personalRecordCounts(List<TrainingHistoryEntry> history) {
  final ordered = [...history]..sort((a, b) => _newestFirst(b, a));
  final bestEstimate = <String, double>{};
  final bestWeight = <String, double>{};
  final counts = <String, int>{};
  for (final entry in ordered) {
    final estimate = <String, double>{};
    final weight = <String, double>{};
    final exercises = entry.snapshot.workout.exercises;
    final planId = entry.snapshot.plan.id;
    final keys = [
      for (var i = 0; i < exercises.length; i++)
        '$planId/${exercises[i].id ?? 'index-$i'}',
    ];
    for (final set in entry.snapshot.actualSets) {
      final index = set.reference.exerciseIndex;
      final kg = set.weightKg;
      final reps = set.reps;
      if (index >= exercises.length ||
          exercises[index].isTimed ||
          kg == null ||
          reps == null ||
          kg <= 0 ||
          reps <= 0) {
        continue;
      }
      final key = keys[index];
      final e1rm = estimatedOneRepMaxKg(kg, reps);
      if (e1rm > (estimate[key] ?? 0)) estimate[key] = e1rm;
      if (kg > (weight[key] ?? 0)) weight[key] = kg;
    }
    var records = 0;
    for (final key in estimate.keys) {
      final previousEstimate = bestEstimate[key];
      final previousWeight = bestWeight[key];
      if (previousEstimate != null &&
          previousWeight != null &&
          (estimate[key]! > previousEstimate ||
              weight[key]! > previousWeight)) {
        records++;
      }
      if (previousEstimate == null || estimate[key]! > previousEstimate) {
        bestEstimate[key] = estimate[key]!;
      }
      if (previousWeight == null || weight[key]! > previousWeight) {
        bestWeight[key] = weight[key]!;
      }
    }
    counts[entry.id] = records;
  }
  return counts;
}

/// One row of the "Recent" list.
final class TrainingWorkoutSummary {
  const TrainingWorkoutSummary({
    required this.entry,
    required this.personalRecords,
    required this.volumeKg,
  });

  final TrainingHistoryEntry entry;

  /// See [personalRecordCounts] for the rule ("2 PRs").
  final int personalRecords;

  /// [trainingLoadKg] of this workout.
  final double volumeKg;

  String get title => entry.snapshot.workout.title;

  /// UTC; call `toLocal()` before formatting ("Fri, Sep 25").
  DateTime get finishedAt => entry.finishedAt;

  /// Wall time from start to finish, pauses included ("52 min").
  Duration get duration =>
      entry.finishedAt.difference(entry.snapshot.startedAt);
}

/// The newest [limit] workouts of [history], newest first, each with its
/// record count (computed over the WHOLE history) and volume.
List<TrainingWorkoutSummary> recentTrainingWorkouts(
  List<TrainingHistoryEntry> history, {
  int limit = 3,
}) {
  if (limit <= 0 || history.isEmpty) return const <TrainingWorkoutSummary>[];
  final records = personalRecordCounts(history);
  final newest = [...history]..sort(_newestFirst);
  return List.unmodifiable([
    for (final entry in newest.take(limit))
      TrainingWorkoutSummary(
        entry: entry,
        personalRecords: records[entry.id] ?? 0,
        volumeKg: trainingLoadKg(entry),
      ),
  ]);
}
