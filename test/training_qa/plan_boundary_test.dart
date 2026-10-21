import 'dart:convert';

import 'package:eatova/src/models/coach_training_proposal.dart';
import 'package:eatova/src/models/training_plan.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures.dart';

// Field, range, Unicode and aggregate validation of a Coach proposal lives in
// test/models/training_plan_test.dart; history roles and refusals in
// test/services/coach_training_plan_service_test.dart.

void main() {
  test('valid draft survives serialization without repairing user text', () {
    final raw = trainingDraft();
    raw['title'] = '  A 🏋️ plan\n';
    firstExercise(raw)['sets'] = 2.0;
    final draft = CoachTrainingProposal.fromJson(raw)!;
    expect(draft.title, raw['title']);
    expect(draft.workouts.single.exercises.first.sets, 2);
    final plan = draft.toTrainingPlan(
      id: trainingPlanIdForMessage('message-1'),
    );
    expect(
      TrainingPlan.fromJson(
        jsonDecode(jsonEncode(plan.toJson())) as Map<dynamic, dynamic>,
      ).toJson(),
      plan.toJson(),
    );
    expect(plan.toRow().keys, unorderedEquals(['id', 'plan', 'exercise_ids']));
  });

  test('mutable input and serialized output cannot alter an adopted plan', () {
    final raw = trainingDraft();
    final draft = CoachTrainingProposal.fromJson(raw)!;
    final plan = draft.toTrainingPlan(id: 'manual-1');
    firstExercise(raw)['name'] = 'Changed raw input';
    final encoded = plan.toJson();
    firstExercise(encoded['plan'] as Map<String, dynamic>)['name'] =
        'Changed output';
    expect(plan.workouts.single.exercises.first.name, 'Chair squat');
    expect(() => plan.workouts.clear(), throwsUnsupportedError);
    expect(
      () => plan.workouts.single.exercises.clear(),
      throwsUnsupportedError,
    );
  });
}
