import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../l10n/l10n.dart';
import '../../models/number_input.dart';
import '../../models/training_history.dart';
import '../../models/training_insights.dart';
import '../../models/training_limits.dart';
import '../../models/training_log.dart';
import '../../models/training_plan.dart';
import '../../services/day_math.dart';
import '../../services/sync_error_messages.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/common/app_snack.dart';
import '../../widgets/common/decimal_text.dart';
import '../../widgets/design/design.dart';

part 'training_log_fields.dart';

/// What the log editor edits. The caller allocates [historyId] once per
/// workout; every Add, retries included, carries it.
sealed class TrainingLogEditorRequest {
  const TrainingLogEditorRequest({required this.historyId});

  final String historyId;
}

/// A workout without a plan: blank, or prefilled from [initial] (a Coach
/// draft, then [fromCoach] shows the review copy).
final class FreeLogRequest extends TrainingLogEditorRequest {
  const FreeLogRequest({
    required super.historyId,
    this.initial,
    this.fromCoach = false,
  });

  final LoggedWorkoutDraft? initial;
  final bool fromCoach;
}

/// Workout [workoutIndex] of the saved [plan], done without the player.
final class PlanAttachedLogRequest extends TrainingLogEditorRequest {
  const PlanAttachedLogRequest({
    required super.historyId,
    required this.plan,
    required this.workoutIndex,
  });

  final TrainingPlan plan;
  final int workoutIndex;
}

/// What became of one Add.
enum TrainingLogSaveOutcome { saved, queued, deleted, blocked, failed }

/// The [TrainingLogSaveOutcome] of a store write such as
/// `HomeStore.logCompletedWorkout`.
Future<TrainingLogSaveOutcome> trainingLogSaveOutcome(
  Future<SyncDelivery> Function() write,
) async {
  try {
    return await write() == SyncDelivery.delivered
        ? TrainingLogSaveOutcome.saved
        : TrainingLogSaveOutcome.queued;
  } on TrainingCompletionDeleted {
    return TrainingLogSaveOutcome.deleted;
  } on TrainingLogBlockedBySession {
    return TrainingLogSaveOutcome.blocked;
  } catch (_) {
    return TrainingLogSaveOutcome.failed;
  }
}

/// Opens the log editor. Nothing is written before Add, which hands one
/// entry with the request's ID to [onSave] at a time. Closes on saved,
/// queued or deleted and returns that outcome; null when dismissed.
/// [history] feeds name suggestions and "Last time" prefills.
Future<TrainingLogSaveOutcome?> showTrainingLogEditor(
  BuildContext context, {
  required TrainingLogEditorRequest request,
  required Future<TrainingLogSaveOutcome> Function(TrainingHistoryEntry entry)
  onSave,
  List<TrainingHistoryEntry> history = const [],
}) => showEatovaSheet<TrainingLogSaveOutcome>(
  context,
  _TrainingLogEditor(request: request, onSave: onSave, history: history),
  dragHandle: false,
  enableDrag: false,
);

class _TrainingLogEditor extends StatefulWidget {
  const _TrainingLogEditor({
    required this.request,
    required this.onSave,
    required this.history,
  });

  final TrainingLogEditorRequest request;
  final Future<TrainingLogSaveOutcome> Function(TrainingHistoryEntry) onSave;
  final List<TrainingHistoryEntry> history;

  @override
  State<_TrainingLogEditor> createState() => _TrainingLogEditorState();
}

class _TrainingLogEditorState extends State<_TrainingLogEditor> {
  final _title = TextEditingController();
  final _note = TextEditingController();
  final _duration = _NumberField(
    1,
    TrainingLogLimits.durationMinutesMax,
    digits: 3,
  );
  final _scroll = ScrollController();
  final List<_FreeExercise> _exercises = [];
  final List<List<_PlannedSet>> _planned = [];
  late final List<_KnownExercise> _known = _knownExercises(widget.history);
  DateTime? _day;
  bool _ready = false;
  bool _dirty = false;
  bool _busy = false;
  bool _closing = false;
  String? _error;

  PlanAttachedLogRequest? get _plan => switch (widget.request) {
    final PlanAttachedLogRequest request => request,
    FreeLogRequest() => null,
  };

  bool get _fromCoach => switch (widget.request) {
    FreeLogRequest(:final fromCoach) => fromCoach,
    PlanAttachedLogRequest() => false,
  };

  List<TrainingExercise> get _plannedExercises {
    final plan = _plan;
    if (plan == null ||
        plan.workoutIndex < 0 ||
        plan.workoutIndex >= plan.plan.workouts.length) {
      return const [];
    }
    return plan.plan.workouts[plan.workoutIndex].exercises;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Weight prefills are locale-formatted ("62,5" under de).
    if (_ready) return;
    _ready = true;
    final l10n = context.l10n;
    final today = startOfDay(clock.now());
    switch (widget.request) {
      case FreeLogRequest(:final initial?):
        _title.text = initial.title;
        _note.text = initial.note;
        _duration.controller.text = initial.durationMinutes?.toString() ?? '';
        _day = switch (initial.performedOn) {
          final day? => startOfDay(day),
          null => null,
        };
        _exercises.addAll([
          for (final exercise in initial.exercises)
            _FreeExercise(
              name: exercise.name,
              timed: exercise.timed,
              durationSeconds: exercise.durationSeconds,
              sets: [
                for (final set in exercise.sets)
                  _FreeSet(
                    reps: exercise.timed ? '' : set.reps?.toString() ?? '',
                    weight: _weightText(set.weightKg, l10n),
                  ),
              ],
            ),
        ]);
        if (_exercises.isEmpty) _exercises.add(_FreeExercise());
      case FreeLogRequest():
        _day = today;
        _exercises.add(_FreeExercise());
      case PlanAttachedLogRequest(:final plan):
        _day = today;
        _planned.addAll([
          for (final exercise in _plannedExercises)
            _plannedSets(plan.id, exercise, l10n),
        ]);
    }
  }

  /// Planned reps; weights from "Last time" set k (or its last set) unless
  /// that session recorded no weight at all (spec A2).
  List<_PlannedSet> _plannedSets(
    String planId,
    TrainingExercise exercise,
    AppLocalizations l10n,
  ) {
    final last = lastTrainingPerformanceFor(
      widget.history,
      planId: planId,
      exercise: exercise,
    );
    final weighted = last.any((set) => set.weightKg != null);
    return [
      for (var s = 0; s < exercise.sets; s++)
        _PlannedSet(
          reps: exercise.isTimed ? '' : '${exercise.reps}',
          weight: weighted
              ? _weightText(
                  (s < last.length ? last[s] : last.last).weightKg,
                  l10n,
                )
              : '',
        ),
    ];
  }

  static String _weightText(double? kg, AppLocalizations l10n) =>
      kg == null ? '' : formatDecimalInput(kg, l10n);

  @override
  void dispose() {
    _title.dispose();
    _note.dispose();
    _duration.dispose();
    _scroll.dispose();
    for (final exercise in _exercises) {
      exercise.dispose();
    }
    for (final sets in _planned) {
      for (final set in sets) {
        set.dispose();
      }
    }
    super.dispose();
  }

  void _changed() => setState(() {
    _dirty = true;
    _error = null;
  });

  bool get _hasInvalidInput {
    if (_duration.invalid) return true;
    if (_plan == null) return _exercises.any((e) => e.hasInvalidInput);
    final exercises = _plannedExercises;
    for (var e = 0; e < _planned.length; e++) {
      for (final set in _planned[e]) {
        if (set.done &&
            ((!exercises[e].isTimed && set.reps.invalid) ||
                set.weight.invalid)) {
          return true;
        }
      }
    }
    return false;
  }

  LoggedWorkoutDraft _freeDraft() => LoggedWorkoutDraft(
    title: _title.text,
    performedOn: _day,
    durationMinutes: _duration.value?.toInt(),
    note: _note.text,
    otherDaysOmitted: switch (widget.request) {
      FreeLogRequest(:final initial?) => initial.otherDaysOmitted,
      _ => false,
    },
    exercises: [for (final exercise in _exercises) exercise.toLogged()],
  );

  /// Mirrors the guards of [buildPlanAttachedLog]; [LoggedWorkoutProblem.empty]
  /// means no set is ticked.
  List<LoggedWorkoutProblem> _plannedProblems(DateTime now) {
    final exercises = _plannedExercises;
    final day = _day;
    final back = day == null ? 0 : daysBetween(now.toLocal(), day);
    var missingReps = false;
    for (var e = 0; e < _planned.length; e++) {
      missingReps |=
          !exercises[e].isTimed &&
          _planned[e].any((set) => set.done && set.reps.value == null);
    }
    var note = true;
    try {
      TrainingJson.text(_note.text.trim(), TrainingLimits.notesMaxLength);
    } on FormatException {
      note = false;
    }
    return [
      if (!_planned.any((sets) => sets.any((set) => set.done)))
        LoggedWorkoutProblem.empty,
      if (day == null) LoggedWorkoutProblem.missingDate,
      if (back < 0 || back > TrainingLogLimits.daysBack)
        LoggedWorkoutProblem.dateOutOfRange,
      if (missingReps) LoggedWorkoutProblem.missingReps,
      if (!note) LoggedWorkoutProblem.tooLarge,
    ];
  }

  List<LoggedWorkoutProblem> _problems(DateTime now) => _plan == null
      ? validateLoggedWorkout(_freeDraft(), now: now)
      : _plannedProblems(now);

  String _problemText(AppLocalizations l10n, LoggedWorkoutProblem problem) =>
      switch (problem) {
        LoggedWorkoutProblem.empty =>
          _plan == null
              ? l10n.trainingLogProblemEmpty
              : l10n.trainingLogProblemNoSetDone,
        LoggedWorkoutProblem.missingDate ||
        LoggedWorkoutProblem.dateOutOfRange => l10n.trainingLogProblemDate(
          TrainingLogLimits.daysBack,
        ),
        LoggedWorkoutProblem.missingReps => l10n.trainingLogProblemReps,
        LoggedWorkoutProblem.missingDuration => l10n.trainingLogProblemDuration,
        LoggedWorkoutProblem.tooLarge => l10n.trainingLogProblemRange,
      };

  TrainingHistoryEntry _build(DateTime now, AppLocalizations l10n) {
    final request = widget.request;
    return switch (request) {
      FreeLogRequest() => buildLoggedWorkout(
        historyId: request.historyId,
        draft: _freeDraft(),
        now: now,
        fallbackTitle: l10n.trainingLogDefaultTitle,
      ),
      PlanAttachedLogRequest() => buildPlanAttachedLog(
        historyId: request.historyId,
        plan: request.plan,
        workoutIndex: request.workoutIndex,
        sets: [
          for (var e = 0; e < _planned.length; e++)
            [
              for (final set in _planned[e])
                PlanAttachedSet(
                  done: set.done,
                  reps: _plannedExercises[e].isTimed
                      ? null
                      : set.reps.value?.toInt(),
                  weightKg: set.weight.value?.toDouble(),
                ),
            ],
        ],
        performedOn: _day!,
        durationMinutes: _duration.value?.toInt(),
        note: _note.text,
        now: now,
      ),
    };
  }

  Future<void> _save() async {
    if (_busy) return;
    final l10n = context.l10n;
    final now = clock.now();
    final problems = _problems(now);
    if (_hasInvalidInput || problems.isNotEmpty) {
      setState(
        () => _error = problems.isEmpty
            ? l10n.trainingPageInvalid
            : _problemText(l10n, problems.first),
      );
      return;
    }
    final entry = _build(now, l10n);
    setState(() {
      _busy = true;
      _error = null;
    });
    FocusManager.instance.primaryFocus?.unfocus();
    TrainingLogSaveOutcome outcome;
    try {
      outcome = await widget.onSave(entry);
    } catch (_) {
      outcome = TrainingLogSaveOutcome.failed;
    }
    if (!mounted) return;
    switch (outcome) {
      case TrainingLogSaveOutcome.saved || TrainingLogSaveOutcome.queued:
        showAppSnack(
          context,
          deliveryHint(
            l10n.trainingLogSaved,
            outcome == TrainingLogSaveOutcome.saved
                ? SyncDelivery.delivered
                : SyncDelivery.queuedRetry,
            l10n,
          ),
        );
        Navigator.pop(context, outcome);
      case TrainingLogSaveOutcome.deleted:
        // This ID can never be added again; the sheet has nothing left to do.
        showAppSnack(context, l10n.trainingLogDeleted, tone: SnackTone.warning);
        Navigator.pop(context, outcome);
      case TrainingLogSaveOutcome.blocked || TrainingLogSaveOutcome.failed:
        setState(() {
          _busy = false;
          _error = outcome == TrainingLogSaveOutcome.blocked
              ? l10n.trainingLogBlocked
              : l10n.trainingLogSaveError;
        });
    }
  }

  Future<void> _close() async {
    if (_busy || _closing) return;
    if (!_dirty) {
      Navigator.pop(context);
      return;
    }
    _closing = true;
    final l10n = context.l10n;
    final discard = await showEatovaDialog<bool>(
      context: context,
      builder: (dialogContext) => EatovaConfirmDialog(
        key: const ValueKey('training-log-discard-dialog'),
        title: l10n.trainingPageDiscardTitle,
        body: l10n.trainingPageDiscardBody,
        icon: Icons.edit_off_rounded,
        destructive: true,
        cancelLabel: l10n.trainingPageKeepEditing,
        onCancel: () => Navigator.pop(dialogContext, false),
        confirmKey: const ValueKey('training-log-discard-confirm'),
        confirmLabel: l10n.trainingPageDiscard,
        onConfirm: () => Navigator.pop(dialogContext, true),
      ),
    );
    _closing = false;
    if (mounted && discard == true) Navigator.pop(context);
  }

  void _setDay(DateTime day) {
    _day = day;
    _changed();
  }

  Future<void> _pickDay() async {
    final today = startOfDay(clock.now());
    final first = addDays(today, -TrainingLogLimits.daysBack);
    final current = _day;
    final picked = await showDatePicker(
      context: context,
      initialDate:
          current == null || current.isBefore(first) || current.isAfter(today)
          ? today
          : current,
      firstDate: first,
      lastDate: today,
      currentDate: today,
    );
    if (mounted && picked != null) _setDay(startOfDay(picked));
  }

  /// A picked name takes its kind and, while nothing is typed yet, the sets
  /// of its last performance.
  void _pickName(_FreeExercise exercise, _KnownExercise known) {
    exercise.name.text = known.name;
    if (exercise.blank) {
      exercise.timed = known.timed;
      final seconds = known.durationSeconds;
      if (known.timed && seconds != null) {
        exercise.minutes.controller.text = seconds < 60
            ? ''
            : '${seconds ~/ 60}';
        exercise.seconds.controller.text = seconds % 60 == 0
            ? ''
            : '${seconds % 60}';
      }
      // No plan has an empty ID, so every plan and log is searched.
      final last = lastTrainingPerformanceByName(
        widget.history,
        excludePlanId: '',
        exerciseName: known.name,
        isTimed: known.timed,
      );
      if (last.isNotEmpty) {
        final l10n = context.l10n;
        for (final set in exercise.sets) {
          set.dispose();
        }
        exercise.sets
          ..clear()
          ..addAll([
            for (final set in last.take(TrainingLimits.setsMax))
              _FreeSet(
                reps: known.timed ? '' : set.reps?.toString() ?? '',
                weight: _weightText(set.weightKg, l10n),
              ),
          ]);
      }
    }
    _changed();
  }

  List<_KnownExercise> _suggestions(_FreeExercise exercise) {
    final typed = normalizeExerciseName(exercise.name.text);
    if (typed.isEmpty) return _known.take(4).toList();
    if (_known.any((known) => known.key == typed)) return const [];
    return [
      ..._known.where((known) => known.key.startsWith(typed)),
      ..._known.where(
        (known) => !known.key.startsWith(typed) && known.key.contains(typed),
      ),
    ].take(4).toList();
  }

  void _plannedWeightChanged(List<_PlannedSet> sets, int index) {
    sets[index].weightEdited = true;
    final text = sets[index].weight.controller.text;
    for (var s = index + 1; s < sets.length; s++) {
      if (!sets[s].weightEdited) sets[s].weight.controller.text = text;
    }
    _changed();
  }

  @override
  Widget build(BuildContext context) {
    final problems = _problems(clock.now());
    final invalid = _hasInvalidInput;
    final ready = !_busy && !invalid && problems.isEmpty;
    final hint = invalid
        ? context.l10n.trainingPageInvalid
        : problems.isEmpty
        ? null
        : _problemText(context.l10n, problems.first);
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    return PopScope(
      canPop: !_busy && !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: SheetDismissGuard(
        // Own the gesture from pointer-down; dirty/busy may change mid-drag.
        active: true,
        followDrag: true,
        onDismissAttempt: _close,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Short sheets with large text scroll as a whole: a pinned header
            // and footer would leave the fields no room at all.
            final compact = constraints.maxHeight < 400 * scale;
            final header = Padding(
              padding: EdgeInsets.fromLTRB(compact ? 0 : 20, 14, 12, 10),
              child: _header(context),
            );
            final footer = _footer(context, hint: hint, ready: ready);
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SheetHandle(onDismiss: _close),
                if (!compact) header,
                Flexible(
                  child: SingleChildScrollView(
                    key: const ValueKey('training-log-scroll'),
                    controller: _scroll,
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    padding: EdgeInsets.fromLTRB(20, 0, 20, compact ? 0 : 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (compact) header,
                        ..._content(context),
                        if (compact) footer,
                      ],
                    ),
                  ),
                ),
                if (!compact)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: footer,
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  List<Widget> _content(BuildContext context) {
    final l10n = context.l10n;
    final plan = _plan;
    return [
      if (plan != null)
        _intro(context, l10n.trainingLogPlannedBody)
      else if (_fromCoach)
        _intro(context, l10n.trainingLogReviewBody),
      if (plan == null)
        _textField(
          controller: _title,
          label: l10n.trainingLogName,
          hint: l10n.trainingLogDefaultTitle,
          key: 'training-log-title',
          maxLength: TrainingLimits.titleMaxLength,
        ),
      _label(context, l10n.trainingLogDay),
      _dayChips(context),
      const SizedBox(height: 16),
      _label(context, l10n.trainingLogDuration),
      _numberField(
        _duration,
        key: 'training-log-duration',
        semantic: l10n.trainingLogDuration,
        hint: l10n.trainingActualOptional,
        gap: 18,
      ),
      if (plan == null) ...[
        for (var e = 0; e < _exercises.length; e++) _freeExercise(context, e),
        CreationAddButton(
          key: const ValueKey('training-log-add-exercise'),
          label: l10n.trainingPageAddExercise,
          onPressed: _busy || _exercises.length >= TrainingLimits.exercisesMax
              ? null
              : () {
                  _exercises.add(_FreeExercise());
                  _changed();
                },
        ),
        const SizedBox(height: 18),
      ] else
        for (var e = 0; e < _planned.length; e++) _plannedExercise(context, e),
      _textField(
        controller: _note,
        label: l10n.trainingHistoryNote,
        hint: l10n.trainingActualOptional,
        key: 'training-log-note',
        maxLength: TrainingLimits.notesMaxLength,
        lines: 3,
      ),
    ];
  }

  /// The reason Add is disabled (or the last failure) above the button.
  Widget _footer(
    BuildContext context, {
    required String? hint,
    required bool ready,
  }) {
    final t = context.t;
    final l10n = context.l10n;
    final message = _error ?? (_busy ? null : hint);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (message != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    message,
                    style: AppType.ui(
                      14,
                      color: _error != null ? t.danger : t.ink2,
                      height: 1.4,
                    ),
                  ),
                ),
              ),
            if (_busy)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: LinearProgressIndicator(color: t.accent),
              ),
            PrimaryActionButton(
              key: const ValueKey('training-log-save'),
              label: _busy ? l10n.trainingPageSaving : l10n.trainingLogSave,
              onTap: ready ? _save : null,
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final plan = _plan;
    final title = plan != null
        ? (_plannedExercises.isEmpty
              ? l10n.trainingLogAsDone
              : plan.plan.workouts[plan.workoutIndex].title)
        : _fromCoach
        ? l10n.trainingLogReviewTitle
        : l10n.trainingLogTitle;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (plan != null) ...[
                Text(
                  l10n.trainingLogAsDone.toUpperCase(),
                  semanticsLabel: l10n.trainingLogAsDone,
                  style: AppType.eyebrow(t.accentText),
                ),
                const SizedBox(height: 4),
              ],
              HeadingSemantics(
                level: 1,
                child: Text(
                  title,
                  style: AppType.display(24, color: t.ink, height: 1.15),
                ),
              ),
            ],
          ),
        ),
        IconButton(
          key: const ValueKey('training-log-close'),
          onPressed: _busy ? null : _close,
          tooltip: l10n.trainingPageClose,
          icon: const Icon(Icons.close_rounded),
        ),
      ],
    );
  }

  Widget _intro(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 18),
    child: Text(
      text,
      style: AppType.ui(14, color: context.t.ink2, height: 1.45),
    ),
  );

  Widget _label(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      text,
      style: AppType.ui(13, color: context.t.ink2, weight: FontWeight.w500),
    ),
  );

  Widget _textField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required String key,
    required int maxLength,
    int lines = 1,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _label(context, label),
      SheetField(
        fieldKey: ValueKey(key),
        label: null,
        semanticLabel: label,
        hint: hint,
        controller: controller,
        enabled: !_busy,
        maxLines: lines,
        maxLength: maxLength,
        keyboardType: lines > 1 ? TextInputType.multiline : TextInputType.text,
        textCapitalization: TextCapitalization.sentences,
        onChanged: (_) => _changed(),
        bottomGap: 18,
      ),
    ],
  );

  Widget _numberField(
    _NumberField field, {
    required String key,
    required String semantic,
    String hint = '',
    bool enabled = true,
    double gap = 0,
    ValueChanged<String>? onChanged,
  }) => SheetField(
    key: ObjectKey(field),
    fieldKey: ValueKey(key),
    label: null,
    semanticLabel: semantic,
    hint: hint,
    controller: field.controller,
    enabled: enabled && !_busy,
    keyboardType: TextInputType.numberWithOptions(decimal: field.decimal),
    inputFormatters: [DigitBudgetFormatter(field.digits)],
    errorText: enabled ? field.error(context.l10n) : null,
    onChanged: onChanged ?? (_) => _changed(),
    bottomGap: gap,
  );

  Widget _chip({
    required String key,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final t = context.t;
    return ChoiceChip(
      key: ValueKey(key),
      selected: selected,
      label: Text(label),
      selectedColor: t.lime,
      checkmarkColor: t.onLime,
      labelStyle: AppType.ui(14, color: selected ? t.onLime : t.ink2),
      onSelected: _busy ? null : (_) => onTap(),
    );
  }

  Widget _dayChips(BuildContext context) {
    final l10n = context.l10n;
    final today = startOfDay(clock.now());
    final yesterday = addDays(today, -1);
    final day = _day;
    final other = day != null && day != today && day != yesterday;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _chip(
          key: 'training-log-day-today',
          label: l10n.trainingLogToday,
          selected: day == today,
          onTap: () => _setDay(today),
        ),
        _chip(
          key: 'training-log-day-yesterday',
          label: l10n.trainingLogYesterday,
          selected: day == yesterday,
          onTap: () => _setDay(yesterday),
        ),
        _chip(
          key: 'training-log-day-pick',
          label: other
              ? DateFormat.MMMEd(l10n.localeName).format(day)
              : l10n.trainingLogOtherDay,
          selected: other,
          onTap: _pickDay,
        ),
      ],
    );
  }

  /// The column captions above set rows; the fields carry their own names.
  Widget _columns(
    BuildContext context, {
    required double lead,
    required bool reps,
    required double trailing,
  }) {
    final l10n = context.l10n;
    Widget caption(String text) => Expanded(
      child: Text(
        text.toUpperCase(),
        style: AppType.eyebrow(context.t.ink2, size: 9.5),
      ),
    );
    return ExcludeSemantics(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          children: [
            SizedBox(width: lead),
            if (reps) ...[
              caption(l10n.trainingLogReps),
              const SizedBox(width: 10),
            ],
            caption(l10n.trainingLogKg),
            SizedBox(width: trailing),
          ],
        ),
      ),
    );
  }

  Widget _card(Key key, List<Widget> children) => Padding(
    key: key,
    padding: const EdgeInsets.only(bottom: 14),
    child: Material(
      color: context.t.surf,
      borderRadius: BorderRadius.circular(rCard),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    ),
  );

  Widget _freeExercise(BuildContext context, int e) {
    final t = context.t;
    final l10n = context.l10n;
    final exercise = _exercises[e];
    final prefix = 'training-log-exercise-$e';
    final suggestions = _suggestions(exercise);
    return _card(ObjectKey(exercise), [
      Row(
        children: [
          Expanded(
            child: Text(
              l10n.trainingPageExerciseNumber(e + 1),
              style: AppType.ui(15, color: t.ink, weight: FontWeight.w600),
            ),
          ),
          if (_exercises.length > 1)
            IconButton(
              key: ValueKey('$prefix-remove'),
              tooltip: l10n.trainingPageRemoveExercise,
              onPressed: _busy
                  ? null
                  : () {
                      _exercises.removeAt(e).dispose();
                      _changed();
                    },
              icon: const Icon(Icons.delete_outline_rounded),
            )
          else
            const SizedBox(height: 48),
        ],
      ),
      Padding(
        padding: const EdgeInsets.only(right: 8),
        child: SheetField(
          key: ObjectKey(exercise.name),
          fieldKey: ValueKey('$prefix-name'),
          label: null,
          semanticLabel: l10n.trainingPageExerciseName,
          hint: l10n.trainingPageExerciseNameHint,
          controller: exercise.name,
          enabled: !_busy,
          maxLength: TrainingLimits.titleMaxLength,
          textCapitalization: TextCapitalization.sentences,
          onChanged: (_) => _changed(),
        ),
      ),
      if (suggestions.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var i = 0; i < suggestions.length; i++)
                ActionChip(
                  key: ValueKey('$prefix-suggestion-$i'),
                  avatar: Icon(Icons.history_rounded, size: 16, color: t.ink2),
                  label: Text(suggestions[i].name),
                  onPressed: _busy
                      ? null
                      : () => _pickName(exercise, suggestions[i]),
                ),
            ],
          ),
        ),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final timed in [false, true])
            _chip(
              key: '$prefix-${timed ? 'timed' : 'reps'}',
              label: timed
                  ? l10n.trainingPageTimed
                  : l10n.trainingPageRepetitions,
              selected: exercise.timed == timed,
              onTap: () {
                exercise.timed = timed;
                _changed();
              },
            ),
        ],
      ),
      const SizedBox(height: 12),
      if (exercise.timed) ...[
        _label(context, l10n.trainingLogDurationPerSet),
        Padding(
          padding: const EdgeInsets.only(right: 8, bottom: 12),
          child: CreationFieldGrid(
            children: [
              _numberField(
                exercise.minutes,
                key: '$prefix-minutes',
                semantic: l10n.trainingLogMinutes,
                hint: l10n.trainingLogMinutes,
              ),
              _numberField(
                exercise.seconds,
                key: '$prefix-seconds',
                semantic: l10n.trainingLogSeconds,
                hint: l10n.trainingLogSeconds,
              ),
            ],
          ),
        ),
      ],
      _columns(
        context,
        lead: _numberWidth(context),
        reps: !exercise.timed,
        trailing: 48,
      ),
      for (var s = 0; s < exercise.sets.length; s++)
        _freeSetRow(context, exercise, prefix, s),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton.icon(
          key: ValueKey('$prefix-add-set'),
          onPressed: _busy || exercise.sets.length >= TrainingLimits.setsMax
              ? null
              : () {
                  // "Add set" repeats the last set (spec B).
                  final last = exercise.sets.last;
                  exercise.sets.add(
                    _FreeSet(
                      reps: last.reps.controller.text,
                      weight: last.weight.controller.text,
                    ),
                  );
                  _changed();
                },
          style: TextButton.styleFrom(minimumSize: const Size(0, 48)),
          icon: const Icon(Icons.add_rounded, size: 20),
          label: Text(l10n.trainingLogAddSet),
        ),
      ),
    ]);
  }

  /// Wide enough for "10" at any text size.
  double _numberWidth(BuildContext context) =>
      MediaQuery.textScalerOf(context).scale(24);

  Widget _setNumber(BuildContext context, int s) => SizedBox(
    width: _numberWidth(context),
    child: ExcludeSemantics(
      child: Text(
        '${s + 1}',
        style: AppType.ui(14, color: context.t.ink2, weight: FontWeight.w700),
      ),
    ),
  );

  Widget _freeSetRow(
    BuildContext context,
    _FreeExercise exercise,
    String exercisePrefix,
    int s,
  ) {
    final l10n = context.l10n;
    final set = exercise.sets[s];
    final prefix = '$exercisePrefix-set-$s';
    return Padding(
      key: ObjectKey(set),
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          _setNumber(context, s),
          if (!exercise.timed) ...[
            Expanded(
              child: _numberField(
                set.reps,
                key: '$prefix-reps',
                semantic: l10n.trainingLogRepsSemantics(s + 1),
              ),
            ),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: _numberField(
              set.weight,
              key: '$prefix-weight',
              semantic: l10n.trainingLogWeightSemantics(s + 1),
            ),
          ),
          if (exercise.sets.length > 1)
            IconButton(
              key: ValueKey('$prefix-remove'),
              tooltip: l10n.trainingLogRemoveSet(s + 1),
              onPressed: _busy
                  ? null
                  : () {
                      exercise.sets.removeAt(s).dispose();
                      _changed();
                    },
              icon: const Icon(Icons.close_rounded),
            )
          else
            const SizedBox(width: 48),
        ],
      ),
    );
  }

  Widget _plannedExercise(BuildContext context, int e) {
    final t = context.t;
    final l10n = context.l10n;
    final exercise = _plannedExercises[e];
    final sets = _planned[e];
    final timed = exercise.isTimed;
    return _card(ValueKey('training-log-planned-$e'), [
      Padding(
        padding: const EdgeInsets.only(top: 4, right: 8, bottom: 10),
        child: Wrap(
          spacing: 10,
          runSpacing: 2,
          crossAxisAlignment: WrapCrossAlignment.end,
          children: [
            Text(
              exercise.name,
              style: AppType.ui(15, color: t.ink, weight: FontWeight.w700),
            ),
            Text(
              timed
                  ? l10n.trainingPageSetsTime(
                      exercise.sets,
                      exercise.durationSeconds!,
                    )
                  : l10n.trainingPageSetsReps(exercise.sets, exercise.reps!),
              style: AppType.ui(13, color: t.ink2),
            ),
          ],
        ),
      ),
      _columns(
        context,
        lead: _numberWidth(context) + 58,
        reps: !timed,
        trailing: 0,
      ),
      for (var s = 0; s < sets.length; s++)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            children: [
              _setNumber(context, s),
              _DoneToggle(
                key: ValueKey('training-log-planned-$e-$s-done'),
                done: sets[s].done,
                label: l10n.trainingLogSetDone(s + 1),
                onTap: _busy
                    ? null
                    : () {
                        sets[s].done = !sets[s].done;
                        _changed();
                      },
              ),
              const SizedBox(width: 10),
              if (!timed) ...[
                Expanded(
                  child: _numberField(
                    sets[s].reps,
                    key: 'training-log-planned-$e-$s-reps',
                    semantic: l10n.trainingLogRepsSemantics(s + 1),
                    enabled: sets[s].done,
                  ),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: _numberField(
                  sets[s].weight,
                  key: 'training-log-planned-$e-$s-weight',
                  semantic: l10n.trainingLogWeightSemantics(s + 1),
                  enabled: sets[s].done,
                  onChanged: (_) => _plannedWeightChanged(sets, s),
                ),
              ),
            ],
          ),
        ),
    ]);
  }
}
