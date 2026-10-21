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
import 'training_log.dart' show normalizeExerciseName;
import 'training_plan.dart';
import 'training_session.dart';

/// Local midnight of the Monday that starts [date]'s week (weeks run Mon–Sun,
/// as in the design's "This week" strip).
DateTime startOfLocalWeek(DateTime date) {
  final local = date.toLocal();
  return addDays(startOfDay(local), DateTime.monday - local.weekday);
}

DateTime _localDay(DateTime instant) => startOfDay(instant.toLocal());

/// A coarse instant prefilter, two days wider than the local days it guards
/// on each side, so it can never drop an entry the exact day-key rule would
/// keep. Local `DateTime` construction and day keys cost ~15-30 us per entry
/// (2000 entries: 30-60 ms per call); an instant comparison costs nothing.
final class _InstantWindow {
  const _InstantWindow(this.start, this.end);

  final DateTime start;
  final DateTime end;

  bool contains(DateTime instant) =>
      !instant.isBefore(start) && instant.isBefore(end);
}

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
/// Feeds "Last time 75 kg × 8" together with [lastTrainingPerformanceFor].
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

  /// [topTrainingSet] of [lastTrainingPerformanceFor]; null when this
  /// exercise was never performed, neither in this plan nor by name.
  final TrainingSetActual? lastTopSet;
}

/// "Last time" for [exercise] of the plan [planId] (spec A2): the newest
/// session of this plan that performed it ([lastTrainingPerformance]);
/// without one, the newest same-named exercise of the same kind in another
/// plan or a log ([lastTrainingPerformanceByName]). Records match by name
/// everywhere ([personalRecords]).
List<TrainingSetActual> lastTrainingPerformanceFor(
  List<TrainingHistoryEntry> history, {
  required String planId,
  required TrainingExercise exercise,
}) {
  final id = exercise.id;
  if (id != null) {
    final own = lastTrainingPerformance(
      history,
      planId,
      id,
      isTimed: exercise.isTimed,
    );
    if (own.isNotEmpty) return own;
  }
  return lastTrainingPerformanceByName(
    history,
    excludePlanId: planId,
    exerciseName: exercise.name,
    isTimed: exercise.isTimed,
  );
}

/// The player's weight-prefill source (spec A2): [lastTrainingPerformanceFor]
/// over only the sessions in which [exercise] carried a weight, so a session
/// logged without weights never blanks the prefill.
List<TrainingSetActual> lastWeightedTrainingPerformanceFor(
  List<TrainingHistoryEntry> history, {
  required String planId,
  required TrainingExercise exercise,
}) {
  final name = normalizeExerciseName(exercise.name);
  bool weighted(TrainingHistoryEntry entry) {
    final ownPlan = entry.snapshot.plan.id == planId;
    final exercises = entry.snapshot.workout.exercises;
    return entry.snapshot.actualSets.any((actual) {
      if (actual.weightKg == null) return false;
      final candidate = exercises[actual.reference.exerciseIndex];
      return candidate.isTimed == exercise.isTimed &&
          (ownPlan
              ? exercise.id != null && candidate.id == exercise.id
              : normalizeExerciseName(candidate.name) == name);
    });
  }

  return lastTrainingPerformanceFor(
    history.where(weighted).toList(),
    planId: planId,
    exercise: exercise,
  );
}

/// Last time's weight for set [setIndex]: that set's, else the last set's
/// (spec A2); null without [sets].
double? lastTimeWeightForSet(List<TrainingSetActual> sets, int setIndex) {
  if (sets.isEmpty) return null;
  for (final set in sets) {
    if (set.reference.setIndex == setIndex) return set.weightKg;
  }
  return sets.last.weightKg;
}

/// The selected plan's workout for today. The Today activity card shows
/// [workout] (the one done today once [completedToday]); the Training card
/// offers [upNextWorkoutIndex].
final class TrainingNextWorkout {
  const TrainingNextWorkout({
    required this.plan,
    required this.workoutIndex,
    required this.completedToday,
    required this.exercises,
  });

  final TrainingPlan plan;

  /// Index of [workout] into `plan.workouts`. A new start uses
  /// [upNextWorkoutIndex], which differs once [completedToday].
  final int workoutIndex;

  /// True when today's workout is already done: [workout] is then the one
  /// finished today, not the next in the rotation.
  final bool completedToday;

  /// One entry per exercise of [workout], in execution order.
  final List<TrainingExercisePreview> exercises;

  /// The workout to start next: the rotation's successor of [workoutIndex]
  /// once that one is [completedToday] (wrapping around), else
  /// [workoutIndex] itself.
  int get upNextWorkoutIndex =>
      completedToday ? (workoutIndex + 1) % plan.workouts.length : workoutIndex;

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
/// Other plans and free logs (`log_` plan ids) never move the rotation; they
/// only feed "Last time" by name ([lastTrainingPerformanceFor]).
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
          lastTopSet: topTrainingSet(
            lastTrainingPerformanceFor(
              history,
              planId: plan.id,
              exercise: exercise,
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
  const TrainingWeek({required this.start, required this.days});

  /// Local Monday midnight ([startOfLocalWeek]).
  final DateTime start;

  /// Exactly seven days, Monday first.
  final List<TrainingWeekDay> days;

  /// Completed sessions this week, any plan ("4 done"). No planned count:
  /// plans store no sessions per week, and their workouts rotate (the Coach
  /// builds 2-3 workouts for 4-5 weekly sessions).
  int get doneSessions =>
      days.fold(0, (count, day) => count + day.sessions.length);

  /// Local Sunday midnight (for "Sep 28 – Oct 4").
  DateTime get end => days.last.date;
}

/// [now]'s week with the finished sessions of [history] per day.
///
/// Planned session types per weekday are NOT derivable: a plan has no
/// weekday assignment.
TrainingWeek trainingWeekOf({
  required DateTime now,
  required List<TrainingHistoryEntry> history,
}) {
  final start = startOfLocalWeek(now);
  final today = _localDay(now);
  final window = _InstantWindow(addDays(start, -2), addDays(start, 9));
  final byDay = <String, List<TrainingHistoryEntry>>{};
  for (final entry in history) {
    if (!window.contains(entry.finishedAt)) continue;
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
  return TrainingWeek(start: start, days: List.unmodifiable(days));
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
}

/// The "Weekly volume" chart: full weeks oldest first, then the current week.
final class TrainingVolumeTrend {
  const TrainingVolumeTrend(this.weeks);

  /// Oldest first; the last entry is the current partial week.
  final List<TrainingVolumeWeek> weeks;

  TrainingVolumeWeek get currentWeek => weeks.last;

  /// Change of `weeks[index]` against the week before it in percent
  /// ("↑ 9%"), unrounded; null when that earlier week has no volume or is not
  /// charted.
  double? changePercentAt(int index) {
    if (index < 1 || index >= weeks.length) return null;
    final before = weeks[index - 1].volumeKg;
    if (before <= 0) return null;
    return (weeks[index].volumeKg - before) / before * 100;
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
  final window = _InstantWindow(
    addDays(starts.first, -2),
    addDays(current, 9),
  );
  for (final entry in history) {
    if (!window.contains(entry.finishedAt)) continue;
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

/// What a [TrainingRecord] beat.
enum TrainingRecordKind {
  /// A heavier set: estimated one-rep max or heaviest weight.
  load,

  /// More reps in one set without weight (bodyweight exercises).
  reps,
}

/// One exercise's personal record in one workout ([personalRecords]).
final class TrainingRecord {
  const TrainingRecord({
    required this.exerciseName,
    required this.kind,
    required this.set,
  });

  /// The exercise as this workout names it.
  final String exerciseName;
  final TrainingRecordKind kind;

  /// The set that holds the record: the best estimate (the heaviest set when
  /// only the weight beat), or the most reps without weight.
  final TrainingSetActual set;
}

/// One exercise's best sets within one workout.
final class _ExerciseBests {
  _ExerciseBests(this.name, this.index);

  final String name;

  /// First position in the workout, for the display order.
  final int index;
  double estimate = 0;
  double heaviest = 0;
  int reps = 0;
  TrainingSetActual? estimateSet;
  TrainingSetActual? heaviestSet;
  TrainingSetActual? repsSet;

  void add(TrainingSetActual set, int count) {
    final kg = set.weightKg;
    if (kg != null && kg > 0) {
      final e1rm = estimatedOneRepMaxKg(kg, count);
      if (e1rm > estimate) {
        estimate = e1rm;
        estimateSet = set;
      }
      if (kg > heaviest) {
        heaviest = kg;
        heaviestSet = set;
      }
    } else if (count > reps) {
      reps = count;
      repsSet = set;
    }
  }
}

/// The best values per exercise over the workouts added so far, keyed by
/// [normalizeExerciseName]. Workouts must be added oldest first.
final class _RecordBook {
  final _estimate = <String, double>{};
  final _weight = <String, double>{};
  final _reps = <String, int>{};

  /// The records [sets] of [workout] set against every workout added
  /// before, in workout order; then adds them to the bests.
  List<TrainingRecord> add(
    TrainingWorkout workout,
    Iterable<TrainingSetActual> sets,
  ) {
    final exercises = workout.exercises;
    final bests = <String, _ExerciseBests>{};
    for (final set in sets) {
      final index = set.reference.exerciseIndex;
      final reps = set.reps;
      if (index >= exercises.length ||
          exercises[index].isTimed ||
          reps == null ||
          reps <= 0) {
        continue;
      }
      final name = exercises[index].name;
      bests
          .putIfAbsent(
            normalizeExerciseName(name),
            () => _ExerciseBests(name.trim(), index),
          )
          .add(set, reps);
    }
    final records = <(int, TrainingRecord)>[];
    for (final MapEntry(:key, value: best) in bests.entries) {
      final previousEstimate = _estimate[key];
      final previousWeight = _weight[key];
      final previousReps = _reps[key];
      TrainingRecord? record;
      if (best.estimateSet case final estimateSet?) {
        if (previousEstimate != null && previousWeight != null) {
          final beatsEstimate = best.estimate > previousEstimate;
          if (beatsEstimate || best.heaviest > previousWeight) {
            record = TrainingRecord(
              exerciseName: best.name,
              kind: TrainingRecordKind.load,
              set: beatsEstimate ? estimateSet : best.heaviestSet!,
            );
          }
        }
        if (previousEstimate == null || best.estimate > previousEstimate) {
          _estimate[key] = best.estimate;
        }
        if (previousWeight == null || best.heaviest > previousWeight) {
          _weight[key] = best.heaviest;
        }
      }
      if (best.repsSet case final repsSet?) {
        if (record == null &&
            previousReps != null &&
            best.reps > previousReps) {
          record = TrainingRecord(
            exerciseName: best.name,
            kind: TrainingRecordKind.reps,
            set: repsSet,
          );
        }
        if (previousReps == null || best.reps > previousReps) {
          _reps[key] = best.reps;
        }
      }
      if (record != null) records.add((best.index, record));
    }
    records.sort((a, b) => a.$1.compareTo(b.$1));
    return [for (final (_, record) in records) record];
  }
}

/// Personal records per workout, keyed by [TrainingHistoryEntry.id]; every
/// workout of [history] has an entry, empty without a record.
///
/// PR rule: an exercise scores ONE record in a workout when that workout's
/// best set beats every EARLIER workout (by finish time) of the same exercise
/// on
///  * estimated load — [estimatedOneRepMaxKg] of its best weighted set, or
///  * actual load — its heaviest weight, or
///  * reps — its most reps in a set without weight (bodyweight).
/// A tie is no record, and the first time an exercise is performed (with or
/// without weight) sets that baseline without a record. Timed sets and sets
/// without reps are skipped. "Same exercise" is the [normalizeExerciseName]
/// of its name, across plans, copied plans and free logs.
Map<String, List<TrainingRecord>> personalRecords(
  List<TrainingHistoryEntry> history,
) {
  final book = _RecordBook();
  return {
    for (final entry in [...history]..sort((a, b) => _newestFirst(b, a)))
      entry.id: List.unmodifiable(
        book.add(entry.snapshot.workout, entry.snapshot.actualSets),
      ),
  };
}

/// [personalRecords] counted per workout ("2 PRs").
Map<String, int> personalRecordCounts(List<TrainingHistoryEntry> history) => {
  for (final MapEntry(:key, :value) in personalRecords(history).entries)
    key: value.length,
};

/// The records a workout in progress sets with its done [sets] of [workout]
/// against all of [history] (the finish sheet); the workout's own saved
/// entry, [sessionId], is not its own baseline.
List<TrainingRecord> sessionPersonalRecords({
  required List<TrainingHistoryEntry> history,
  required TrainingWorkout workout,
  required Iterable<TrainingSetActual> sets,
  required String sessionId,
}) {
  final book = _RecordBook();
  final earlier = history.where((entry) => entry.id != sessionId).toList()
    ..sort((a, b) => _newestFirst(b, a));
  for (final entry in earlier) {
    book.add(entry.snapshot.workout, entry.snapshot.actualSets);
  }
  return List.unmodifiable(book.add(workout, sets));
}

/// One workout's best set of an exercise ([trainingExerciseProgress]).
final class TrainingExerciseBest {
  const TrainingExerciseBest({
    required this.entry,
    required this.set,
    required this.isRecord,
  });

  final TrainingHistoryEntry entry;

  /// [topTrainingSet] of the workout's sets of this exercise.
  final TrainingSetActual set;

  /// The workout set a record for this exercise ([personalRecords]).
  final bool isRecord;
}

/// The best set of [exerciseName] per workout, newest first: every workout
/// of [history] with a set of a repetition exercise of that
/// [normalizeExerciseName], across plans and free logs.
List<TrainingExerciseBest> trainingExerciseProgress(
  List<TrainingHistoryEntry> history,
  String exerciseName,
) {
  final name = normalizeExerciseName(exerciseName);
  final records = personalRecords(history);
  final rows = <TrainingExerciseBest>[];
  for (final entry in [...history]..sort(_newestFirst)) {
    final exercises = entry.snapshot.workout.exercises;
    final best = topTrainingSet(
      entry.snapshot.actualSets.where((set) {
        final index = set.reference.exerciseIndex;
        return index < exercises.length &&
            !exercises[index].isTimed &&
            set.reps != null &&
            normalizeExerciseName(exercises[index].name) == name;
      }),
    );
    if (best == null) continue;
    rows.add(
      TrainingExerciseBest(
        entry: entry,
        set: best,
        isRecord: records[entry.id]!.any(
          (record) => normalizeExerciseName(record.exerciseName) == name,
        ),
      ),
    );
  }
  return List.unmodifiable(rows);
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
