import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../services/day_math.dart';
import 'coach_training_proposal.dart';
import 'training_history.dart';
import 'training_limits.dart';
import 'training_plan.dart';
import 'training_session.dart';

/// Bounds of a logged workout, shared with the Coach wire schema (spec C3).
abstract final class TrainingLogLimits {
  static const int daysBack = 30;
  static const int durationMinutesMax = 600;
  static const int timedSecondsMax = 36000;
  static const int repsMax = 1000;
  static const double weightKgMax = 2000;
}

/// Plan ID prefix of a free log: `log_<historyId>`.
const String trainingLogPlanPrefix = 'log_';

/// The identity form of an exercise name: trimmed, inner whitespace collapsed
/// to one space, lowercase.
String normalizeExerciseName(String name) =>
    name.trim().replaceAll(_whitespace, ' ').toLowerCase();

final RegExp _whitespace = RegExp(r'\s+');

/// Exercise ID of a logged workout: 'n_' plus the first 32 hex chars of the
/// SHA-256 of the normalized name; the k-th repeat (k > 1) appends '_k'.
String trainingLogExerciseId(String name, int occurrence) {
  final digest = sha256
      .convert(utf8.encode(normalizeExerciseName(name)))
      .toString()
      .substring(0, 32);
  return occurrence > 1 ? 'n_${digest}_$occurrence' : 'n_$digest';
}

/// Whether [entry] was logged after the fact rather than played.
bool isLoggedTrainingEntry(TrainingHistoryEntry entry) =>
    entry.snapshot.plan.id.startsWith(trainingLogPlanPrefix);

/// False for a log without a stated duration (start equals finish).
bool trainingEntryHasDuration(TrainingHistoryEntry entry) =>
    !entry.snapshot.startedAt.isAtSameMomentAs(entry.finishedAt);

/// One logged set; a timed exercise ignores [reps].
final class LoggedSet {
  const LoggedSet({this.reps, this.weightKg});

  final int? reps;
  final double? weightKg;
}

/// One logged exercise; [durationSeconds] is per set and only for [timed].
final class LoggedExercise {
  const LoggedExercise({
    required this.name,
    required this.timed,
    this.durationSeconds,
    required this.sets,
  });

  final String name;
  final bool timed;
  final int? durationSeconds;
  final List<LoggedSet> sets;
}

/// An editable completed workout before it becomes a history entry.
final class LoggedWorkoutDraft {
  const LoggedWorkoutDraft({
    required this.title,
    this.performedOn,
    this.durationMinutes,
    this.note = '',
    this.otherDaysOmitted = false,
    required this.exercises,
  });

  final String title;

  /// Local calendar day (year, month, day); the time is ignored.
  final DateTime? performedOn;
  final int? durationMinutes;
  final String note;
  final bool otherDaysOmitted;
  final List<LoggedExercise> exercises;
}

/// [empty] also covers an exercise without a name or sets; [tooLarge] covers
/// every value outside the limits, including invalid text.
enum LoggedWorkoutProblem {
  empty,
  missingDate,
  dateOutOfRange,
  missingReps,
  missingDuration,
  tooLarge,
}

/// Every problem that keeps [draft] from being built, in enum order; empty
/// when [buildLoggedWorkout] succeeds.
List<LoggedWorkoutProblem> validateLoggedWorkout(
  LoggedWorkoutDraft draft, {
  required DateTime now,
}) {
  final problems = <LoggedWorkoutProblem>{};
  final exercises = draft.exercises;
  if (exercises.isEmpty ||
      exercises.any((e) => e.name.trim().isEmpty || e.sets.isEmpty)) {
    problems.add(LoggedWorkoutProblem.empty);
  }
  final day = draft.performedOn;
  if (day == null) {
    problems.add(LoggedWorkoutProblem.missingDate);
  } else if (!_dayInRange(day, now)) {
    problems.add(LoggedWorkoutProblem.dateOutOfRange);
  }
  final minutes = draft.durationMinutes;
  if (exercises.length > TrainingLimits.exercisesMax ||
      !_validText(draft.title, TrainingLimits.titleMaxLength) ||
      !_validText(draft.note, TrainingLimits.notesMaxLength) ||
      (minutes != null &&
          (minutes < 1 || minutes > TrainingLogLimits.durationMinutesMax))) {
    problems.add(LoggedWorkoutProblem.tooLarge);
  }
  for (final exercise in exercises) {
    if (exercise.sets.length > TrainingLimits.setsMax ||
        !_validText(exercise.name, TrainingLimits.titleMaxLength) ||
        exercise.sets.any((set) => !_validWeight(set.weightKg))) {
      problems.add(LoggedWorkoutProblem.tooLarge);
    }
    final seconds = exercise.durationSeconds;
    if (!exercise.timed) {
      if (exercise.sets.any((set) => set.reps == null)) {
        problems.add(LoggedWorkoutProblem.missingReps);
      }
      if (exercise.sets.any(
        (set) =>
            set.reps != null &&
            (set.reps! < 0 || set.reps! > TrainingLogLimits.repsMax),
      )) {
        problems.add(LoggedWorkoutProblem.tooLarge);
      }
    } else if (seconds == null) {
      problems.add(LoggedWorkoutProblem.missingDuration);
    } else if (seconds < TrainingLimits.durationSecondsMin ||
        seconds > TrainingLogLimits.timedSecondsMax ||
        exercise.sets.length * _parts(seconds) > TrainingLimits.setsMax) {
      problems.add(LoggedWorkoutProblem.tooLarge);
    }
  }
  return [
    for (final problem in LoggedWorkoutProblem.values)
      if (problems.contains(problem)) problem,
  ];
}

/// Today finishes now; an earlier day finishes at the current local time of
/// day on that day (never after now). Without a duration, start == finish.
({DateTime startedAt, DateTime finishedAt}) loggedWorkoutTimes({
  required DateTime performedOn,
  int? durationMinutes,
  required DateTime now,
}) {
  final local = now.toLocal();
  var finished = daysBetween(local, performedOn) == 0
      ? local
      : DateTime(
          performedOn.year,
          performedOn.month,
          performedOn.day,
          local.hour,
          local.minute,
          local.second,
          local.millisecond,
          local.microsecond,
        );
  if (finished.isAfter(local)) finished = local;
  final finishedAt = finished.toUtc();
  return (
    startedAt: durationMinutes == null
        ? finishedAt
        : finishedAt.subtract(Duration(minutes: durationMinutes)),
    finishedAt: finishedAt,
  );
}

/// A free log as history: its own one-workout plan `log_<historyId>`, every
/// set completed at the finish time. Prescriptions only satisfy the plan
/// limits (reps = clamp(max actual, 1, 100), no rest); actuals stay as
/// logged. A timed set over an hour becomes k = ⌈d/3600⌉ equal parts of
/// ⌈d/k⌉ seconds with the set's weight. Throws [ArgumentError] unless
/// [validateLoggedWorkout] finds no problem.
TrainingHistoryEntry buildLoggedWorkout({
  required String historyId,
  required LoggedWorkoutDraft draft,
  required DateTime now,
  required String fallbackTitle,
}) {
  final problems = validateLoggedWorkout(draft, now: now);
  if (problems.isNotEmpty) {
    throw ArgumentError(
      'Invalid logged workout: ${problems.map((p) => p.name).join(', ')}',
    );
  }
  final times = loggedWorkoutTimes(
    performedOn: draft.performedOn!,
    durationMinutes: draft.durationMinutes,
    now: now,
  );
  final occurrences = <String, int>{};
  final exercises = <TrainingExercise>[];
  final actuals = <TrainingSetActual>[];
  void complete(int setIndex, {int? reps, double? weightKg}) => actuals.add(
    TrainingSetActual(
      reference: TrainingSetReference(
        exerciseIndex: exercises.length - 1,
        setIndex: setIndex,
      ),
      completedAt: times.finishedAt,
      reps: reps,
      weightKg: weightKg,
    ),
  );
  for (final logged in draft.exercises) {
    final occurrence = occurrences.update(
      normalizeExerciseName(logged.name),
      (count) => count + 1,
      ifAbsent: () => 1,
    );
    final id = trainingLogExerciseId(logged.name, occurrence);
    final name = logged.name.trim();
    final sets = logged.sets;
    if (logged.timed) {
      final seconds = logged.durationSeconds!;
      final parts = _parts(seconds);
      exercises.add(
        TrainingExercise(
          id: id,
          name: name,
          sets: sets.length * parts,
          durationSeconds: (seconds + parts - 1) ~/ parts,
          restSeconds: 0,
        ),
      );
      for (var s = 0; s < sets.length; s++) {
        for (var part = 0; part < parts; part++) {
          complete(s * parts + part, weightKg: sets[s].weightKg);
        }
      }
    } else {
      final most = sets.fold<int>(0, (top, set) => max(top, set.reps!));
      exercises.add(
        TrainingExercise(
          id: id,
          name: name,
          sets: sets.length,
          reps: most.clamp(1, TrainingLimits.repsMax),
          restSeconds: 0,
        ),
      );
      for (var s = 0; s < sets.length; s++) {
        complete(s, reps: sets[s].reps, weightKg: sets[s].weightKg);
      }
    }
  }
  final title = draft.title.trim().isEmpty ? fallbackTitle : draft.title.trim();
  final plan = TrainingPlan(
    id: '$trainingLogPlanPrefix$historyId',
    proposal: CoachTrainingProposal(
      title: title,
      workouts: [TrainingWorkout(title: title, exercises: exercises)],
    ),
  );
  return TrainingHistoryEntry(
    snapshot: _review(
      plan: plan,
      historyId: historyId,
      workoutIndex: 0,
      startedAt: times.startedAt,
      actuals: actuals,
      skipped: const [],
    ),
    finishedAt: times.finishedAt,
    note: draft.note.trim(),
  );
}

/// One set of a plan-attached log; [reps] is ignored for timed exercises.
final class PlanAttachedSet {
  const PlanAttachedSet({required this.done, this.reps, this.weightKg});

  final bool done;
  final int? reps;
  final double? weightKg;
}

/// A workout of a saved [plan] done without the player: the real plan,
/// exercise IDs and [workoutIndex]; undone sets are skipped. [sets] mirrors
/// the workout (one list per exercise, one entry per planned set). Throws
/// [ArgumentError] for a mismatched shape, no done set, a done repetition set
/// without reps, or a day or duration outside the log limits.
TrainingHistoryEntry buildPlanAttachedLog({
  required String historyId,
  required TrainingPlan plan,
  required int workoutIndex,
  required List<List<PlanAttachedSet>> sets,
  required DateTime performedOn,
  int? durationMinutes,
  String note = '',
  required DateTime now,
}) {
  if (workoutIndex < 0 || workoutIndex >= plan.workouts.length) {
    throw ArgumentError('Workout index out of range');
  }
  final exercises = plan.workouts[workoutIndex].exercises;
  var matches = sets.length == exercises.length;
  for (var e = 0; matches && e < exercises.length; e++) {
    matches = sets[e].length == exercises[e].sets;
  }
  if (!matches) throw ArgumentError('Sets do not match the workout');
  if (!sets.any((exercise) => exercise.any((set) => set.done))) {
    throw ArgumentError('A plan-attached log needs a done set');
  }
  if (!_dayInRange(performedOn, now) ||
      (durationMinutes != null &&
          (durationMinutes < 1 ||
              durationMinutes > TrainingLogLimits.durationMinutesMax))) {
    throw ArgumentError('Day or duration out of range');
  }
  final times = loggedWorkoutTimes(
    performedOn: performedOn,
    durationMinutes: durationMinutes,
    now: now,
  );
  final actuals = <TrainingSetActual>[];
  final skipped = <TrainingSetReference>[];
  for (var e = 0; e < exercises.length; e++) {
    final timed = exercises[e].isTimed;
    for (var s = 0; s < exercises[e].sets; s++) {
      final set = sets[e][s];
      final reference = TrainingSetReference(exerciseIndex: e, setIndex: s);
      if (!set.done) {
        skipped.add(reference);
        continue;
      }
      if (!timed && set.reps == null) {
        throw ArgumentError('A done repetition set needs reps');
      }
      actuals.add(
        TrainingSetActual(
          reference: reference,
          completedAt: times.finishedAt,
          reps: timed ? null : set.reps,
          weightKg: set.weightKg,
        ),
      );
    }
  }
  return TrainingHistoryEntry(
    snapshot: _review(
      plan: plan,
      historyId: historyId,
      workoutIndex: workoutIndex,
      startedAt: times.startedAt,
      actuals: actuals,
      skipped: skipped,
    ),
    finishedAt: times.finishedAt,
    note: note.trim(),
  );
}

/// The finished review state: cursor on the last set, nothing running.
TrainingSessionSnapshot _review({
  required TrainingPlan plan,
  required String historyId,
  required int workoutIndex,
  required DateTime startedAt,
  required List<TrainingSetActual> actuals,
  required List<TrainingSetReference> skipped,
}) {
  final exercises = plan.workouts[workoutIndex].exercises;
  return TrainingSessionSnapshot(
    plan: plan,
    sessionId: historyId,
    startedAt: startedAt,
    workoutIndex: workoutIndex,
    exerciseIndex: exercises.length - 1,
    setIndex: exercises.last.sets - 1,
    phase: TrainingSessionPhase.review,
    remainingMilliseconds: 0,
    completedSets: [for (final actual in actuals) actual.reference],
    skippedSets: skipped,
    actualSets: actuals,
  );
}

/// Parts a timed set is split into so each fits the plan's one-hour cap.
int _parts(int seconds) =>
    (seconds + TrainingLimits.durationSecondsMax - 1) ~/
    TrainingLimits.durationSecondsMax;

bool _dayInRange(DateTime day, DateTime now) {
  final back = daysBetween(now.toLocal(), day);
  return back >= 0 && back <= TrainingLogLimits.daysBack;
}

bool _validWeight(double? kg) =>
    kg == null ||
    (kg.isFinite && kg >= 0 && kg <= TrainingLogLimits.weightKgMax);

bool _validText(String value, int maximum) {
  try {
    TrainingJson.text(value.trim(), maximum);
    return true;
  } on FormatException {
    return false;
  }
}
