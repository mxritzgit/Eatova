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

  // Bounds, keys, types and dates are pinned once, for Dart, TypeScript and
  // SQL alike, by the shared fixture in coach_workout_log_parity_test.dart.

  test('rejects arbitrary shapes without throwing', () {
    expect(CoachWorkoutLog.fromJson(const {}), isNull);
    expect(CoachWorkoutLog.fromJson(const {1: 2}), isNull);
    expect(
      CoachWorkoutLog.fromJson({..._canonical(), 'exercises': null}),
      isNull,
    );
  });
}
