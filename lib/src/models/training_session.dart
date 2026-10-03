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

DateTime trainingTimestamp(Object? value, {bool allowOffset = false}) {
  if (value is! String ||
      !(value.endsWith('Z') ||
          (allowOffset && RegExp(r'[+-][0-9]{2}:[0-9]{2}$').hasMatch(value)))) {
    throw const FormatException('Invalid training timestamp');
  }
  final date = DateTime.tryParse(value);
  if (date == null || date.year < 2000 || date.year > 2200) {
    throw const FormatException('Invalid training timestamp');
  }
  return date.toUtc();
}

/// A recovery checkpoint's status is always paused; a running rest or timed
/// interval is recorded only as its wall-clock deadline ([phaseEndsAt]).
final class TrainingSessionSnapshot {
  TrainingSessionSnapshot({
    required this.plan,
    String? sessionId,
    DateTime? startedAt,
    List<TrainingSetActual> actualSets = const [],
    this.draftReps,
    this.draftWeightKg,
    this.pendingCompletionAt,
    this.pendingCompletionNote,
    this.recoveryNote,
    DateTime? phaseEndsAt,
    required this.workoutIndex,
    required this.exerciseIndex,
    required this.setIndex,
    required this.phase,
    required this.remainingMilliseconds,
    List<TrainingSetReference> completedSets = const [],
    List<TrainingSetReference> skippedSets = const [],
  }) : sessionId = sessionId ?? uuidV4(),
       startedAt = (startedAt ?? clock.now()).toUtc(),
       phaseEndsAt = phaseEndsAt?.toUtc(),
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
    if (recoveryNote != null) {
      TrainingJson.text(recoveryNote, TrainingLimits.notesMaxLength);
    }
    if ((pendingCompletionAt == null) != (pendingCompletionNote == null)) {
      throw const FormatException('Invalid pending completion');
    }
    if (pendingCompletionAt != null) {
      trainingTimestamp(pendingCompletionAt!.toUtc().toIso8601String());
      TrainingJson.text(pendingCompletionNote, TrainingLimits.notesMaxLength);
      if (phase != TrainingSessionPhase.review ||
          actualSets.length != completedSets.length ||
          pendingCompletionAt!.isBefore(this.startedAt) ||
          actualSets.any((a) => a.completedAt.isAfter(pendingCompletionAt!))) {
        throw const FormatException('Invalid pending completion');
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
    if (this.phaseEndsAt != null) {
      trainingTimestamp(this.phaseEndsAt!.toIso8601String());
      final running =
          phase == TrainingSessionPhase.rest ||
          (phase == TrainingSessionPhase.exercise && exercise.isTimed);
      if (!running || pendingCompletionAt != null) {
        throw const FormatException('Invalid training phase deadline');
      }
    }
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
    // Rest follows any completed set except the workout's final set.
    if (phase == TrainingSessionPhase.rest &&
        ((exerciseIndex == workout.exercises.length - 1 &&
                setIndex == exercise.sets - 1) ||
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

  /// Local-only receipt recovery; excluded from the immutable server snapshot.
  final String? recoveryNote;

  /// Local-only UTC deadline of a running rest or timed interval; presence
  /// means running. Never in review, with a pending completion or in history.
  final DateTime? phaseEndsAt;
  final DateTime? pendingCompletionAt;
  final String? pendingCompletionNote;
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

  /// Decodes a v2 checkpoint. A v1 checkpoint recorded no start time and is
  /// rejected until [upgradeLegacyJson] pins one; a start taken from the clock
  /// on every read would never match the stored checkpoint again.
  factory TrainingSessionSnapshot.fromJson(Map<dynamic, dynamic> json) =>
      TrainingSessionSnapshot._decode(json, null);

  /// Whether [json] is a v1 checkpoint, written only by builds from #70.
  static bool isLegacyJson(Map<dynamic, dynamic> json) =>
      json['schema_version'] == 1;

  /// The v2 form of a v1 checkpoint, with its unknown start pinned to
  /// [observedAt] (default: now), or to a recorded earlier pending completion;
  /// null for any other version. Persist the result once: its digest ID and
  /// ledger are stable, the pinned start is not.
  static Map<String, dynamic>? upgradeLegacyJson(
    Map<dynamic, dynamic> json, {
    DateTime? observedAt,
  }) {
    if (!isLegacyJson(json)) return null;
    final observed = (observedAt ?? clock.now()).toUtc();
    final completion = json.containsKey('pending_completion_at')
        ? trainingTimestamp(json['pending_completion_at'])
        : null;
    return TrainingSessionSnapshot._decode(
      json,
      completion != null && completion.isBefore(observed)
          ? completion
          : observed,
    ).toJson();
  }

  factory TrainingSessionSnapshot._decode(
    Map<dynamic, dynamic> json,
    DateTime? legacyStartedAt,
  ) {
    final version = TrainingJson.integer(json['schema_version'], 1, 2);
    if (version == 1 && legacyStartedAt == null) {
      throw const FormatException('Unpinned legacy training session');
    }
    final pending =
        json.containsKey('pending_completion_at') ||
        json.containsKey('pending_completion_note');
    TrainingJson.requireKeys(json, {
      if (json.containsKey('recovery_note')) 'recovery_note',
      if (pending) ...['pending_completion_at', 'pending_completion_note'],
      if (version == 2 && json.containsKey('phase_ends_at')) 'phase_ends_at',
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
    final rawActuals = version == 2 ? json['actual_sets'] : const <dynamic>[];
    if (rawActuals is! List || rawActuals.length > 200) {
      throw const FormatException('Invalid training actuals');
    }
    return TrainingSessionSnapshot(
      recoveryNote: json.containsKey('recovery_note')
          ? TrainingJson.text(
              json['recovery_note'],
              TrainingLimits.notesMaxLength,
            )
          : null,
      phaseEndsAt: json.containsKey('phase_ends_at')
          ? trainingTimestamp(json['phase_ends_at'])
          : null,
      pendingCompletionAt: pending
          ? trainingTimestamp(json['pending_completion_at'])
          : null,
      pendingCompletionNote: pending
          ? TrainingJson.text(
              json['pending_completion_note'],
              TrainingLimits.notesMaxLength,
            )
          : null,
      draftReps: version == 2 && json['draft_reps'] != null
          ? TrainingJson.integer(json['draft_reps'], 0, 1000)
          : null,
      draftWeightKg: version == 2
          ? (json['draft_weight_kg'] as num?)?.toDouble()
          : null,
      sessionId: version == 2 ? json['session_id'] as String : legacyId,
      startedAt: version == 2
          ? trainingTimestamp(json['started_at'])
          : legacyStartedAt,
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
    if (recoveryNote != null) 'recovery_note': recoveryNote,
    if (pendingCompletionAt != null) ...{
      'pending_completion_at': pendingCompletionAt!.toUtc().toIso8601String(),
      'pending_completion_note': pendingCompletionNote,
    },
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
    if (phaseEndsAt != null) 'phase_ends_at': phaseEndsAt!.toIso8601String(),
    'completed_sets': completedSets.map((entry) => entry.toJson()).toList(),
    'skipped_sets': skippedSets.map((entry) => entry.toJson()).toList(),
  };
}
