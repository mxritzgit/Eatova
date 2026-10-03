import 'package:clock/clock.dart';
import 'package:eatova/src/models/coach_training_proposal.dart';
import 'package:eatova/src/models/training_plan.dart';
import 'package:eatova/src/models/training_session.dart';
import 'package:eatova/src/services/training_session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'training_timer_fixtures.dart';

// Automatic progression on wall-clock deadlines (spec A1/A4, 2026-10-03).
// Supersedes "a late tick ends only the visible phase and the next phase
// gets its full duration": a passed deadline now completes the set AT the
// deadline, its rest runs from there, and only a seen rest end starts the
// next timed set. Repetition sets complete with one ✓.

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

  test('one ▶ runs the timed set, its rest and the next timed set while the '
      'player is shown', () {
    session.startActiveSet();
    elapse(trainingGetReady + const Duration(seconds: 30));
    expect(session.phase, TrainingSessionPhase.rest);
    expect(session.completedSetCount, 1);
    expect(session.isRunning, isTrue);
    expect(session.remaining, const Duration(seconds: 15));

    elapse(const Duration(seconds: 15));
    expect(session.phase, TrainingSessionPhase.exercise);
    expect(session.setIndex, 1);
    expect(session.remaining, const Duration(seconds: 30));
    expect(session.isRunning, isTrue, reason: 'a seen rest end chains');

    elapse(const Duration(seconds: 30));
    expect(
      session.phase,
      TrainingSessionPhase.rest,
      reason: 'between exercises',
    );
    expect(session.activeSet?.exerciseIndex, 1);
    elapse(const Duration(seconds: 15));
    expect(session.exerciseIndex, 1);
    expect(session.exercise.isTimed, isFalse);
    expect(session.isRunning, isFalse);
    expect(session.completedSetCount, 2);
    elapse(const Duration(days: 1));
    expect(session.completedSetCount, 2, reason: 'repetitions need ✓');
  });

  test('a late tick completes the set at its deadline; an unseen rest end '
      'leaves the next timed set waiting', () {
    session.start();
    final deadline = session.phaseEndsAt!;
    elapse(const Duration(hours: 8));
    expect(session.completedSetCount, 1);
    expect(session.actualSets.single.completedAt, deadline);
    expect(session.phase, TrainingSessionPhase.exercise);
    expect(session.setIndex, 1);
    expect(session.isRunning, isFalse);
    expect(session.remaining, const Duration(seconds: 30));
    for (var i = 0; i < 10; i++) {
      session.tick();
    }
    expect(session.completedSetCount, 1, reason: 'one unseen completion');
  });

  test('zero-rest timed exercises chain into review while seen', () {
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
    session.undoLastCompleted();
    expect(session.completedSetCount, 2);
    expect(session.isRunning, isFalse);
    expect(session.remaining, const Duration(seconds: 20));
  });

  test('✓ completes repetitions at once and starts their rest; a following '
      'timed set waits for ▶', () {
    useExercises([
      TrainingExercise(name: 'Squats', sets: 2, reps: 12, restSeconds: 10),
      TrainingExercise(
        name: 'Hold',
        sets: 1,
        durationSeconds: 20,
        restSeconds: 0,
      ),
    ]);
    session.completeActiveSet();
    expect(session.phase, TrainingSessionPhase.rest);
    expect(session.isRunning, isTrue);
    elapse(const Duration(seconds: 10));
    expect(session.setIndex, 1);
    expect(session.isRunning, isFalse);
    session.completeActiveSet();
    expect(session.completedSetCount, 2);
    expect(
      session.phase,
      TrainingSessionPhase.rest,
      reason: 'between exercises',
    );
    expect(session.activeSet?.exerciseIndex, 1);
    session.continueAfterRest();
    expect(session.isRunning, isFalse, reason: 'a skipped rest never chains');
    session.startActiveSet();
    elapse(trainingGetReady + const Duration(seconds: 20));
    expect(session.completedSetCount, 3);
    expect(session.phase, TrainingSessionPhase.review);
  });

  test('a pause at expiry waits at zero for ✓', () {
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
  });

  test('a hidden player applies nothing until it is shown again', () {
    var visible = false;
    final gated = TrainingSessionController(
      plan: timerPlan(),
      monotonicNow: clock.now,
      canRun: () => visible,
      autoTick: false,
    );
    addTearDown(gated.dispose);
    gated.start();
    expect(gated.isRunning, isFalse, reason: 'start() needs the player shown');
    visible = true;
    gated.start();
    clock.elapse(const Duration(seconds: 30));
    visible = false;
    gated.tick();
    expect(gated.isRunning, isTrue, reason: 'time keeps running');
    expect(gated.completedSets, isEmpty);
    visible = true;
    gated.tick();
    expect(gated.completedSets, hasLength(1));
    expect(gated.phase, TrainingSessionPhase.rest);
  });

  test('a skip, an undo and a pause stop the automatic chain', () {
    session.startActiveSet();
    elapse(trainingGetReady + const Duration(seconds: 30));
    expect(session.phase, TrainingSessionPhase.rest);
    session.pause();
    elapse(const Duration(days: 1));
    expect(session.phase, TrainingSessionPhase.rest);
    session.continueAfterRest();
    expect(session.setIndex, 1);
    expect(session.isRunning, isFalse);
    session.skipActiveSet();
    expect(session.completedSetCount, 1);
    expect(session.skippedSets, hasLength(1));
    session.undoLastCompleted();
    expect(session.exerciseIndex, 0);
    expect(session.setIndex, 0);
    expect(session.skippedSets, isEmpty);
    expect(session.isRunning, isFalse);
  });

  test('an automatic transition notifies once and checkpoints a running rest '
      'that a recovery continues', () {
    var now = DateTime.utc(2026, 10, 3, 18);
    withClock(Clock(() => now), () {
      final wall = TrainingSessionController(
        plan: timerPlan(),
        autoTick: false,
      );
      addTearDown(wall.dispose);
      final checkpoints = <TrainingSessionSnapshot>[];
      wall.start();
      wall.addListener(() => checkpoints.add(wall.snapshot()));
      now = now.add(const Duration(seconds: 30));
      wall.tick();
      expect(checkpoints, hasLength(1));
      final checkpoint = TrainingSessionSnapshot.fromJson(
        checkpoints.single.toJson(),
      );
      expect(checkpoint.phase, TrainingSessionPhase.rest);
      expect(checkpoint.phaseEndsAt, now.add(const Duration(seconds: 15)));
      now = now.add(const Duration(seconds: 5));
      final recovered = TrainingSessionController.fromSnapshot(
        checkpoint,
        autoTick: false,
      );
      addTearDown(recovered.dispose);
      expect(recovered.isRunning, isTrue);
      expect(recovered.remaining, const Duration(seconds: 10));
      now = now.add(const Duration(seconds: 10));
      recovered.tick();
      expect(recovered.setIndex, 1);
      expect(recovered.isRunning, isTrue, reason: 'seen in the foreground');
      expect(recovered.remaining, const Duration(seconds: 30));
    });
  });
}
