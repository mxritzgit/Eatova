import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'coach_training_proposal.dart';
import 'training_limits.dart';
import 'training_workout.dart';

export 'training_limits.dart' show TrainingLimits;
export 'training_workout.dart';

/// An adopted or manually created plan. Ownership is set only by the store.
final class TrainingPlan {
  TrainingPlan({required String id, required CoachTrainingProposal proposal})
    : id = TrainingJson.id(id),
      proposal = _identify(id, proposal);

  static CoachTrainingProposal _identify(
    String id,
    CoachTrainingProposal value,
  ) {
    final seen = <String>{};
    return value.copyWith(
      workouts: [
        for (var w = 0; w < value.workouts.length; w++)
          value.workouts[w].copyWith(
            exercises: [
              for (var e = 0; e < value.workouts[w].exercises.length; e++)
                value.workouts[w].exercises[e].copyWith(
                  id: (() {
                    final original = value.workouts[w].exercises[e].id;
                    final identity =
                        original ??
                        'legacy_${sha256.convert(utf8.encode('$id:$w:$e'))}';
                    TrainingJson.id(identity);
                    if (!seen.add(identity)) {
                      throw const FormatException(
                        'Duplicate exercise identity',
                      );
                    }
                    return identity;
                  })(),
                ),
            ],
          ),
      ],
    );
  }

  final String id;
  final CoachTrainingProposal proposal;

  String get title => proposal.title;
  String get description => proposal.description;
  String get goal => proposal.goal;
  List<TrainingWorkout> get workouts => proposal.workouts;
  int get estimatedDurationSeconds => proposal.estimatedDurationSeconds;

  /// Local cache and outbox envelopes carry no client-supplied owner.
  factory TrainingPlan.fromJson(Map<dynamic, dynamic> json) {
    TrainingJson.requireKeys(json, {
      'id',
      'plan',
      if (json.containsKey('exercise_ids')) 'exercise_ids',
    });
    return TrainingPlan.fromRow(json);
  }

  factory TrainingPlan.fromRow(Map<dynamic, dynamic> row) {
    final id = TrainingJson.id(row['id']);
    final rawPlan = row['plan'];
    if (rawPlan is! Map) {
      throw const FormatException('Invalid training plan');
    }
    final proposal = CoachTrainingProposal.fromJson(rawPlan);
    if (proposal == null) {
      throw const FormatException('Invalid training plan');
    }
    final rawIds = row['exercise_ids'];
    if (rawIds == null) return proposal.toTrainingPlan(id: id);
    if (rawIds is! List || rawIds.length != proposal.workouts.length) {
      throw const FormatException('Invalid exercise identities');
    }
    return TrainingPlan(
      id: id,
      proposal: proposal.copyWith(
        workouts: [
          for (var w = 0; w < proposal.workouts.length; w++)
            proposal.workouts[w].copyWith(
              exercises: (() {
                final ids = rawIds[w];
                final exercises = proposal.workouts[w].exercises;
                if (ids is! List || ids.length != exercises.length) {
                  throw const FormatException('Invalid exercise identities');
                }
                return [
                  for (var e = 0; e < exercises.length; e++)
                    exercises[e].copyWith(id: TrainingJson.id(ids[e])),
                ];
              })(),
            ),
        ],
      ),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'plan': proposal.toJson(),
    'exercise_ids': [
      for (final workout in workouts)
        [for (final exercise in workout.exercises) exercise.id],
    ],
  };

  Map<String, dynamic> toRow() => toJson();

  TrainingPlan copyWith({CoachTrainingProposal? proposal}) =>
      TrainingPlan(id: id, proposal: proposal ?? this.proposal);
}

/// Idempotent adoption across double taps, app restarts, and sync retries.
String trainingPlanIdForMessage(String messageId) =>
    TrainingJson.id('coach_${TrainingJson.id(messageId)}');
