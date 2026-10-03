import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../models/training_history.dart';
import '../../models/training_insights.dart';
import '../../models/training_plan.dart';
import '../../models/training_session.dart';
import '../../services/rest_alert_guard.dart';
import '../../services/rest_alerts.dart';
import '../../services/screen_awake.dart';
import '../../services/training_session_controller.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/common/app_snack.dart';
import '../../widgets/common/motion.dart';
import '../../widgets/design/design.dart';
import 'player/player_exercise_card.dart';
import 'player/player_finish_sheet.dart';
import 'player/player_header.dart';
import 'player/player_rest_bar.dart';
import 'player/player_set_row.dart';

enum _SaveIntent { checkpoint, leave, clear, complete }

enum _UnstoredChoice { finish, leave, stay }

/// Owner of the player's keep-awake hold ([ScreenAwake], ruling R16).
const String trainingPlayerAwakeOwner = 'training-player';

/// Debounce of durable writes after field edits (spec A7).
const Duration _editDebounce = Duration(milliseconds: 600);

/// One step of the rest bar's −15 s / +15 s.
const Duration _restStep = Duration(seconds: 15);

/// The list player (spec A1–A7, Option L). The caller provides account-pinned
/// durable storage, rest alerts and the permission gate.
class TrainingPlayerScreen extends StatefulWidget {
  const TrainingPlayerScreen({
    super.key,
    this.plan,
    this.workoutIndex = 0,
    this.initialSnapshot,
    required this.onPersist,
    this.onComplete,
    this.history = const [],
    this.restAlerts = const NoopRestAlertScheduler(),
    this.alertPermission,
    this.screenAwake = const MethodChannelScreenAwake(),
    this.openAlertSettings = openNotificationSettings,
    this.monotonicNow,
  }) : assert((plan == null) != (initialSnapshot == null));

  final TrainingPlan? plan;
  final int workoutIndex;
  final TrainingSessionSnapshot? initialSnapshot;

  /// Stores the checkpoint (null clears it). True only once it is stored;
  /// false when it was refused (the source plan changed). Failures throw.
  final Future<bool> Function(TrainingSessionSnapshot?) onPersist;
  final Future<void> Function(TrainingHistoryEntry)? onComplete;
  final List<TrainingHistoryEntry> history;
  final RestAlertScheduler restAlerts;

  /// Null where notifications are unavailable: no explainer, no chip.
  final RestAlertPermissionGate? alertPermission;
  final ScreenAwake screenAwake;
  final Future<void> Function() openAlertSettings;
  @visibleForTesting
  final Duration Function()? monotonicNow;

  @override
  State<TrainingPlayerScreen> createState() => _TrainingPlayerScreenState();
}

class _TrainingPlayerScreenState extends State<TrainingPlayerScreen>
    with WidgetsBindingObserver {
  late final TrainingSessionController _session;
  late final List<List<TrainingSetActual>> _lastTime;
  late final int _alertId;
  final ScrollController _scroll = ScrollController();
  final TextEditingController _note = TextEditingController();
  final Map<TrainingSetReference, GlobalKey> _rowKeys = {};
  final Set<int> _expanded = {};
  final Set<int> _notesOpen = {};
  // Every (set, 'reps' | 'weight') field holding an invalid value.
  final Set<(TrainingSetReference, String)> _invalid = {};
  Future<void> _writes = Future<void>.value();
  Timer? _debounce;
  Animation<double>? _coverAnimation;
  ModalRoute<dynamic>? _route;
  bool _covered = false;
  bool _allowPop = false;
  bool _leaving = false;
  bool _dialogOpen = false;
  bool _sheetOpen = false;
  bool _hasSaved = false;
  bool _notStored = false;
  bool _saveFailed = false;
  bool _restExpanded = false;
  // Granted until the gate says otherwise: no gate, no chip.
  RestAlertPermission _alertPermission = RestAlertPermission.granted;
  bool _askedAlerts = false;
  bool _alertsChipBusy = false;
  bool _awake = false;
  int _pendingWrites = 0;
  _SaveIntent _retryIntent = _SaveIntent.checkpoint;
  _SaveIntent? _terminalIntent;
  TrainingHistoryEntry? _pendingCompletion;
  ({DateTime at, bool rest})? _scheduledAlert;
  String _identity = '';
  TrainingSetReference? _shownActive;
  int _shownCompleted = 0;
  int _shownPhaseEnds = 0;
  TrainingSessionPhase _shownPhase = TrainingSessionPhase.exercise;

  bool get _enabled => !_leaving && _pendingCompletion == null;

  @override
  void initState() {
    super.initState();
    if ((widget.plan == null) == (widget.initialSnapshot == null)) {
      throw ArgumentError('Provide a training plan or recovery snapshot');
    }
    final snapshot = widget.initialSnapshot;
    final plan = snapshot?.plan ?? widget.plan!;
    final index = snapshot?.workoutIndex ?? widget.workoutIndex;
    final exercises = index >= 0 && index < plan.workouts.length
        ? plan.workouts[index].exercises
        : const <TrainingExercise>[];
    // Spec A2: computed once per route, not per tick.
    _lastTime = [
      for (final exercise in exercises)
        lastTrainingPerformanceFor(
          widget.history,
          planId: plan.id,
          exercise: exercise,
        ),
    ];
    final weighted = [
      for (final exercise in exercises)
        lastWeightedTrainingPerformanceFor(
          widget.history,
          planId: plan.id,
          exercise: exercise,
        ),
    ];
    double? lastWeight(int exercise, int set) =>
        lastTimeWeightForSet(weighted[exercise], set);
    _session = snapshot == null
        ? TrainingSessionController(
            plan: plan,
            workoutIndex: index,
            monotonicNow: widget.monotonicNow,
            canRun: _visible,
            lastWeight: lastWeight,
          )
        : TrainingSessionController.fromSnapshot(
            snapshot,
            monotonicNow: widget.monotonicNow,
            canRun: _visible,
            lastWeight: lastWeight,
          );
    _alertId = restAlertIdForSession(_session.sessionId);
    _note.text = snapshot?.recoveryNote ?? '';
    if (snapshot?.pendingCompletionAt != null) {
      _pendingCompletion = TrainingHistoryEntry.fromRecovery(snapshot!);
      _note.text = _pendingCompletion!.note;
      _saveFailed = true;
      _retryIntent = _SaveIntent.complete;
      _terminalIntent = _SaveIntent.complete;
    }
    _remember();
    _session.addListener(_sessionChanged);
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _openAlerts();
      if (!_leaving) unawaited(_persist());
      _syncAwake();
      _scrollToActive();
      if (_session.phase == TrainingSessionPhase.review) {
        unawaited(_openFinishSheet());
      }
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
  }

  /// Shown and in front: the only state that may start the next timed set
  /// on its own (spec A4) or keep the display awake (A6).
  bool _visible() {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    return mounted &&
        !_leaving &&
        !_dialogOpen &&
        (_route?.isCurrent ?? true) &&
        (lifecycle == null || lifecycle == AppLifecycleState.resumed);
  }

  void _routeCoverageChanged() {
    final covered = (_coverAnimation?.value ?? 0) > 0;
    if (covered != _covered) {
      _covered = covered;
      // A cover never pauses; it only flushes edits (spec A7).
      if (covered && !_leaving) unawaited(_persist());
      if (!covered) _session.catchUp();
      _syncAwake();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Time kept running in the background: apply what passed.
      _session.catchUp();
      _readAlertPermission();
      _scrollToActive();
    } else if (!_leaving) {
      unawaited(_persist());
    }
    _syncAwake();
  }

  String get _currentIdentity =>
      '${_session.exerciseIndex}:${_session.setIndex}:${_session.phase.name}'
      ':${_session.completedSetCount}:${_session.skippedSets.length}'
      ':${_session.phaseEndsAt?.microsecondsSinceEpoch}';

  void _remember() {
    _identity = _currentIdentity;
    _shownActive = _session.activeSet;
    _shownCompleted = _session.completedSetCount;
    _shownPhaseEnds = _session.phaseEnds;
    _shownPhase = _session.phase;
  }

  void _sessionChanged() {
    if (!mounted) return;
    final structural = _identity != _currentIdentity;
    if (structural) {
      final previousActive = _shownActive;
      final previousCompleted = _shownCompleted;
      final previousPhase = _shownPhase;
      final seenEnd =
          _session.phaseEnds != _shownPhaseEnds && _session.lastPhaseEndSeen;
      _remember();
      _invalid.removeWhere(
        (cell) =>
            cell.$1 != _session.activeSet && !_session.isCompleted(cell.$1),
      );
      if (seenEnd) unawaited(HapticFeedback.vibrate());
      _announce(previousCompleted, previousPhase);
      if (_session.phase != TrainingSessionPhase.rest) _restExpanded = false;
      if (_session.activeSet != previousActive) _scrollToActive();
      if (!_leaving) unawaited(_persist());
      if (_session.phase == TrainingSessionPhase.review &&
          previousPhase != TrainingSessionPhase.review) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(_openFinishSheet());
        });
      }
    }
    _syncAlert();
    _syncAwake();
    setState(() {});
  }

  /// Set done, rest start and rest over (spec A7), never per second.
  void _announce(int previousCompleted, TrainingSessionPhase previousPhase) {
    final l = context.l10n;
    final parts = <String>[];
    final last = _session.lastCompleted;
    if (_session.completedSetCount > previousCompleted && last != null) {
      parts.add(
        l.trainingTimerAnnounceSetDone(
          _session.workout.exercises[last.exerciseIndex].name,
          last.setIndex + 1,
        ),
      );
    }
    final active = _session.activeSet;
    if (_session.phase == TrainingSessionPhase.rest &&
        previousPhase != TrainingSessionPhase.rest) {
      parts.add(l.trainingTimerAnnounceRest(_session.displaySeconds));
    } else if (previousPhase == TrainingSessionPhase.rest &&
        _session.phase == TrainingSessionPhase.exercise &&
        active != null) {
      parts.add(
        l.trainingTimerAnnounceRestOver(
          _session.workout.exercises[active.exerciseIndex].name,
          active.setIndex + 1,
        ),
      );
    }
    if (parts.isEmpty) return;
    unawaited(
      SemanticsService.sendAnnouncement(
        View.of(context),
        parts.join(' '),
        Directionality.of(context),
      ),
    );
  }

  // --- Alerts (spec A5) -----------------------------------------------------

  /// Opening or resuming: drop whatever an earlier process planned, then
  /// schedule only what the current phase needs.
  void _openAlerts() {
    unawaited(_quiet(widget.restAlerts.cancelRestAlert(_alertId)));
    _scheduledAlert = null;
    _syncAlert();
    _readAlertPermission();
  }

  void _readAlertPermission() {
    final gate = widget.alertPermission;
    if (gate == null) return;
    unawaited(
      _quiet(
        gate.state().then((state) {
          if (mounted && state != _alertPermission) {
            setState(() => _alertPermission = state);
          }
        }),
      ),
    );
  }

  bool get _alertsOff => _alertPermission != RestAlertPermission.granted;

  void _syncAlert() {
    final ends = _session.phaseEndsAt;
    final want = ends == null || _terminalIntent != null
        ? null
        : (at: ends, rest: _session.phase == TrainingSessionPhase.rest);
    if (want == _scheduledAlert) return;
    _scheduledAlert = want;
    if (want == null) {
      unawaited(_quiet(widget.restAlerts.cancelRestAlert(_alertId)));
      return;
    }
    final l = context.l10n;
    final exercise = _session.exercise;
    final restFollows =
        exercise.restSeconds > 0 &&
        !(_session.exerciseIndex == _session.workout.exercises.length - 1 &&
            _session.setIndex == exercise.sets - 1);
    // D5: generic texts, no exercise names or weights on the lock screen.
    unawaited(
      _quiet(
        widget.restAlerts.scheduleRestAlert(
          id: _alertId,
          at: want.at,
          title: want.rest
              ? l.trainingRestAlertTitle
              : l.trainingIntervalAlertTitle,
          body: want.rest
              ? l.trainingRestAlertBody
              : restFollows
              ? l.trainingIntervalAlertBody
              : l.trainingTimerAlertSetDoneBody,
        ),
      ),
    );
    if (!_askedAlerts && widget.alertPermission != null) {
      _askedAlerts = true;
      unawaited(_explainAlerts());
    }
  }

  /// One in-context explainer before the system prompt, at the first phase
  /// that would alert, only if this device never asked (spec A5) and never
  /// showed it ([RestAlertExplainerMemory]).
  Future<void> _explainAlerts() async {
    final gate = widget.alertPermission!;
    final memory = switch (gate) {
      final RestAlertExplainerMemory memory => memory,
      _ => null,
    };
    RestAlertPermission state;
    bool shown;
    try {
      state = await gate.state();
      shown =
          state == RestAlertPermission.notAsked &&
          (await memory?.explainerShown() ?? false);
    } catch (_) {
      return;
    }
    if (!mounted) return;
    setState(() => _alertPermission = state);
    if (state != RestAlertPermission.notAsked ||
        shown ||
        _leaving ||
        _dialogOpen) {
      return;
    }
    final l = context.l10n;
    _dialogOpen = true;
    // Shown once per device: "Not now" (or a dismissal) leaves the chip,
    // which can still ask the system.
    if (memory != null) unawaited(_quiet(memory.markExplainerShown()));
    final allow = await showEatovaDialog<bool>(
      context: context,
      builder: (context) => EatovaDialog(
        title: l.trainingTimerAlertsTitle,
        content: Text(l.trainingTimerAlertsBody),
        icon: Icons.notifications_active_outlined,
        actions: [
          EatovaDialogAction(
            buttonKey: const ValueKey('training-alerts-allow'),
            label: l.trainingTimerAlertsAllow,
            onPressed: () => Navigator.pop(context, true),
          ),
          EatovaDialogAction(
            buttonKey: const ValueKey('training-alerts-later'),
            label: l.trainingTimerAlertsLater,
            onPressed: () => Navigator.pop(context, false),
            secondary: true,
          ),
        ],
      ),
    );
    _dialogOpen = false;
    if (!mounted) return;
    _session.catchUp();
    _syncAwake();
    if (allow == true) await _requestAlerts(gate);
  }

  /// The system prompt; once granted the running phase is planned again.
  Future<void> _requestAlerts(RestAlertPermissionGate gate) async {
    bool granted;
    try {
      granted = await gate.request();
    } catch (_) {
      granted = false;
    }
    if (!mounted) return;
    setState(
      () => _alertPermission = granted
          ? RestAlertPermission.granted
          : RestAlertPermission.denied,
    );
    if (granted) {
      // Planned before the grant; plan again so the OS delivers it.
      _scheduledAlert = null;
      _syncAlert();
    }
  }

  /// The "Alerts off" chip: the system prompt while this device never
  /// requested it (iOS shows no notification switch in Settings before a
  /// request), the notification settings after a real request or denial.
  Future<void> _alertsOffTapped() async {
    final gate = widget.alertPermission;
    if (gate == null || _alertsChipBusy) return;
    _alertsChipBusy = true;
    try {
      RestAlertPermission state;
      try {
        state = await gate.state();
      } catch (_) {
        state = RestAlertPermission.denied;
      }
      if (!mounted) return;
      switch (state) {
        case RestAlertPermission.notAsked:
          await _requestAlerts(gate);
        case RestAlertPermission.denied:
          setState(() => _alertPermission = state);
          await _quiet(widget.openAlertSettings());
        case RestAlertPermission.granted:
          // Turned on elsewhere meanwhile: no chip, and plan with the grant.
          setState(() => _alertPermission = state);
          _scheduledAlert = null;
          _syncAlert();
      }
    } finally {
      _alertsChipBusy = false;
    }
  }

  // --- Keep awake (spec A6) -------------------------------------------------

  void _syncAwake() {
    final active = _session.activeExercise;
    final want =
        _visible() &&
        _session.isRunning &&
        active != null &&
        active.isTimed &&
        _terminalIntent == null;
    if (want == _awake) return;
    _awake = want;
    unawaited(
      _quiet(
        widget.screenAwake.setKeepAwake(want, owner: trainingPlayerAwakeOwner),
      ),
    );
  }

  // --- Persistence (spec A7) ------------------------------------------------

  TrainingSessionSnapshot _recoverySnapshot() =>
      _pendingCompletion?.recoverySnapshot() ??
      TrainingSessionSnapshot.fromJson({
        ..._session.snapshot().toJson(),
        if (_note.text.isNotEmpty) 'recovery_note': _note.text,
      });

  /// Field edits reach the controller at once; the durable write waits.
  void _persistSoon() {
    _debounce?.cancel();
    _debounce = Timer(_editDebounce, () {
      _debounce = null;
      if (mounted && !_leaving) unawaited(_persist());
    });
  }

  Future<void> _persist([_SaveIntent intent = _SaveIntent.checkpoint]) {
    _debounce?.cancel();
    _debounce = null;
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
      // Finish freezes the workout: no deadline may complete a set while
      // the entry is written or awaits its retry (spec A1).
      if (intent == _SaveIntent.complete) _session.pause();
      _syncAlert();
      _syncAwake();
    }
    _pendingWrites++;
    if (mounted) setState(() {});
    final operation = _writes.then((_) async {
      try {
        if (validationError != null) throw validationError;
        var stored = true;
        if (intent == _SaveIntent.complete) {
          final complete = widget.onComplete;
          if (complete == null) {
            throw StateError('Training history unavailable');
          }
          _pendingCompletion ??= _session.completion(note: _note.text);
          await complete(_pendingCompletion!);
        } else {
          stored = await persist(snapshot);
        }
        if (!mounted) return;
        _saveFailed = false;
        if (intent == _SaveIntent.checkpoint) {
          _hasSaved = stored;
          _notStored = !stored;
          return;
        }
        if (intent == _SaveIntent.leave && !stored) {
          // The place was refused: never close as if it were kept (spec A7).
          // Stay and offer Finish, which still saves the workout.
          _hasSaved = false;
          _notStored = true;
          _leaving = false;
          if (_pendingCompletion != null) {
            // A failed completion still awaits its retry: keep Retry visible.
            _saveFailed = true;
            _retryIntent = _SaveIntent.complete;
            _terminalIntent = _SaveIntent.complete;
          } else {
            _terminalIntent = null;
          }
          _syncAwake();
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) unawaited(_leaveUnstored());
          });
          return;
        }
        _close();
      } on TrainingCompletionDeleted {
        if (!mounted) return;
        showAppSnack(context, context.l10n.trainingHistoryAlreadyDeleted);
        _close();
      } on TrainingCompletionSourceRetired {
        if (!mounted) return;
        showAppSnack(context, context.l10n.trainingHistorySourceChanged);
        _close();
      } catch (_) {
        if (!mounted) return;
        // An older checkpoint cannot unlock or replace a newer terminal intent.
        if (intent == _SaveIntent.checkpoint && _terminalIntent != null) return;
        _saveFailed = true;
        _retryIntent = intent;
        _leaving = false;
      } finally {
        _pendingWrites--;
        if (mounted) setState(() {});
      }
    });
    _writes = operation;
    return operation;
  }

  void _close() {
    setState(() => _allowPop = true);
    // PopScope must rebuild before the programmatic pop.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  /// An explicit workout action abandons a failed exit attempt.
  void _act(VoidCallback action) {
    if (!_enabled) return;
    _terminalIntent = null;
    action();
  }

  // --- Dialogs and the finish sheet -----------------------------------------

  Future<bool> _confirm({required bool discard}) async {
    if (_dialogOpen || _leaving) return false;
    _dialogOpen = true;
    final l = context.l10n;
    final confirmed = await showEatovaDialog<bool>(
      context: context,
      builder: (context) => EatovaConfirmDialog(
        title: discard
            ? l.trainingTimerDiscardTitle
            : l.trainingTimerLeaveTitle,
        body: discard ? l.trainingTimerDiscardBody : l.trainingTimerLeaveBody,
        icon: discard ? Icons.delete_outline_rounded : Icons.pause_rounded,
        destructive: discard,
        cancelLabel: l.trainingTimerStay,
        onCancel: () => Navigator.pop(context, false),
        confirmKey: const ValueKey('training-timer-confirm-exit'),
        confirmLabel: discard
            ? l.trainingTimerDiscard
            : l.trainingTimerSaveLeave,
        onConfirm: () => Navigator.pop(context, true),
      ),
    );
    _dialogOpen = false;
    if (mounted) {
      _session.catchUp();
      _syncAwake();
    }
    return mounted && confirmed == true;
  }

  Future<void> _leave() async {
    // A refused checkpoint cannot keep the place; never promise it.
    if (_notStored && !_leaving) return _leaveUnstored();
    if (!await _confirm(discard: false)) return;
    // Leaving is an explicit pause: no timer runs while the player is gone.
    _session.pause();
    await _persist(_SaveIntent.leave);
  }

  /// Leaving when the place cannot be stored (spec A7): say so and offer
  /// Finish, which still saves the workout with its frozen plan copy. It
  /// also works while a failed completion awaits its retry, so a refused
  /// place never leaves the player without an exit.
  Future<void> _leaveUnstored() async {
    if (_dialogOpen || _sheetOpen || _leaving || !mounted) return;
    _dialogOpen = true;
    final l = context.l10n;
    final canFinish =
        _pendingCompletion != null || _session.completedSetCount > 0;
    final choice = await showEatovaDialog<_UnstoredChoice>(
      context: context,
      builder: (context) => EatovaDialog(
        title: l.trainingTimerLeaveUnstoredTitle,
        content: Text(
          canFinish
              ? l.trainingTimerLeaveUnstoredBody
              : l.trainingTimerLeaveUnstoredBodyEmpty,
        ),
        icon: Icons.cloud_off_rounded,
        actions: [
          if (canFinish)
            EatovaDialogAction(
              buttonKey: const ValueKey('training-timer-unstored-finish'),
              label: l.trainingTimerFinishShort,
              onPressed: () => Navigator.pop(context, _UnstoredChoice.finish),
            ),
          EatovaDialogAction(
            buttonKey: const ValueKey('training-timer-unstored-leave'),
            label: l.trainingTimerLeaveUnstored,
            onPressed: () => Navigator.pop(context, _UnstoredChoice.leave),
            secondary: canFinish,
            destructive: true,
          ),
          EatovaDialogAction(
            buttonKey: const ValueKey('training-timer-unstored-stay'),
            label: l.trainingTimerStay,
            onPressed: () => Navigator.pop(context, _UnstoredChoice.stay),
            secondary: true,
          ),
        ],
      ),
    );
    _dialogOpen = false;
    if (!mounted || _leaving) return;
    _session.catchUp();
    _syncAwake();
    switch (choice) {
      case _UnstoredChoice.finish when _pendingCompletion != null:
        // The sheet is locked behind the pending entry; retry that entry.
        await _persist(_SaveIntent.complete);
      case _UnstoredChoice.finish:
        await _openFinishSheet();
      case _UnstoredChoice.leave:
        _leaveWithoutSaving();
      case _UnstoredChoice.stay || null:
        break;
    }
  }

  /// Closes without a write: the store refused this place, and the dispose
  /// checkpoint must not try again.
  void _leaveWithoutSaving() {
    if (_leaving) return;
    _terminalIntent = _SaveIntent.leave;
    _leaving = true;
    _syncAlert();
    _syncAwake();
    _close();
  }

  Future<void> _discard() async {
    if (!await _confirm(discard: true)) return;
    await _persist(_SaveIntent.clear);
  }

  Future<void> _openFinishSheet() async {
    if (_sheetOpen || _dialogOpen || !_enabled || !mounted) return;
    _sheetOpen = true;
    FocusManager.instance.primaryFocus?.unfocus();
    final choice = await showPlayerFinishSheet(
      context,
      completed: _session.completedSetCount,
      skipped: _session.skippedSets.length,
      open: _session.openSetCount,
      total: _session.totalSets,
      valuesValid: _completionValuesValid,
      note: _note,
      onNoteChanged: _persistSoon,
    );
    _sheetOpen = false;
    if (!mounted || !_enabled) return;
    switch (choice) {
      case PlayerFinishChoice.save:
        await _persist(_SaveIntent.complete);
      case PlayerFinishChoice.logRest:
        _act(_session.completeOpenSetsAsShown);
        await _persist(_SaveIntent.complete);
      case PlayerFinishChoice.discard:
        await _discard();
      case PlayerFinishChoice.keepTraining:
        // Skipped to the end: keep training reopens those skips.
        if (_session.phase == TrainingSessionPhase.review) {
          _act(_session.reopenTrailingSkips);
        }
      case null:
        break;
    }
  }

  bool get _completionValuesValid =>
      _invalid.every((cell) => !_session.isCompleted(cell.$1)) &&
      _session.completedSets.every((reference) {
        final actual = _session.actualFor(reference);
        return actual != null &&
            (_session.workout.exercises[reference.exerciseIndex].isTimed ||
                actual.reps != null);
      });

  // --- List -----------------------------------------------------------------

  GlobalKey _rowKey(TrainingSetReference reference) =>
      _rowKeys.putIfAbsent(reference, GlobalKey.new);

  /// The active row sits above the rest bar and the keyboard (spec A3).
  void _scrollToActive() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final active = _session.activeSet;
      final target = active == null ? null : _rowKeys[active]?.currentContext;
      if (!mounted || target == null) return;
      unawaited(
        Scrollable.ensureVisible(
          target,
          alignment: 0.35,
          duration: motionDuration(context, const Duration(milliseconds: 220)),
          curve: Curves.easeOutCubic,
        ),
      );
    });
  }

  PlayerActions get _actions => PlayerActions(
    complete: () {
      FocusManager.instance.primaryFocus?.unfocus();
      _act(_session.completeActiveSet);
    },
    start: () {
      FocusManager.instance.primaryFocus?.unfocus();
      _act(_session.startActiveSet);
    },
    undo: () => _act(_session.undoLastCompleted),
    skipSet: () => _act(_session.skipActiveSet),
    skipExercise: () => _act(_session.nextExercise),
    completeRemaining: () => _act(_session.completeRemainingAsPlanned),
    editActive: (reps, weightKg) {
      if (!_enabled) return;
      _session.setCurrentActual(reps: reps, weightKg: weightKg);
      setState(() {});
      _persistSoon();
    },
    editCompleted: (reference, reps, weightKg) {
      if (!_enabled) return;
      _session.setCompletedActual(reference, reps: reps, weightKg: weightKg);
      _persistSoon();
    },
    validity: (reference, cell, valid) {
      final changed = valid
          ? _invalid.remove((reference, cell))
          : _invalid.add((reference, cell));
      if (!changed || !mounted) return;
      // An unmounting field reports while the tree is locked; the set is
      // current at once (a finish sheet opening after this frame reads it).
      if (WidgetsBinding.instance.schedulerPhase ==
          SchedulerPhase.persistentCallbacks) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() {});
        });
      } else {
        setState(() {});
      }
    },
    copyLast: (last) {
      if (!_enabled) return;
      // A focused field keeps its text; let it show the copied values.
      FocusManager.instance.primaryFocus?.unfocus();
      final timed = _session.activeExercise?.isTimed ?? true;
      _session.setCurrentActual(
        reps: timed ? null : last.reps ?? _session.actualReps,
        weightKg: last.weightKg,
      );
      setState(() {});
      _persistSoon();
    },
  );

  bool get _activeValid {
    final active = _session.activeSet;
    return active == null || !_invalid.any((cell) => cell.$1 == active);
  }

  PlayerRestState? _restState() {
    final active = _session.activeSet;
    if (_session.phase != TrainingSessionPhase.rest || active == null) {
      return null;
    }
    return PlayerRestState(
      seconds: _session.displaySeconds,
      running: _session.isRunning,
      nextExercise: _session.workout.exercises[active.exerciseIndex].name,
      nextSet: active.setIndex + 1,
      alertsOff: _alertsOff,
      enabled: _enabled,
      onShorter: () => _act(() => _session.adjustRest(-_restStep)),
      onLonger: _session.canAdjustRest(_restStep)
          ? () => _act(() => _session.adjustRest(_restStep))
          : null,
      onSkip: () => _act(_session.continueAfterRest),
      onResume: () => _act(_session.start),
      alertsAsk: _alertPermission == RestAlertPermission.notAsked,
      onAlertsOff: () => unawaited(_alertsOffTapped()),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _coverAnimation?.removeListener(_routeCoverageChanged);
    _debounce?.cancel();
    _session.removeListener(_sessionChanged);
    // External route removal cannot await a save. Retain queue order and never
    // enqueue behind a terminal clear. Root rejects writes after account
    // changes. A running rest keeps its deadline in this checkpoint.
    if (!_leaving && _terminalIntent == null) {
      try {
        final snapshot = _recoverySnapshot();
        final persist = widget.onPersist;
        _writes = _writes
            .then((_) => persist(snapshot))
            .catchError((Object _) => false);
      } catch (_) {
        // Retain the last valid checkpoint if an external edit is invalid.
      }
    }
    // A player never leaves an alert behind (account switch, sign-out).
    unawaited(_quiet(widget.restAlerts.cancelRestAlert(_alertId)));
    if (_awake) {
      unawaited(
        _quiet(
          widget.screenAwake.setKeepAwake(
            false,
            owner: trainingPlayerAwakeOwner,
          ),
        ),
      );
    }
    _session.dispose();
    _scroll.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final t = context.t;
    final rest = _restState();
    final running = _session.isRunning;
    final canResume =
        !running &&
        _session.phase != TrainingSessionPhase.review &&
        _session.remaining > Duration.zero &&
        (_session.phase == TrainingSessionPhase.rest ||
            (_session.exercise.isTimed &&
                _session.remaining < _session.phaseDuration));
    final list = SingleChildScrollView(
      key: const ValueKey('training-player-list'),
      controller: _scroll,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var e = 0; e < _session.workout.exercises.length; e++) ...[
            PlayerExerciseCard(
              key: ValueKey('training-player-exercise-$e'),
              session: _session,
              exerciseIndex: e,
              lastTime: e < _lastTime.length ? _lastTime[e] : const [],
              actions: _actions,
              expanded: _expanded.contains(e),
              onToggleExpanded: () => setState(
                () => _expanded.contains(e)
                    ? _expanded.remove(e)
                    : _expanded.add(e),
              ),
              notesOpen: _notesOpen.contains(e),
              onToggleNotes: () => setState(
                () => _notesOpen.contains(e)
                    ? _notesOpen.remove(e)
                    : _notesOpen.add(e),
              ),
              rowKey: _rowKey,
              activeValid: _activeValid,
              enabled: _enabled,
            ),
            const SizedBox(height: 12),
          ],
          if (!_completionValuesValid) ...[
            Text(
              l.trainingActualMissing,
              style: AppType.ui(14, color: t.danger),
            ),
            const SizedBox(height: 8),
          ],
          Semantics(
            liveRegion: true,
            child: Text(
              _saveFailed
                  ? l.trainingTimerNotSaved
                  : _notStored
                  ? l.trainingTimerNotStored
                  : _pendingWrites > 0
                  ? l.trainingTimerSaving
                  : _hasSaved
                  ? l.trainingTimerSaved
                  : l.trainingTimerNotSaved,
              key: const ValueKey('training-timer-save-status'),
              textAlign: TextAlign.center,
              style: AppType.ui(13, color: _notStored ? t.warning : t.ink2),
            ),
          ),
        ],
      ),
    );

    return PopScope(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_restExpanded) {
          setState(() => _restExpanded = false);
        } else if (!_leaving) {
          unawaited(_leave());
        }
      },
      child: Scaffold(
        backgroundColor: t.bg,
        body: SafeArea(
          child: ReadableWidth(
            child: Stack(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    PlayerHeader(
                      title: _session.workout.title,
                      done: _session.completedSetCount,
                      total: _session.totalSets,
                      elapsed: () => _session.elapsed,
                      enabled: _enabled,
                      backEnabled: !_leaving,
                      onBack: () => unawaited(_leave()),
                      onFinish: () => unawaited(_openFinishSheet()),
                      onDiscard: () => unawaited(_discard()),
                      onPause: running ? () => _act(_session.pause) : null,
                      onResume: canResume
                          ? () => _act(
                              _session.phase == TrainingSessionPhase.rest
                                  ? _session.start
                                  : _session.startActiveSet,
                            )
                          : null,
                    ),
                    if (_saveFailed)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                        child: Row(
                          children: [
                            Expanded(
                              child: Semantics(
                                liveRegion: true,
                                child: Text(
                                  l.trainingTimerSaveFailed,
                                  key: const ValueKey(
                                    'training-timer-save-error',
                                  ),
                                  style: AppType.ui(14, color: t.danger),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            TextButton.icon(
                              key: const ValueKey('training-timer-retry'),
                              onPressed: _pendingWrites > 0
                                  ? null
                                  : () => unawaited(_persist(_retryIntent)),
                              style: TextButton.styleFrom(
                                minimumSize: const Size(0, 48),
                              ),
                              icon: const Icon(Icons.refresh_rounded),
                              label: Text(l.trainingTimerRetry),
                            ),
                          ],
                        ),
                      ),
                    Expanded(child: list),
                    if (rest != null && !_restExpanded)
                      ConstrainedBox(
                        // Large text: the bar scrolls instead of eating the
                        // list (the full view is one tap away).
                        constraints: BoxConstraints(
                          maxHeight: MediaQuery.sizeOf(context).height * 0.4,
                        ),
                        child: PlayerRestBar(
                          rest: rest,
                          onExpand: () => setState(() => _restExpanded = true),
                        ),
                      ),
                  ],
                ),
                if (rest != null && _restExpanded)
                  Positioned.fill(
                    child: PlayerRestView(
                      rest: rest,
                      onCollapse: () => setState(() => _restExpanded = false),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Alerts, the display flag and settings links never break the workout.
Future<void> _quiet(Future<void> future) => future.catchError((Object _) {});
