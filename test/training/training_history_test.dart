import 'dart:convert';

import 'package:clock/clock.dart';
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
      controller.previousSet();
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
      final restored = TrainingSessionSnapshot.fromJson(value);
      expect(restored.actualSets, isEmpty);
      expect(restored.completedSets.length, 1);
      expect(
        TrainingSessionSnapshot.fromJson(value).sessionId,
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
