import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:crypto/crypto.dart';

import '../services/uuid.dart';
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

/// Actual values belong to one completed set, never to the prescription.
final class TrainingSetActual {
  TrainingSetActual({
    required this.reference,
    required this.completedAt,
    this.reps,
    this.weightKg,
  }) {
    if (reps != null) TrainingJson.integer(reps, 0, 1000);
    if (weightKg != null &&
        (!weightKg!.isFinite || weightKg! < 0 || weightKg! > 2000)) {
      throw const FormatException('Invalid training weight');
    }
  }
  final TrainingSetReference reference;
  final int? reps;
  final double? weightKg;
  final DateTime completedAt;
  Map<String, dynamic> toJson() => {
    ...reference.toJson(),
    'reps': reps,
    'weight_kg': weightKg,
    'completed_at': completedAt.toUtc().toIso8601String(),
  };
  factory TrainingSetActual.fromJson(Map<dynamic, dynamic> json) {
    TrainingJson.requireKeys(json, const {
      'exercise_index',
      'set_index',
      'reps',
      'weight_kg',
      'completed_at',
    });
    final weight = json['weight_kg'];
    if (weight != null && weight is! num) {
      throw const FormatException('Invalid training weight');
    }
    return TrainingSetActual(
      reference: TrainingSetReference(
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
      ),
      reps: json['reps'] == null
          ? null
          : TrainingJson.integer(json['reps'], 0, 1000),
      weightKg: (weight as num?)?.toDouble(),
      completedAt: trainingTimestamp(json['completed_at']),
    );
  }
}

DateTime trainingTimestamp(Object? value) {
  if (value is! String || !value.endsWith('Z')) {
    throw const FormatException('Invalid training timestamp');
  }
  final date = DateTime.tryParse(value);
  if (date == null || date.year < 2000 || date.year > 2200) {
    throw const FormatException('Invalid training timestamp');
  }
  return date.toUtc();
}

/// A recovery checkpoint is always paused, with no wall-clock deadline.
final class TrainingSessionSnapshot {
  TrainingSessionSnapshot({
    required this.plan,
    String? sessionId,
    DateTime? startedAt,
    List<TrainingSetActual> actualSets = const [],
    this.draftReps,
    this.draftWeightKg,
    required this.workoutIndex,
    required this.exerciseIndex,
    required this.setIndex,
    required this.phase,
    required this.remainingMilliseconds,
    List<TrainingSetReference> completedSets = const [],
    List<TrainingSetReference> skippedSets = const [],
  }) : sessionId = sessionId ?? uuidV4(),
       startedAt = (startedAt ?? clock.now()).toUtc(),
       actualSets = List.unmodifiable(actualSets),
       completedSets = List.unmodifiable(completedSets),
       skippedSets = List.unmodifiable(skippedSets) {
    if (draftReps != null) TrainingJson.integer(draftReps, 0, 1000);
    if (draftWeightKg != null &&
        (!draftWeightKg!.isFinite ||
            draftWeightKg! < 0 ||
            draftWeightKg! > 2000)) {
      throw const FormatException('Invalid training weight');
    }
    if (!isUuidShape(this.sessionId)) {
      throw const FormatException('Invalid training session ID');
    }
    trainingTimestamp(this.startedAt.toIso8601String());
    final actualReferences = <TrainingSetReference>{};
    for (final actual in actualSets) {
      if (!completedSets.contains(actual.reference) ||
          !actualReferences.add(actual.reference) ||
          actual.completedAt.isBefore(this.startedAt)) {
        throw const FormatException('Invalid training actual values');
      }
    }
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

  final int? draftReps;
  final double? draftWeightKg;
  final String sessionId;
  final DateTime startedAt;
  final List<TrainingSetActual> actualSets;
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
    final version = TrainingJson.integer(json['schema_version'], 1, 2);
    TrainingJson.requireKeys(json, {
      if (version == 2) ...[
        'session_id',
        'started_at',
        'actual_sets',
        'draft_reps',
        'draft_weight_kg',
      ],
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

    if (version == 2 &&
        (json['session_id'] is! String ||
            (json['draft_weight_kg'] != null &&
                json['draft_weight_kg'] is! num))) {
      throw const FormatException('Invalid training session');
    }
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

    // Legacy recovery has no actual values. Preserve its ledger honestly; the
    // completion review asks for missing repetition values before saving.
    final digest = version == 1
        ? sha256
              .convert(utf8.encode(jsonEncode(json)))
              .toString()
              .substring(0, 32)
        : '00000000000000000000000000000000';
    final legacyId =
        '${digest.substring(0, 8)}-${digest.substring(8, 12)}-${digest.substring(12, 16)}-${digest.substring(16, 20)}-${digest.substring(20)}';
    final rawActuals = version == 2 ? json['actual_sets'] : const [];
    if (rawActuals is! List || rawActuals.length > 200) {
      throw const FormatException('Invalid training actuals');
    }
    return TrainingSessionSnapshot(
      draftReps: version == 2 && json['draft_reps'] != null
          ? TrainingJson.integer(json['draft_reps'], 0, 1000)
          : null,
      draftWeightKg: version == 2
          ? (json['draft_weight_kg'] as num?)?.toDouble()
          : null,
      sessionId: version == 2 ? json['session_id'] as String : legacyId,
      startedAt: version == 2
          ? trainingTimestamp(json['started_at'])
          : clock.now().toUtc(),
      actualSets: rawActuals.map((raw) {
        if (raw is! Map) throw const FormatException('Invalid training actual');
        return TrainingSetActual.fromJson(raw);
      }).toList(),
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
    'schema_version': 2,
    'draft_reps': draftReps,
    'draft_weight_kg': draftWeightKg,
    'session_id': sessionId,
    'started_at': startedAt.toUtc().toIso8601String(),
    'actual_sets': actualSets.map((entry) => entry.toJson()).toList(),
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
