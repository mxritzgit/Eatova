import 'dart:convert';

import 'package:eatova/src/models/chat_message.dart';
import 'package:eatova/src/models/coach_training_proposal.dart';
import 'package:eatova/src/models/training_plan.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures.dart';

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
      TrainingPlan.fromJson(jsonDecode(jsonEncode(plan.toJson()))).toJson(),
      plan.toJson(),
    );
    expect(plan.toRow().keys, unorderedEquals(['id', 'plan']));
  });

  for (final level in ['plan', 'workout', 'exercise']) {
    test('reject missing and injected fields on $level', () {
      Map<String, dynamic> target(Map<String, dynamic> raw) => switch (level) {
        'workout' => firstWorkout(raw),
        'exercise' => firstExercise(raw),
        _ => raw,
      };
      for (final key in target(trainingDraft()).keys.toList()) {
        final raw = trainingDraft();
        target(raw).remove(key);
        expect(
          CoachTrainingProposal.fromJson(raw),
          isNull,
          reason: '$level.$key absent',
        );
      }
      for (final key in ['id', 'user_id', 'created_at', '__proto__']) {
        final raw = trainingDraft();
        target(raw)[key] = 'attacker';
        expect(
          CoachTrainingProposal.fromJson(raw),
          isNull,
          reason: '$level.$key added',
        );
      }
    });
  }

  test('numeric prescriptions reject unsafe types and out-of-range values', () {
    final invalid = <String, List<Object?>>{
      'sets': [null, true, '2', 0, 11, 1.5, double.nan, double.infinity],
      'reps': [true, '8', 0, 101, 1.5, double.negativeInfinity],
      'rest_seconds': [null, false, '30', -1, 601, 1.5, double.nan],
    };
    for (final field in invalid.entries) {
      for (final value in field.value) {
        final raw = trainingDraft();
        firstExercise(raw)[field.key] = value;
        expect(
          CoachTrainingProposal.fromJson(raw),
          isNull,
          reason: '${field.key}=$value',
        );
      }
    }
    for (final duration in [4, 3601, 5.5, '30', false]) {
      final raw = trainingDraft();
      firstExercise(raw)
        ..['reps'] = null
        ..['duration_seconds'] = duration;
      expect(
        CoachTrainingProposal.fromJson(raw),
        isNull,
        reason: 'duration=$duration',
      );
    }
    for (final pair in [(null, null), (8, 30)]) {
      final raw = trainingDraft();
      firstExercise(raw)
        ..['reps'] = pair.$1
        ..['duration_seconds'] = pair.$2;
      expect(CoachTrainingProposal.fromJson(raw), isNull);
    }
  });

  test('Unicode boundary is codepoints and forbidden controls fail closed', () {
    final raw = trainingDraft()..['title'] = '🏋' * 120;
    expect(CoachTrainingProposal.fromJson(raw)?.title, raw['title']);
    raw['title'] = '🏋' * 121;
    expect(CoachTrainingProposal.fromJson(raw), isNull);
    for (var code = 0; code < 32; code++) {
      raw['title'] = 'A${String.fromCharCode(code)}B';
      expect(
        CoachTrainingProposal.fromJson(raw) != null,
        [9, 10, 13].contains(code),
        reason: 'control $code',
      );
    }
    for (final text in ['\u0085', '\uFEFF', '\u2000', ' \t\n']) {
      raw['title'] = text;
      expect(CoachTrainingProposal.fromJson(raw), isNull);
    }
  });

  test(
    'aggregate limit counts every nested string and preserves the boundary',
    () {
      final raw = trainingDraft()
        ..['title'] = 'P'
        ..['description'] = ''
        ..['goal'] = '';
      final workout = firstWorkout(raw)
        ..['title'] = 'W'
        ..['description'] = '';
      workout['exercises'] = List.generate(
        20,
        (_) => {
          ...firstExercise(trainingDraft()),
          'name': 'N' * 99,
          'notes': 'x' * 500,
        },
      );
      // 1 plan + 1 workout + 20 * (99 + 500) + 18 = 12000 codepoints.
      raw['description'] = '🏋' * 18;
      expect(CoachTrainingProposal.fromJson(raw), isNotNull);
      raw['description'] = '🏋' * 19;
      expect(CoachTrainingProposal.fromJson(raw), isNull);
    },
  );

  test('mutable input and serialized output cannot alter an adopted plan', () {
    final raw = trainingDraft();
    final draft = CoachTrainingProposal.fromJson(raw)!;
    final plan = draft.toTrainingPlan(id: 'manual-1');
    firstExercise(raw)['name'] = 'Changed raw input';
    final encoded = plan.toJson();
    firstExercise(encoded['plan'])['name'] = 'Changed output';
    expect(plan.workouts.single.exercises.first.name, 'Chair squat');
    expect(() => plan.workouts.clear(), throwsUnsupportedError);
    expect(
      () => plan.workouts.single.exercises.clear(),
      throwsUnsupportedError,
    );
  });

  for (final role in ['user', 'system', 'tool', '', null]) {
    test('history role $role cannot expose an adoptable proposal', () {
      expect(
        ChatMessage.fromRow(trainingMessage(role: role)).trainingPlanProposal,
        isNull,
      );
    });
  }
  test('history with absent role cannot expose an adoptable proposal', () {
    final row = trainingMessage()..remove('role');
    expect(ChatMessage.fromRow(row).trainingPlanProposal, isNull);
  });
  test(
    'valid assistant history survives; refusal and conflicting proposal do not',
    () {
      expect(
        ChatMessage.fromRow(trainingMessage()).trainingPlanProposal,
        isNotNull,
      );
      expect(
        ChatMessage.fromRow(
          trainingMessage()..['refusal'] = true,
        ).trainingPlanProposal,
        isNull,
      );
      expect(
        ChatMessage.fromRow(
          trainingMessage()..['recipe'] = {},
        ).trainingPlanProposal,
        isNull,
      );
      final row = trainingMessage();
      firstExercise(row['training_plan'])['sets'] = 999;
      expect(ChatMessage.fromRow(row).trainingPlanProposal, isNull);
    },
  );
}
