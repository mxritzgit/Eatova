import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/training_plan.dart';
import '../models/training_session.dart';

/// Timer callbacks refresh the UI; only monotonic elapsed time changes duration.
final class TrainingSessionController extends ChangeNotifier {
  TrainingSessionController({
    required TrainingPlan plan,
    int workoutIndex = 0,
    Duration Function()? monotonicNow,
    bool Function()? canRun,
    bool autoTick = true,
  }) : this.fromSnapshot(
         _initial(plan, workoutIndex),
         monotonicNow: monotonicNow,
         canRun: canRun,
         autoTick: autoTick,
       );

  TrainingSessionController.fromSnapshot(
    TrainingSessionSnapshot snapshot, {
    Duration Function()? monotonicNow,
    bool Function()? canRun,
    bool autoTick = true,
  }) : plan = snapshot.plan,
       workoutIndex = snapshot.workoutIndex,
       _exerciseIndex = snapshot.exerciseIndex,
       _setIndex = snapshot.setIndex,
       _phase = snapshot.phase,
       _remaining = Duration(milliseconds: snapshot.remainingMilliseconds),
       _completed = snapshot.completedSets.toSet(),
       _skipped = snapshot.skippedSets.toSet(),
       _canRun = canRun,
       _autoTick = autoTick {
    _watch.start();
    _now = monotonicNow ?? (() => _watch.elapsed);
  }

  static TrainingSessionSnapshot _initial(TrainingPlan plan, int workoutIndex) {
    if (workoutIndex < 0 || workoutIndex >= plan.workouts.length) {
      throw const FormatException('Invalid training workout');
    }
    return TrainingSessionSnapshot(
      plan: plan,
      workoutIndex: workoutIndex,
      exerciseIndex: 0,
      setIndex: 0,
      phase: TrainingSessionPhase.exercise,
      remainingMilliseconds:
          (plan.workouts[workoutIndex].exercises.first.durationSeconds ?? 0) *
          1000,
    );
  }

  final TrainingPlan plan;
  final int workoutIndex;
  final bool _autoTick;
  // Recheck visibility before a callback can record an automatic completion.
  final bool Function()? _canRun;
  final Stopwatch _watch = Stopwatch();
  late final Duration Function() _now;
  final Set<TrainingSetReference> _completed;
  final Set<TrainingSetReference> _skipped;
  int _exerciseIndex;
  int _setIndex;
  TrainingSessionPhase _phase;
  Duration _remaining;
  Duration _anchor = Duration.zero;
  Duration _anchorRemaining = Duration.zero;
  Timer? _ticker;
  bool _running = false;
  bool _disposed = false;

  TrainingWorkout get workout => plan.workouts[workoutIndex];
  TrainingExercise get exercise => workout.exercises[exerciseIndex];
  int get exerciseIndex => _exerciseIndex;
  int get setIndex => _setIndex;
  TrainingSessionPhase get phase => _phase;
  bool get isRunning => _running;
  Duration get remaining => _sampleRemaining();
  Duration get phaseDuration => Duration(
    seconds: switch (phase) {
      TrainingSessionPhase.exercise => exercise.durationSeconds ?? 0,
      TrainingSessionPhase.rest => exercise.restSeconds,
      TrainingSessionPhase.review => 0,
    },
  );
  List<TrainingSetReference> get completedSets => List.unmodifiable(_completed);
  List<TrainingSetReference> get skippedSets => List.unmodifiable(_skipped);
  int get totalSets => workout.totalSets;
  int get completedSetCount => _completed.length;
  double get progress => completedSetCount / totalSets;
  bool get canPreviousSet =>
      phase != TrainingSessionPhase.exercise ||
      setIndex > 0 ||
      exerciseIndex > 0;
  bool get canPreviousExercise =>
      phase == TrainingSessionPhase.review || exerciseIndex > 0;
  TrainingSetReference get _current =>
      TrainingSetReference(exerciseIndex: exerciseIndex, setIndex: setIndex);
  bool get _isTimed => phase == TrainingSessionPhase.rest || exercise.isTimed;

  Duration _sampleRemaining() {
    if (!_running || !_isTimed) return _remaining;
    final elapsed = _now() - _anchor;
    final value =
        _anchorRemaining - (elapsed.isNegative ? Duration.zero : elapsed);
    return value.isNegative ? Duration.zero : value;
  }

  void _stop() {
    _remaining = _sampleRemaining();
    _running = false;
    _ticker?.cancel();
    _ticker = null;
  }

  void start() {
    if (_disposed ||
        _running ||
        !(_canRun?.call() ?? true) ||
        phase == TrainingSessionPhase.review ||
        (_isTimed && remaining == Duration.zero)) {
      return;
    }
    _startRunning();
    notifyListeners();
  }

  void _startRunning() {
    _anchor = _now();
    _anchorRemaining = _remaining;
    _running = true;
    if (_autoTick && _isTimed) {
      _ticker = Timer.periodic(
        const Duration(milliseconds: 100),
        (_) => tick(),
      );
    }
  }

  void pause() {
    if (_disposed) return;
    _stop();
    notifyListeners();
  }

  void tick() {
    if (_disposed || !_running || !_isTimed) return;
    if (!(_canRun?.call() ?? true)) {
      pause();
      return;
    }
    if (remaining == Duration.zero) {
      _stop();
      if (phase == TrainingSessionPhase.exercise) {
        _completeSet();
      } else {
        _advance();
      }
      // A late callback ends only the visible phase. Every new interval gets
      // its full duration instead of consuming time before it was presented.
      _startNextTimedPhase();
    }
    notifyListeners();
  }

  void _adjust(Duration delta) {
    if (_disposed || phase == TrainingSessionPhase.review || !_isTimed) return;
    _stop();
    final adjusted = _remaining + delta;
    _remaining = adjusted < Duration.zero
        ? Duration.zero
        : adjusted > phaseDuration
        ? phaseDuration
        : adjusted;
    notifyListeners();
  }

  void rewind10Seconds() => _adjust(const Duration(seconds: 10));
  void forward10Seconds() => _adjust(const Duration(seconds: -10));

  void resetPhase() {
    if (_disposed || phase == TrainingSessionPhase.review) return;
    _stop();
    _remaining = phaseDuration;
    notifyListeners();
  }

  /// Reps and a paused/adjusted zero require deliberate confirmation.
  void completeCurrentSet() {
    if (_disposed ||
        phase != TrainingSessionPhase.exercise ||
        (exercise.isTimed ? remaining > Duration.zero : !_running)) {
      return;
    }
    _stop();
    _completeSet();
    _startNextTimedPhase();
    notifyListeners();
  }

  void _completeSet() {
    _completed.add(_current);
    _skipped.remove(_current);
    if (setIndex < exercise.sets - 1 && exercise.restSeconds > 0) {
      _phase = TrainingSessionPhase.rest;
      _remaining = phaseDuration;
    } else {
      _advance();
    }
  }

  void _startNextTimedPhase() {
    if (phase != TrainingSessionPhase.review &&
        _isTimed &&
        (_canRun?.call() ?? true)) {
      _startRunning();
    }
  }

  /// Also permits explicitly skipping a rest that has not elapsed.
  void continueAfterRest() {
    if (_disposed || phase != TrainingSessionPhase.rest) return;
    _stop();
    _advance();
    notifyListeners();
  }

  void _advance() {
    if (setIndex < exercise.sets - 1) {
      _setIndex++;
    } else if (exerciseIndex < workout.exercises.length - 1) {
      _exerciseIndex++;
      _setIndex = 0;
    } else {
      _phase = TrainingSessionPhase.review;
      _remaining = Duration.zero;
      return;
    }
    _phase = TrainingSessionPhase.exercise;
    _remaining = phaseDuration;
  }

  void nextSet() {
    if (_disposed || phase == TrainingSessionPhase.review) return;
    _stop();
    if (phase == TrainingSessionPhase.exercise) _skipped.add(_current);
    _advance();
    notifyListeners();
  }

  void nextExercise() {
    if (_disposed || phase == TrainingSessionPhase.review) return;
    _stop();
    for (var index = setIndex; index < exercise.sets; index++) {
      final entry = TrainingSetReference(
        exerciseIndex: exerciseIndex,
        setIndex: index,
      );
      if (!_completed.contains(entry)) _skipped.add(entry);
    }
    _setIndex = exercise.sets - 1;
    _advance();
    notifyListeners();
  }

  void _rewindTo(int exerciseIndex, int setIndex) {
    _stop();
    _exerciseIndex = exerciseIndex;
    _setIndex = setIndex;
    bool atOrAfter(TrainingSetReference entry) =>
        entry.exerciseIndex > exerciseIndex ||
        (entry.exerciseIndex == exerciseIndex && entry.setIndex >= setIndex);
    _completed.removeWhere(atOrAfter);
    _skipped.removeWhere(atOrAfter);
    _phase = TrainingSessionPhase.exercise;
    _remaining = phaseDuration;
    notifyListeners();
  }

  void previousSet() {
    if (_disposed || !canPreviousSet) return;
    if (phase != TrainingSessionPhase.exercise) {
      _rewindTo(exerciseIndex, setIndex);
    } else if (setIndex > 0) {
      _rewindTo(exerciseIndex, setIndex - 1);
    } else {
      _rewindTo(
        exerciseIndex - 1,
        workout.exercises[exerciseIndex - 1].sets - 1,
      );
    }
  }

  void previousExercise() {
    if (_disposed || !canPreviousExercise) return;
    _rewindTo(
      phase == TrainingSessionPhase.review ? exerciseIndex : exerciseIndex - 1,
      0,
    );
  }

  TrainingSessionSnapshot snapshot() => TrainingSessionSnapshot(
    plan: plan,
    workoutIndex: workoutIndex,
    exerciseIndex: exerciseIndex,
    setIndex: setIndex,
    phase: phase,
    remainingMilliseconds: remaining.inMilliseconds,
    completedSets: completedSets,
    skippedSets: skippedSets,
  );

  @override
  void dispose() {
    _stop();
    _disposed = true;
    _watch.stop();
    super.dispose();
  }
}
