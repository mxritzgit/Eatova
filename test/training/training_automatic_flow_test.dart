import 'package:eatova/src/models/coach_training_proposal.dart';
import 'package:eatova/src/models/training_plan.dart';
import 'package:eatova/src/models/training_session.dart';
import 'package:eatova/src/services/training_session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'training_timer_fixtures.dart';

void main() {
  late TimerTestClock clock;
  late TrainingSessionController session;

  void useExercises(List<TrainingExercise> exercises) {
    session.dispose();
    session = TrainingSessionController(
      plan: TrainingPlan(
        id: 'automatic_timer',
        proposal: CoachTrainingProposal(
          title: 'Automatic intervals',
          workouts: [TrainingWorkout(title: 'Intervals', exercises: exercises)],
        ),
      ),
      monotonicNow: clock.now,
      autoTick: false,
    );
  }

  void elapse(Duration duration) {
    clock.elapse(duration);
    session.tick();
  }

  setUp(() {
    clock = TimerTestClock();
    session = TrainingSessionController(
      plan: timerPlan(),
      monotonicNow: clock.now,
      autoTick: false,
    );
  });
  tearDown(() => session.dispose());

  test(
    'one start automatically completes work, rest, and the next timed set',
    () {
      session.start();
      elapse(const Duration(seconds: 30));
      expect(session.phase, TrainingSessionPhase.rest);
      expect(session.completedSetCount, 1);
      expect(session.isRunning, isTrue);
      expect(session.remaining, const Duration(seconds: 15));

      elapse(const Duration(seconds: 15));
      expect(session.phase, TrainingSessionPhase.exercise);
      expect(session.setIndex, 1);
      expect(session.remaining, const Duration(seconds: 30));
      expect(session.isRunning, isTrue);

      elapse(const Duration(seconds: 30));
      expect(session.exerciseIndex, 1);
      expect(session.exercise.isTimed, isFalse);
      expect(session.isRunning, isFalse);
      expect(session.completedSetCount, 2);
      elapse(const Duration(days: 1));
      expect(session.completedSetCount, 2);
    },
  );

  test('delayed callbacks advance once and never consume an unseen phase', () {
    session.start();
    elapse(const Duration(hours: 8));
    expect(session.phase, TrainingSessionPhase.rest);
    expect(session.completedSetCount, 1);
    expect(session.remaining, const Duration(seconds: 15));
    for (var i = 0; i < 10; i++) {
      session.tick();
    }
    expect(session.phase, TrainingSessionPhase.rest);
    expect(session.remaining, const Duration(seconds: 15));
    elapse(const Duration(seconds: 17));
    expect(session.setIndex, 1);
    expect(session.remaining, const Duration(seconds: 30));
    elapse(const Duration(milliseconds: 1234));
    expect(session.remaining, const Duration(milliseconds: 28766));
  });

  test('zero-rest timed exercises continue through final set into review', () {
    useExercises([
      TrainingExercise(
        name: 'Hold',
        sets: 2,
        durationSeconds: 10,
        restSeconds: 0,
      ),
      TrainingExercise(
        name: 'Reach',
        sets: 1,
        durationSeconds: 20,
        restSeconds: 15,
      ),
    ]);
    session.start();
    elapse(const Duration(seconds: 10));
    expect(session.setIndex, 1);
    expect(session.isRunning, isTrue);
    elapse(const Duration(seconds: 10));
    expect(session.exerciseIndex, 1);
    expect(session.isRunning, isTrue);
    expect(session.remaining, const Duration(seconds: 20));
    elapse(const Duration(seconds: 20));
    expect(session.phase, TrainingSessionPhase.review);
    expect(session.isRunning, isFalse);
    expect(session.progress, 1);
    expect(session.skippedSets, isEmpty);
    elapse(const Duration(days: 1));
    expect(session.completedSetCount, 3);
    session.previousSet();
    expect(session.completedSetCount, 2);
    expect(session.isRunning, isFalse);
    expect(session.remaining, const Duration(seconds: 20));
  });

  test(
    'manually completed reps start rest, next reps still need completion',
    () {
      useExercises([
        TrainingExercise(name: 'Squats', sets: 2, reps: 12, restSeconds: 10),
        TrainingExercise(
          name: 'Hold',
          sets: 1,
          durationSeconds: 20,
          restSeconds: 0,
        ),
      ]);
      session.start();
      elapse(const Duration(hours: 8));
      expect(session.completedSetCount, 0);
      session.completeCurrentSet();
      expect(session.phase, TrainingSessionPhase.rest);
      expect(session.isRunning, isTrue);
      elapse(const Duration(seconds: 10));
      expect(session.setIndex, 1);
      expect(session.isRunning, isFalse);
      session.completeCurrentSet();
      expect(session.completedSetCount, 1);
      session.start();
      session.completeCurrentSet();
      expect(session.exerciseIndex, 1);
      expect(session.isRunning, isTrue);
      elapse(const Duration(seconds: 20));
      expect(session.completedSetCount, 3);
      expect(session.phase, TrainingSessionPhase.review);
    },
  );

  test(
    'pause at expiry never completes or advances until deliberate confirmation',
    () {
      session.start();
      clock.elapse(const Duration(seconds: 30));
      session.pause();
      elapse(const Duration(days: 1));
      expect(session.remaining, Duration.zero);
      expect(session.completedSetCount, 0);
      expect(session.phase, TrainingSessionPhase.exercise);
      session.completeCurrentSet();
      expect(session.phase, TrainingSessionPhase.rest);
      expect(session.isRunning, isTrue);
    },
  );

  test(
    'visibility is checked before starting and before any timed completion',
    () {
      var visible = false;
      final gated = TrainingSessionController(
        plan: timerPlan(),
        monotonicNow: clock.now,
        canRun: () => visible,
        autoTick: false,
      );
      addTearDown(gated.dispose);
      gated.start();
      expect(gated.isRunning, isFalse);
      visible = true;
      gated.start();
      clock.elapse(const Duration(seconds: 30));
      visible = false;
      gated.tick();
      expect(gated.isRunning, isFalse);
      expect(gated.completedSets, isEmpty);
      expect(gated.phase, TrainingSessionPhase.exercise);
      visible = true;
      gated.tick();
      expect(gated.completedSets, isEmpty);
      expect(gated.remaining, Duration.zero);
    },
  );

  test('adjustment, reset and navigation interrupt automatic progression', () {
    session.start();
    elapse(const Duration(seconds: 30));
    session.forward10Seconds();
    expect(session.remaining, const Duration(seconds: 5));
    expect(session.isRunning, isFalse);
    elapse(const Duration(days: 1));
    expect(session.setIndex, 0);
    session.resetPhase();
    expect(session.remaining, const Duration(seconds: 15));
    session.start();
    session.continueAfterRest();
    expect(session.setIndex, 1);
    expect(session.isRunning, isFalse);
    expect(session.completedSetCount, 1);
    session.start();
    clock.elapse(const Duration(seconds: 30));
    session.nextSet();
    expect(session.completedSetCount, 1);
    expect(session.skippedSets.length, 1);
    session.previousSet();
    expect(session.exerciseIndex, 0);
    expect(session.setIndex, 1);
    expect(session.skippedSets, isEmpty);
    expect(session.isRunning, isFalse);
  });

  test(
    'automatic transition notifies once with a valid paused recovery snapshot',
    () {
      final checkpoints = <TrainingSessionSnapshot>[];
      session.start();
      session.addListener(() => checkpoints.add(session.snapshot()));
      elapse(const Duration(seconds: 30));
      expect(checkpoints.length, 1);
      final checkpoint = TrainingSessionSnapshot.fromJson(
        checkpoints.single.toJson(),
      );
      expect(checkpoint.phase, TrainingSessionPhase.rest);
      expect(checkpoint.completedSets.length, 1);
      final recovered = TrainingSessionController.fromSnapshot(
        checkpoint,
        monotonicNow: clock.now,
        autoTick: false,
      );
      addTearDown(recovered.dispose);
      clock.elapse(const Duration(days: 1));
      recovered.tick();
      expect(recovered.isRunning, isFalse);
      expect(recovered.remaining, const Duration(seconds: 15));
      recovered.start();
      clock.elapse(const Duration(seconds: 15));
      recovered.tick();
      expect(recovered.setIndex, 1);
      expect(recovered.isRunning, isTrue);
      expect(recovered.remaining, const Duration(seconds: 30));
    },
  );
}
