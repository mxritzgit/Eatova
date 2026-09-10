import 'dart:convert';

import 'package:eatova/src/models/coach_training_proposal.dart';
import 'package:eatova/src/models/training_plan.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _exercise({bool timed = false}) => {
  'name': timed ? 'Plank' : 'Squat',
  'sets': 3,
  'reps': timed ? null : 10,
  'duration_seconds': timed ? 45 : null,
  'rest_seconds': 60,
  'notes': 'Keep a comfortable range of motion.',
};

Map<String, dynamic> _workout() => {
  'title': 'Full body',
  'description': 'A controlled session.',
  'exercises': [_exercise(), _exercise(timed: true)],
};

Map<String, dynamic> _proposal() => {
  'schema_version': 1,
  'title': 'Strength foundations',
  'description': 'Two sessions each week.',
  'goal': 'Build a consistent routine.',
  'workouts': [_workout(), _workout()..['title'] = 'Second session'],
};

CoachTrainingProposal _draft() => CoachTrainingProposal.fromJson(_proposal())!;

void main() {
  group('strict proposal JSON', () {
    test('preserves every field in a multi-workout round trip', () {
      final wire = _proposal();
      final draft = CoachTrainingProposal.fromJson(wire)!;
      expect(draft.toJson(), wire);
      expect(
        CoachTrainingProposal.fromJson(
          jsonDecode(jsonEncode(draft.toJson())),
        )!.toJson(),
        wire,
      );
      expect(draft.workouts[0].exercises[0].reps, 10);
      expect(draft.workouts[0].exercises[1].durationSeconds, 45);
    });

    test('never coerces arbitrary string fields', () {
      for (final field in ['title', 'description', 'goal']) {
        for (final value in [null, 2, true, <String>[]]) {
          expect(
            CoachTrainingProposal.fromJson(_proposal()..[field] = value),
            isNull,
            reason: '$field must reject $value',
          );
        }
      }
      expect(
        CoachTrainingProposal.fromJson(_proposal()..['title'] = '\t\n\r '),
        isNull,
      );
      expect(
        CoachTrainingProposal.fromJson(_proposal()..['title'] = '\u0085'),
        isNull,
      );
      final wire = _proposal()..['title'] = '  Keep this spacing\n';
      expect(CoachTrainingProposal.fromJson(wire)!.title, wire['title']);
    });

    test('requires all and only the declared fields at every level', () {
      for (final key in _proposal().keys) {
        expect(
          CoachTrainingProposal.fromJson(_proposal()..remove(key)),
          isNull,
        );
      }
      for (final field in ['id', 'user_id', 'created_at', 'constructor']) {
        expect(
          CoachTrainingProposal.fromJson(_proposal()..[field] = 'untrusted'),
          isNull,
        );
      }
      expect(
        CoachTrainingProposal.fromJson({..._proposal(), 42: 'not a JSON key'}),
        isNull,
      );
      for (final key in _workout().keys) {
        expect(
          () => TrainingWorkout.fromJson(_workout()..remove(key)),
          throwsFormatException,
        );
      }
      expect(
        () => TrainingWorkout.fromJson(_workout()..['id'] = 'extra'),
        throwsFormatException,
      );
      for (final key in _exercise().keys) {
        expect(
          () => TrainingExercise.fromJson(_exercise()..remove(key)),
          throwsFormatException,
        );
      }
      expect(
        () => TrainingExercise.fromJson(_exercise()..['calories'] = 100),
        throwsFormatException,
      );
    });

    test('requires exactly schema version one', () {
      for (final version in [0, 2, 1.1, '1', true, null, double.nan]) {
        expect(
          CoachTrainingProposal.fromJson(
            _proposal()..['schema_version'] = version,
          ),
          isNull,
        );
      }
      expect(
        CoachTrainingProposal.fromJson(_proposal()..['schema_version'] = 1.0),
        isNotNull,
      );
    });

    test('enforces every individual Unicode codepoint limit', () {
      for (final (field, limit) in [
        ('title', 120),
        ('description', 1000),
        ('goal', 200),
      ]) {
        expect(
          CoachTrainingProposal.fromJson(_proposal()..[field] = '🏋' * limit),
          isNotNull,
        );
        expect(
          CoachTrainingProposal.fromJson(
            _proposal()..[field] = '🏋' * (limit + 1),
          ),
          isNull,
        );
      }
      for (final (field, limit) in [('title', 120), ('description', 500)]) {
        expect(
          TrainingWorkout.fromJson(_workout()..[field] = 'é' * limit),
          isA<TrainingWorkout>(),
        );
        expect(
          () =>
              TrainingWorkout.fromJson(_workout()..[field] = 'é' * (limit + 1)),
          throwsFormatException,
        );
      }
      for (final (field, limit) in [('name', 120), ('notes', 500)]) {
        expect(
          TrainingExercise.fromJson(_exercise()..[field] = '🏋' * limit),
          isA<TrainingExercise>(),
        );
        expect(
          () => TrainingExercise.fromJson(
            _exercise()..[field] = '🏋' * (limit + 1),
          ),
          throwsFormatException,
        );
      }
    });

    test(
      'rejects forbidden controls and invalid UTF-16 without truncation',
      () {
        for (var code = 0; code < 32; code++) {
          final proposal = _proposal()
            ..['goal'] = 'a${String.fromCharCode(code)}b';
          expect(
            CoachTrainingProposal.fromJson(proposal),
            [9, 10, 13].contains(code) ? isNotNull : isNull,
            reason: 'C0 code $code',
          );
        }
        for (final broken in [
          String.fromCharCode(0xd800),
          '${String.fromCharCode(0xd800)}a',
          String.fromCharCode(0xdc00),
        ]) {
          expect(
            CoachTrainingProposal.fromJson(_proposal()..['goal'] = broken),
            isNull,
          );
        }
      },
    );

    test('enforces the combined cap across nested string values', () {
      final exercise = TrainingExercise(
        name: 'a',
        sets: 1,
        reps: 1,
        restSeconds: 0,
        notes: '🏋' * 500,
      );
      final workouts = [
        TrainingWorkout(title: 'a', exercises: List.filled(20, exercise)),
        TrainingWorkout(title: 'a', exercises: [exercise, exercise, exercise]),
      ];
      // 23 * (1 + 500), two workout titles, one plan title = 11,526.
      final boundary = CoachTrainingProposal(
        title: 'a',
        description: 'b' * 474,
        workouts: workouts,
      );
      expect(CoachTrainingProposal.fromJson(boundary.toJson()), isNotNull);
      expect(
        () => boundary.copyWith(description: 'b' * 475),
        throwsFormatException,
      );
      expect(
        CoachTrainingProposal.fromJson(
          boundary.toJson()..['description'] = 'b' * 475,
        ),
        isNull,
      );
    });

    test('rejects invalid lists, child shapes, and overflowing counts', () {
      for (final workouts in [
        null,
        {},
        [],
        [false],
        List.filled(8, _workout()),
      ]) {
        expect(
          CoachTrainingProposal.fromJson(_proposal()..['workouts'] = workouts),
          isNull,
        );
      }
      for (final exercises in [
        null,
        {},
        [],
        [false],
        List.filled(21, _exercise()),
      ]) {
        expect(
          () => TrainingWorkout.fromJson(_workout()..['exercises'] = exercises),
          throwsFormatException,
        );
      }
      expect(
        CoachTrainingProposal.fromJson(
          _proposal()..['workouts'] = List.filled(7, _workout()),
        ),
        isNotNull,
      );
      expect(
        TrainingWorkout.fromJson(
          _workout()..['exercises'] = List.filled(20, _exercise()),
        ).exercises,
        hasLength(20),
      );
    });
  });

  group('exercise types and editing', () {
    for (final (field, minimum, maximum) in [
      ('sets', 1, 10),
      ('reps', 1, 100),
      ('duration_seconds', 5, 3600),
      ('rest_seconds', 0, 600),
    ]) {
      test('$field accepts only bounded mathematical integers', () {
        Map<String, dynamic> wire() =>
            _exercise(timed: field == 'duration_seconds');
        for (final value in [minimum, maximum, minimum.toDouble()]) {
          expect(
            TrainingExercise.fromJson(wire()..[field] = value).toJson()[field],
            value,
          );
        }
        for (final value in [
          minimum - 1,
          maximum + 1,
          minimum + 0.5,
          '$minimum',
          true,
          [],
          double.nan,
          double.infinity,
        ]) {
          expect(
            () => TrainingExercise.fromJson(wire()..[field] = value),
            throwsFormatException,
            reason: '$field = $value',
          );
        }
      });
    }

    test('requires exactly one exercise mode and clears it explicitly', () {
      final repetition = TrainingExercise.fromJson(_exercise());
      expect(repetition.isTimed, isFalse);
      final timed = repetition.copyWith(reps: null, durationSeconds: 30);
      expect(timed.isTimed, isTrue);
      expect(timed.reps, isNull);
      expect(timed.copyWith(durationSeconds: null, reps: 5).reps, 5);
      expect(repetition.reps, 10);
      expect(() => repetition.copyWith(reps: null), throwsFormatException);
      expect(
        () => repetition.copyWith(durationSeconds: 30),
        throwsFormatException,
      );
      expect(() => repetition.copyWith(reps: '10'), throwsFormatException);
      expect(
        () => TrainingExercise.fromJson(_exercise()..['reps'] = null),
        throwsFormatException,
      );
    });

    test('copyWith preserves unchanged values and revalidates all edits', () {
      final draft = _draft();
      final exercise = draft.workouts.first.exercises.first;
      expect(exercise.copyWith().toJson(), exercise.toJson());
      final edited = exercise.copyWith(
        name: 'Goblet squat',
        sets: 2,
        restSeconds: 90,
        notes: 'Use a comfortable weight.',
      );
      expect(edited.name, 'Goblet squat');
      expect(edited.sets, 2);
      expect(edited.restSeconds, 90);
      expect(edited.notes, 'Use a comfortable weight.');
      final workout = draft.workouts.first.copyWith(
        title: 'Session A',
        description: 'Edited session.',
        exercises: [edited],
      );
      expect(workout.copyWith().toJson(), workout.toJson());
      final proposal = draft.copyWith(
        title: 'New title',
        description: 'New description',
        goal: 'New goal',
        workouts: [workout],
      );
      expect(proposal.title, 'New title');
      expect(proposal.description, 'New description');
      expect(proposal.goal, 'New goal');
      expect(proposal.workouts.single.title, 'Session A');
      expect(proposal.copyWith().toJson(), proposal.toJson());
      expect(() => exercise.copyWith(sets: 0), throwsFormatException);
      expect(() => workout.copyWith(exercises: []), throwsFormatException);
      expect(() => proposal.copyWith(workouts: []), throwsFormatException);
      expect(() => proposal.copyWith(title: ''), throwsFormatException);
      expect(
        () => workout.copyWith(exercises: List.filled(21, exercise)),
        throwsFormatException,
      );
      expect(
        () => proposal.copyWith(workouts: List.filled(8, workout)),
        throwsFormatException,
      );
    });

    test('defensive immutable lists and detached JSON protect a session', () {
      final exercises = [TrainingExercise.fromJson(_exercise())];
      final workout = TrainingWorkout(title: 'A', exercises: exercises);
      final workouts = [workout];
      final proposal = CoachTrainingProposal(title: 'A', workouts: workouts);
      final plan = proposal.toTrainingPlan(id: 'manual-1');
      exercises.clear();
      workouts.clear();
      expect(plan.workouts, hasLength(1));
      expect(plan.workouts.single.exercises, hasLength(1));
      expect(() => plan.workouts.clear(), throwsUnsupportedError);
      expect(() => workout.exercises.clear(), throwsUnsupportedError);
      final json = plan.toJson();
      ((json['plan'] as Map)['workouts'] as List).clear();
      expect(plan.workouts, hasLength(1));
    });

    test('duration estimates count work and between-set rests only', () {
      final draft = _draft();
      final reps = draft.workouts.first.exercises.first;
      final timed = draft.workouts.first.exercises.last;
      expect(reps.estimatedDurationSeconds, 3 * 10 * 3 + 2 * 60);
      expect(timed.estimatedDurationSeconds, 3 * 45 + 2 * 60);
      expect(timed.copyWith(sets: 1).estimatedDurationSeconds, 45);
      expect(draft.workouts.first.estimatedDurationSeconds, 465);
      expect(draft.workouts.first.totalSets, 6);
      expect(draft.estimatedDurationSeconds, 930);
      expect(draft.toTrainingPlan(id: 'p1').estimatedDurationSeconds, 930);
    });
  });

  group('saved plan boundary', () {
    test(
      'explicit adoption retains content and uses deterministic identity',
      () {
        final draft = _draft();
        final first = draft.toTrainingPlan(
          id: trainingPlanIdForMessage('msg-1'),
        );
        final retry = draft.toTrainingPlan(
          id: trainingPlanIdForMessage('msg-1'),
        );
        expect(first.id, 'coach_msg-1');
        expect(first.id, retry.id);
        expect(first.toRow()['id'], 'coach_msg-1');
        expect(first.toRow()['plan'], draft.toJson());
        expect(first.toRow()['exercise_ids'], isNotEmpty);
        expect(first.title, draft.title);
        expect(first.description, draft.description);
        expect(first.goal, draft.goal);
        expect(first.proposal.toJson(), draft.toJson());
        expect(first.toJson(), retry.toJson());
        expect(first.copyWith().toJson(), first.toJson());
        final changed = first.copyWith(
          proposal: draft.copyWith(title: 'Edited'),
        );
        expect(changed.id, first.id);
        expect(changed.title, 'Edited');
        expect(first.title, draft.title);
      },
    );

    test(
      'local envelope is strict, database metadata cannot assign ownership',
      () {
        final plan = _draft().toTrainingPlan(id: 'manual_123');
        expect(TrainingPlan.fromJson(plan.toJson()).toJson(), plan.toJson());
        final row = {
          ...plan.toRow(),
          'user_id': 'someone-else',
          'created_at': '2026-09-08T12:00:00Z',
          'updated_at': '2026-09-08T12:00:00Z',
        };
        expect(TrainingPlan.fromRow(row).toRow(), plan.toRow());
        expect(() => TrainingPlan.fromJson(row), throwsFormatException);
        for (final bad in [
          <String, dynamic>{},
          {'id': 'p1'},
          {'id': 'p1', 'plan': null},
          {'id': 'p1', 'plan': []},
          {'id': 'p1', 'plan': <String, dynamic>{}},
          {'id': 'p1', 'plan': _proposal()..['title'] = 123},
        ]) {
          expect(() => TrainingPlan.fromRow(bad), throwsFormatException);
        }
      },
    );

    test('invalid identities never become repaired or random identities', () {
      final draft = _draft();
      for (final invalid in ['', ' ', 'a b', '../a', 'x\n', 'ö', 'x' * 101]) {
        expect(
          () => draft.toTrainingPlan(id: invalid),
          throwsFormatException,
          reason: 'Invalid ID: ${jsonEncode(invalid)}',
        );
        expect(() => trainingPlanIdForMessage(invalid), throwsFormatException);
      }
      expect(draft.toTrainingPlan(id: 'x' * 100).id, hasLength(100));
      expect(trainingPlanIdForMessage('x' * 94), hasLength(100));
      expect(() => trainingPlanIdForMessage('x' * 95), throwsFormatException);
      expect(
        () => TrainingPlan.fromJson({'id': 123, 'plan': _proposal()}),
        throwsFormatException,
      );
    });
  });
}
