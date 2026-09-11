import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../models/coach_training_proposal.dart';
import '../../models/training_plan.dart';
import '../../services/sync_error_messages.dart';
import '../../services/uuid.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/common/app_snack.dart';
import '../../widgets/design/design.dart';
import 'training_exercise_list.dart';

part 'training_plan_fields.dart';

/// Draft review and editing never persist data before the explicit save action.
Future<bool> showTrainingPlanEditor(
  BuildContext context, {
  CoachTrainingProposal? initialDraft,
  required Future<SyncDelivery> Function(CoachTrainingProposal) onSave,
  String? submitLabel,
}) async =>
    await showEatovaSheet<bool>(
      context,
      _TrainingPlanEditor(
        initialDraft: initialDraft,
        onSave: onSave,
        submitLabel: submitLabel,
      ),
      dragHandle: false,
      enableDrag: false,
    ) ??
    false;

class _TrainingPlanEditor extends StatefulWidget {
  const _TrainingPlanEditor({
    this.initialDraft,
    required this.onSave,
    this.submitLabel,
  });

  final CoachTrainingProposal? initialDraft;
  final Future<SyncDelivery> Function(CoachTrainingProposal) onSave;
  final String? submitLabel;

  @override
  State<_TrainingPlanEditor> createState() => _TrainingPlanEditorState();
}

class _TrainingPlanEditorState extends State<_TrainingPlanEditor> {
  late final _PlanText _title;
  late final _PlanText _description;
  late final _PlanText _goal;
  late final List<_WorkoutFields> _workouts;
  late bool _editing;
  bool _dirty = false;
  bool _busy = false;
  bool _closing = false;
  String? _error;
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    final draft = widget.initialDraft;
    _editing = draft == null;
    _title = _PlanText(
      draft?.title ?? '',
      TrainingLimits.titleMaxLength,
      required: true,
    );
    _description = _PlanText(
      draft?.description ?? '',
      TrainingLimits.descriptionMaxLength,
    );
    _goal = _PlanText(draft?.goal ?? '', TrainingLimits.goalMaxLength);
    _workouts =
        draft?.workouts.map(_WorkoutFields.new).toList() ??
        [_WorkoutFields(null)];
  }

  @override
  void dispose() {
    _scroll.dispose();
    for (final value in [_title, _description, _goal]) {
      value.dispose();
    }
    for (final workout in _workouts) {
      workout.dispose();
    }
    super.dispose();
  }

  Iterable<_PlanText> get _values sync* {
    yield* [_title, _description, _goal];
    for (final workout in _workouts) {
      yield* workout.values;
    }
  }

  void _changed() => setState(() {
    _dirty = true;
    _error = null;
  });

  Future<void> _close() async {
    if (_busy || _closing) return;
    if (!_dirty) {
      Navigator.pop(context, false);
      return;
    }
    _closing = true;
    final l10n = context.l10n;
    final discard = await showEatovaDialog<bool>(
      context: context,
      builder: (dialogContext) => EatovaConfirmDialog(
        key: const ValueKey('training-discard-dialog'),
        title: l10n.trainingPageDiscardTitle,
        body: l10n.trainingPageDiscardBody,
        icon: Icons.edit_off_rounded,
        destructive: true,
        cancelLabel: l10n.trainingPageKeepEditing,
        onCancel: () => Navigator.pop(dialogContext, false),
        confirmKey: const ValueKey('training-discard-confirm'),
        confirmLabel: l10n.trainingPageDiscard,
        onConfirm: () => Navigator.pop(dialogContext, true),
      ),
    );
    _closing = false;
    if (mounted && discard == true) Navigator.pop(context, false);
  }

  Future<void> _save() async {
    if (_busy) return;
    final l10n = context.l10n;
    var valid = true;
    for (final value in _values) {
      value.error = value.validate(l10n);
      if (value.error != null) valid = false;
    }
    if (!valid) {
      setState(() {
        _editing = true;
        _error = l10n.trainingPageInvalid;
      });
      return;
    }
    late final CoachTrainingProposal draft;
    try {
      draft = CoachTrainingProposal(
        title: _title.controller.text,
        description: _description.controller.text,
        goal: _goal.controller.text,
        workouts: _workouts.map((workout) => workout.build()).toList(),
      );
    } on FormatException {
      setState(() => _error = l10n.trainingPageContentLimit);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    FocusManager.instance.primaryFocus?.unfocus();
    try {
      final delivery = await widget.onSave(draft);
      if (!mounted) return;
      showAppSnack(
        context,
        deliveryHint(l10n.trainingPageSaved, delivery, l10n),
      );
      Navigator.pop(context, true);
    } catch (_) {
      if (mounted) setState(() => _error = l10n.trainingPageSaveError);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxHeight < 400;
        final title = _editing
            ? (widget.initialDraft == null
                  ? l10n.trainingPageCreateTitle
                  : l10n.trainingPageEditTitle)
            : l10n.trainingPageReviewTitle;
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
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SheetHandle(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 12, 12),
                  child: _header(context, title, compact: compact),
                ),
                Flexible(
                  child: SingleChildScrollView(
                    key: const ValueKey('training-editor-scroll'),
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (compact) ...[
                          HeadingSemantics(
                            level: 1,
                            child: Text(
                              title,
                              style: AppType.display(
                                24,
                                color: t.ink,
                                height: 1.15,
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                        ],
                        if (_editing)
                          ..._editFields(context)
                        else
                          ..._review(context),
                      ],
                    ),
                  ),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_error != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Semantics(
                              liveRegion: true,
                              child: Text(
                                _error!,
                                style: AppType.ui(
                                  14,
                                  color: t.danger,
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
                          key: const ValueKey('training-editor-save'),
                          label: _busy
                              ? l10n.trainingPageSaving
                              : widget.submitLabel ?? l10n.trainingPageSave,
                          onTap: _busy ? null : _save,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _header(BuildContext context, String title, {required bool compact}) {
    final close = IconButton(
      key: const ValueKey('training-editor-close'),
      onPressed: _busy ? null : _close,
      tooltip: context.l10n.trainingPageClose,
      icon: const Icon(Icons.close_rounded),
    );
    if (compact) {
      return Row(
        children: [
          Expanded(
            child: Text(
              context.l10n.trainingPageTitle,
              style: AppType.ui(
                15,
                weight: FontWeight.w600,
                color: context.t.ink,
              ),
            ),
          ),
          close,
        ],
      );
    }
    final style = AppType.display(24, color: context.t.ink, height: 1.15);
    final heading = HeadingSemantics(
      level: 1,
      child: Text(title, style: style),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        var inline = true;
        for (final word in title.split(RegExp(r'\s+'))) {
          final measure = TextPainter(
            text: TextSpan(text: word, style: style),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
          )..layout();
          if (measure.width >
              constraints.maxWidth -
                  48 -
                  (MediaQuery.textScalerOf(context).scale(14) <= 18 ? 58 : 0)) {
            inline = false;
          }
          measure.dispose();
        }
        return inline
            ? Row(
                children: [
                  if (MediaQuery.textScalerOf(context).scale(14) <= 18) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: context.t.forest,
                        borderRadius: BorderRadius.circular(rControl),
                      ),
                      child: Icon(
                        Icons.fitness_center_rounded,
                        color: context.t.lime,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 12),
                  ],
                  Expanded(child: heading),
                  close,
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Align(alignment: Alignment.centerRight, child: close),
                  heading,
                ],
              );
      },
    );
  }

  void _beginEditing() {
    setState(() => _editing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
    });
  }

  List<Widget> _review(BuildContext context) {
    final draft = widget.initialDraft!;
    final t = context.t;
    final l10n = context.l10n;
    return [
      Text(
        l10n.trainingPageReviewBody,
        style: AppType.ui(14, color: t.ink2, height: 1.45),
      ),
      const SizedBox(height: 20),
      Text(draft.title, style: AppType.display(26, color: t.ink)),
      if (draft.description.isNotEmpty) ...[
        const SizedBox(height: 10),
        Text(
          draft.description,
          style: AppType.ui(14, color: t.ink2, height: 1.45),
        ),
      ],
      if (draft.goal.isNotEmpty) ...[
        const SizedBox(height: 10),
        Text(
          draft.goal,
          style: AppType.ui(14, color: t.accent, weight: FontWeight.w600),
        ),
      ],
      TextButton.icon(
        key: const ValueKey('training-editor-edit'),
        onPressed: _busy ? null : _beginEditing,
        icon: const Icon(Icons.edit_outlined),
        label: Text(l10n.trainingPageEdit),
      ),
      for (var i = 0; i < draft.workouts.length; i++) ...[
        const SizedBox(height: 20),
        Text(
          l10n.trainingPageWorkoutNumber(i + 1),
          style: AppType.ui(13, color: t.ink2),
        ),
        const SizedBox(height: 6),
        SectionHeading(title: draft.workouts[i].title),
        if (draft.workouts[i].description.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              draft.workouts[i].description,
              style: AppType.ui(14, color: t.ink2, height: 1.45),
            ),
          ),
        TrainingExerciseList(exercises: draft.workouts[i].exercises),
      ],
    ];
  }

  Widget _field(
    _PlanText value,
    String label,
    String key, {
    String? hint,
    int lines = 1,
  }) => Focus(
    canRequestFocus: false,
    onFocusChange: (focused) {
      if (!focused && mounted) {
        setState(() => value.error = value.validate(context.l10n));
      }
    },
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            label,
            style: AppType.ui(
              13,
              color: context.t.ink2,
              weight: FontWeight.w500,
            ),
          ),
        ),
        SheetField(
          key: ObjectKey(value),
          fieldKey: ValueKey(key),
          label: null,
          semanticLabel: label,
          hint: hint ?? label,
          controller: value.controller,
          enabled: !_busy,
          maxLines: lines,
          keyboardType: value.min == null
              ? (lines > 1 ? TextInputType.multiline : TextInputType.text)
              : TextInputType.number,
          inputFormatters: value.min == null
              ? null
              : [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(4),
                ],
          errorText: value.error,
          onChanged: (_) {
            if (value.error != null) value.error = value.validate(context.l10n);
            _changed();
          },
        ),
      ],
    ),
  );

  List<Widget> _editFields(BuildContext context) {
    final l10n = context.l10n;
    return [
      if (widget.initialDraft == null) ...[
        Text(
          l10n.trainingCreateIntro,
          style: AppType.ui(14, color: context.t.ink2, height: 1.45),
        ),
        const SizedBox(height: 22),
      ],
      _field(
        _title,
        l10n.trainingPagePlanName,
        'training-editor-title',
        hint: l10n.trainingPagePlanNameHint,
      ),
      _field(
        _description,
        l10n.trainingPageDescription,
        'training-editor-description',
        hint: l10n.trainingPageDescriptionHint,
        lines: 2,
      ),
      _field(
        _goal,
        l10n.trainingPageGoal,
        'training-editor-goal',
        hint: l10n.trainingPageNotesHint,
      ),
      const SizedBox(height: 8),
      for (var i = 0; i < _workouts.length; i++) _workoutFields(context, i),
      CreationAddButton(
        key: const ValueKey('training-editor-add-workout'),
        onPressed: _busy || _workouts.length >= TrainingLimits.workoutsMax
            ? null
            : () {
                _workouts.add(_WorkoutFields(null));
                _changed();
              },
        label: l10n.trainingPageAddWorkout,
      ),
    ];
  }

  Widget _workoutFields(BuildContext context, int index) {
    final workout = _workouts[index];
    final l10n = context.l10n;
    return Column(
      key: ObjectKey(workout),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 18),
        CreationSectionHeading(
          number: index + 1,
          title: l10n.trainingPageWorkoutNumber(index + 1),
          note: l10n.trainingWorkoutIntro,
        ),
        if (_workouts.length > 1)
          _orderButtons(
            keyPrefix: 'training-editor-workout-$index',
            removeLabel: l10n.trainingPageRemoveWorkout,
            index: index,
            count: _workouts.length,
            move: (target) {
              _workouts.removeAt(index);
              _workouts.insert(target, workout);
              _changed();
            },
            remove: () {
              _workouts.removeAt(index);
              workout.dispose();
              _changed();
            },
          ),
        _field(
          workout.title,
          l10n.trainingPageWorkoutName,
          'training-editor-workout-$index-title',
          hint: l10n.trainingPageWorkoutNameHint,
        ),
        _field(
          workout.description,
          l10n.trainingPageWorkoutNotes,
          'training-editor-workout-$index-description',
          hint: l10n.trainingPageNotesHint,
          lines: 2,
        ),
        for (var j = 0; j < workout.exercises.length; j++)
          _exerciseFields(context, index, j),
        CreationAddButton(
          key: ValueKey('training-editor-add-exercise-$index'),
          onPressed:
              _busy || workout.exercises.length >= TrainingLimits.exercisesMax
              ? null
              : () {
                  workout.exercises.add(_ExerciseFields(null));
                  _changed();
                },
          label: l10n.trainingPageAddExercise,
        ),
        Divider(color: context.t.line, height: 28),
      ],
    );
  }

  Widget _exerciseFields(BuildContext context, int workoutIndex, int index) {
    final exercises = _workouts[workoutIndex].exercises;
    final exercise = exercises[index];
    final l10n = context.l10n;
    final prefix = 'training-editor-exercise-$workoutIndex-$index';
    return Padding(
      key: ObjectKey(exercise),
      padding: const EdgeInsets.only(bottom: 14),
      child: Material(
        color: context.t.surf,
        borderRadius: BorderRadius.circular(rCard),
        clipBehavior: Clip.antiAlias,
        child: ExpansionTile(
          initiallyExpanded: true,
          iconColor: context.t.ink2,
          collapsedIconColor: context.t.ink2,
          tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          leading: ExcludeSemantics(
            child: Text(
              (index + 1).toString().padLeft(2, '0'),
              style: AppType.display(18, color: context.t.accent),
            ),
          ),
          shape: const Border(),
          collapsedShape: const Border(),
          title: Text(
            exercise.name.controller.text.trim().isEmpty
                ? l10n.trainingPageExerciseNumber(index + 1)
                : exercise.name.controller.text,
            style: AppType.ui(
              15,
              color: context.t.ink,
              weight: FontWeight.w600,
            ),
          ),
          children: [
            if (exercises.length > 1)
              _orderButtons(
                keyPrefix: prefix,
                removeLabel: l10n.trainingPageRemoveExercise,
                index: index,
                count: exercises.length,
                move: (target) {
                  exercises.removeAt(index);
                  exercises.insert(target, exercise);
                  _changed();
                },
                remove: () {
                  exercises.removeAt(index);
                  exercise.dispose();
                  _changed();
                },
              ),
            _field(
              exercise.name,
              l10n.trainingPageExerciseName,
              '$prefix-name',
              hint: l10n.trainingPageExerciseNameHint,
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final timed in [false, true])
                    ChoiceChip(
                      key: ValueKey('$prefix-${timed ? 'time' : 'reps'}'),
                      selected: timed == exercise.timed,
                      label: Text(
                        timed
                            ? l10n.trainingPageTimed
                            : l10n.trainingPageRepetitions,
                      ),
                      selectedColor: context.t.lime,
                      checkmarkColor: context.t.onLime,
                      labelStyle: AppType.ui(
                        14,
                        color: timed == exercise.timed
                            ? context.t.onLime
                            : context.t.ink2,
                      ),
                      onSelected: _busy
                          ? null
                          : (_) {
                              exercise.timed = timed;
                              _changed();
                            },
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            CreationFieldGrid(
              children: [
                _field(exercise.sets, l10n.trainingPageSets, '$prefix-sets'),
                if (exercise.timed)
                  _field(
                    exercise.duration,
                    l10n.trainingPageDuration,
                    '$prefix-duration',
                  )
                else
                  _field(
                    exercise.reps,
                    l10n.trainingPageReps,
                    '$prefix-repetitions',
                  ),
                _field(exercise.rest, l10n.trainingPageRest, '$prefix-rest'),
              ],
            ),
            _field(
              exercise.notes,
              l10n.trainingPageExerciseNotes,
              '$prefix-notes',
              hint: l10n.trainingPageNotesHint,
              lines: 2,
            ),
          ],
        ),
      ),
    );
  }

  Widget _orderButtons({
    required String keyPrefix,
    required String removeLabel,
    required int index,
    required int count,
    required ValueChanged<int> move,
    required VoidCallback remove,
  }) => Wrap(
    alignment: WrapAlignment.end,
    children: [
      IconButton(
        key: ValueKey('$keyPrefix-up'),
        tooltip: context.l10n.trainingPageMoveUp,
        onPressed: _busy || index == 0 ? null : () => move(index - 1),
        icon: const Icon(Icons.arrow_upward_rounded),
      ),
      IconButton(
        key: ValueKey('$keyPrefix-down'),
        tooltip: context.l10n.trainingPageMoveDown,
        onPressed: _busy || index == count - 1 ? null : () => move(index + 1),
        icon: const Icon(Icons.arrow_downward_rounded),
      ),
      IconButton(
        key: ValueKey('$keyPrefix-remove'),
        tooltip: removeLabel,
        onPressed: _busy || count == 1 ? null : remove,
        icon: const Icon(Icons.delete_outline_rounded),
      ),
    ],
  );
}
