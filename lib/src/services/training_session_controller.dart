import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:clock/clock.dart';

import '../models/training_plan.dart';
import '../models/training_history.dart';
import '../models/training_session.dart';

/// Last time's weight for set `setIndex` of exercise `exerciseIndex`, already
/// resolved from history by the caller (spec A2); null without one.
typedef TrainingLastWeight = double? Function(int exerciseIndex, int setIndex);

/// The lead-in after ▶ before a timed set counts down (spec A1).
const Duration trainingGetReady = Duration(seconds: 3);

/// How late a deadline may be noticed and still count as seen (foreground).
const Duration _seenWindow = Duration(seconds: 2);

/// The workout ledger on wall-clock deadlines (spec A1/A4).
///
/// A running rest or timed set is only its UTC deadline ([phaseEndsAt]), so
/// time keeps running while the app is in the background. The ticker merely
/// refreshes the UI and applies [catchUp]. The ledger stays a sequential
/// prefix: only [activeSet] can be completed.
final class TrainingSessionController extends ChangeNotifier {
  TrainingSessionController({
    required TrainingPlan plan,
    int workoutIndex = 0,
    Duration Function()? monotonicNow,
    bool Function()? canRun,
    bool autoTick = true,
    TrainingLastWeight? lastWeight,
  }) : this._(
         _initial(plan, workoutIndex),
         monotonicNow,
         canRun,
         autoTick,
         lastWeight,
         fresh: true,
       );

  /// Recovery: a running rest continues (or has ended into the next set); a
  /// timed set whose deadline passed waits at zero for ✓.
  TrainingSessionController.fromSnapshot(
    TrainingSessionSnapshot snapshot, {
    Duration Function()? monotonicNow,
    bool Function()? canRun,
    bool autoTick = true,
    TrainingLastWeight? lastWeight,
  }) : this._(
         snapshot,
         monotonicNow,
         canRun,
         autoTick,
         lastWeight,
         fresh: false,
       );

  TrainingSessionController._(
    TrainingSessionSnapshot snapshot,
    Duration Function()? monotonicNow,
    this._canRun,
    this._autoTick,
    this._lastWeight, {
    required bool fresh,
  }) : plan = snapshot.plan,
       sessionId = snapshot.sessionId,
       workoutIndex = snapshot.workoutIndex,
       _startedAt = snapshot.startedAt,
       _actuals = {
         for (final actual in snapshot.actualSets) actual.reference: actual,
       },
       _draftReps = snapshot.draftReps,
       _draftWeightKg = snapshot.draftWeightKg,
       _exerciseIndex = snapshot.exerciseIndex,
       _setIndex = snapshot.setIndex,
       _phase = snapshot.phase,
       _remaining = Duration(milliseconds: snapshot.remainingMilliseconds),
       _completed = snapshot.completedSets.toSet(),
       _skipped = snapshot.skippedSets.toSet() {
    // Test seam: a monotonic source offsets the wall clock read once here.
    if (monotonicNow != null) {
      final base = clock.now().toUtc().subtract(monotonicNow());
      _now = () => base.add(monotonicNow());
    } else {
      _now = () => clock.now().toUtc();
    }
    final endsAt = snapshot.phaseEndsAt;
    _started =
        !fresh &&
        (_completed.isNotEmpty ||
            endsAt != null ||
            (_phase == TrainingSessionPhase.exercise &&
                exercise.isTimed &&
                _remaining < phaseDuration));
    if (fresh) _seedDraft();
    if (endsAt != null) _recover(endsAt);
    _notifiedKey = _displayKey;
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
  final String sessionId;
  final bool Function()? _canRun;
  final bool _autoTick;
  final TrainingLastWeight? _lastWeight;
  late final DateTime Function() _now;
  final Map<TrainingSetReference, TrainingSetActual> _actuals;
  final Set<TrainingSetReference> _completed;
  final Set<TrainingSetReference> _skipped;
  DateTime _startedAt;
  bool _started = false;
  int? _draftReps;
  double? _draftWeightKg;
  int _exerciseIndex;
  int _setIndex;
  TrainingSessionPhase _phase;
  // Frozen remaining time while nothing runs.
  Duration _remaining;
  // Deadline of the running rest or timed set; null when nothing runs.
  DateTime? _endsAt;
  Timer? _ticker;
  bool _disposed = false;
  int _phaseEnds = 0;
  bool _lastPhaseEndSeen = false;
  (int, int)? _notifiedKey;

  TrainingWorkout get workout => plan.workouts[workoutIndex];

  /// The exercise under the ledger cursor (during a rest: the one just done).
  TrainingExercise get exercise => workout.exercises[exerciseIndex];
  int get exerciseIndex => _exerciseIndex;
  int get setIndex => _setIndex;
  TrainingSessionPhase get phase => _phase;

  /// First ✓ or ▶ of this session ([hasStarted]); before that, the opening.
  DateTime get startedAt => _startedAt;
  bool get hasStarted => _started;

  /// Whether a rest or timed set counts down (it has a deadline).
  bool get isRunning => _endsAt != null;
  DateTime? get phaseEndsAt => _endsAt;

  /// Deadlines this controller has passed, and whether the latest was seen
  /// in the foreground (the player's haptic cue).
  int get phaseEnds => _phaseEnds;
  bool get lastPhaseEndSeen => _lastPhaseEndSeen;

  Duration get remaining {
    final ends = _endsAt;
    return ends == null ? _remaining : _clamp(ends.difference(_now()));
  }

  /// What is left of the lead-in after ▶ ([trainingGetReady]).
  Duration get getReadyRemaining {
    final ends = _endsAt;
    if (ends == null || _phase != TrainingSessionPhase.exercise) {
      return Duration.zero;
    }
    final lead = ends.difference(_now()) - phaseDuration;
    return lead.isNegative ? Duration.zero : lead;
  }

  Duration get phaseDuration => Duration(
    seconds: switch (phase) {
      TrainingSessionPhase.exercise => exercise.durationSeconds ?? 0,
      // Rest between exercises uses the completed exercise's rest.
      TrainingSessionPhase.rest => exercise.restSeconds,
      TrainingSessionPhase.review => 0,
    },
  );

  /// [remaining] as the player shows it: whole seconds, rounded up.
  int get displaySeconds => (remaining.inMilliseconds / 1000).ceil();

  /// Time since the first ✓ or ▶; null before it.
  Duration? get elapsed {
    if (!_started) return null;
    final value = _now().difference(_startedAt);
    return value.isNegative ? Duration.zero : value;
  }

  List<TrainingSetReference> get completedSets => List.unmodifiable(_completed);
  List<TrainingSetReference> get skippedSets => List.unmodifiable(_skipped);
  List<TrainingSetActual> get actualSets => List.unmodifiable(_actuals.values);
  int get totalSets => workout.totalSets;
  int get completedSetCount => _completed.length;
  double get progress => completedSetCount / totalSets;
  TrainingSetReference get _current =>
      TrainingSetReference(exerciseIndex: exerciseIndex, setIndex: setIndex);

  /// The one set whose ✓ (or ▶) is enabled: the cursor, or during a rest the
  /// set after it; null in review.
  TrainingSetReference? get activeSet => switch (_phase) {
    TrainingSessionPhase.exercise => _current,
    TrainingSessionPhase.rest => _following(_current),
    TrainingSessionPhase.review => null,
  };

  TrainingExercise? get activeExercise {
    final active = activeSet;
    return active == null ? null : workout.exercises[active.exerciseIndex];
  }

  /// Unfinished sets that are neither completed nor skipped.
  int get openSetCount => totalSets - _completed.length - _skipped.length;

  bool isCompleted(TrainingSetReference reference) =>
      _completed.contains(reference);
  bool isSkipped(TrainingSetReference reference) =>
      _skipped.contains(reference);
  TrainingSetActual? actualFor(TrainingSetReference reference) =>
      _actuals[reference];

  /// The most recent completed set, the one [undoLastCompleted] reopens.
  TrainingSetReference? get lastCompleted {
    TrainingSetReference? latest;
    for (final reference in _completed) {
      if (latest == null || _order(reference) > _order(latest)) {
        latest = reference;
      }
    }
    return latest;
  }

  // Draft of the active set: reps default to the plan, weight to the prefill.
  int? get actualReps {
    final active = activeExercise;
    if (active == null || active.isTimed) return null;
    return _draftReps ?? active.reps;
  }

  double? get actualWeightKg => activeSet == null ? null : _draftWeightKg;

  /// Reps a row shows: the record, the active draft or the plan.
  int? shownReps(TrainingSetReference reference) {
    final exercise = workout.exercises[reference.exerciseIndex];
    if (exercise.isTimed) return null;
    if (_completed.contains(reference)) return _actuals[reference]?.reps;
    if (reference == activeSet) return actualReps;
    return exercise.reps;
  }

  /// Weight a row shows: the record, the active draft or the prefill.
  double? shownWeight(TrainingSetReference reference) {
    if (_completed.contains(reference)) return _actuals[reference]?.weightKg;
    if (reference == activeSet) return _draftWeightKg;
    if (_skipped.contains(reference)) return null;
    return _carriedWeight(reference);
  }

  /// Spec A2: once a weight differs from its prefill earlier in this
  /// exercise, the latest weight carries forward; else Last time set k.
  double? _carriedWeight(TrainingSetReference reference) {
    final active = activeSet;
    double? carried;
    var changed = false;
    for (var s = 0; s < reference.setIndex; s++) {
      final earlier = TrainingSetReference(
        exerciseIndex: reference.exerciseIndex,
        setIndex: s,
      );
      final double? weight;
      if (_actuals[earlier] case final actual?
          when _completed.contains(earlier)) {
        weight = actual.weightKg;
      } else if (earlier == active) {
        weight = _draftWeightKg;
      } else {
        continue;
      }
      if (weight != _lastWeightFor(earlier)) changed = true;
      carried = weight;
    }
    return changed ? carried : _lastWeightFor(reference);
  }

  double? _lastWeightFor(TrainingSetReference reference) =>
      _lastWeight?.call(reference.exerciseIndex, reference.setIndex);

  void _seedDraft() {
    final active = activeSet;
    _draftReps = null;
    _draftWeightKg = active == null ? null : _carriedWeight(active);
  }

  /// Field edits of the active row; never pause and never notify.
  void setCurrentActual({int? reps, double? weightKg}) {
    final active = activeSet;
    if (_disposed || active == null) return;
    // Use the same validation as the completed ledger.
    TrainingSetActual(
      reference: active,
      completedAt: _now(),
      reps: reps,
      weightKg: weightKg,
    );
    _draftReps = activeExercise!.isTimed ? null : reps;
    _draftWeightKg = weightKg;
  }

  /// Corrects a completed row; its completion time stays.
  void setCompletedActual(
    TrainingSetReference reference, {
    int? reps,
    double? weightKg,
  }) {
    if (_disposed || !_completed.contains(reference)) return;
    _actuals[reference] = TrainingSetActual(
      reference: reference,
      completedAt: _actuals[reference]?.completedAt ?? _clampToStart(_now()),
      reps: reps,
      weightKg: weightKg,
    );
    notifyListeners();
  }

  /// ✓ on the active row: ends a rest early, completes a repetition set at
  /// once and a timed set that runs ("Done early") or waits at zero.
  void completeActiveSet() {
    final active = activeExercise;
    if (_disposed || active == null) return;
    if (active.isTimed &&
        (_phase == TrainingSessionPhase.rest ||
            (_endsAt == null && _remaining > Duration.zero))) {
      return;
    }
    if (_phase == TrainingSessionPhase.rest) _endRest(chain: false);
    final now = _now();
    _markStarted(now);
    _endsAt = null;
    _record(_current, reps: actualReps, weightKg: _draftWeightKg, at: now);
    _afterCompletion(now, chain: false);
    _changed();
  }

  /// Fixture form of ✓: the cursor set only; a timed set only at zero.
  void completeCurrentSet() {
    if (_disposed ||
        _phase != TrainingSessionPhase.exercise ||
        (exercise.isTimed && remaining > Duration.zero)) {
      return;
    }
    completeActiveSet();
  }

  /// ▶ on the active timed row: ends a rest early and counts down after a
  /// [trainingGetReady] lead-in (none when resuming a paused set).
  void startActiveSet() {
    final active = activeExercise;
    if (_disposed || active == null || !active.isTimed) return;
    if (_phase == TrainingSessionPhase.rest) _endRest(chain: false);
    if (_endsAt != null || _remaining == Duration.zero) return;
    final now = _now();
    _markStarted(now);
    final lead = _remaining == phaseDuration ? trainingGetReady : Duration.zero;
    _endsAt = now.add(lead + _remaining);
    _changed();
  }

  /// Starts or resumes the cursor phase without a lead-in. A repetition set
  /// only marks the workout as started.
  void start() {
    if (_disposed ||
        _endsAt != null ||
        _phase == TrainingSessionPhase.review ||
        !(_canRun?.call() ?? true)) {
      return;
    }
    final now = _now();
    if (_phase == TrainingSessionPhase.exercise && !exercise.isTimed) {
      if (_started) return;
      _markStarted(now);
      _changed();
      return;
    }
    if (_remaining == Duration.zero) return;
    _markStarted(now);
    _endsAt = now.add(_remaining);
    _changed();
  }

  /// Freezes a running rest or timed set (header menu, leaving).
  void pause() {
    if (_disposed || _endsAt == null) return;
    _remaining = remaining;
    _endsAt = null;
    _changed();
  }

  /// Skip rest: the next set becomes active and waits (a timed one for ▶).
  void continueAfterRest() {
    if (_disposed || _phase != TrainingSessionPhase.rest) return;
    _endRest(chain: false);
    _changed();
  }

  /// Whether [adjustRest] by [delta] applies in full. The planned rest caps a
  /// longer one (spec A4), so +15 s fits only once 15 s of it have passed.
  bool canAdjustRest(Duration delta) =>
      !_disposed &&
      _phase == TrainingSessionPhase.rest &&
      remaining + delta <= phaseDuration;

  /// −15 s / +15 s on the rest bar; within the planned rest, zero skips it.
  /// Nothing changes (and nothing notifies) at the planned rest's cap.
  void adjustRest(Duration delta) {
    if (_disposed || _phase != TrainingSessionPhase.rest) return;
    final current = remaining;
    final next = _clamp(current + delta);
    if (next == Duration.zero) {
      continueAfterRest();
      return;
    }
    if (next == current) return;
    if (_endsAt != null) {
      _endsAt = _now().add(next);
    } else {
      _remaining = next;
    }
    _changed();
  }

  /// Skip set: the active set is skipped, never completed.
  void skipActiveSet() {
    if (_disposed || activeSet == null) return;
    if (_phase == TrainingSessionPhase.rest) _endRest(chain: false);
    _endsAt = null;
    _skipped.add(_current);
    _advanceAfterSkip();
    _changed();
  }

  /// Skip exercise: the active exercise's open sets are skipped.
  void nextExercise() {
    if (_disposed || activeSet == null) return;
    if (_phase == TrainingSessionPhase.rest) _endRest(chain: false);
    _endsAt = null;
    for (var s = setIndex; s < exercise.sets; s++) {
      final reference = TrainingSetReference(
        exerciseIndex: exerciseIndex,
        setIndex: s,
      );
      if (!_completed.contains(reference)) _skipped.add(reference);
    }
    _setIndex = exercise.sets - 1;
    _advanceAfterSkip();
    _changed();
  }

  /// Completes the active exercise's open sets with the values shown.
  void completeRemainingAsPlanned() {
    if (_disposed || activeSet == null) return;
    if (_phase == TrainingSessionPhase.rest) _endRest(chain: false);
    final now = _now();
    _markStarted(now);
    _endsAt = null;
    for (var s = setIndex; s < exercise.sets; s++) {
      final reference = TrainingSetReference(
        exerciseIndex: exerciseIndex,
        setIndex: s,
      );
      // Read before recording: the active row shows its draft.
      final reps = shownReps(reference);
      final weight = shownWeight(reference);
      _record(reference, reps: reps, weightKg: weight, at: now);
    }
    _setIndex = exercise.sets - 1;
    _afterCompletion(now, chain: false);
    _changed();
  }

  /// "I did the rest — log as shown": every open set, then review.
  void completeOpenSetsAsShown() {
    if (_disposed || activeSet == null) return;
    if (_phase == TrainingSessionPhase.rest) _endRest(chain: false);
    final now = _now();
    _markStarted(now);
    _endsAt = null;
    for (var e = exerciseIndex; e < workout.exercises.length; e++) {
      for (var s = 0; s < workout.exercises[e].sets; s++) {
        final reference = TrainingSetReference(exerciseIndex: e, setIndex: s);
        if (_order(reference) < _order(_current) ||
            _completed.contains(reference) ||
            _skipped.contains(reference)) {
          continue;
        }
        final reps = shownReps(reference);
        final weight = shownWeight(reference);
        _record(reference, reps: reps, weightKg: weight, at: now);
      }
    }
    _toReview();
    _changed();
  }

  /// Undo: reopens the most recent completed set with its values as the
  /// draft; its rest and every later skip go away.
  void undoLastCompleted() {
    final last = lastCompleted;
    if (_disposed || last == null) return;
    final actual = _actuals[last];
    _rewindTo(last);
    _draftReps = actual?.reps;
    _draftWeightKg = actual?.weightKg;
    _changed();
  }

  /// "Keep training" after skipping to the end: reopens the skipped sets
  /// after the last completed one.
  void reopenTrailingSkips() {
    if (_disposed) return;
    final last = lastCompleted;
    final target = last == null
        ? const TrainingSetReference(exerciseIndex: 0, setIndex: 0)
        : _following(last);
    if (target == null || !_skipped.contains(target)) return;
    _rewindTo(target);
    _seedDraft();
    _changed();
  }

  void _rewindTo(TrainingSetReference target) {
    bool atOrAfter(TrainingSetReference entry) =>
        _order(entry) >= _order(target);
    _endsAt = null;
    _exerciseIndex = target.exerciseIndex;
    _setIndex = target.setIndex;
    _actuals.removeWhere((reference, _) => atOrAfter(reference));
    _completed.removeWhere(atOrAfter);
    _skipped.removeWhere(atOrAfter);
    _phase = TrainingSessionPhase.exercise;
    _remaining = phaseDuration;
  }

  /// Foreground refresh: applies passed deadlines while the player is shown.
  void tick() {
    if (_disposed || _endsAt == null || !(_canRun?.call() ?? true)) return;
    if (_catchUp(_now())) {
      _changed();
    } else if (_displayKey != _notifiedKey) {
      notifyListeners();
    }
  }

  /// Applies every deadline passed by [now] (default: this controller's
  /// clock; spec A4): a timed set completes at its deadline, its rest runs
  /// from there, and a following timed set starts only when that end was seen
  /// in the foreground. True if anything changed.
  bool catchUp([DateTime? now]) {
    if (_disposed || !_catchUp(now?.toUtc() ?? _now())) return false;
    _changed();
    return true;
  }

  bool _catchUp(DateTime now) {
    var changed = false;
    var seenSoFar = true;
    for (;;) {
      final ends = _endsAt;
      if (ends == null || now.isBefore(ends)) return changed;
      final seen =
          seenSoFar &&
          now.difference(ends) <= _seenWindow &&
          (_canRun?.call() ?? true);
      seenSoFar = seen;
      changed = true;
      _phaseEnds++;
      _lastPhaseEndSeen = seen;
      _endsAt = null;
      if (_phase == TrainingSessionPhase.exercise) {
        _remaining = Duration.zero;
        _record(_current, reps: null, weightKg: _draftWeightKg, at: ends);
        _afterCompletion(ends, chain: seen);
      } else {
        _endRest(chain: seen, at: ends);
      }
    }
  }

  void _recover(DateTime endsAt) {
    final now = _now();
    if (now.isBefore(endsAt)) {
      _endsAt = endsAt;
      _syncTicker();
    } else if (_phase == TrainingSessionPhase.exercise) {
      // No phantom completion after process death.
      _remaining = Duration.zero;
    } else {
      _endRest(chain: false);
    }
  }

  void _markStarted(DateTime at) {
    if (_started) return;
    _started = true;
    if (_completed.isEmpty) _startedAt = at;
  }

  DateTime _clampToStart(DateTime at) =>
      at.isBefore(_startedAt) ? _startedAt : at;

  void _record(
    TrainingSetReference reference, {
    required int? reps,
    required double? weightKg,
    required DateTime at,
  }) {
    _actuals[reference] = TrainingSetActual(
      reference: reference,
      completedAt: _clampToStart(at),
      reps: reps,
      weightKg: weightKg,
    );
    _completed.add(reference);
    _skipped.remove(reference);
  }

  /// After the cursor set was completed at [at]: its rest (also between
  /// exercises), the next set, or review after the workout's final set.
  void _afterCompletion(DateTime at, {required bool chain}) {
    final next = _following(_current);
    if (next == null) {
      _toReview();
      return;
    }
    if (exercise.restSeconds > 0) {
      _phase = TrainingSessionPhase.rest;
      _remaining = phaseDuration;
      _endsAt = at.add(phaseDuration);
      _seedDraft();
      return;
    }
    _moveTo(next);
    _seedDraft();
    if (chain && exercise.isTimed) _endsAt = at.add(phaseDuration);
  }

  /// Rest over: the next set is active with the draft seeded at rest start.
  void _endRest({required bool chain, DateTime? at}) {
    _endsAt = null;
    _moveTo(_following(_current)!);
    if (chain && exercise.isTimed) _endsAt = at!.add(phaseDuration);
  }

  void _advanceAfterSkip() {
    final next = _following(_current);
    if (next == null) {
      _toReview();
      return;
    }
    _moveTo(next);
    _seedDraft();
  }

  void _moveTo(TrainingSetReference reference) {
    _exerciseIndex = reference.exerciseIndex;
    _setIndex = reference.setIndex;
    _phase = TrainingSessionPhase.exercise;
    _remaining = phaseDuration;
  }

  void _toReview() {
    _endsAt = null;
    _exerciseIndex = workout.exercises.length - 1;
    _setIndex = exercise.sets - 1;
    _phase = TrainingSessionPhase.review;
    _remaining = Duration.zero;
    _draftReps = null;
    _draftWeightKg = null;
  }

  TrainingSetReference? _following(TrainingSetReference reference) {
    if (reference.setIndex <
        workout.exercises[reference.exerciseIndex].sets - 1) {
      return TrainingSetReference(
        exerciseIndex: reference.exerciseIndex,
        setIndex: reference.setIndex + 1,
      );
    }
    if (reference.exerciseIndex < workout.exercises.length - 1) {
      return TrainingSetReference(
        exerciseIndex: reference.exerciseIndex + 1,
        setIndex: 0,
      );
    }
    return null;
  }

  int _order(TrainingSetReference reference) =>
      reference.exerciseIndex * 1000 + reference.setIndex;

  Duration _clamp(Duration value) => value.isNegative
      ? Duration.zero
      : value > phaseDuration
      ? phaseDuration
      : value;

  (int, int) get _displayKey =>
      (displaySeconds, (getReadyRemaining.inMilliseconds / 1000).ceil());

  void _changed() {
    _syncTicker();
    notifyListeners();
  }

  void _syncTicker() {
    if (_endsAt != null && _autoTick && !_disposed) {
      _ticker ??= Timer.periodic(
        const Duration(milliseconds: 100),
        (_) => tick(),
      );
    } else {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  @override
  void notifyListeners() {
    _notifiedKey = _displayKey;
    super.notifyListeners();
  }

  /// Saves a finished workout. Without [finishedAt], a save more than five
  /// minutes after the last set finishes at that set (spec A7).
  TrainingHistoryEntry completion({String note = '', DateTime? finishedAt}) {
    final skipped = {..._skipped};
    for (var e = 0; e < workout.exercises.length; e++) {
      for (var s = 0; s < workout.exercises[e].sets; s++) {
        final ref = TrainingSetReference(exerciseIndex: e, setIndex: s);
        if (!_completed.contains(ref)) skipped.add(ref);
      }
    }
    return TrainingHistoryEntry(
      snapshot: TrainingSessionSnapshot(
        sessionId: sessionId,
        startedAt: _startedAt,
        plan: plan,
        workoutIndex: workoutIndex,
        exerciseIndex: workout.exercises.length - 1,
        setIndex: workout.exercises.last.sets - 1,
        phase: TrainingSessionPhase.review,
        remainingMilliseconds: 0,
        completedSets: completedSets,
        skippedSets: skipped.toList(),
        actualSets: actualSets,
      ),
      finishedAt: finishedAt ?? _defaultFinish(),
      note: note,
    );
  }

  DateTime _defaultFinish() {
    final now = _now();
    DateTime? last;
    for (final actual in _actuals.values) {
      if (last == null || actual.completedAt.isAfter(last)) {
        last = actual.completedAt;
      }
    }
    var finished = now;
    if (last != null &&
        (now.difference(last) > const Duration(minutes: 5) ||
            now.isBefore(last))) {
      finished = last;
    }
    return finished.isBefore(_startedAt) ? _startedAt : finished;
  }

  TrainingSessionSnapshot snapshot() => TrainingSessionSnapshot(
    sessionId: sessionId,
    startedAt: _startedAt,
    actualSets: actualSets,
    draftReps: _draftReps,
    draftWeightKg: _draftWeightKg,
    plan: plan,
    workoutIndex: workoutIndex,
    exerciseIndex: exerciseIndex,
    setIndex: setIndex,
    phase: phase,
    remainingMilliseconds: remaining.inMilliseconds,
    phaseEndsAt: _endsAt,
    completedSets: completedSets,
    skippedSets: skippedSets,
  );

  @override
  void dispose() {
    _disposed = true;
    _ticker?.cancel();
    _ticker = null;
    super.dispose();
  }
}
