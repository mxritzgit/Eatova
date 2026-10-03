import 'dart:convert';

import 'package:eatova/src/models/coach_training_proposal.dart';
import 'package:eatova/src/models/training_history.dart';
import 'package:eatova/src/models/training_log.dart';
import 'package:eatova/src/models/training_plan.dart';
import 'package:eatova/src/models/training_session.dart';
import 'package:flutter_test/flutter_test.dart';

const _historyId = '3f2b8c1e-4d5a-4b6c-8d7e-9f0a1b2c3d4e';

// sha256('bench press'), first 32 hex chars (computed independently).
const _benchId = 'n_cd65829835dee8803618007036630742';

// Europe/Berlin falls back on Sunday 2026-10-25: Saturday 09:30 CEST to
// Sunday 09:30 CET is 25 hours.
final _now = DateTime(2026, 10, 25, 9, 30, 15);
final _today = DateTime(2026, 10, 25);
final _yesterday = DateTime(2026, 10, 24);
final _tomorrow = DateTime(2026, 10, 26);

const _bench = LoggedExercise(
  name: 'Bench press',
  timed: false,
  sets: [LoggedSet(reps: 8, weightKg: 80), LoggedSet(reps: 6, weightKg: 82.5)],
);
const _pushUps = LoggedExercise(
  name: 'Push-ups',
  timed: false,
  sets: [LoggedSet(reps: 20)],
);
const _plank = LoggedExercise(
  name: 'Plank',
  timed: true,
  durationSeconds: 90,
  sets: [LoggedSet(), LoggedSet(weightKg: 10)],
);

LoggedWorkoutDraft _draft({
  List<LoggedExercise> exercises = const [_bench],
  DateTime? performedOn,
  int? durationMinutes,
  String title = 'Push day',
  String note = '',
}) => LoggedWorkoutDraft(
  title: title,
  performedOn: performedOn ?? _today,
  durationMinutes: durationMinutes,
  note: note,
  exercises: exercises,
);

TrainingHistoryEntry _build(LoggedWorkoutDraft draft) => buildLoggedWorkout(
  historyId: _historyId,
  draft: draft,
  now: _now,
  fallbackTitle: 'Workout',
);

TrainingHistoryEntry _roundTrip(TrainingHistoryEntry entry) =>
    TrainingHistoryEntry.fromRow(jsonDecode(jsonEncode(entry.toRow())) as Map);

void main() {
  group('names and identities', () {
    test('normalization trims, collapses whitespace and lowercases', () {
      expect(normalizeExerciseName('  Bench\t  PRESS \n'), 'bench press');
      expect(normalizeExerciseName('Squat'), 'squat');
    });

    test('exercise IDs hash the normalized name and number repeats', () {
      expect(trainingLogExerciseId('Bench press', 1), _benchId);
      expect(trainingLogExerciseId('  BENCH   press ', 1), _benchId);
      expect(trainingLogExerciseId('Bench press', 2), '${_benchId}_2');
      expect(trainingLogExerciseId('Bench press', 3), '${_benchId}_3');
      expect(trainingLogExerciseId('Squat', 1), isNot(_benchId));
    });
  });

  group('buildLoggedWorkout', () {
    test('builds a valid history row that survives the cache roundtrip', () {
      final entry = _build(
        _draft(exercises: const [_bench, _pushUps, _plank], note: 'Easy'),
      );
      expect(_roundTrip(entry).toRow(), entry.toRow());
      expect(entry.id, _historyId);
      expect(entry.note, 'Easy');
      final snapshot = entry.snapshot;
      expect(snapshot.plan.id, 'log_$_historyId');
      expect(snapshot.plan.title, 'Push day');
      expect(snapshot.workoutIndex, 0);
      expect(snapshot.workout.title, 'Push day');
      expect(snapshot.phase, TrainingSessionPhase.review);
      expect(snapshot.remainingMilliseconds, 0);
      expect(snapshot.draftReps, isNull);
      expect(snapshot.draftWeightKg, isNull);
      expect(snapshot.exerciseIndex, 2);
      expect(snapshot.setIndex, 1);
      expect(snapshot.skippedSets, isEmpty);
      expect(snapshot.completedSets.length, 5);
      expect(isLoggedTrainingEntry(entry), isTrue);

      final exercises = snapshot.workout.exercises;
      expect(exercises.map((e) => e.name), [
        'Bench press',
        'Push-ups',
        'Plank',
      ]);
      expect(exercises.map((e) => e.sets), [2, 1, 2]);
      expect(exercises.map((e) => e.reps), [8, 20, null]);
      expect(exercises.map((e) => e.durationSeconds), [null, null, 90]);
      expect(exercises.map((e) => e.restSeconds), everyElement(0));
      expect(snapshot.actualSets.map((a) => a.reps), [8, 6, 20, null, null]);
      expect(snapshot.actualSets.map((a) => a.weightKg), [
        80,
        82.5,
        null,
        null,
        10,
      ]);
      expect(
        snapshot.actualSets.map((a) => a.completedAt),
        everyElement(entry.finishedAt),
      );
    });

    test('actual repetitions stay actual while the plan is clamped', () {
      final entry = _build(
        _draft(
          exercises: const [
            LoggedExercise(
              name: 'Jumping jacks',
              timed: false,
              sets: [LoggedSet(reps: 150), LoggedSet(reps: 40)],
            ),
            LoggedExercise(
              name: 'Failed attempt',
              timed: false,
              sets: [LoggedSet(reps: 0, weightKg: 140)],
            ),
          ],
        ),
      );
      expect(entry.snapshot.workout.exercises.map((e) => e.reps), [100, 1]);
      expect(entry.snapshot.actualSets.map((a) => a.reps), [150, 40, 0]);
      expect(_roundTrip(entry).toRow(), entry.toRow());
    });

    test('a repeated name gets a numbered identity', () {
      final entry = _build(
        _draft(
          exercises: const [
            _bench,
            _pushUps,
            LoggedExercise(
              name: '  BENCH   press ',
              timed: false,
              sets: [LoggedSet(reps: 12, weightKg: 60)],
            ),
          ],
        ),
      );
      final ids = entry.snapshot.workout.exercises.map((e) => e.id).toList();
      expect(ids[0], _benchId);
      expect(ids[1], trainingLogExerciseId('Push-ups', 1));
      expect(ids[2], '${_benchId}_2');
      expect(entry.snapshot.workout.exercises[2].name, 'BENCH   press');
    });

    test('twenty exercises with ten sets each fit', () {
      final entry = _build(
        _draft(
          exercises: [
            for (var i = 0; i < 20; i++)
              LoggedExercise(
                name: 'Exercise $i',
                timed: false,
                sets: [
                  for (var s = 0; s < 10; s++)
                    LoggedSet(reps: 10 + s, weightKg: 20.25),
                ],
              ),
          ],
        ),
      );
      expect(entry.snapshot.completedSets.length, 200);
      expect(entry.snapshot.exerciseIndex, 19);
      expect(entry.snapshot.setIndex, 9);
      expect(_roundTrip(entry).toRow(), entry.toRow());
    });

    test('a timed set over an hour splits into equal parts', () {
      final entry = _build(
        _draft(
          exercises: const [
            LoggedExercise(
              name: 'Run',
              timed: true,
              durationSeconds: 7200,
              sets: [LoggedSet(weightKg: 5)],
            ),
            LoggedExercise(
              name: 'Row',
              timed: true,
              durationSeconds: 3601,
              sets: [LoggedSet(), LoggedSet()],
            ),
          ],
        ),
      );
      final run = entry.snapshot.workout.exercises[0];
      expect(run.sets, 2);
      expect(run.durationSeconds, 3600);
      final row = entry.snapshot.workout.exercises[1];
      expect(row.sets, 4);
      expect(row.durationSeconds, 1801);
      final actuals = entry.snapshot.actualSets;
      expect(actuals.map((a) => a.reps), everyElement(isNull));
      expect(actuals.map((a) => a.weightKg), [5, 5, null, null, null, null]);
      expect(_roundTrip(entry).toRow(), entry.toRow());
    });

    test('today finishes now and no duration means start equals finish', () {
      final entry = _build(_draft());
      expect(entry.finishedAt, _now.toUtc());
      expect(entry.snapshot.startedAt, entry.finishedAt);
      expect(trainingEntryHasDuration(entry), isFalse);
    });

    test('a duration sets the start', () {
      final entry = _build(_draft(durationMinutes: 50));
      expect(entry.finishedAt, _now.toUtc());
      expect(
        entry.snapshot.startedAt,
        _now.toUtc().subtract(const Duration(minutes: 50)),
      );
      expect(trainingEntryHasDuration(entry), isTrue);
    });

    test('a blank title falls back', () {
      expect(_build(_draft(title: '  ')).snapshot.plan.title, 'Workout');
    });

    test('an invalid draft is never built', () {
      expect(
        () => _build(_draft(exercises: const [])),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => _build(_draft(performedOn: _tomorrow)),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('loggedWorkoutTimes', () {
    test('an earlier day keeps the local time of day across DST', () {
      final times = loggedWorkoutTimes(performedOn: _yesterday, now: _now);
      final local = times.finishedAt.toLocal();
      expect(times.finishedAt.isUtc, isTrue);
      expect(times.finishedAt, DateTime(2026, 10, 24, 9, 30, 15).toUtc());
      expect((local.year, local.month, local.day), (2026, 10, 24));
      expect((local.hour, local.minute, local.second), (9, 30, 15));
      expect(times.startedAt, times.finishedAt);
      // In Europe/Berlin the 25-hour Sunday makes `now - 24 h` land at 10:30.
      final naive = _now.subtract(const Duration(days: 1));
      if (naive.hour != 9) expect(naive.hour, 10);
    });

    test('the time of the picked day is ignored and the start follows', () {
      final times = loggedWorkoutTimes(
        performedOn: DateTime(2026, 10, 20, 23, 59),
        durationMinutes: 45,
        now: _now,
      );
      expect(times.finishedAt, DateTime(2026, 10, 20, 9, 30, 15).toUtc());
      expect(
        times.startedAt,
        times.finishedAt.subtract(const Duration(minutes: 45)),
      );
    });

    test('a nonexistent local time still stays on its day and before now', () {
      final now = DateTime(2026, 3, 30, 2, 30);
      final times = loggedWorkoutTimes(
        performedOn: DateTime(2026, 3, 29),
        now: now,
      );
      final local = times.finishedAt.toLocal();
      expect((local.year, local.month, local.day), (2026, 3, 29));
      expect(times.finishedAt.isAfter(now), isFalse);
    });
  });

  group('validateLoggedWorkout', () {
    List<LoggedWorkoutProblem> validate(LoggedWorkoutDraft draft) =>
        validateLoggedWorkout(draft, now: _now);

    test('a complete draft has no problems', () {
      expect(
        validate(
          _draft(
            exercises: const [_bench, _pushUps, _plank],
            durationMinutes: 600,
            note: 'n' * 500,
          ),
        ),
        isEmpty,
      );
    });

    test('the date is required and within the last 30 days', () {
      expect(
        validate(const LoggedWorkoutDraft(title: '', exercises: [_bench])),
        [LoggedWorkoutProblem.missingDate],
      );
      expect(validate(_draft(performedOn: _tomorrow)), [
        LoggedWorkoutProblem.dateOutOfRange,
      ]);
      expect(validate(_draft(performedOn: DateTime(2026, 9, 24))), [
        LoggedWorkoutProblem.dateOutOfRange,
      ]);
      expect(validate(_draft(performedOn: DateTime(2026, 9, 25))), isEmpty);
      expect(validate(_draft(performedOn: _yesterday)), isEmpty);
    });

    test('nothing to log is empty', () {
      for (final exercises in [
        const <LoggedExercise>[],
        const [
          LoggedExercise(name: ' ', timed: false, sets: [LoggedSet(reps: 5)]),
        ],
        const [LoggedExercise(name: 'Squat', timed: false, sets: [])],
      ]) {
        expect(validate(_draft(exercises: exercises)), [
          LoggedWorkoutProblem.empty,
        ]);
      }
    });

    test('a repetition set needs reps, a timed exercise its duration', () {
      expect(
        validate(
          _draft(
            exercises: const [
              LoggedExercise(
                name: 'Squat',
                timed: false,
                sets: [LoggedSet(reps: 5), LoggedSet(weightKg: 100)],
              ),
            ],
          ),
        ),
        [LoggedWorkoutProblem.missingReps],
      );
      expect(
        validate(
          _draft(
            exercises: const [
              LoggedExercise(name: 'Run', timed: true, sets: [LoggedSet()]),
            ],
          ),
        ),
        [LoggedWorkoutProblem.missingDuration],
      );
    });

    test('problems are reported together in a stable order', () {
      expect(
        validate(
          const LoggedWorkoutDraft(
            title: 'Gym',
            exercises: [
              LoggedExercise(name: 'Run', timed: true, sets: [LoggedSet()]),
              LoggedExercise(name: 'Squat', timed: false, sets: [LoggedSet()]),
              LoggedExercise(
                name: 'Row',
                timed: false,
                sets: [LoggedSet(reps: 1001)],
              ),
            ],
          ),
        ),
        [
          LoggedWorkoutProblem.missingDate,
          LoggedWorkoutProblem.missingReps,
          LoggedWorkoutProblem.missingDuration,
          LoggedWorkoutProblem.tooLarge,
        ],
      );
    });

    LoggedExercise reps(int value, {double? weightKg, String name = 'Squat'}) =>
        LoggedExercise(
          name: name,
          timed: false,
          sets: [LoggedSet(reps: value, weightKg: weightKg)],
        );
    LoggedExercise timed(int seconds, {int sets = 1}) => LoggedExercise(
      name: 'Run',
      timed: true,
      durationSeconds: seconds,
      sets: [for (var i = 0; i < sets; i++) const LoggedSet()],
    );
    final tooLarge = <String, LoggedWorkoutDraft>{
      '21 exercises': _draft(
        exercises: [for (var i = 0; i < 21; i++) reps(5, name: 'E$i')],
      ),
      '11 sets': _draft(
        exercises: [
          LoggedExercise(
            name: 'Squat',
            timed: false,
            sets: [for (var i = 0; i < 11; i++) const LoggedSet(reps: 5)],
          ),
        ],
      ),
      '1001 reps': _draft(exercises: [reps(1001)]),
      'negative reps': _draft(exercises: [reps(-1)]),
      '2000.5 kg': _draft(exercises: [reps(5, weightKg: 2000.5)]),
      'negative weight': _draft(exercises: [reps(5, weightKg: -1)]),
      'NaN weight': _draft(exercises: [reps(5, weightKg: double.nan)]),
      'over ten hours': _draft(exercises: [timed(36001)]),
      'under five seconds': _draft(exercises: [timed(4)]),
      'six two-hour sets': _draft(exercises: [timed(7200, sets: 6)]),
      'a long name': _draft(exercises: [reps(5, name: 'n' * 121)]),
      'a control character': _draft(exercises: [reps(5, name: 'Bench\u0007')]),
      'a long title': _draft(title: 't' * 121),
      'a long note': _draft(note: 'n' * 501),
      'zero minutes': _draft(durationMinutes: 0),
      '601 minutes': _draft(durationMinutes: 601),
    };
    for (final entry in tooLarge.entries) {
      test('${entry.key} exceeds the limits', () {
        expect(validate(entry.value), [LoggedWorkoutProblem.tooLarge]);
        expect(() => _build(entry.value), throwsA(isA<ArgumentError>()));
      });
    }

    test('the limits themselves still build', () {
      final draft = _draft(
        title: 't' * 120,
        exercises: [
          reps(1000, weightKg: 2000, name: 'n' * 120),
          reps(0, weightKg: 0),
          timed(36000),
          timed(5, sets: 10),
          timed(7200, sets: 5),
        ],
      );
      expect(validate(draft), isEmpty);
      expect(_roundTrip(_build(draft)).toRow(), _build(draft).toRow());
    });
  });

  group('buildPlanAttachedLog', () {
    final plan = TrainingPlan(
      id: 'manual_strength',
      proposal: CoachTrainingProposal(
        title: 'Strength',
        workouts: [
          TrainingWorkout(
            title: 'Day A',
            exercises: [
              TrainingExercise(name: 'Row', sets: 1, reps: 10, restSeconds: 0),
            ],
          ),
          TrainingWorkout(
            title: 'Day B',
            exercises: [
              TrainingExercise(
                id: 'squat-id',
                name: 'Squat',
                sets: 3,
                reps: 5,
                restSeconds: 120,
              ),
              TrainingExercise(
                id: 'plank-id',
                name: 'Plank',
                sets: 2,
                durationSeconds: 45,
                restSeconds: 30,
              ),
            ],
          ),
        ],
      ),
    );
    const done = PlanAttachedSet(done: true, reps: 5, weightKg: 100);
    const undone = PlanAttachedSet(done: false, reps: 5, weightKg: 100);

    TrainingHistoryEntry attach(
      List<List<PlanAttachedSet>> sets, {
      DateTime? performedOn,
      int workoutIndex = 1,
    }) => buildPlanAttachedLog(
      historyId: _historyId,
      plan: plan,
      workoutIndex: workoutIndex,
      sets: sets,
      performedOn: performedOn ?? _yesterday,
      durationMinutes: 40,
      note: 'Felt good',
      now: _now,
    );

    test('keeps the real plan and marks undone sets skipped', () {
      final entry = attach([
        [done, const PlanAttachedSet(done: true, reps: 7), undone],
        [const PlanAttachedSet(done: true, reps: 3, weightKg: 8), undone],
      ]);
      expect(_roundTrip(entry).toRow(), entry.toRow());
      final snapshot = entry.snapshot;
      expect(snapshot.plan.toJson(), plan.toJson());
      expect(snapshot.workoutIndex, 1);
      expect(snapshot.workout.exercises.map((e) => e.id), [
        'squat-id',
        'plank-id',
      ]);
      expect(snapshot.completedSets, const [
        TrainingSetReference(exerciseIndex: 0, setIndex: 0),
        TrainingSetReference(exerciseIndex: 0, setIndex: 1),
        TrainingSetReference(exerciseIndex: 1, setIndex: 0),
      ]);
      expect(snapshot.skippedSets, const [
        TrainingSetReference(exerciseIndex: 0, setIndex: 2),
        TrainingSetReference(exerciseIndex: 1, setIndex: 1),
      ]);
      expect(snapshot.actualSets.map((a) => a.reps), [5, 7, null]);
      expect(snapshot.actualSets.map((a) => a.weightKg), [100, null, 8]);
      expect(
        snapshot.actualSets.map((a) => a.completedAt),
        everyElement(entry.finishedAt),
      );
      expect(snapshot.exerciseIndex, 1);
      expect(snapshot.setIndex, 1);
      expect(entry.finishedAt, DateTime(2026, 10, 24, 9, 30, 15).toUtc());
      expect(
        snapshot.startedAt,
        entry.finishedAt.subtract(const Duration(minutes: 40)),
      );
      expect(entry.note, 'Felt good');
      expect(isLoggedTrainingEntry(entry), isFalse);
    });

    test('needs at least one done set', () {
      expect(
        () => attach([
          [undone, undone, undone],
          [undone, undone],
        ]),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects a mismatched shape, missing reps and an invalid day', () {
      for (final call in <void Function()>[
        () => attach([
          [done, done, done],
        ]),
        () => attach([
          [done, done],
          [done, done],
        ]),
        () => attach([
          [done, done, done],
          [done, done],
        ], workoutIndex: 2),
        () => attach([
          [const PlanAttachedSet(done: true), done, done],
          [done, done],
        ]),
        () => attach([
          [done, done, done],
          [done, done],
        ], performedOn: _tomorrow),
      ]) {
        expect(call, throwsA(isA<ArgumentError>()));
      }
    });
  });
}
