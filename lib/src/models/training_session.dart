import 'training_limits.dart';
import 'training_plan.dart';

enum TrainingSessionPhase { exercise, rest, review }

/// A set's identity within the immutable selected workout.
final class TrainingSetReference {
  const TrainingSetReference({
    required this.exerciseIndex,
    required this.setIndex,
  });

  final int exerciseIndex;
  final int setIndex;

  Map<String, dynamic> toJson() => {
    'exercise_index': exerciseIndex,
    'set_index': setIndex,
  };

  @override
  bool operator ==(Object other) =>
      other is TrainingSetReference &&
      other.exerciseIndex == exerciseIndex &&
      other.setIndex == setIndex;

  @override
  int get hashCode => Object.hash(exerciseIndex, setIndex);
}

/// A recovery checkpoint is always paused, with no wall-clock deadline.
final class TrainingSessionSnapshot {
  TrainingSessionSnapshot({
    required this.plan,
    required this.workoutIndex,
    required this.exerciseIndex,
    required this.setIndex,
    required this.phase,
    required this.remainingMilliseconds,
    List<TrainingSetReference> completedSets = const [],
    List<TrainingSetReference> skippedSets = const [],
  }) : completedSets = List.unmodifiable(completedSets),
       skippedSets = List.unmodifiable(skippedSets) {
    TrainingJson.integer(workoutIndex, 0, plan.workouts.length - 1);
    TrainingJson.integer(exerciseIndex, 0, workout.exercises.length - 1);
    TrainingJson.integer(setIndex, 0, exercise.sets - 1);
    final maximum = switch (phase) {
      TrainingSessionPhase.exercise => (exercise.durationSeconds ?? 0) * 1000,
      TrainingSessionPhase.rest => exercise.restSeconds * 1000,
      TrainingSessionPhase.review => 0,
    };
    TrainingJson.integer(remainingMilliseconds, 0, maximum);
    final seen = <TrainingSetReference>{};
    for (final entry in [...completedSets, ...skippedSets]) {
      TrainingJson.integer(
        entry.exerciseIndex,
        0,
        workout.exercises.length - 1,
      );
      TrainingJson.integer(
        entry.setIndex,
        0,
        workout.exercises[entry.exerciseIndex].sets - 1,
      );
      if (!seen.add(entry) ||
          entry.exerciseIndex > exerciseIndex ||
          (entry.exerciseIndex == exerciseIndex && entry.setIndex > setIndex)) {
        throw const FormatException('Invalid training session progress');
      }
    }
    final current = TrainingSetReference(
      exerciseIndex: exerciseIndex,
      setIndex: setIndex,
    );
    final pastSets =
        workout.exercises
            .take(exerciseIndex)
            .fold<int>(0, (count, item) => count + item.sets) +
        setIndex;
    if (seen.length !=
        pastSets + (phase == TrainingSessionPhase.exercise ? 0 : 1)) {
      throw const FormatException('Invalid training session progress');
    }
    if (phase == TrainingSessionPhase.exercise && seen.contains(current)) {
      throw const FormatException('Invalid training session progress');
    }
    if (phase == TrainingSessionPhase.rest &&
        (setIndex == exercise.sets - 1 ||
            exercise.restSeconds == 0 ||
            !completedSets.contains(current))) {
      throw const FormatException('Invalid training session rest');
    }
    if (phase == TrainingSessionPhase.review &&
        (exerciseIndex != workout.exercises.length - 1 ||
            setIndex != exercise.sets - 1 ||
            seen.length != workout.totalSets)) {
      throw const FormatException('Invalid training session review');
    }
  }

  final TrainingPlan plan;
  final int workoutIndex;
  final int exerciseIndex;
  final int setIndex;
  final TrainingSessionPhase phase;
  final int remainingMilliseconds;
  final List<TrainingSetReference> completedSets;
  final List<TrainingSetReference> skippedSets;

  TrainingWorkout get workout => plan.workouts[workoutIndex];
  TrainingExercise get exercise => workout.exercises[exerciseIndex];
  int get totalSets => workout.totalSets;

  factory TrainingSessionSnapshot.fromJson(Map<dynamic, dynamic> json) {
    TrainingJson.requireKeys(json, const {
      'schema_version',
      'status',
      'plan',
      'workout_index',
      'exercise_index',
      'set_index',
      'phase',
      'remaining_milliseconds',
      'completed_sets',
      'skipped_sets',
    });
    TrainingJson.integer(json['schema_version'], 1, 1);
    final rawPlan = json['plan'];
    if (json['status'] != 'paused' || rawPlan is! Map) {
      throw const FormatException('Invalid training session');
    }
    final phase = switch (json['phase']) {
      'exercise' => TrainingSessionPhase.exercise,
      'rest' => TrainingSessionPhase.rest,
      'review' => TrainingSessionPhase.review,
      _ => throw const FormatException('Invalid training session phase'),
    };
    List<TrainingSetReference> ledger(Object? raw) {
      if (raw is! List ||
          raw.length > TrainingLimits.exercisesMax * TrainingLimits.setsMax) {
        throw const FormatException('Invalid training session progress');
      }
      return raw.map((entry) {
        if (entry is! Map) {
          throw const FormatException('Invalid training session set');
        }
        TrainingJson.requireKeys(entry, const {'exercise_index', 'set_index'});
        return TrainingSetReference(
          exerciseIndex: TrainingJson.integer(
            entry['exercise_index'],
            0,
            TrainingLimits.exercisesMax - 1,
          ),
          setIndex: TrainingJson.integer(
            entry['set_index'],
            0,
            TrainingLimits.setsMax - 1,
          ),
        );
      }).toList();
    }

    return TrainingSessionSnapshot(
      plan: TrainingPlan.fromJson(rawPlan),
      workoutIndex: TrainingJson.integer(
        json['workout_index'],
        0,
        TrainingLimits.workoutsMax - 1,
      ),
      exerciseIndex: TrainingJson.integer(
        json['exercise_index'],
        0,
        TrainingLimits.exercisesMax - 1,
      ),
      setIndex: TrainingJson.integer(
        json['set_index'],
        0,
        TrainingLimits.setsMax - 1,
      ),
      phase: phase,
      remainingMilliseconds: TrainingJson.integer(
        json['remaining_milliseconds'],
        0,
        TrainingLimits.durationSecondsMax * 1000,
      ),
      completedSets: ledger(json['completed_sets']),
      skippedSets: ledger(json['skipped_sets']),
    );
  }

  Map<String, dynamic> toJson() => {
    'schema_version': 1,
    'status': 'paused',
    'plan': plan.toJson(),
    'workout_index': workoutIndex,
    'exercise_index': exerciseIndex,
    'set_index': setIndex,
    'phase': phase.name,
    'remaining_milliseconds': remainingMilliseconds,
    'completed_sets': completedSets.map((entry) => entry.toJson()).toList(),
    'skipped_sets': skippedSets.map((entry) => entry.toJson()).toList(),
  };
}
