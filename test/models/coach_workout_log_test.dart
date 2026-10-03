import 'dart:convert';

import 'package:eatova/src/models/coach_workout_log.dart';
import 'package:eatova/src/models/training_log.dart';
import 'package:flutter_test/flutter_test.dart';

/// The canonical v1 example of spec C3 (after the server transform).
Map<String, dynamic> _canonical() =>
    jsonDecode('''
{
  "schema_version": 1,
  "title": "Push day",
  "performed_on": "2026-10-02",
  "duration_minutes": 55,
  "other_days_omitted": true,
  "note": "Shoulder felt fine.",
  "exercises": [
    {"name": "Bench press", "kind": "reps", "duration_seconds": null,
     "sets": [{"reps": 8, "weight_kg": 80}, {"reps": 8, "weight_kg": 82.5},
              {"reps": null, "weight_kg": 102.05}]},
    {"name": "Plank", "kind": "timed", "duration_seconds": 90,
     "sets": [{"reps": null, "weight_kg": null}]},
    {"name": "Run", "kind": "timed", "duration_seconds": null,
     "sets": [{"reps": null, "weight_kg": null}]}
  ]
}''')
        as Map<String, dynamic>;

Map<String, dynamic> _exercise(Map<String, dynamic> json, int index) =>
    (json['exercises'] as List)[index] as Map<String, dynamic>;

Map<String, dynamic> _set(Map<String, dynamic> json, int exercise, int set) =>
    (_exercise(json, exercise)['sets'] as List)[set] as Map<String, dynamic>;

void main() {
  test('accepts the canonical example and writes it back unchanged', () {
    final json = _canonical();
    final log = CoachWorkoutLog.fromJson(json)!;
    expect(log.title, 'Push day');
    expect(log.performedOn, '2026-10-02');
    expect(log.durationMinutes, 55);
    expect(log.otherDaysOmitted, isTrue);
    expect(log.note, 'Shoulder felt fine.');
    expect(log.exercises.map((e) => e.kind), [
      CoachWorkoutLogKind.reps,
      CoachWorkoutLogKind.timed,
      CoachWorkoutLogKind.timed,
    ]);
    expect(log.exercises.first.sets.map((s) => s.weightKg), [80, 82.5, 102.05]);
    expect(log.toJson(), json);
    final again = CoachWorkoutLog.fromJson(
      jsonDecode(jsonEncode(log.toJson())) as Map,
    )!;
    expect(jsonEncode(again.toJson()), jsonEncode(log.toJson()));
  });

  test('toDraft maps kinds, durations, the day and the gaps', () {
    final draft = CoachWorkoutLog.fromJson(_canonical())!.toDraft();
    expect(draft.title, 'Push day');
    expect(draft.performedOn, DateTime(2026, 10, 2));
    expect(draft.durationMinutes, 55);
    expect(draft.note, 'Shoulder felt fine.');
    expect(draft.otherDaysOmitted, isTrue);
    expect(draft.exercises.map((e) => e.name), ['Bench press', 'Plank', 'Run']);
    expect(draft.exercises.map((e) => e.timed), [false, true, true]);
    expect(draft.exercises.map((e) => e.durationSeconds), [null, 90, null]);
    expect(draft.exercises.first.sets.map((s) => s.reps), [8, 8, null]);
    expect(draft.exercises.first.sets.map((s) => s.weightKg), [
      80,
      82.5,
      102.05,
    ]);
    // Unsaid reps and durations stay gaps the review sheet must fill.
    expect(validateLoggedWorkout(draft, now: DateTime(2026, 10, 3, 12)), [
      LoggedWorkoutProblem.missingReps,
      LoggedWorkoutProblem.missingDuration,
    ]);
  });

  test('an unknown day stays unknown', () {
    final json = _canonical()
      ..['performed_on'] = null
      ..['duration_minutes'] = null;
    final draft = CoachWorkoutLog.fromJson(json)!.toDraft();
    expect(draft.performedOn, isNull);
    expect(draft.durationMinutes, isNull);
  });

  final valid = <String, void Function(Map<String, dynamic>)>{
    'a leap day': (j) => j['performed_on'] = '2028-02-29',
    'an old day (format only, no clock)': (j) =>
        j['performed_on'] = '2020-01-01',
    'zero reps and zero weight': (j) => _set(j, 0, 0)
      ..['reps'] = 0
      ..['weight_kg'] = 0,
    'the upper bounds': (j) {
      _set(j, 0, 0)
        ..['reps'] = 1000
        ..['weight_kg'] = 2000;
      j['duration_minutes'] = 600;
      j['note'] = 'n' * 500;
      j['title'] = 't' * 120;
    },
    'ten timed hours': (j) => _exercise(j, 1)['duration_seconds'] = 36000,
    'five two-hour sets': (j) => _exercise(j, 1)
      ..['duration_seconds'] = 7200
      ..['sets'] = [
        for (var i = 0; i < 5; i++) {'reps': null, 'weight_kg': null},
      ],
  };
  for (final entry in valid.entries) {
    test('accepts ${entry.key}', () {
      final json = _canonical();
      entry.value(json);
      expect(CoachWorkoutLog.fromJson(json), isNotNull);
    });
  }

  final invalid = <String, void Function(Map<String, dynamic>)>{
    'an extra key': (j) => j['calories'] = 300,
    'an extra exercise key': (j) => _exercise(j, 0)['rpe'] = 8,
    'an extra set key': (j) => _set(j, 0, 0)['rir'] = 2,
    'a missing key': (j) => j.remove('note'),
    'a missing set key': (j) => _set(j, 0, 0).remove('weight_kg'),
    'schema version 2': (j) => j['schema_version'] = 2,
    'a numeric title': (j) => j['title'] = 5,
    'a blank title': (j) => j['title'] = '  ',
    'a long title': (j) => j['title'] = 't' * 121,
    'a long note': (j) => j['note'] = 'n' * 501,
    'a string flag': (j) => j['other_days_omitted'] = 'false',
    'a missing flag': (j) => j['other_days_omitted'] = null,
    'string reps': (j) => _set(j, 0, 0)['reps'] = '8',
    'fractional reps': (j) => _set(j, 0, 0)['reps'] = 8.5,
    'string weight': (j) => _set(j, 0, 0)['weight_kg'] = '80',
    'an unknown kind': (j) => _exercise(j, 0)['kind'] = 'cardio',
    'exercises as a map': (j) => j['exercises'] = <String, dynamic>{},
    'a set as a list': (j) => (_exercise(j, 0)['sets'] as List)[0] = [8, 80],
    'no exercises': (j) => j['exercises'] = <dynamic>[],
    '21 exercises': (j) => j['exercises'] = [
      for (var i = 0; i < 21; i++) {..._exercise(j, 0), 'name': 'E$i'},
    ],
    'no sets': (j) => _exercise(j, 0)['sets'] = <dynamic>[],
    '11 sets': (j) => _exercise(j, 0)['sets'] = [
      for (var i = 0; i < 11; i++) {'reps': 5, 'weight_kg': null},
    ],
    'three decimals': (j) => _set(j, 0, 0)['weight_kg'] = 102.055,
    'over 2000 kg': (j) => _set(j, 0, 0)['weight_kg'] = 2000.001,
    'a negative weight': (j) => _set(j, 0, 0)['weight_kg'] = -0.5,
    '1001 reps': (j) => _set(j, 0, 0)['reps'] = 1001,
    'negative reps': (j) => _set(j, 0, 0)['reps'] = -1,
    'timed with reps': (j) => _set(j, 1, 0)['reps'] = 30,
    'reps with a duration': (j) => _exercise(j, 0)['duration_seconds'] = 60,
    'six two-hour sets': (j) => _exercise(j, 1)
      ..['duration_seconds'] = 7200
      ..['sets'] = [
        for (var i = 0; i < 6; i++) {'reps': null, 'weight_kg': null},
      ],
    'over ten hours': (j) => _exercise(j, 1)['duration_seconds'] = 36001,
    'four seconds': (j) => _exercise(j, 1)['duration_seconds'] = 4,
    'zero minutes': (j) => j['duration_minutes'] = 0,
    '601 minutes': (j) => j['duration_minutes'] = 601,
    'February 30': (j) => j['performed_on'] = '2026-02-30',
    'an unpadded date': (j) => j['performed_on'] = '2026-2-3',
    'a timestamp': (j) => j['performed_on'] = '2026-10-02T00:00:00Z',
    'a blank name': (j) => _exercise(j, 0)['name'] = ' ',
    'a long name': (j) => _exercise(j, 0)['name'] = 'n' * 121,
    'a control character': (j) => _exercise(j, 0)['name'] = 'Bench\u0007',
    'a lone surrogate': (j) => _exercise(j, 0)['name'] = 'Bench \uD800',
  };
  for (final entry in invalid.entries) {
    test('rejects ${entry.key}', () {
      final json = _canonical();
      entry.value(json);
      expect(CoachWorkoutLog.fromJson(json), isNull);
    });
  }

  test('rejects arbitrary shapes without throwing', () {
    expect(CoachWorkoutLog.fromJson(const {}), isNull);
    expect(CoachWorkoutLog.fromJson(const {1: 2}), isNull);
    expect(
      CoachWorkoutLog.fromJson({..._canonical(), 'exercises': null}),
      isNull,
    );
  });
}
