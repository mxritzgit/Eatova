import 'package:eatova/src/models/coach_training_context.dart';
import 'package:eatova/src/models/coach_training_proposal.dart';
import 'package:eatova/src/models/training_plan.dart';
import 'package:flutter_test/flutter_test.dart';

CoachTrainingProposal _plan({String notes = ''}) => CoachTrainingProposal(
  title: 'Saved plan',
  workouts: [
    TrainingWorkout(
      title: 'A',
      exercises: [
        TrainingExercise(
          name: 'Squat',
          sets: 3,
          reps: 8,
          restSeconds: 60,
          notes: notes,
        ),
      ],
    ),
  ],
);

Map<String, dynamic> _brief() => {
  'schema_version': 1,
  'intent': 'create',
  'goal': 'Strength',
  'experience': 'beginner',
  'equipment': 'bodyweight',
  'sessions_per_week': 3,
  'minutes_per_session': 30,
  'selected_plan': null,
};

void main() {
  test(
    'brief round-trips only explicit data and a validated plan snapshot',
    () {
      for (final intent in ['adapt', 'discuss']) {
        final input = _brief()
          ..addAll({'intent': intent, 'selected_plan': _plan().toJson()});
        final parsed = CoachTrainingContext.fromJson(input);
        expect(parsed.toJson(), input);
        expect(parsed.selectedPlan!.workouts.single.exercises.single.reps, 8);
      }
      expect(CoachTrainingContext.fromJson(_brief()).selectedPlan, isNull);
    },
  );

  test(
    'brief rejects malformed numbers, fields, controls and nested payloads',
    () {
      final bad = <Map<String, dynamic>>[
        {'owner': 'B'},
        {'intent': 'unknown'},
        {'intent': 'adapt'},
        {'selected_plan': _plan().toJson()},
        {'selected_plan': {}},
        {
          'goal': {'instructions': 'nested'},
        },
        {'goal': 'x' * 201},
        {'goal': '\u0085'},
        {'goal': 'a\u0000b'},
        {'goal': '\ud800'},
        {'goal': 'a\u007fb'},
        {'experience': []},
        {'equipment': 'all'},
        for (final value in [double.nan, double.infinity, 3.5, 0, 8, '3'])
          {'sessions_per_week': value},
        for (final value in [double.nan, double.infinity, 30.5, 9, 181, '30'])
          {'minutes_per_session': value},
        {'intent': 'adapt', 'selected_plan': _plan(notes: 'a\u007fb').toJson()},
      ];
      for (final change in bad) {
        expect(
          () => CoachTrainingContext.fromJson(_brief()..addAll(change)),
          throwsFormatException,
        );
      }
      final nested = _plan().toJson();
      ((nested['workouts'] as List).first['exercises'] as List).first['sets'] =
          double.nan;
      expect(
        () => CoachTrainingContext.fromJson(
          _brief()..addAll({'intent': 'adapt', 'selected_plan': nested}),
        ),
        throwsFormatException,
      );
    },
  );
}
