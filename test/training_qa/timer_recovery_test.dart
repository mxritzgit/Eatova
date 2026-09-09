import 'dart:convert';
import 'dart:math';

import 'package:eatova/src/models/coach_training_proposal.dart';
import 'package:eatova/src/models/training_plan.dart';
import 'package:eatova/src/models/training_session.dart';
import 'package:eatova/src/services/training_session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures.dart';

TrainingPlan _plan() {
  final raw = trainingDraft();
  final exercises = firstWorkout(raw)['exercises'] as List;
  firstWorkout(raw)['exercises'] = exercises.reversed.toList();
  return CoachTrainingProposal.fromJson(raw)!.toTrainingPlan(id: 'timer-plan');
}

void main() {
  test('pause, rewind, fast-forward and reset use elapsed time, not ticks', () {
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
    // One tick must account for the entire interval.
    controller.tick();
    expect(controller.remaining, const Duration(milliseconds: 27655));
    controller.pause();
    time += const Duration(hours: 2);
    controller.tick();
    expect(controller.remaining, const Duration(milliseconds: 27655));
    controller.rewind10Seconds();
    expect(controller.remaining, const Duration(milliseconds: 37655));
    controller.rewind10Seconds();
    expect(controller.remaining, const Duration(seconds: 40));
    controller.forward10Seconds();
    expect(controller.remaining, const Duration(seconds: 30));
    controller.start();
    time += const Duration(seconds: 2);
    controller.resetPhase();
    expect(controller.remaining, const Duration(seconds: 40));
    expect(controller.isRunning, isFalse);
    expect(controller.completedSetCount, 0);
  });

  test(
    'automatic rest and sets start with full duration after a late callback',
    () {
      var time = Duration.zero;
      final controller = TrainingSessionController(
        plan: _plan(),
        monotonicNow: () => time,
        autoTick: false,
      );
      addTearDown(controller.dispose);
      controller.start();
      time += const Duration(days: 1);
      controller.tick();
      expect(controller.exerciseIndex, 0);
      expect(controller.setIndex, 0);
      expect(controller.phase, TrainingSessionPhase.rest);
      expect(controller.completedSetCount, 1);
      expect(controller.remaining, const Duration(seconds: 15));
      expect(controller.isRunning, isTrue);
      time += const Duration(seconds: 16);
      controller.tick();
      expect(controller.phase, TrainingSessionPhase.exercise);
      expect(controller.setIndex, 1);
      expect(controller.remaining, const Duration(seconds: 40));
      expect(controller.isRunning, isTrue);
    },
  );

  test(
    'reboot restores paused full snapshot without depending on the library',
    () {
      var time = Duration.zero;
      final controller = TrainingSessionController(
        plan: _plan(),
        monotonicNow: () => time,
        autoTick: false,
      );
      controller.nextSet(); // skip first set
      controller.start();
      time += const Duration(milliseconds: 12750);
      controller.pause();
      final serialized = jsonEncode(controller.snapshot().toJson());
      controller.dispose();
      time += const Duration(days: 7);
      final restored = TrainingSessionController.fromSnapshot(
        TrainingSessionSnapshot.fromJson(jsonDecode(serialized)),
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

  test(
    'previous exercise removes later progress; skip is never completion',
    () {
      final controller = TrainingSessionController(
        plan: _plan(),
        autoTick: false,
      );
      addTearDown(controller.dispose);
      controller.nextExercise();
      expect(controller.exerciseIndex, 1);
      expect(controller.skippedSets, hasLength(2));
      expect(controller.progress, 0);
      controller.start();
      controller.completeCurrentSet();
      expect(controller.completedSetCount, 1);
      controller.previousExercise();
      expect(controller.exerciseIndex, 0);
      expect(controller.setIndex, 0);
      expect(controller.completedSets, isEmpty);
      expect(controller.skippedSets, isEmpty);
      expect(controller.isRunning, isFalse);
      expect(controller.remaining, const Duration(seconds: 40));
    },
  );

  test('every real navigation transition remains recoverable', () {
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
      controller.nextSet,
      controller.nextExercise,
      controller.previousSet,
      controller.previousExercise,
      controller.completeCurrentSet,
      controller.continueAfterRest,
      controller.forward10Seconds,
      controller.rewind10Seconds,
      controller.resetPhase,
    ];
    for (var step = 0; step < 500; step++) {
      time += Duration(milliseconds: random.nextInt(60000));
      actions[random.nextInt(actions.length)]();
      final encoded = controller.snapshot().toJson();
      final decoded = TrainingSessionSnapshot.fromJson(
        jsonDecode(jsonEncode(encoded)),
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
