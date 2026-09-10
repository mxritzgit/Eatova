import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../models/training_plan.dart';
import '../../models/training_session.dart';
import '../../models/training_history.dart';
import 'training_actual_fields.dart';
import '../../services/training_session_controller.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/design/design.dart';
import '../../widgets/common/app_snack.dart';

enum _SaveIntent { checkpoint, leave, clear, complete }

// The model and Postgres count code points; retain whole displayed characters.
class _TrainingNoteFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (newValue.text.runes.length <= TrainingLimits.notesMaxLength) {
      return newValue;
    }
    var length = 0;
    final text = newValue.text.characters.takeWhile((character) {
      length += character.runes.length;
      return length <= TrainingLimits.notesMaxLength;
    }).join();
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(
        offset: newValue.selection.extentOffset.clamp(0, text.length),
      ),
    );
  }
}

/// A self-contained player. The caller provides account-pinned durable storage.
class TrainingPlayerScreen extends StatefulWidget {
  const TrainingPlayerScreen({
    super.key,
    this.plan,
    this.workoutIndex = 0,
    this.initialSnapshot,
    required this.onPersist,
    this.onComplete,
    this.history = const [],
    this.monotonicNow,
  }) : assert((plan == null) != (initialSnapshot == null));

  final TrainingPlan? plan;
  final int workoutIndex;
  final TrainingSessionSnapshot? initialSnapshot;
  final Future<void> Function(TrainingSessionSnapshot?) onPersist;
  final Future<void> Function(TrainingHistoryEntry)? onComplete;
  final List<TrainingHistoryEntry> history;
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
  ModalRoute<dynamic>? _route;
  bool _covered = false;
  bool _allowPop = false;
  bool _leaving = false;
  bool _dialogOpen = false;
  bool _hasSaved = false;
  bool _saveFailed = false;
  int _pendingWrites = 0;
  _SaveIntent _retryIntent = _SaveIntent.checkpoint;
  _SaveIntent? _terminalIntent;
  TrainingHistoryEntry? _pendingCompletion;
  bool _actualValid = true;
  final Set<TrainingSetReference> _invalidActuals = {};
  final TextEditingController _note = TextEditingController();
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
            canRun: _canRunSession,
          )
        : TrainingSessionController.fromSnapshot(
            widget.initialSnapshot!,
            monotonicNow: widget.monotonicNow,
            canRun: _canRunSession,
          );
    _note.text = widget.initialSnapshot?.recoveryNote ?? '';
    if (widget.initialSnapshot?.pendingCompletionAt != null) {
      _pendingCompletion = TrainingHistoryEntry.fromRecovery(
        widget.initialSnapshot!,
      );
      _note.text = _pendingCompletion!.note;
      _saveFailed = true;
      _retryIntent = _SaveIntent.complete;
      _terminalIntent = _SaveIntent.complete;
    }
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
    _route = ModalRoute.of(context);
    final animation = _route?.secondaryAnimation;
    if (animation != _coverAnimation) {
      _coverAnimation?.removeListener(_routeCoverageChanged);
      _coverAnimation = animation;
      animation?.addListener(_routeCoverageChanged);
    }
    if (!_canRunSession() && _session.isRunning) _session.pause();
  }

  bool _canRunSession() {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    return mounted &&
        !_leaving &&
        _actualValid &&
        !_dialogOpen &&
        (_route?.isCurrent ?? true) &&
        (lifecycle == null || lifecycle == AppLifecycleState.resumed);
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
    final phaseChanged = _phaseIdentity != _currentPhaseIdentity;
    final interrupted = _wasRunning && !_session.isRunning && !_canRunSession();
    _wasRunning = _session.isRunning;
    if (phaseChanged) {
      _phaseIdentity = _currentPhaseIdentity;
      _hasStartedPhase = false;
      _actualValid = true;
    }
    _invalidActuals.removeWhere(
      (ref) =>
          _session.phase != TrainingSessionPhase.review ||
          !_session.completedSets.contains(ref),
    );
    _hasStartedPhase = _hasStartedPhase || _session.isRunning;
    setState(() {});
    if ((phaseChanged || interrupted) && !_leaving) {
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
    if (_leaving || _pendingCompletion != null) return;
    // An explicit workout action abandons a failed exit attempt.
    _terminalIntent = null;
    _pendingCompletion = null;
    action();
    unawaited(_persist());
  }

  TrainingSessionSnapshot _recoverySnapshot() =>
      _pendingCompletion?.recoverySnapshot() ??
      TrainingSessionSnapshot.fromJson({
        ..._session.snapshot().toJson(),
        if (_note.text.isNotEmpty) 'recovery_note': _note.text,
      });

  Future<void> _persist([_SaveIntent intent = _SaveIntent.checkpoint]) {
    if ((_leaving || _terminalIntent != null) &&
        intent == _SaveIntent.checkpoint) {
      return Future<void>.value();
    }
    TrainingSessionSnapshot? snapshot;
    Object? validationError;
    try {
      snapshot = intent == _SaveIntent.clear ? null : _recoverySnapshot();
    } catch (error) {
      validationError = error;
    }
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
        if (validationError != null) throw validationError;
        if (intent == _SaveIntent.complete) {
          final complete = widget.onComplete;
          if (complete == null) {
            throw StateError('Training history unavailable');
          }
          _pendingCompletion ??= _session.completion(note: _note.text);
          await complete(_pendingCompletion!);
        } else {
          await persist(snapshot);
        }
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
      } on TrainingCompletionDeleted {
        if (!mounted) return;
        showAppSnack(context, context.l10n.trainingHistoryAlreadyDeleted);
        setState(() => _allowPop = true);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) Navigator.of(context).pop();
        });
      } on TrainingCompletionSourceRetired {
        if (!mounted) return;
        showAppSnack(context, context.l10n.trainingHistorySourceChanged);
        setState(() => _allowPop = true);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) Navigator.of(context).pop();
        });
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
    final confirmed = await showEatovaDialog<bool>(
      context: context,
      builder: (context) => EatovaConfirmDialog(
        title: discard
            ? l.trainingTimerDiscardTitle
            : finish
            ? l.trainingTimerFinishTitle
            : l.trainingTimerLeaveTitle,
        body: discard
            ? l.trainingTimerDiscardBody
            : finish
            ? l.trainingTimerFinishBody(
                _session.completedSetCount,
                _session.totalSets,
              )
            : l.trainingTimerLeaveBody,
        icon: discard
            ? Icons.delete_outline_rounded
            : finish
            ? Icons.check_rounded
            : Icons.pause_rounded,
        destructive: discard,
        cancelLabel: l.trainingTimerStay,
        onCancel: () => Navigator.pop(context, false),
        confirmKey: const ValueKey('training-timer-confirm-exit'),
        confirmLabel: discard
            ? l.trainingTimerDiscard
            : finish
            ? l.trainingTimerFinish
            : l.trainingTimerSaveLeave,
        onConfirm: () => Navigator.pop(context, true),
      ),
    );
    _dialogOpen = false;
    if (!mounted || confirmed != true) return;
    await _persist(
      discard
          ? _SaveIntent.clear
          : finish
          ? _SaveIntent.complete
          : _SaveIntent.leave,
    );
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
      try {
        final snapshot = _recoverySnapshot();
        final persist = widget.onPersist;
        _writes = _writes
            .then((_) => persist(snapshot))
            .catchError((Object _) {});
      } catch (_) {
        // Retain the last valid checkpoint if an external edit is invalid.
      }
    }
    _session.dispose();
    _scroll.dispose();
    _note.dispose();
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
      onPressed:
          _leaving ||
              action == null ||
              (_pendingCompletion != null && id != 'retry')
          ? null
          : id == 'retry'
          ? action
          : () => _act(action),
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

  Widget _controlPair(Widget first, Widget? second) => LayoutBuilder(
    builder: (context, constraints) {
      if (second == null) return first;
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
                      if (!review && timed) ...[
                        const SizedBox(height: 8),
                        Text(
                          atZero
                              ? l.trainingTimerConfirmHint
                              : l.trainingTimerAutomaticHint,
                          textAlign: TextAlign.center,
                          style: AppType.ui(14, color: t.onForest, height: 1.4),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                if (!review && !rest) ...[
                  if (_lastPerformance.isNotEmpty) ...[
                    SectionHeading(title: l.trainingHistoryLastTime),
                    const SizedBox(height: 8),
                    for (final actual in _lastPerformance)
                      Text(
                        l.trainingHistorySetValue(
                          actual.reference.setIndex + 1,
                          actual.reps == null
                              ? l.trainingHistoryTimed
                              : l.trainingHistoryRepsValue(actual.reps!),
                          actual.weightKg == null
                              ? l.trainingActualNoWeight
                              : l.trainingHistoryWeightValue(
                                  actual.weightKg!.toString(),
                                ),
                        ),
                        style: AppType.ui(14, color: t.ink2, height: 1.5),
                      ),
                    const SizedBox(height: 16),
                  ],
                  TrainingActualFields(
                    key: ValueKey('actual-$_phaseIdentity'),
                    timed: _session.exercise.isTimed,
                    reps: _session.actualReps,
                    weightKg: _session.actualWeightKg,
                    enabled: !_leaving && _pendingCompletion == null,
                    onValidityChanged: (valid) {
                      _session.pause();
                      setState(() => _actualValid = valid);
                    },
                    onChanged: (reps, weight) {
                      _session.setCurrentActual(reps: reps, weightKg: weight);
                      _pendingCompletion = null;
                      unawaited(_persist());
                    },
                  ),
                  const SizedBox(height: 16),
                ],
                if (review) ...[
                  SectionHeading(title: l.trainingActualReview),
                  const SizedBox(height: 12),
                  for (final reference in _session.completedSets) ...[
                    Text(
                      '${_session.workout.exercises[reference.exerciseIndex].name} \u00b7 ${l.trainingTimerSet(reference.setIndex + 1, _session.workout.exercises[reference.exerciseIndex].sets)}',
                      style: AppType.ui(
                        15,
                        color: t.ink,
                        weight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (_session
                            .workout
                            .exercises[reference.exerciseIndex]
                            .isTimed &&
                        !_session.actualSets.any(
                          (a) => a.reference == reference,
                        ))
                      TextButton(
                        onPressed: _leaving
                            ? null
                            : () {
                                _session.setCompletedActual(reference);
                                unawaited(_persist());
                              },
                        child: Text(l.trainingActualConfirmLegacyTimed),
                      ),
                    TrainingActualFields(
                      key: ValueKey(
                        'review-${reference.exerciseIndex}-${reference.setIndex}',
                      ),
                      timed: _session
                          .workout
                          .exercises[reference.exerciseIndex]
                          .isTimed,
                      reps: _session.actualSets
                          .where((a) => a.reference == reference)
                          .firstOrNull
                          ?.reps,
                      weightKg: _session.actualSets
                          .where((a) => a.reference == reference)
                          .firstOrNull
                          ?.weightKg,
                      enabled: !_leaving && _pendingCompletion == null,
                      onValidityChanged: (valid) => setState(() {
                        if (valid) {
                          _invalidActuals.remove(reference);
                        } else {
                          _invalidActuals.add(reference);
                        }
                      }),
                      onChanged: (reps, weight) {
                        _session.setCompletedActual(
                          reference,
                          reps: reps,
                          weightKg: weight,
                        );
                        _pendingCompletion = null;
                        unawaited(_persist());
                      },
                    ),
                    const SizedBox(height: 20),
                  ],
                  if (!_completionValuesValid)
                    Text(
                      l.trainingActualMissing,
                      style: AppType.ui(14, color: t.danger),
                    ),
                  Text(
                    l.trainingHistoryNote,
                    style: AppType.ui(13, color: t.ink2),
                  ),
                  const SizedBox(height: 8),
                  SheetField(
                    controller: _note,
                    fieldKey: const ValueKey('training-history-note'),
                    label: null,
                    semanticLabel: l.trainingHistoryNote,
                    hint: l.trainingActualOptional,
                    maxLines: 3,
                    inputFormatters: [_TrainingNoteFormatter()],
                    enabled: !_leaving && _pendingCompletion == null,
                    onChanged: (_) {
                      _pendingCompletion = null;
                      unawaited(_persist());
                    },
                  ),
                  const SizedBox(height: 16),
                ],
                PrimaryActionButton(
                  key: const ValueKey('training-timer-primary'),
                  label: primaryLabel,
                  icon: review || atZero || (!timed && running)
                      ? Icons.check_rounded
                      : running
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  onTap:
                      _leaving ||
                          _pendingCompletion != null ||
                          (!review && !_actualValid) ||
                          (review && !_completionValuesValid)
                      ? null
                      : primaryAction,
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
                  rest
                      ? null
                      : _secondary(
                          'next-set',
                          l.trainingTimerNextSet,
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
                    onPressed:
                        _leaving ||
                            _pendingCompletion != null ||
                            !_completionValuesValid
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
                  onPressed: _leaving || _pendingCompletion != null
                      ? null
                      : () => _exitDialog(discard: true),
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

  bool get _completionValuesValid =>
      _invalidActuals.isEmpty &&
      _session.completedSets.every((ref) {
        final actual = _session.actualSets
            .where((a) => a.reference == ref)
            .firstOrNull;
        return actual != null &&
            (_session.workout.exercises[ref.exerciseIndex].isTimed ||
                actual.reps != null);
      });

  List<TrainingSetActual> get _lastPerformance => lastTrainingPerformance(
    widget.history,
    _session.plan.id,
    _session.exercise.id!,
    isTimed: _session.exercise.isTimed,
  );

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
