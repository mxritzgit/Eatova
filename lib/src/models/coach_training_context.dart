import 'dart:convert';

import 'coach_training_proposal.dart';
import 'training_limits.dart';

enum CoachTrainingIntent { create, adapt, discuss }

enum CoachTrainingExperience { beginner, intermediate, advanced }

enum CoachTrainingEquipment { bodyweight, dumbbells, gym }

/// An explicitly reviewed, per-request snapshot. No owner, IDs or history.
final class CoachTrainingContext {
  CoachTrainingContext({
    required this.intent,
    required String goal,
    required this.experience,
    required this.equipment,
    required int sessionsPerWeek,
    required int minutesPerSession,
    this.selectedPlan,
  }) : goal = TrainingJson.text(goal, 200, required: true),
       sessionsPerWeek = TrainingJson.integer(sessionsPerWeek, 1, 7),
       minutesPerSession = TrainingJson.integer(minutesPerSession, 10, 180) {
    if ((intent == CoachTrainingIntent.create) != (selectedPlan == null) ||
        _controlCharacters.hasMatch(goal) ||
        (selectedPlan != null &&
            _planText(selectedPlan!).any(_controlCharacters.hasMatch)) ||
        utf8.encode(jsonEncode(toJson())).length > maxBytes) {
      throw const FormatException('Invalid training context');
    }
  }

  static const maxBytes = 128 * 1024;
  static final _controlCharacters = RegExp(
    r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]',
  );

  final CoachTrainingIntent intent;
  final String goal;
  final CoachTrainingExperience experience;
  final CoachTrainingEquipment equipment;
  final int sessionsPerWeek;
  final int minutesPerSession;
  final CoachTrainingProposal? selectedPlan;

  factory CoachTrainingContext.fromJson(Map<dynamic, dynamic> json) {
    TrainingJson.requireKeys(json, const {
      'schema_version',
      'intent',
      'goal',
      'experience',
      'equipment',
      'sessions_per_week',
      'minutes_per_session',
      'selected_plan',
    });
    TrainingJson.integer(json['schema_version'], 1, 1);
    final rawPlan = json['selected_plan'];
    final plan = rawPlan is Map
        ? CoachTrainingProposal.fromJson(rawPlan)
        : null;
    if (rawPlan != null && plan == null) {
      throw const FormatException('Invalid selected training plan');
    }
    return CoachTrainingContext(
      intent: _enumValue(CoachTrainingIntent.values, json['intent']),
      goal: TrainingJson.text(json['goal'], 200, required: true),
      experience: _enumValue(
        CoachTrainingExperience.values,
        json['experience'],
      ),
      equipment: _enumValue(CoachTrainingEquipment.values, json['equipment']),
      sessionsPerWeek: TrainingJson.integer(json['sessions_per_week'], 1, 7),
      minutesPerSession: TrainingJson.integer(
        json['minutes_per_session'],
        10,
        180,
      ),
      selectedPlan: plan,
    );
  }

  static T _enumValue<T extends Enum>(List<T> values, Object? value) {
    for (final item in values) {
      if (item.name == value) return item;
    }
    throw const FormatException('Invalid training choice');
  }

  static Iterable<String> _planText(CoachTrainingProposal plan) sync* {
    yield plan.title;
    yield plan.description;
    yield plan.goal;
    for (final workout in plan.workouts) {
      yield workout.title;
      yield workout.description;
      for (final exercise in workout.exercises) {
        yield exercise.name;
        yield exercise.notes;
      }
    }
  }

  Map<String, dynamic> toJson() => {
    'schema_version': 1,
    'intent': intent.name,
    'goal': goal,
    'experience': experience.name,
    'equipment': equipment.name,
    'sessions_per_week': sessionsPerWeek,
    'minutes_per_session': minutesPerSession,
    'selected_plan': selectedPlan?.toJson(),
  };
}
