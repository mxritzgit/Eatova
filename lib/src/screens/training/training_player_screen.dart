import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/training_plan.dart';
import '../../models/training_session.dart';
import '../../services/training_session_controller.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/design/design.dart';

enum _SaveIntent { checkpoint, leave, clear }

/// A self-contained player. The caller provides account-pinned durable storage.
class TrainingPlayerScreen extends StatefulWidget {
  const TrainingPlayerScreen({
    super.key,
    this.plan,
    this.workoutIndex = 0,
    this.initialSnapshot,
    required this.onPersist,
    this.monotonicNow,
  }) : assert((plan == null) != (initialSnapshot == null));

  final TrainingPlan? plan;
  final int workoutIndex;
  final TrainingSessionSnapshot? initialSnapshot;
  final Future<void> Function(TrainingSessionSnapshot?) onPersist;
  @visibleForTesting
  final Duration Function()? monotonicNow;

  @override
  State<TrainingPlayerScreen> createState() => _TrainingPlayerScreenState();
}

class _TrainingPlayerScreenState extends State<TrainingPlayerScreen>
    with WidgetsBindingObserver {
  late final TrainingSessionController _session;
  final ScrollController _scroll = ScrollController();
  Future<void> _writes = Future<void>.value();
  Timer? _checkpointTimer;
  Animation<double>? _coverAnimation;
  bool _covered = false;
  bool _allowPop = false;
  bool _leaving = false;
  bool _dialogOpen = false;
  bool _hasSaved = false;
  bool _saveFailed = false;
  int _pendingWrites = 0;
  _SaveIntent _retryIntent = _SaveIntent.checkpoint;
  _SaveIntent? _terminalIntent;
  bool _wasRunning = false;
  bool _hasStartedPhase = false;
  String _phaseIdentity = '';

  String get _currentPhaseIdentity =>
      '${_session.exerciseIndex}:${_session.setIndex}:${_session.phase.name}';

  @override
  void initState() {
    super.initState();
    if ((widget.plan == null) == (widget.initialSnapshot == null)) {
      throw ArgumentError('Provide a training plan or recovery snapshot');
    }
    _session = widget.initialSnapshot == null
        ? TrainingSessionController(
            plan: widget.plan!,
            workoutIndex: widget.workoutIndex,
            monotonicNow: widget.monotonicNow,
          )
        : TrainingSessionController.fromSnapshot(
            widget.initialSnapshot!,
            monotonicNow: widget.monotonicNow,
          );
    _phaseIdentity = _currentPhaseIdentity;
    _hasStartedPhase = widget.initialSnapshot != null;
    _session.addListener(_sessionChanged);
    WidgetsBinding.instance.addObserver(this);
    _checkpointTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_session.isRunning && !_leaving && _pendingWrites == 0) {
        unawaited(_persist());
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_leaving) unawaited(_persist());
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final animation = ModalRoute.of(context)?.secondaryAnimation;
    if (animation != _coverAnimation) {
      _coverAnimation?.removeListener(_routeCoverageChanged);
      _coverAnimation = animation;
      animation?.addListener(_routeCoverageChanged);
    }
  }

  void _routeCoverageChanged() {
    final covered = (_coverAnimation?.value ?? 0) > 0;
    if (covered && !_covered && !_leaving && !_dialogOpen) {
      _session.pause();
      unawaited(_persist());
    }
    _covered = covered;
  }

  void _sessionChanged() {
    if (!mounted) return;
    final reachedZero =
        (_session.exercise.isTimed ||
            _session.phase == TrainingSessionPhase.rest) &&
        _wasRunning &&
        !_session.isRunning &&
        _session.remaining == Duration.zero;
    _wasRunning = _session.isRunning;
    if (_phaseIdentity != _currentPhaseIdentity) {
      _phaseIdentity = _currentPhaseIdentity;
      _hasStartedPhase = false;
    }
    _hasStartedPhase = _hasStartedPhase || _session.isRunning;
    setState(() {});
    if (reachedZero && !_leaving) {
      // Listener callbacks never start or advance a phase.
      unawaited(_persist());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && !_leaving) {
      _session.pause();
      unawaited(_persist());
    }
  }

  void _act(VoidCallback action) {
    if (_leaving) return;
    // An explicit workout action abandons a failed exit attempt.
    _terminalIntent = null;
    action();
    unawaited(_persist());
  }

  Future<void> _persist([_SaveIntent intent = _SaveIntent.checkpoint]) {
    if ((_leaving || _terminalIntent != null) &&
        intent == _SaveIntent.checkpoint) {
      return Future<void>.value();
    }
    final snapshot = intent == _SaveIntent.clear ? null : _session.snapshot();
    // Capture the account-pinned callback alongside its immutable value.
    final persist = widget.onPersist;
    if (intent != _SaveIntent.checkpoint) {
      _terminalIntent = intent;
      _leaving = true;
    }
    _pendingWrites++;
    if (mounted) setState(() {});
    final operation = _writes.then((_) async {
      try {
        await persist(snapshot);
        if (!mounted) return;
        _hasSaved = true;
        _saveFailed = false;
        if (intent != _SaveIntent.checkpoint) {
          setState(() => _allowPop = true);
          // PopScope must rebuild before the programmatic pop.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) Navigator.of(context).pop();
          });
        }
      } catch (_) {
        if (!mounted) return;
        // An older checkpoint cannot unlock or replace a newer terminal intent.
        if (intent == _SaveIntent.checkpoint && _terminalIntent != null) return;
        _session.pause();
        _saveFailed = true;
        _retryIntent = intent;
        _leaving = false;
        if (_scroll.hasClients) _scroll.jumpTo(0);
      } finally {
        _pendingWrites--;
        if (mounted) setState(() {});
      }
    });
    _writes = operation;
    return operation;
  }

  Future<void> _exitDialog({bool discard = false, bool finish = false}) async {
    if (_dialogOpen || _leaving) return;
    _session.pause();
    unawaited(_persist());
    _dialogOpen = true;
    final l = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: Text(
          discard
              ? l.trainingTimerDiscardTitle
              : finish
              ? l.trainingTimerFinishTitle
              : l.trainingTimerLeaveTitle,
        ),
        content: Text(
          discard
              ? l.trainingTimerDiscardBody
              : finish
              ? l.trainingTimerFinishBody(
                  _session.completedSetCount,
                  _session.totalSets,
                )
              : l.trainingTimerLeaveBody,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l.trainingTimerStay),
          ),
          TextButton(
            key: const ValueKey('training-timer-confirm-exit'),
            style: discard
                ? TextButton.styleFrom(foregroundColor: context.t.danger)
                : null,
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              discard
                  ? l.trainingTimerDiscard
                  : finish
                  ? l.trainingTimerFinish
                  : l.trainingTimerSaveLeave,
            ),
          ),
        ],
      ),
    );
    _dialogOpen = false;
    if (!mounted || confirmed != true) return;
    await _persist(discard || finish ? _SaveIntent.clear : _SaveIntent.leave);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _coverAnimation?.removeListener(_routeCoverageChanged);
    _checkpointTimer?.cancel();
    _session.removeListener(_sessionChanged);
    _session.pause();
    // External route removal cannot await a save. Retain queue order and never
    // enqueue behind a terminal clear. Root rejects writes after account changes.
    if (!_leaving && _terminalIntent == null) {
      final snapshot = _session.snapshot();
      final persist = widget.onPersist;
      _writes = _writes
          .then((_) => persist(snapshot))
          .catchError((Object _) {});
    }
    _session.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Widget _secondary(
    String id,
    String label,
    IconData icon,
    VoidCallback? action,
  ) {
    return OutlinedButton(
      key: ValueKey('training-timer-$id'),
      onPressed: _leaving || action == null ? null : () => _act(action),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        foregroundColor: context.t.ink,
        side: BorderSide(color: context.t.line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 8),
          Flexible(child: Text(label, textAlign: TextAlign.center)),
        ],
      ),
    );
  }

  Widget _controlPair(Widget first, Widget second) => LayoutBuilder(
    builder: (context, constraints) {
      final stack =
          constraints.maxWidth < 340 ||
          MediaQuery.textScalerOf(context).scale(14) > 21;
      if (stack) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [first, const SizedBox(height: 8), second],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: first),
          const SizedBox(width: 8),
          Expanded(child: second),
        ],
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final t = context.t;
    final review = _session.phase == TrainingSessionPhase.review;
    final rest = _session.phase == TrainingSessionPhase.rest;
    final timed = rest || _session.exercise.isTimed;
    final atZero = timed && _session.remaining == Duration.zero;
    final running = _session.isRunning;
    final status = review
        ? l.trainingTimerReview
        : atZero
        ? l.trainingTimerTimeUp
        : running
        ? l.trainingTimerRunning
        : l.trainingTimerPaused;
    final primaryLabel = review
        ? l.trainingTimerFinish
        : rest && atZero
        ? l.trainingTimerContinue
        : !rest && ((timed && atZero) || (!timed && running))
        ? l.trainingTimerCompleteSet
        : running
        ? l.trainingTimerPause
        : _hasStartedPhase
        ? l.trainingTimerResume
        : l.trainingTimerStart;
    final VoidCallback primaryAction = review
        ? () => unawaited(_exitDialog(finish: true))
        : rest && atZero
        ? () => _act(_session.continueAfterRest)
        : !rest && ((timed && atZero) || (!timed && running))
        ? () => _act(_session.completeCurrentSet)
        : running
        ? () => _act(_session.pause)
        : () => _act(_session.start);
    final seconds = (_session.remaining.inMilliseconds / 1000).ceil();
    final minutesPart = (seconds ~/ 60).toString().padLeft(2, '0');
    final secondsPart = (seconds % 60).toString().padLeft(2, '0');
    final nextIndex = _session.exerciseIndex + 1;

    return PopScope(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) unawaited(_exitDialog());
      },
      child: Scaffold(
        backgroundColor: t.bg,
        body: SafeArea(
          child: SingleChildScrollView(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    IconButton(
                      key: const ValueKey('training-timer-back'),
                      tooltip: l.trainingTimerBack,
                      onPressed: _leaving ? null : () => _exitDialog(),
                      icon: const Icon(Icons.arrow_back_rounded),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _session.workout.title,
                        style: AppType.ui(
                          15,
                          weight: FontWeight.w600,
                          color: t.ink,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (_saveFailed) ...[
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      l.trainingTimerSaveFailed,
                      key: const ValueKey('training-timer-save-error'),
                      style: AppType.ui(14, color: t.danger),
                    ),
                  ),
                  _secondary(
                    'retry',
                    l.trainingTimerRetry,
                    Icons.refresh_rounded,
                    _pendingWrites > 0
                        ? null
                        : () {
                            unawaited(_persist(_retryIntent));
                          },
                  ),
                  const SizedBox(height: 16),
                ],
                Text(
                  l.trainingTimerProgress(
                    _session.completedSetCount,
                    _session.totalSets,
                  ),
                  key: const ValueKey('training-timer-progress-label'),
                  style: AppType.ui(14, color: t.ink2),
                ),
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  value: _session.progress,
                  minHeight: 4,
                  borderRadius: BorderRadius.circular(rPill),
                  color: t.accent,
                  backgroundColor: t.tile,
                  semanticsLabel: l.trainingTimerProgress(
                    _session.completedSetCount,
                    _session.totalSets,
                  ),
                ),
                const SizedBox(height: 24),
                Container(
                  key: const ValueKey('training-timer-hero'),
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: t.forest,
                    borderRadius: BorderRadius.circular(rHero),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      HeadingSemantics(
                        level: 1,
                        child: Text(
                          review
                              ? l.trainingTimerReview
                              : rest
                              ? l.trainingTimerRest
                              : _session.exercise.name,
                          style: AppType.display(
                            22,
                            color: t.onForest,
                            height: 1.15,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        review
                            ? l.trainingTimerSkipped(
                                _session.skippedSets.length,
                              )
                            : l.trainingTimerSet(
                                _session.setIndex + 1,
                                _session.exercise.sets,
                              ),
                        style: AppType.ui(14, color: t.onForest),
                      ),
                      const SizedBox(height: 24),
                      if (review)
                        Text(
                          l.trainingTimerProgress(
                            _session.completedSetCount,
                            _session.totalSets,
                          ),
                          style: AppType.display(28, color: t.onForest),
                        )
                      else if (timed)
                        Semantics(
                          key: const ValueKey('training-timer-readout'),
                          label: l.trainingTimerSecondsRemaining(seconds),
                          child: ExcludeSemantics(
                            child: LayoutBuilder(
                              builder: (context, constraints) {
                                final largeText =
                                    MediaQuery.textScalerOf(context).scale(64) >
                                    90;
                                if (!largeText) {
                                  return Text(
                                    '$minutesPart:$secondsPart',
                                    textAlign: TextAlign.center,
                                    style: AppType.display(
                                      64,
                                      color: t.onForest,
                                      height: 1,
                                    ),
                                  );
                                }
                                return Wrap(
                                  alignment: WrapAlignment.center,
                                  spacing: 24,
                                  runSpacing: 16,
                                  children: [
                                    _timePart(
                                      minutesPart,
                                      l.trainingTimerMinutes,
                                    ),
                                    _timePart(
                                      secondsPart,
                                      l.trainingTimerSeconds,
                                    ),
                                  ],
                                );
                              },
                            ),
                          ),
                        )
                      else ...[
                        Text(
                          '${_session.exercise.reps}',
                          textAlign: TextAlign.center,
                          style: AppType.display(
                            64,
                            color: t.onForest,
                            height: 1,
                          ),
                        ),
                        Text(
                          l.trainingTimerRepetitions,
                          textAlign: TextAlign.center,
                          style: AppType.ui(15, color: t.onForest),
                        ),
                      ],
                      const SizedBox(height: 24),
                      Semantics(
                        liveRegion: true,
                        label: l.trainingTimerAnnouncement(
                          review
                              ? l.trainingTimerReview
                              : _session.exercise.name,
                          review
                              ? l.trainingTimerProgress(
                                  _session.completedSetCount,
                                  _session.totalSets,
                                )
                              : l.trainingTimerSet(
                                  _session.setIndex + 1,
                                  _session.exercise.sets,
                                ),
                          rest ? '${l.trainingTimerRest}. $status' : status,
                        ),
                        child: ExcludeSemantics(
                          child: Text(
                            status,
                            key: const ValueKey('training-timer-status'),
                            textAlign: TextAlign.center,
                            style: AppType.ui(
                              15,
                              weight: FontWeight.w600,
                              color: t.onForest,
                            ),
                          ),
                        ),
                      ),
                      if (atZero) ...[
                        const SizedBox(height: 8),
                        Text(
                          l.trainingTimerConfirmHint,
                          textAlign: TextAlign.center,
                          style: AppType.ui(14, color: t.onForest, height: 1.4),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                PrimaryActionButton(
                  key: const ValueKey('training-timer-primary'),
                  label: primaryLabel,
                  icon: review || atZero || (!timed && running)
                      ? Icons.check_rounded
                      : running
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  onTap: _leaving ? null : primaryAction,
                ),
                const SizedBox(height: 12),
                if (!review) ...[
                  if (!timed)
                    _secondary(
                      'pause',
                      l.trainingTimerPause,
                      Icons.pause_rounded,
                      running ? _session.pause : null,
                    ),
                  if (timed)
                    _controlPair(
                      _secondary(
                        'rewind',
                        l.trainingTimerRewind,
                        Icons.replay_10_rounded,
                        _session.rewind10Seconds,
                      ),
                      _secondary(
                        'forward',
                        l.trainingTimerForward,
                        Icons.forward_10_rounded,
                        _session.forward10Seconds,
                      ),
                    ),
                  const SizedBox(height: 8),
                  _secondary(
                    'reset',
                    l.trainingTimerReset,
                    Icons.restart_alt_rounded,
                    _session.resetPhase,
                  ),
                  if (rest) ...[
                    const SizedBox(height: 8),
                    _secondary(
                      'skip-rest',
                      l.trainingTimerSkipRest,
                      Icons.skip_next_rounded,
                      _session.continueAfterRest,
                    ),
                  ],
                ],
                const SizedBox(height: 24),
                HeadingSemantics(
                  level: 2,
                  child: Text(
                    l.trainingTimerNavigate,
                    style: AppType.ui(
                      15,
                      weight: FontWeight.w600,
                      color: t.ink,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                _controlPair(
                  _secondary(
                    'previous-set',
                    l.trainingTimerPreviousSet,
                    Icons.chevron_left_rounded,
                    _session.canPreviousSet ? _session.previousSet : null,
                  ),
                  _secondary(
                    'next-set',
                    rest ? l.trainingTimerContinue : l.trainingTimerNextSet,
                    Icons.chevron_right_rounded,
                    review ? null : _session.nextSet,
                  ),
                ),
                const SizedBox(height: 8),
                _controlPair(
                  _secondary(
                    'previous-exercise',
                    l.trainingTimerPreviousExercise,
                    Icons.skip_previous_rounded,
                    _session.canPreviousExercise
                        ? _session.previousExercise
                        : null,
                  ),
                  _secondary(
                    'next-exercise',
                    l.trainingTimerNextExercise,
                    Icons.skip_next_rounded,
                    review ? null : _session.nextExercise,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  l.trainingTimerNavigationHint,
                  style: AppType.ui(13, color: t.ink2, height: 1.4),
                ),
                if (!review && _session.exercise.notes.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  HeadingSemantics(
                    level: 2,
                    child: Text(
                      l.trainingTimerInstructions,
                      style: AppType.ui(
                        15,
                        weight: FontWeight.w600,
                        color: t.ink,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _session.exercise.notes,
                    style: AppType.ui(15, color: t.ink, height: 1.5),
                  ),
                ],
                if (!review &&
                    nextIndex < _session.workout.exercises.length) ...[
                  const SizedBox(height: 24),
                  Divider(color: t.line),
                  const SizedBox(height: 16),
                  Text(
                    l.trainingTimerUpNext,
                    style: AppType.ui(13, color: t.ink2),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _session.workout.exercises[nextIndex].name,
                    style: AppType.display(20, color: t.ink),
                  ),
                ],
                const SizedBox(height: 24),
                if (!review)
                  TextButton(
                    key: const ValueKey('training-timer-finish'),
                    onPressed: _leaving
                        ? null
                        : () => _exitDialog(finish: true),
                    child: Text(l.trainingTimerFinish),
                  ),
                TextButton(
                  key: const ValueKey('training-timer-discard'),
                  style: TextButton.styleFrom(
                    foregroundColor: t.danger,
                    minimumSize: const Size(0, 48),
                  ),
                  onPressed: _leaving ? null : () => _exitDialog(discard: true),
                  child: Text(l.trainingTimerDiscard),
                ),
                const SizedBox(height: 12),
                Text(
                  _saveFailed
                      ? l.trainingTimerNotSaved
                      : _pendingWrites > 0
                      ? l.trainingTimerSaving
                      : _hasSaved
                      ? l.trainingTimerSaved
                      : l.trainingTimerNotSaved,
                  key: const ValueKey('training-timer-save-status'),
                  textAlign: TextAlign.center,
                  style: AppType.ui(13, color: t.ink2),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _timePart(String value, String unit) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        value,
        style: AppType.display(64, color: context.t.onForest, height: 1),
      ),
      Text(unit, style: AppType.ui(14, color: context.t.onForest)),
    ],
  );
}
