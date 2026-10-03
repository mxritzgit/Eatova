import 'dart:convert';
import 'dart:math';

import 'package:clock/clock.dart';
import 'package:eatova/src/models/coach_training_proposal.dart';
import 'package:eatova/src/models/training_plan.dart';
import 'package:eatova/src/models/training_session.dart';
import 'package:eatova/src/services/training_session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'training_timer_fixtures.dart';

// The list player (spec A1/A4, 2026-10-03): one tap per set, wall-clock
// deadlines, rest after every completed set except the workout's last.
// Supersedes the Start gate for repetition sets and "recovery always paused".

const _bench = 0;
const _plank = 1;
const _row = 2;

TrainingSetReference _set(int exercise, int set) =>
    TrainingSetReference(exerciseIndex: exercise, setIndex: set);

TrainingPlan _plan() => TrainingPlan(
  id: 'controller_plan',
  proposal: CoachTrainingProposal(
    title: 'Strength',
    workouts: [
      TrainingWorkout(
        title: 'Day A',
        exercises: [
          TrainingExercise(name: 'Bench', sets: 3, reps: 8, restSeconds: 90),
          TrainingExercise(
            name: 'Plank',
            sets: 2,
            durationSeconds: 30,
            restSeconds: 15,
          ),
          TrainingExercise(name: 'Row', sets: 2, reps: 10, restSeconds: 0),
        ],
      ),
    ],
  ),
);

/// Runs [body] under a wall clock the test moves with `wall.now = ...`.
final class _Wall {
  _Wall([DateTime? start]) : now = start ?? DateTime.utc(2026, 10, 3, 18);
  DateTime now;
  void elapse(Duration duration) => now = now.add(duration);
  T run<T>(T Function() body) => withClock(Clock(() => now), body);
}

TrainingSessionController _controller({
  TrainingLastWeight? lastWeight,
  bool Function()? canRun,
}) => TrainingSessionController(
  plan: _plan(),
  autoTick: false,
  lastWeight: lastWeight,
  canRun: canRun,
);

TrainingSessionController _restore(TrainingSessionSnapshot snapshot) =>
    TrainingSessionController.fromSnapshot(
      TrainingSessionSnapshot.fromJson(
        jsonDecode(jsonEncode(snapshot.toJson())) as Map,
      ),
      autoTick: false,
    );

void main() {
  group('one tap per set', () {
    test('✓ completes a repetition set without start()', () {
      final wall = _Wall();
      wall.run(() {
        final session = _controller();
        addTearDown(session.dispose);
        expect(session.activeSet, _set(_bench, 0));
        session.completeActiveSet();
        expect(session.completedSets, [_set(_bench, 0)]);
        expect(session.actualSets.single.reps, 8);
        expect(session.phase, TrainingSessionPhase.rest);
        expect(session.activeSet, _set(_bench, 1));
      });
    });

    test('✓ on the next set during a rest ends the rest early', () {
      final wall = _Wall();
      wall.run(() {
        final session = _controller();
        addTearDown(session.dispose);
        session.completeActiveSet();
        wall.elapse(const Duration(seconds: 20));
        session.completeActiveSet();
        expect(session.completedSets, [_set(_bench, 0), _set(_bench, 1)]);
        expect(session.phase, TrainingSessionPhase.rest);
        expect(session.remaining, const Duration(seconds: 90));
      });
    });

    test('start() and completeCurrentSet() still complete fixtures', () {
      final wall = _Wall();
      wall.run(() {
        final session = TrainingSessionController(
          plan: timerPlan(),
          workoutIndex: 1,
          autoTick: false,
        );
        addTearDown(session.dispose);
        session.setCurrentActual(reps: 6, weightKg: 12.5);
        session.start();
        session.completeCurrentSet();
        expect(session.phase, TrainingSessionPhase.review);
        final entry = session.completion();
        expect(entry.snapshot.actualSets.single.reps, 6);
        expect(entry.snapshot.actualSets.single.weightKg, 12.5);
      });
    });

    test('a timed set needs ▶ (or zero) before ✓; Done early completes it', () {
      final wall = _Wall();
      wall.run(() {
        final session = _controller();
        addTearDown(session.dispose);
        session.nextExercise();
        expect(session.activeSet, _set(_plank, 0));
        session.completeActiveSet();
        session.completeCurrentSet();
        expect(session.completedSets, isEmpty);
        session.startActiveSet();
        expect(session.getReadyRemaining, const Duration(seconds: 3));
        wall.elapse(const Duration(seconds: 13));
        expect(session.getReadyRemaining, Duration.zero);
        expect(session.remaining, const Duration(seconds: 20));
        session.completeCurrentSet();
        expect(session.completedSets, isEmpty, reason: 'not at zero yet');
        session.completeActiveSet();
        expect(session.completedSets, [_set(_plank, 0)]);
        expect(session.actualSets.single.reps, isNull);
        expect(session.phase, TrainingSessionPhase.rest);
      });
    });
  });

  group('rest between exercises', () {
    test(
      'rest follows an exercise\'s last set, with that exercise\'s rest',
      () {
        final wall = _Wall();
        wall.run(() {
          final session = _controller();
          addTearDown(session.dispose);
          for (var s = 0; s < 3; s++) {
            session.completeActiveSet();
          }
          expect(session.phase, TrainingSessionPhase.rest);
          expect(session.exerciseIndex, _bench, reason: 'cursor stays put');
          expect(session.setIndex, 2);
          expect(session.remaining, const Duration(seconds: 90));
          expect(session.activeSet, _set(_plank, 0));
          final restored = _restore(session.snapshot());
          addTearDown(restored.dispose);
          expect(restored.phase, TrainingSessionPhase.rest);
          expect(restored.isRunning, isTrue);
        });
      },
    );

    test('no rest after the workout\'s final set; a rest of 0 advances', () {
      final wall = _Wall();
      wall.run(() {
        final session = _controller();
        addTearDown(session.dispose);
        session.nextExercise();
        session.nextExercise();
        expect(session.activeSet, _set(_row, 0));
        session.completeActiveSet();
        expect(session.phase, TrainingSessionPhase.exercise);
        expect(session.activeSet, _set(_row, 1));
        session.completeActiveSet();
        expect(session.phase, TrainingSessionPhase.review);
        expect(session.isRunning, isFalse);
      });
    });
  });

  group('weight prefill (spec A2)', () {
    // Last time: 60 / 70 / 80 kg for Bench.
    double? lastTime(int exercise, int set) =>
        exercise == _bench ? 60.0 + 10 * set : null;

    test('without changes every set shows Last time set k', () {
      final wall = _Wall();
      wall.run(() {
        final session = _controller(lastWeight: lastTime);
        addTearDown(session.dispose);
        expect(session.actualWeightKg, 60);
        expect(session.shownWeight(_set(_bench, 1)), 70);
        expect(session.shownWeight(_set(_bench, 2)), 80);
        session.completeActiveSet();
        expect(session.actualWeightKg, 70, reason: 'next set seeded in rest');
        session.completeActiveSet();
        session.completeActiveSet();
        expect(session.actualSets.map((a) => a.weightKg), [
          60,
          70,
          80,
        ], reason: 'a ramp is never flattened to 60/60/60');
      });
    });

    test('a changed weight carries forward within the exercise', () {
      final wall = _Wall();
      wall.run(() {
        final session = _controller(lastWeight: lastTime);
        addTearDown(session.dispose);
        session.setCurrentActual(reps: 8, weightKg: 62.5);
        expect(session.shownWeight(_set(_bench, 1)), 62.5);
        session.completeActiveSet();
        expect(session.actualWeightKg, 62.5);
        session.setCurrentActual(reps: 8, weightKg: 65);
        session.completeActiveSet();
        expect(session.actualWeightKg, 65);
        expect(session.shownWeight(_set(_plank, 0)), isNull);
      });
    });

    test('no history means no weight and planned reps', () {
      final wall = _Wall();
      wall.run(() {
        final session = _controller();
        addTearDown(session.dispose);
        expect(session.actualWeightKg, isNull);
        expect(session.actualReps, 8);
        expect(session.shownReps(_set(_bench, 2)), 8);
        expect(session.shownReps(_set(_plank, 0)), isNull);
      });
    });

    test('complete remaining as planned uses the shown values', () {
      final wall = _Wall();
      wall.run(() {
        final session = _controller(lastWeight: lastTime);
        addTearDown(session.dispose);
        session.setCurrentActual(reps: 7, weightKg: 62.5);
        session.completeRemainingAsPlanned();
        expect(session.completedSets, [
          _set(_bench, 0),
          _set(_bench, 1),
          _set(_bench, 2),
        ]);
        expect(session.actualSets.map((a) => (a.reps, a.weightKg)), [
          (7, 62.5),
          (8, 62.5),
          (8, 62.5),
        ]);
        expect(session.phase, TrainingSessionPhase.rest);
        expect(session.activeSet, _set(_plank, 0));
      });
    });

    test('undo rewinds to the last completed set, keeps its values and '
        'ends its rest', () {
      final wall = _Wall();
      wall.run(() {
        final session = _controller();
        addTearDown(session.dispose);
        session.setCurrentActual(reps: 6, weightKg: 40);
        session.completeActiveSet();
        expect(session.isRunning, isTrue);
        session.undoLastCompleted();
        expect(session.completedSets, isEmpty);
        expect(session.phase, TrainingSessionPhase.exercise);
        expect(session.isRunning, isFalse);
        expect(session.phaseEndsAt, isNull);
        expect(session.actualReps, 6);
        expect(session.actualWeightKg, 40);
      });
    });

    test('undo also reopens the sets skipped after it', () {
      final wall = _Wall();
      wall.run(() {
        final session = _controller();
        addTearDown(session.dispose);
        session.completeActiveSet();
        session.skipActiveSet();
        expect(session.skippedSets, [_set(_bench, 1)]);
        session.undoLastCompleted();
        expect(session.skippedSets, isEmpty);
        expect(session.activeSet, _set(_bench, 0));
      });
    });
  });

  group('wall-clock deadlines (spec A4)', () {
    test('rest carries phaseEndsAt; remaining comes from clock.now()', () {
      final wall = _Wall();
      wall.run(() {
        final session = _controller();
        addTearDown(session.dispose);
        final completedAt = wall.now;
        session.completeActiveSet();
        expect(
          session.phaseEndsAt,
          completedAt.add(const Duration(seconds: 90)),
        );
        expect(session.snapshot().phaseEndsAt, session.phaseEndsAt);
        wall.elapse(const Duration(milliseconds: 12345));
        expect(session.remaining, const Duration(milliseconds: 77655));
        // A backwards clock step clamps instead of breaking validation.
        wall.elapse(const Duration(hours: -3));
        expect(session.remaining, const Duration(seconds: 90));
        expect(
          () => TrainingSessionSnapshot.fromJson(session.snapshot().toJson()),
          returnsNormally,
        );
      });
    });

    test('▶ on a timed set adds a 3 s lead to its deadline', () {
      final wall = _Wall();
      wall.run(() {
        final session = _controller();
        addTearDown(session.dispose);
        session.nextExercise();
        final start = wall.now;
        session.startActiveSet();
        expect(session.phaseEndsAt, start.add(const Duration(seconds: 33)));
        expect(session.remaining, const Duration(seconds: 30));
        wall.elapse(const Duration(seconds: 1));
        expect(session.getReadyRemaining, const Duration(seconds: 2));
      });
    });

    test('±15 s moves the rest deadline within the rest', () {
      final wall = _Wall();
      wall.run(() {
        final session = _controller();
        addTearDown(session.dispose);
        session.completeActiveSet();
        final ends = session.phaseEndsAt!;
        wall.elapse(const Duration(seconds: 30));
        session.adjustRest(const Duration(seconds: 15));
        expect(session.phaseEndsAt, ends.add(const Duration(seconds: 15)));
        session.adjustRest(const Duration(seconds: -15));
        session.adjustRest(const Duration(seconds: -15));
        expect(session.remaining, const Duration(seconds: 45));
        session.adjustRest(const Duration(minutes: 5));
        expect(session.remaining, const Duration(seconds: 90));
        session.adjustRest(const Duration(minutes: -5));
        expect(session.phase, TrainingSessionPhase.exercise);
        expect(session.activeSet, _set(_bench, 1));
      });
    });

    test('catchUp: a timed set past its deadline completes at the deadline, '
        'its rest runs from there and the next timed set waits', () {
      final wall = _Wall();
      wall.run(() {
        final session = _controller();
        addTearDown(session.dispose);
        session.nextExercise();
        session.startActiveSet();
        final deadline = session.phaseEndsAt!;
        wall.elapse(const Duration(minutes: 10));
        session.catchUp(wall.now);
        expect(session.completedSets, [_set(_plank, 0)]);
        expect(session.actualSets.single.completedAt, deadline);
        expect(session.phase, TrainingSessionPhase.exercise);
        expect(session.activeSet, _set(_plank, 1));
        expect(session.isRunning, isFalse, reason: 'unseen rest end waits');
        expect(session.remaining, const Duration(seconds: 30));
        expect(session.completedSetCount, 1, reason: 'one unseen completion');
      });
    });

    test('catchUp inside the rest keeps the rest from the deadline', () {
      final wall = _Wall();
      wall.run(() {
        final session = _controller();
        addTearDown(session.dispose);
        session.nextExercise();
        session.startActiveSet();
        final deadline = session.phaseEndsAt!;
        wall.elapse(const Duration(seconds: 40));
        session.catchUp(wall.now);
        expect(session.phase, TrainingSessionPhase.rest);
        expect(session.phaseEndsAt, deadline.add(const Duration(seconds: 15)));
        expect(session.remaining, const Duration(seconds: 8));
      });
    });

    test(
      'a seen rest end starts the following timed set from the deadline',
      () {
        final wall = _Wall();
        wall.run(() {
          final session = _controller();
          addTearDown(session.dispose);
          session.nextExercise();
          session.startActiveSet();
          wall.elapse(const Duration(seconds: 33));
          session.tick();
          expect(session.phase, TrainingSessionPhase.rest);
          final restEnd = session.phaseEndsAt!;
          wall.elapse(const Duration(seconds: 15, milliseconds: 100));
          session.tick();
          expect(session.activeSet, _set(_plank, 1));
          expect(session.phaseEndsAt, restEnd.add(const Duration(seconds: 30)));
        });
      },
    );

    test('a hidden player never chains into the next timed set', () {
      final wall = _Wall();
      var visible = true;
      wall.run(() {
        final session = _controller(canRun: () => visible);
        addTearDown(session.dispose);
        session.nextExercise();
        session.startActiveSet();
        wall.elapse(const Duration(seconds: 33));
        visible = false;
        session.tick();
        expect(session.completedSets, isEmpty, reason: 'tick waits');
        visible = true;
        wall.elapse(const Duration(seconds: 20));
        session.tick();
        expect(session.completedSets, [_set(_plank, 0)]);
        expect(session.activeSet, _set(_plank, 1));
        expect(session.isRunning, isFalse);
      });
    });

    test('recovery continues a running rest', () {
      final wall = _Wall();
      wall.run(() {
        final session = _controller();
        session.completeActiveSet();
        final checkpoint = session.snapshot();
        session.dispose();
        wall.elapse(const Duration(seconds: 50));
        final restored = _restore(checkpoint);
        addTearDown(restored.dispose);
        expect(restored.phase, TrainingSessionPhase.rest);
        expect(restored.isRunning, isTrue);
        expect(restored.remaining, const Duration(seconds: 40));
      });
    });

    test('recovery after the rest ended opens the next set', () {
      final wall = _Wall();
      wall.run(() {
        final session = _controller();
        session.completeActiveSet();
        final checkpoint = session.snapshot();
        session.dispose();
        wall.elapse(const Duration(minutes: 5));
        final restored = _restore(checkpoint);
        addTearDown(restored.dispose);
        expect(restored.phase, TrainingSessionPhase.exercise);
        expect(restored.activeSet, _set(_bench, 1));
      });
    });

    test('recovery of a timed set past its deadline waits at zero for ✓', () {
      final wall = _Wall();
      wall.run(() {
        final session = _controller();
        session.nextExercise();
        session.startActiveSet();
        final checkpoint = session.snapshot();
        session.dispose();
        wall.elapse(const Duration(hours: 2));
        final restored = _restore(checkpoint);
        addTearDown(restored.dispose);
        expect(restored.completedSets, isEmpty, reason: 'no phantom set');
        expect(restored.isRunning, isFalse);
        expect(restored.remaining, Duration.zero);
        restored.completeActiveSet();
        expect(restored.completedSets, [_set(_plank, 0)]);
      });
    });

    test('pause freezes a running phase and start() resumes it', () {
      final wall = _Wall();
      wall.run(() {
        final session = _controller();
        addTearDown(session.dispose);
        session.completeActiveSet();
        wall.elapse(const Duration(seconds: 10));
        session.pause();
        expect(session.isRunning, isFalse);
        expect(session.snapshot().phaseEndsAt, isNull);
        wall.elapse(const Duration(hours: 1));
        expect(session.remaining, const Duration(seconds: 80));
        session.start();
        wall.elapse(const Duration(seconds: 5));
        expect(session.remaining, const Duration(seconds: 75));
      });
    });

    test('the monotonic seam still drives the deadline', () {
      final time = TimerTestClock();
      final session = TrainingSessionController(
        plan: _plan(),
        monotonicNow: time.now,
        autoTick: false,
      );
      addTearDown(session.dispose);
      session.completeActiveSet();
      time.elapse(const Duration(milliseconds: 12437));
      expect(session.remaining, const Duration(milliseconds: 77563));
    });
  });

  group('times', () {
    test('startedAt is the first ✓ or ▶, not the player opening', () {
      final wall = _Wall();
      wall.run(() {
        final opened = wall.now;
        final session = _controller();
        addTearDown(session.dispose);
        expect(session.hasStarted, isFalse);
        wall.elapse(const Duration(minutes: 12));
        session.completeActiveSet();
        expect(session.startedAt, opened.add(const Duration(minutes: 12)));
        expect(session.hasStarted, isTrue);
        wall.elapse(const Duration(minutes: 1));
        session.completeActiveSet();
        expect(session.startedAt, opened.add(const Duration(minutes: 12)));
      });
    });

    test('a save > 5 min after the last set finishes at the last set', () {
      final wall = _Wall();
      wall.run(() {
        final session = _controller();
        addTearDown(session.dispose);
        session.completeActiveSet();
        final last = wall.now;
        wall.elapse(const Duration(minutes: 4));
        expect(session.completion().finishedAt, wall.now);
        wall.elapse(const Duration(minutes: 2));
        expect(session.completion().finishedAt, last);
      });
    });

    test('completion times stay at or after the start under a backwards '
        'clock', () {
      final wall = _Wall();
      wall.run(() {
        final session = _controller();
        addTearDown(session.dispose);
        session.completeActiveSet();
        final started = session.startedAt;
        wall.elapse(const Duration(hours: -2));
        session.completeActiveSet();
        expect(
          session.actualSets.map((a) => a.completedAt),
          everyElement(isNot(predicate<DateTime>((t) => t.isBefore(started)))),
        );
        expect(
          () => TrainingSessionSnapshot.fromJson(session.snapshot().toJson()),
          returnsNormally,
        );
        final entry = session.completion();
        expect(entry.finishedAt.isBefore(started), isFalse);
      });
    });
  });

  group('skips and the ledger', () {
    test('skips never count as completion and keep a valid prefix', () {
      final wall = _Wall();
      wall.run(() {
        final session = _controller();
        addTearDown(session.dispose);
        session.skipActiveSet();
        session.nextExercise();
        expect(session.skippedSets.length, 3);
        expect(session.progress, 0);
        expect(session.activeSet, _set(_plank, 0));
        session.nextExercise();
        session.nextExercise();
        expect(session.phase, TrainingSessionPhase.review);
        expect(session.completedSetCount, 0);
        session.reopenTrailingSkips();
        expect(session.phase, TrainingSessionPhase.exercise);
        expect(session.activeSet, _set(_bench, 0));
        expect(session.skippedSets, isEmpty);
      });
    });

    test('complete the rest as shown fills only the open sets', () {
      final wall = _Wall();
      wall.run(() {
        final session = _controller();
        addTearDown(session.dispose);
        session.completeActiveSet();
        session.skipActiveSet();
        session.completeOpenSetsAsShown();
        expect(session.phase, TrainingSessionPhase.review);
        expect(session.skippedSets, [_set(_bench, 1)]);
        expect(session.completedSetCount, 6);
        expect(session.completion().snapshot.completedSets.length, 6);
      });
    });

    test('every transition remains a valid, recoverable checkpoint', () {
      final wall = _Wall();
      wall.run(() {
        final random = Random(20261003);
        final session = _controller(lastWeight: (e, s) => 20.0 + s);
        addTearDown(session.dispose);
        final actions = <void Function()>[
          session.completeActiveSet,
          session.completeCurrentSet,
          session.startActiveSet,
          session.start,
          session.pause,
          session.tick,
          () => session.catchUp(wall.now),
          session.continueAfterRest,
          session.skipActiveSet,
          session.nextExercise,
          session.undoLastCompleted,
          session.completeRemainingAsPlanned,
          session.reopenTrailingSkips,
          () => session.adjustRest(const Duration(seconds: 15)),
          () => session.adjustRest(const Duration(seconds: -15)),
          () => session.setCurrentActual(reps: random.nextInt(20), weightKg: 5),
        ];
        for (var step = 0; step < 600; step++) {
          wall.elapse(Duration(milliseconds: random.nextInt(60000) - 5000));
          actions[random.nextInt(actions.length)]();
          final encoded = session.snapshot().toJson();
          final decoded = TrainingSessionSnapshot.fromJson(
            jsonDecode(jsonEncode(encoded)) as Map,
          );
          expect(decoded.toJson(), encoded, reason: 'transition $step');
          expect(
            decoded.completedSets.toSet().intersection(
              decoded.skippedSets.toSet(),
            ),
            isEmpty,
          );
          if (session.phase == TrainingSessionPhase.review &&
              session.completedSetCount > 0) {
            expect(() => session.completion(), returnsNormally);
          }
        }
      });
    });
  });

  group('notifications to the player', () {
    test('ticks notify only when a shown second changes', () {
      final time = TimerTestClock();
      final session = TrainingSessionController(
        plan: _plan(),
        monotonicNow: time.now,
        autoTick: false,
      );
      addTearDown(session.dispose);
      session.completeActiveSet();
      final shown = <int>[];
      session.addListener(() => shown.add(session.displaySeconds));
      for (var i = 0; i < 30; i++) {
        time.elapse(const Duration(milliseconds: 100));
        session.tick();
      }
      expect(shown, [89, 88, 87]);
    });

    test('a disposed controller ignores stale callbacks', () {
      final wall = _Wall();
      wall.run(() {
        final session = _controller();
        session.completeActiveSet();
        session.dispose();
        session
          ..tick()
          ..start()
          ..pause()
          ..completeActiveSet()
          ..startActiveSet()
          ..skipActiveSet()
          ..nextExercise()
          ..undoLastCompleted()
          ..continueAfterRest()
          ..completeRemainingAsPlanned()
          ..adjustRest(const Duration(seconds: 15))
          ..catchUp(wall.now);
        expect(session.completedSetCount, 1);
      });
    });
  });
}
