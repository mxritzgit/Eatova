import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'coach_training_proposal.dart';
import 'training_limits.dart';
import 'training_workout.dart';

export 'training_limits.dart' show TrainingLimits;
export 'training_workout.dart';

/// An adopted or manually created plan. Ownership is set only by the store.
final class TrainingPlan {
  TrainingPlan({
    required String id,
    required CoachTrainingProposal proposal,
    String? sourceId,
    int incarnation = 0,
  }) : id = TrainingJson.id(id),
       sourceId = _sourceId(id, sourceId),
       incarnation = _planIncarnation(id, incarnation),
       proposal = _identify(id, proposal);

  static String? _sourceId(String id, String? sourceId) {
    if (sourceId == null) return null;
    if (id != trainingPlanIdForMessage(sourceId)) {
      throw const FormatException('Mismatched training plan source');
    }
    return sourceId;
  }

  static int _incarnation(Object? value) {
    if (value is! int || value < 0 || value > 0x7fffffff) {
      throw const FormatException('Invalid training plan incarnation');
    }
    return value;
  }

  static int _planIncarnation(String id, int value) {
    final incarnation = _incarnation(value);
    if (incarnation != 0 && (!id.startsWith('coach_') || id.length <= 6)) {
      throw const FormatException('Manual training plan has an incarnation');
    }
    return incarnation;
  }

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

  /// Original Coach message, independent from this adopted incarnation.
  final String? sourceId;

  /// A fresh explicit adoption advances the source generation after deletion.
  final int incarnation;

  /// Older installations encoded the message identity in the plan ID.
  String? get coachSourceId =>
      sourceId ??
      (id.startsWith('coach_') && id.length > 6 ? id.substring(6) : null);

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
      if (json.containsKey('source_id')) 'source_id',
      if (json.containsKey('incarnation')) 'incarnation',
    });
    return TrainingPlan.fromRow(json);
  }

  factory TrainingPlan.fromRow(Map<dynamic, dynamic> row) {
    final id = TrainingJson.id(row['id']);
    final sourceId = row['source_id'] == null
        ? null
        : TrainingJson.id(row['source_id']);
    final incarnation = row.containsKey('incarnation')
        ? _incarnation(row['incarnation'])
        : 0;
    final rawPlan = row['plan'];
    if (rawPlan is! Map) {
      throw const FormatException('Invalid training plan');
    }
    final proposal = CoachTrainingProposal.fromJson(rawPlan);
    if (proposal == null) {
      throw const FormatException('Invalid training plan');
    }
    final rawIds = row['exercise_ids'];
    if (rawIds == null) {
      return TrainingPlan(
        id: id,
        proposal: proposal,
        sourceId: sourceId,
        incarnation: incarnation,
      );
    }
    if (rawIds is! List || rawIds.length != proposal.workouts.length) {
      throw const FormatException('Invalid exercise identities');
    }
    return TrainingPlan(
      id: id,
      sourceId: sourceId,
      incarnation: incarnation,
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
    if (sourceId != null) 'source_id': sourceId,
    if (incarnation != 0) 'incarnation': incarnation,
    'plan': proposal.toJson(),
    'exercise_ids': [
      for (final workout in workouts)
        [for (final exercise in workout.exercises) exercise.id],
    ],
  };

  Map<String, dynamic> toRow() => toJson();

  TrainingPlan copyWith({CoachTrainingProposal? proposal, int? incarnation}) =>
      TrainingPlan(
        id: id,
        proposal: proposal ?? this.proposal,
        sourceId: sourceId,
        incarnation: incarnation ?? this.incarnation,
      );
}

/// Legacy Coach identity retained for existing plans and migration.
String trainingPlanIdForMessage(String messageId) =>
    TrainingJson.id('coach_${TrainingJson.id(messageId)}');
