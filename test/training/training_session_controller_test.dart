import 'dart:convert';

import 'package:eatova/src/models/training_session.dart';
import 'package:eatova/src/services/training_session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'training_timer_fixtures.dart';

void main() {
  late TimerTestClock clock;
  late TrainingSessionController session;
  setUp(() {
    clock = TimerTestClock();
    session = TrainingSessionController(
      plan: timerPlan(),
      monotonicNow: clock.now,
      autoTick: false,
    );
  });
  tearDown(() => session.dispose());

  test('starts paused; progress is completed sets, not visited position', () {
    expect(session.isRunning, isFalse);
    expect(session.remaining, const Duration(seconds: 30));
    session.nextExercise();
    expect(session.exerciseIndex, 1);
    expect(session.skippedSets.length, 2);
    expect(session.progress, 0);
  });

  test('one late tick accounts for all monotonic elapsed milliseconds', () {
    session.start();
    clock.elapse(const Duration(milliseconds: 12437));
    session.tick();
    expect(session.remaining, const Duration(milliseconds: 17563));
    for (var i = 0; i < 100; i++) {
      session.tick();
    }
    expect(session.remaining, const Duration(milliseconds: 17563));
  });

  test(
    'pause samples time before first tick and resume preserves fractions',
    () {
      session.start();
      clock.elapse(const Duration(milliseconds: 3251));
      session.pause();
      clock.elapse(const Duration(days: 3));
      expect(session.remaining, const Duration(milliseconds: 26749));
      session.start();
      clock.elapse(const Duration(milliseconds: 749));
      expect(session.remaining, const Duration(seconds: 26));
    },
  );

  test('paused zero never advances or completes an unattended exercise', () {
    session.start();
    clock.elapse(const Duration(hours: 8));
    session.pause();
    session.tick();
    session.start();
    session.tick();
    expect(session.isRunning, isFalse);
    expect(session.remaining, Duration.zero);
    expect(session.exerciseIndex, 0);
    expect(session.setIndex, 0);
    expect(session.completedSetCount, 0);
    expect(session.phase, TrainingSessionPhase.exercise);
  });

  test('cannot confirm timed set before zero', () {
    session.completeCurrentSet();
    session.start();
    session.completeCurrentSet();
    expect(session.completedSetCount, 0);
    expect(session.isRunning, isTrue);
  });

  test(
    'confirming paused zero starts rest and double confirmation is inert',
    () {
      session.start();
      clock.elapse(const Duration(seconds: 30));
      session.pause();
      session.completeCurrentSet();
      session.completeCurrentSet();
      expect(session.phase, TrainingSessionPhase.rest);
      expect(session.remaining, const Duration(seconds: 15));
      expect(session.isRunning, isTrue);
      expect(session.completedSetCount, 1);
      expect(session.progress, .25);
    },
  );

  test('skipping active rest deliberately leaves the next set paused', () {
    session.start();
    clock.elapse(const Duration(seconds: 30));
    session.completeCurrentSet();
    session.start();
    clock.elapse(const Duration(seconds: 2));
    session.tick();
    expect(session.phase, TrainingSessionPhase.rest);
    expect(session.completedSetCount, 1);
    session.continueAfterRest();
    expect(session.setIndex, 1);
    expect(session.phase, TrainingSessionPhase.exercise);
    expect(session.remaining, const Duration(seconds: 30));
    expect(session.isRunning, isFalse);
  });

  test('no final rest after last set, even when prescription has rest', () {
    session.nextSet();
    session.start();
    clock.elapse(const Duration(seconds: 30));
    session.completeCurrentSet();
    expect(session.exerciseIndex, 1);
    expect(session.phase, TrainingSessionPhase.exercise);
    expect(session.setIndex, 0);
    expect(session.isRunning, isFalse);
    expect(session.completedSetCount, 1);
    expect(session.skippedSets.length, 1);
  });

  test('repetitions never use estimated timing for completion', () {
    session.nextExercise();
    session.completeCurrentSet();
    expect(session.completedSetCount, 0);
    session.start();
    clock.elapse(const Duration(days: 2));
    session.tick();
    expect(session.isRunning, isTrue);
    expect(session.remaining, Duration.zero);
    expect(session.completedSetCount, 0);
    session.completeCurrentSet();
    session.completeCurrentSet();
    expect(session.completedSetCount, 1);
    expect(session.setIndex, 1);
    expect(session.isRunning, isFalse);
  });

  test('rep pause requires deliberate resume before confirmation', () {
    session.nextExercise();
    session.start();
    session.pause();
    session.completeCurrentSet();
    expect(session.completedSetCount, 0);
    session.start();
    session.completeCurrentSet();
    expect(session.completedSetCount, 1);
  });

  test('rewind means more remaining, is clamped, and pauses', () {
    session.start();
    clock.elapse(const Duration(seconds: 12));
    session.rewind10Seconds();
    expect(session.remaining, const Duration(seconds: 28));
    expect(session.isRunning, isFalse);
    session.rewind10Seconds();
    expect(session.remaining, const Duration(seconds: 30));
    clock.elapse(const Duration(minutes: 10));
    session.tick();
    expect(session.remaining, const Duration(seconds: 30));
  });

  test('forward clamps at zero without recording completion', () {
    for (var i = 0; i < 6; i++) {
      session.forward10Seconds();
    }
    expect(session.remaining, Duration.zero);
    expect(session.completedSetCount, 0);
    expect(session.phase, TrainingSessionPhase.exercise);
    session.rewind10Seconds();
    expect(session.remaining, const Duration(seconds: 10));
  });

  test('reset current rest preserves completed set and remains paused', () {
    session.start();
    clock.elapse(const Duration(seconds: 30));
    session.completeCurrentSet();
    session.start();
    clock.elapse(const Duration(seconds: 9));
    session.resetPhase();
    expect(session.remaining, const Duration(seconds: 15));
    expect(session.completedSetCount, 1);
    expect(session.isRunning, isFalse);
  });

  test('rep adjustments and reset never complete sets', () {
    session.nextExercise();
    session.start();
    session.rewind10Seconds();
    session.forward10Seconds();
    expect(session.isRunning, isTrue);
    session.resetPhase();
    expect(session.isRunning, isFalse);
    expect(session.completedSetCount, 0);
  });

  test('going back from rest revokes completed set; replay counts once', () {
    session.start();
    clock.elapse(const Duration(seconds: 30));
    session.completeCurrentSet();
    session.start();
    session.previousSet();
    expect(session.phase, TrainingSessionPhase.exercise);
    expect(session.completedSetCount, 0);
    expect(session.remaining, const Duration(seconds: 30));
    clock.elapse(const Duration(hours: 1));
    session.tick();
    expect(session.remaining, const Duration(seconds: 30));
    session.start();
    clock.elapse(const Duration(seconds: 30));
    session.completeCurrentSet();
    expect(session.completedSetCount, 1);
  });

  test('previous exercise invalidates its ledger and all later sets', () {
    session.nextExercise();
    session.start();
    session.completeCurrentSet();
    session.previousExercise();
    expect(session.exerciseIndex, 0);
    expect(session.setIndex, 0);
    expect(session.completedSetCount, 0);
    expect(session.skippedSets, isEmpty);
  });

  test('previous set crosses exercise boundary to actual final set', () {
    session.nextExercise();
    session.start();
    session.previousSet();
    expect(session.exerciseIndex, 0);
    expect(session.setIndex, 1);
    expect(session.skippedSets.length, 1);
    expect(session.isRunning, isFalse);
    session.previousSet();
    expect(session.setIndex, 0);
    expect(session.canPreviousSet, isFalse);
    session.previousSet();
    session.previousExercise();
    expect(session.setIndex, 0);
  });

  test('skipping from rest does not reclassify completed set', () {
    session.start();
    clock.elapse(const Duration(seconds: 30));
    session.completeCurrentSet();
    session.nextExercise();
    expect(session.completedSetCount, 1);
    expect(session.skippedSets.length, 1);
    expect(session.snapshot().toJson()['status'], 'paused');
  });

  test('all skipped review shows zero real progress and supports rewind', () {
    session.nextExercise();
    session.nextExercise();
    expect(session.phase, TrainingSessionPhase.review);
    expect(session.progress, 0);
    expect(session.skippedSets.length, 4);
    session.nextSet();
    session.nextExercise();
    session.resetPhase();
    session.start();
    session.forward10Seconds();
    expect(session.phase, TrainingSessionPhase.review);
    session.previousSet();
    expect(session.exerciseIndex, 1);
    expect(session.setIndex, 1);
    expect(session.skippedSets.length, 3);
    session.nextSet();
    session.previousExercise();
    expect(session.setIndex, 0);
    expect(session.skippedSets.length, 2);
  });

  test(
    'full completed workout reaches 100 percent without fabricated extras',
    () {
      for (var i = 0; i < 2; i++) {
        session.start();
        clock.elapse(const Duration(seconds: 30));
        session.completeCurrentSet();
        session.continueAfterRest();
      }
      for (var i = 0; i < 2; i++) {
        session.start();
        session.completeCurrentSet();
      }
      expect(session.phase, TrainingSessionPhase.review);
      expect(session.progress, 1);
      expect(session.completedSetCount, 4);
      expect(session.skippedSets, isEmpty);
      expect(
        TrainingSessionSnapshot.fromJson(
          session.snapshot().toJson(),
        ).completedSets.length,
        4,
      );
    },
  );

  test(
    'snapshot samples running time, restores paused with immutable plan',
    () {
      session.start();
      clock.elapse(const Duration(milliseconds: 5678));
      final wire = jsonDecode(jsonEncode(session.snapshot().toJson())) as Map;
      final snapshot = TrainingSessionSnapshot.fromJson(wire);
      final restored = TrainingSessionController.fromSnapshot(
        snapshot,
        monotonicNow: clock.now,
        autoTick: false,
      );
      addTearDown(restored.dispose);
      clock.elapse(const Duration(days: 1));
      expect(restored.isRunning, isFalse);
      expect(restored.remaining, const Duration(milliseconds: 24322));
      expect(session.isRunning, isTrue);
      expect(
        () => snapshot.completedSets.add(
          const TrainingSetReference(exerciseIndex: 0, setIndex: 0),
        ),
        throwsUnsupportedError,
      );
      expect(() => snapshot.plan.workouts.clear(), throwsUnsupportedError);
      expect(restored.plan.toJson(), timerPlan().toJson());
    },
  );

  test('rest recovery preserves exact cursor and completed sets', () {
    session.start();
    clock.elapse(const Duration(seconds: 30));
    session.completeCurrentSet();
    session.start();
    clock.elapse(const Duration(milliseconds: 1240));
    session.pause();
    final restored = TrainingSessionController.fromSnapshot(
      TrainingSessionSnapshot.fromJson(session.snapshot().toJson()),
      autoTick: false,
    );
    addTearDown(restored.dispose);
    expect(restored.phase, TrainingSessionPhase.rest);
    expect(restored.remaining, const Duration(milliseconds: 13760));
    expect(restored.completedSetCount, 1);
    expect(restored.isRunning, isFalse);
  });

  test('workout selection and invalid index use frozen plan boundary', () {
    final other = TrainingSessionController(
      plan: timerPlan(),
      workoutIndex: 1,
      autoTick: false,
    );
    addTearDown(other.dispose);
    other.start();
    other.completeCurrentSet();
    expect(other.phase, TrainingSessionPhase.review);
    expect(other.completedSetCount, 1);
    expect(
      () => TrainingSessionController(plan: timerPlan(), workoutIndex: -1),
      throwsFormatException,
    );
    expect(
      () => TrainingSessionController(plan: timerPlan(), workoutIndex: 2),
      throwsFormatException,
    );
  });

  test('disposed controller cannot run or notify from stale callbacks', () {
    final separate = TrainingSessionController(
      plan: timerPlan(),
      autoTick: false,
    );
    separate.start();
    separate.dispose();
    separate.tick();
    separate.start();
    separate.pause();
    separate.nextSet();
    separate.previousSet();
    separate.nextExercise();
    separate.previousExercise();
    separate.resetPhase();
    separate.forward10Seconds();
    separate.completeCurrentSet();
    separate.continueAfterRest();
    expect(separate.isRunning, isFalse);
  });
}
