import 'dart:convert';
import 'dart:math';

import 'package:clock/clock.dart';
import 'package:eatova/src/models/coach_training_proposal.dart';
import 'package:eatova/src/models/training_plan.dart';
import 'package:eatova/src/models/training_session.dart';
import 'package:eatova/src/services/training_session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures.dart';

// Recovery on wall-clock deadlines (spec A4, 2026-10-03). Supersedes
// "recovery always paused" and "a late callback gives every phase its full
// duration": a running rest continues after a restart, a passed timed set
// waits at zero, and only an explicit pause freezes time.

TrainingPlan _plan() {
  final raw = trainingDraft();
  final exercises = firstWorkout(raw)['exercises'] as List;
  firstWorkout(raw)['exercises'] = exercises.reversed.toList();
  return CoachTrainingProposal.fromJson(raw)!.toTrainingPlan(id: 'timer-plan');
}

void main() {
  test('pause and resume follow the wall clock, not ticks', () {
    var time = Duration.zero;
    final controller = TrainingSessionController(
      plan: _plan(),
      monotonicNow: () => time,
      autoTick: false,
    );
    addTearDown(controller.dispose);
    expect(controller.isRunning, isFalse);
    expect(controller.remaining, const Duration(seconds: 40));
    controller.start();
    time += const Duration(milliseconds: 12345);
    // One tick (or none) accounts for the entire interval.
    controller.tick();
    expect(controller.remaining, const Duration(milliseconds: 27655));
    controller.pause();
    time += const Duration(hours: 2);
    controller.tick();
    expect(controller.remaining, const Duration(milliseconds: 27655));
    controller.startActiveSet();
    expect(
      controller.getReadyRemaining,
      Duration.zero,
      reason: 'resuming a started set has no lead-in',
    );
    time += const Duration(seconds: 2);
    expect(controller.remaining, const Duration(milliseconds: 25655));
    expect(controller.completedSetCount, 0);
  });

  test('a late callback completes at the deadline and runs the rest from '
      'there', () {
    var time = Duration.zero;
    final controller = TrainingSessionController(
      plan: _plan(),
      monotonicNow: () => time,
      autoTick: false,
    );
    addTearDown(controller.dispose);
    controller.start();
    final deadline = controller.phaseEndsAt!;
    time += const Duration(seconds: 50);
    controller.tick();
    expect(controller.completedSetCount, 1);
    expect(controller.actualSets.single.completedAt, deadline);
    expect(controller.phase, TrainingSessionPhase.rest);
    expect(controller.remaining, const Duration(seconds: 5));
    time += const Duration(days: 1);
    controller.tick();
    expect(controller.phase, TrainingSessionPhase.exercise);
    expect(controller.setIndex, 1);
    expect(controller.remaining, const Duration(seconds: 40));
    expect(controller.isRunning, isFalse, reason: 'an unseen rest end waits');
  });

  test(
    'reboot restores a paused snapshot without depending on the library',
    () {
      var time = Duration.zero;
      final controller = TrainingSessionController(
        plan: _plan(),
        monotonicNow: () => time,
        autoTick: false,
      );
      controller.skipActiveSet();
      controller.start();
      time += const Duration(milliseconds: 12750);
      controller.pause();
      final serialized = jsonEncode(controller.snapshot().toJson());
      controller.dispose();
      time += const Duration(days: 7);
      final restored = TrainingSessionController.fromSnapshot(
        TrainingSessionSnapshot.fromJson(
          jsonDecode(serialized) as Map<dynamic, dynamic>,
        ),
        monotonicNow: () => time,
        autoTick: false,
      );
      addTearDown(restored.dispose);
      expect(restored.plan.id, 'timer-plan');
      expect(restored.exercise.name, 'Easy march');
      expect(restored.setIndex, 1);
      expect(restored.skippedSets, hasLength(1));
      expect(restored.completedSetCount, 0);
      expect(restored.remaining, const Duration(milliseconds: 27250));
      expect(restored.isRunning, isFalse);
      time += const Duration(minutes: 5);
      restored.tick();
      expect(restored.remaining, const Duration(milliseconds: 27250));
      restored.start();
      time += const Duration(milliseconds: 250);
      expect(restored.remaining, const Duration(seconds: 27));
    },
  );

  test('a restart keeps a running rest and its deadline', () {
    var now = DateTime.utc(2026, 10, 3, 18);
    withClock(Clock(() => now), () {
      final controller = TrainingSessionController(
        plan: _plan(),
        autoTick: false,
      )..start();
      now = now.add(const Duration(seconds: 40));
      controller.tick();
      final serialized = jsonEncode(controller.snapshot().toJson());
      controller.dispose();
      now = now.add(const Duration(seconds: 6));
      final restored = TrainingSessionController.fromSnapshot(
        TrainingSessionSnapshot.fromJson(
          jsonDecode(serialized) as Map<dynamic, dynamic>,
        ),
        autoTick: false,
      );
      addTearDown(restored.dispose);
      expect(restored.phase, TrainingSessionPhase.rest);
      expect(restored.isRunning, isTrue);
      expect(restored.remaining, const Duration(seconds: 9));
    });
  });

  test('undo removes later progress; a skip is never a completion', () {
    final controller = TrainingSessionController(
      plan: _plan(),
      autoTick: false,
    );
    addTearDown(controller.dispose);
    controller.nextExercise();
    expect(controller.exerciseIndex, 1);
    expect(controller.skippedSets, hasLength(2));
    expect(controller.progress, 0);
    controller.completeActiveSet();
    expect(controller.completedSetCount, 1);
    controller.undoLastCompleted();
    expect(controller.exerciseIndex, 1);
    expect(controller.setIndex, 0);
    expect(controller.completedSets, isEmpty);
    expect(controller.skippedSets, hasLength(2));
    expect(controller.isRunning, isFalse);
  });

  test('every real transition remains recoverable', () {
    var time = Duration.zero;
    final random = Random(20260908);
    final controller = TrainingSessionController(
      plan: _plan(),
      monotonicNow: () => time,
      autoTick: false,
    );
    addTearDown(controller.dispose);
    final actions = [
      controller.start,
      controller.pause,
      controller.tick,
      controller.startActiveSet,
      controller.completeActiveSet,
      controller.completeCurrentSet,
      controller.continueAfterRest,
      controller.skipActiveSet,
      controller.nextExercise,
      controller.undoLastCompleted,
      controller.completeRemainingAsPlanned,
      controller.reopenTrailingSkips,
      () => controller.adjustRest(const Duration(seconds: -15)),
      () => controller.adjustRest(const Duration(seconds: 15)),
    ];
    for (var step = 0; step < 500; step++) {
      time += Duration(milliseconds: random.nextInt(60000));
      actions[random.nextInt(actions.length)]();
      final encoded = controller.snapshot().toJson();
      final decoded = TrainingSessionSnapshot.fromJson(
        jsonDecode(jsonEncode(encoded)) as Map<dynamic, dynamic>,
      );
      expect(decoded.toJson(), encoded, reason: 'transition $step');
      expect(controller.progress, inInclusiveRange(0, 1));
      expect(
        decoded.completedSets.toSet().intersection(decoded.skippedSets.toSet()),
        isEmpty,
      );
    }
  });

  test(
    'tampered recovery cannot claim out-of-range or contradictory progress',
    () {
      final controller = TrainingSessionController(
        plan: _plan(),
        autoTick: false,
      );
      addTearDown(controller.dispose);
      final invalid = <String, Object?>{
        'status': 'running',
        'workout_index': -1,
        'exercise_index': 20,
        'set_index': 2,
        'phase': 'complete',
        'remaining_milliseconds': 40001,
        'completed_sets': [
          {'exercise_index': 0, 'set_index': 0},
        ],
      };
      for (final entry in invalid.entries) {
        final raw = controller.snapshot().toJson()..[entry.key] = entry.value;
        expect(
          () => TrainingSessionSnapshot.fromJson(raw),
          throwsFormatException,
          reason: entry.key,
        );
      }
    },
  );
}
