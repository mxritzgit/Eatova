import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:eatova/src/models/coach_training_proposal.dart';
import 'package:eatova/src/models/training_history.dart';
import 'package:eatova/src/models/training_plan.dart';
import 'package:eatova/src/models/training_session.dart';
import 'package:eatova/src/services/training_session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'training_timer_fixtures.dart';

void main() {
  final now = DateTime.utc(2026, 9, 10, 12);

  TrainingHistoryEntry entry() => withClock(Clock.fixed(now), () {
    final controller = TrainingSessionController(
      plan: timerPlan(),
      workoutIndex: 1,
      autoTick: false,
    );
    controller.setCurrentActual(reps: 6, weightKg: 12.5);
    controller.start();
    controller.completeCurrentSet();
    final value = controller.completion(
      finishedAt: now.add(const Duration(minutes: 2)),
    );
    controller.dispose();
    return value;
  });

  test(
    'actuals, stable session UUID and immutable copied workout survive roundtrip',
    () {
      final value = entry();
      final decoded = TrainingHistoryEntry.fromRow(
        jsonDecode(jsonEncode(value.toRow())) as Map,
      );
      expect(decoded.toRow(), value.toRow());
      expect(decoded.snapshot.actualSets.single.reps, 6);
      expect(decoded.snapshot.actualSets.single.weightKg, 12.5);
      expect(decoded.snapshot.workout.exercises.single.reps, 8);
      expect(decoded.snapshot.startedAt, now);
    },
  );

  test(
    'local pending completion metadata roundtrips but cannot enter server history',
    () {
      final value = entry();
      final pending = TrainingSessionSnapshot.fromJson(
        value.recoverySnapshot().toJson(),
      );
      expect(TrainingHistoryEntry.fromRecovery(pending).toRow(), value.toRow());
      expect(
        () => TrainingHistoryEntry(
          snapshot: pending,
          finishedAt: value.finishedAt,
        ),
        throwsFormatException,
      );
      final malformed = pending.toJson()..remove('pending_completion_note');
      expect(
        () => TrainingSessionSnapshot.fromJson(malformed),
        throwsFormatException,
      );
    },
  );

  test('PostgREST offset timestamps load while recovery requires UTC', () {
    final value = entry();
    final row = value.toRow();
    row['finished_at'] = value.finishedAt.toIso8601String().replaceFirst(
      'Z',
      '+00:00',
    );
    expect(TrainingHistoryEntry.fromRow(row).toRow(), value.toRow());
    final snapshot = value.snapshot.toJson();
    snapshot['started_at'] = '2026-09-10T12:00:00';
    expect(
      () => TrainingSessionSnapshot.fromJson(snapshot),
      throwsFormatException,
    );
  });

  test('partial completion marks untouched sets skipped, never performed', () {
    withClock(Clock.fixed(now), () {
      final controller = TrainingSessionController(
        plan: timerPlan(),
        autoTick: false,
      );
      controller.nextExercise();
      controller.setCurrentActual(reps: 4, weightKg: 0);
      controller.start();
      controller.completeCurrentSet();
      final value = controller.completion();
      expect(value.snapshot.actualSets.single.reps, 4);
      expect(value.snapshot.completedSets.length, 1);
      expect(value.snapshot.skippedSets.length, 3);
      expect(value.snapshot.actualSets.single.weightKg, 0);
      controller.undoLastCompleted();
      expect(controller.actualSets, isEmpty);
      controller.dispose();
    });
  });

  test(
    'recovery preserves current actual values and the completion identity',
    () {
      final first = TrainingSessionController(
        plan: timerPlan(),
        workoutIndex: 1,
        autoTick: false,
      );
      first.setCurrentActual(reps: 7, weightKg: 9.25);
      final restored = TrainingSessionController.fromSnapshot(
        TrainingSessionSnapshot.fromJson(first.snapshot().toJson()),
        autoTick: false,
      );
      expect(restored.isRunning, isFalse);
      expect(restored.sessionId, first.sessionId);
      expect(restored.startedAt, first.startedAt);
      expect(restored.actualReps, 7);
      expect(restored.actualWeightKg, 9.25);
      first.dispose();
      restored.dispose();
    },
  );

  test(
    'last time follows exercise rename/reorder but isolates names and copied plans',
    () {
      final value = entry();
      final original = value.snapshot.plan;
      final exercise = original.workouts[1].exercises.single;
      final changed = original.copyWith(
        proposal: original.proposal.copyWith(
          workouts: [
            original.workouts[1].copyWith(
              exercises: [exercise.copyWith(name: 'Different name', reps: 15)],
            ),
            original.workouts[0],
          ],
        ),
      );
      final persisted = TrainingPlan.fromRow(changed.toRow());
      expect(
        lastTrainingPerformance(
          [value],
          persisted.id,
          persisted.workouts.first.exercises.single.id!,
          isTimed: false,
        ).single.reps,
        6,
      );
      final sameNameNewExercise = exercise.copyWith(id: 'new-exercise');
      expect(
        lastTrainingPerformance(
          [value],
          original.id,
          sameNameNewExercise.id!,
          isTimed: false,
        ),
        isEmpty,
      );
      expect(
        lastTrainingPerformance(
          [value],
          'different-plan',
          exercise.id!,
          isTimed: false,
        ),
        isEmpty,
      );
      expect(
        lastTrainingPerformance(
          [value],
          original.id,
          exercise.id!,
          isTimed: true,
        ),
        isEmpty,
      );
      expect(value.snapshot.workout.exercises.single.name, 'Reach');
      expect(value.snapshot.workout.exercises.single.reps, 8);
    },
  );

  test('legacy snapshot upgrades without inventing actual repetitions', () {
    final value = entry().snapshot.toJson();
    for (final key in [
      'session_id',
      'started_at',
      'actual_sets',
      'draft_reps',
      'draft_weight_kg',
    ]) {
      value.remove(key);
    }
    value['schema_version'] = 1;
    withClock(Clock.fixed(now), () {
      final restored = TrainingSessionSnapshot.fromJson(
        TrainingSessionSnapshot.upgradeLegacyJson(value)!,
      );
      expect(restored.actualSets, isEmpty);
      expect(restored.completedSets.length, 1);
      expect(
        TrainingSessionSnapshot.upgradeLegacyJson(value)!['session_id'],
        restored.sessionId,
      );
      final controller = TrainingSessionController.fromSnapshot(
        restored,
        autoTick: false,
      );
      expect(() => controller.completion(), throwsFormatException);
      controller.setCompletedActual(restored.completedSets.single, reps: 5);
      expect(controller.completion().snapshot.actualSets.single.reps, 5);
      controller.dispose();
    });
  });

  for (final weight in [-1.0, double.nan, double.infinity, 2000.01]) {
    test('reject invalid actual weight $weight', () {
      expect(
        () => TrainingSetActual(
          reference: const TrainingSetReference(exerciseIndex: 0, setIndex: 0),
          completedAt: now,
          reps: 8,
          weightKg: weight,
        ),
        throwsFormatException,
      );
    });
  }

  group('mirrors the server CHECK', () {
    Map<String, dynamic> row() =>
        jsonDecode(jsonEncode(entry().toRow())) as Map<String, dynamic>;
    Map<String, dynamic> snapshotOf(Map<String, dynamic> row) =>
        (row['session'] as Map)['snapshot'] as Map<String, dynamic>;

    final invalid = <String, void Function(Map<String, dynamic>)>{
      'a draft repetition value': (r) => snapshotOf(r)['draft_reps'] = 6,
      'a zero draft repetition value': (r) => snapshotOf(r)['draft_reps'] = 0,
      'a draft weight': (r) => snapshotOf(r)['draft_weight_kg'] = 12.5,
      'an uppercase session ID': (r) {
        const upper = 'ABCDEF01-2345-4678-89AB-CDEF01234567';
        r['id'] = upper;
        snapshotOf(r)['session_id'] = upper;
      },
      'a phase deadline': (r) =>
          snapshotOf(r)['phase_ends_at'] = '2026-09-10T12:01:00.000Z',
    };
    for (final change in invalid.entries) {
      test('rejects ${change.key}', () {
        final value = row();
        change.value(value);
        expect(
          () => TrainingHistoryEntry.fromRow(value),
          throwsFormatException,
        );
      });
    }

    test('the constructor rejects drafts and uppercase IDs directly', () {
      final snapshot = entry().snapshot;
      TrainingSessionSnapshot copy({
        String? sessionId,
        int? draftReps,
        double? draftWeightKg,
      }) => TrainingSessionSnapshot(
        plan: snapshot.plan,
        sessionId: sessionId ?? snapshot.sessionId,
        startedAt: snapshot.startedAt,
        actualSets: snapshot.actualSets,
        draftReps: draftReps,
        draftWeightKg: draftWeightKg,
        workoutIndex: snapshot.workoutIndex,
        exerciseIndex: snapshot.exerciseIndex,
        setIndex: snapshot.setIndex,
        phase: snapshot.phase,
        remainingMilliseconds: 0,
        completedSets: snapshot.completedSets,
        skippedSets: snapshot.skippedSets,
      );
      final finishedAt = now.add(const Duration(minutes: 2));
      expect(
        TrainingHistoryEntry(snapshot: copy(), finishedAt: finishedAt).id,
        snapshot.sessionId,
      );
      for (final invalid in [
        copy(draftReps: 6),
        copy(draftWeightKg: 0),
        copy(sessionId: 'ABCDEF01-2345-4678-89AB-CDEF01234567'),
      ]) {
        expect(
          () => TrainingHistoryEntry(snapshot: invalid, finishedAt: finishedAt),
          throwsFormatException,
        );
      }
    });
  });

  group('lastTrainingPerformanceByName', () {
    TrainingHistoryEntry performed(
      String planId,
      List<TrainingExercise> exercises,
      DateTime finishedAt, {
      Set<int> skippedExercises = const {},
    }) {
      final plan = TrainingPlan(
        id: planId,
        proposal: CoachTrainingProposal(
          title: 'Plan',
          workouts: [TrainingWorkout(title: 'Day', exercises: exercises)],
        ),
      );
      final completed = <TrainingSetReference>[];
      final skipped = <TrainingSetReference>[];
      final actuals = <TrainingSetActual>[];
      for (var e = 0; e < exercises.length; e++) {
        for (var s = 0; s < exercises[e].sets; s++) {
          final ref = TrainingSetReference(exerciseIndex: e, setIndex: s);
          if (skippedExercises.contains(e)) {
            skipped.add(ref);
            continue;
          }
          completed.add(ref);
          actuals.add(
            TrainingSetActual(
              reference: ref,
              completedAt: finishedAt,
              reps: exercises[e].isTimed ? null : 10 + s,
              weightKg: 40.0 + e,
            ),
          );
        }
      }
      return TrainingHistoryEntry(
        snapshot: TrainingSessionSnapshot(
          plan: plan,
          startedAt: finishedAt,
          workoutIndex: 0,
          exerciseIndex: exercises.length - 1,
          setIndex: exercises.last.sets - 1,
          phase: TrainingSessionPhase.review,
          remainingMilliseconds: 0,
          completedSets: completed,
          skippedSets: skipped,
          actualSets: actuals,
        ),
        finishedAt: finishedAt,
      );
    }

    TrainingExercise reps(String name, {int sets = 2}) =>
        TrainingExercise(name: name, sets: sets, reps: 8, restSeconds: 60);
    TrainingExercise timed(String name) => TrainingExercise(
      name: name,
      sets: 1,
      durationSeconds: 60,
      restSeconds: 0,
    );

    final history = [
      performed('older', [reps('Bench Press')], now),
      performed('newer', [
        reps('Rows'),
        reps('  bench   PRESS ', sets: 3),
      ], now.add(const Duration(days: 1))),
      performed('current', [
        reps('Bench press', sets: 1),
      ], now.add(const Duration(days: 2))),
      performed(
        'skipped',
        [reps('Bench press'), reps('Rows')],
        now.add(const Duration(days: 3)),
        skippedExercises: {0},
      ),
      performed('timed', [
        timed('Bench press'),
      ], now.add(const Duration(days: 4))),
    ];

    test('returns the newest other-plan performance with the same name', () {
      final sets = lastTrainingPerformanceByName(
        history,
        excludePlanId: 'current',
        exerciseName: 'bench press',
        isTimed: false,
      );
      expect(sets.map((a) => a.reps), [10, 11, 12]);
      expect(sets.map((a) => a.weightKg), everyElement(41.0));
      expect(sets.map((a) => a.reference.exerciseIndex), everyElement(1));
    });

    test('falls back to older sessions and skips only the excluded plan', () {
      expect(
        lastTrainingPerformanceByName(
          [
            for (final entry in history)
              if (entry.snapshot.plan.id != 'newer') entry,
          ],
          excludePlanId: 'current',
          exerciseName: 'Bench press',
          isTimed: false,
        ).map((a) => a.reps),
        [10, 11],
      );
      // Not excluded, the one-set session of 'current' is the newest.
      expect(
        lastTrainingPerformanceByName(
          history,
          excludePlanId: 'none',
          exerciseName: 'Bench press',
          isTimed: false,
        ).map((a) => a.reps),
        [10],
      );
    });

    test('keeps timed and repetition work apart', () {
      final sets = lastTrainingPerformanceByName(
        history,
        excludePlanId: 'current',
        exerciseName: 'BENCH PRESS',
        isTimed: true,
      );
      expect(sets.single.reps, isNull);
      expect(sets.single.weightKg, 40);
    });

    test('unknown names return nothing', () {
      expect(
        lastTrainingPerformanceByName(
          history,
          excludePlanId: 'current',
          exerciseName: 'Bench',
          isTimed: false,
        ),
        isEmpty,
      );
    });
  });

  test('a plan-attached log blocked by a session is a typed exception', () {
    expect(const TrainingLogBlockedBySession(), isA<Exception>());
  });

  test(
    'reject duplicate identities, timestamp inversion, mismatched IDs and missing actuals',
    () {
      final value = entry();
      final row = jsonDecode(jsonEncode(value.toRow())) as Map<String, dynamic>;
      row['id'] = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
      expect(() => TrainingHistoryEntry.fromRow(row), throwsFormatException);
      expect(
        () => TrainingHistoryEntry(
          snapshot: value.snapshot,
          finishedAt: now.subtract(const Duration(seconds: 1)),
        ),
        throwsFormatException,
      );
      final plan = timerPlan().toRow();
      plan['exercise_ids'] = [
        ['duplicate', 'duplicate'],
        ['third'],
      ];
      expect(() => TrainingPlan.fromRow(plan), throwsFormatException);
    },
  );
}
