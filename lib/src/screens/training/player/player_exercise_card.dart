import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../../models/training_plan.dart';
import '../../../models/training_session.dart';
import '../../../services/training_session_controller.dart';
import '../../../theme/app_tokens.dart';
import '../../../widgets/design/design.dart';
import 'player_format.dart';
import 'player_set_row.dart';

/// One exercise of the list player (spec A3): done ones collapse to a
/// summary line, the active one is expanded with its set rows, upcoming ones
/// show the plan. Notes expand on demand.
class PlayerExerciseCard extends StatelessWidget {
  const PlayerExerciseCard({
    super.key,
    required this.session,
    required this.exerciseIndex,
    required this.lastTime,
    required this.actions,
    required this.expanded,
    required this.onToggleExpanded,
    required this.notesOpen,
    required this.onToggleNotes,
    required this.rowKey,
    required this.activeValid,
    required this.enabled,
  });

  final TrainingSessionController session;
  final int exerciseIndex;

  /// Last time's sets of this exercise, ordered by set index.
  final List<TrainingSetActual> lastTime;
  final PlayerActions actions;

  /// A done or upcoming card the user opened.
  final bool expanded;
  final VoidCallback onToggleExpanded;
  final bool notesOpen;
  final VoidCallback onToggleNotes;

  /// Stable keys per row, so the player can scroll the active row into view.
  final GlobalKey Function(TrainingSetReference reference) rowKey;

  /// False while a field of the active row holds an invalid value.
  final bool activeValid;
  final bool enabled;

  TrainingExercise get _exercise => session.workout.exercises[exerciseIndex];

  TrainingSetReference _ref(int set) =>
      TrainingSetReference(exerciseIndex: exerciseIndex, setIndex: set);

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final t = context.t;
    final exercise = _exercise;
    final active = session.activeSet?.exerciseIndex == exerciseIndex;
    final sets = [for (var s = 0; s < exercise.sets; s++) _ref(s)];
    final done = sets.every(
      (ref) => session.isCompleted(ref) || session.isSkipped(ref),
    );
    final completed = [
      for (final ref in sets)
        if (session.actualFor(ref) case final actual?
            when session.isCompleted(ref))
          actual,
    ];
    // The exercise just finished stays open through its rest, so its last
    // set can still be corrected or undone.
    final resting =
        session.phase == TrainingSessionPhase.rest &&
        session.exerciseIndex == exerciseIndex;
    final showRows = active || expanded || resting;
    final remaining = sets
        .where((ref) => !session.isCompleted(ref) && !session.isSkipped(ref))
        .length;

    final header = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _IndexBadge(
          number: exerciseIndex + 1,
          active: active,
          done: done && completed.isNotEmpty,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              HeadingSemantics(
                level: 2,
                child: Text(
                  exercise.name,
                  style: AppType.display(
                    17,
                    weight: FontWeight.w700,
                    color: t.ink,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                done && !active
                    ? doneSummary(exercise, completed, l)
                    : planSummary(exercise, l),
                key: ValueKey('training-exercise-summary-$exerciseIndex'),
                style: AppType.ui(13, color: t.ink2),
              ),
            ],
          ),
        ),
        if (exercise.notes.isNotEmpty)
          IconButton(
            key: ValueKey('training-exercise-notes-$exerciseIndex'),
            tooltip: l.trainingTimerShowNotes,
            isSelected: notesOpen,
            onPressed: onToggleNotes,
            icon: const Icon(Icons.notes_rounded),
          ),
        if (active)
          PopupMenuButton<String>(
            key: ValueKey('training-exercise-menu-$exerciseIndex'),
            tooltip: l.trainingTimerExerciseOptions(exercise.name),
            enabled: enabled,
            icon: const Icon(Icons.more_horiz_rounded),
            onSelected: (value) => switch (value) {
              'skip-set' => actions.skipSet(),
              'complete-remaining' => actions.completeRemaining(),
              _ => actions.skipExercise(),
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                key: const ValueKey('training-timer-skip-set'),
                value: 'skip-set',
                child: Text(l.trainingTimerNextSet),
              ),
              PopupMenuItem(
                key: const ValueKey('training-timer-complete-remaining'),
                value: 'complete-remaining',
                child: Text(l.trainingTimerCompleteRemaining(remaining)),
              ),
              PopupMenuItem(
                key: const ValueKey('training-timer-skip-exercise'),
                value: 'skip-exercise',
                child: Text(l.trainingTimerSkipExercise),
              ),
            ],
          )
        else if (done && !resting)
          IconButton(
            key: ValueKey('training-exercise-expand-$exerciseIndex'),
            tooltip: expanded
                ? l.trainingTimerHideSets
                : l.trainingTimerShowSets,
            onPressed: onToggleExpanded,
            icon: Icon(
              expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
            ),
          ),
      ],
    );

    return Container(
      key: ValueKey('training-exercise-$exerciseIndex'),
      decoration: BoxDecoration(
        color: t.surf,
        borderRadius: BorderRadius.circular(rCard),
        border: Border.all(color: active ? t.lineStrong : t.line),
      ),
      padding: const EdgeInsets.fromLTRB(14, 14, 10, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          if (notesOpen && exercise.notes.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              exercise.notes,
              style: AppType.ui(14, color: t.ink, height: 1.45),
            ),
          ],
          if (active) _activeTimer(context),
          if (showRows) ...[
            const SizedBox(height: 12),
            LayoutBuilder(
              builder: (context, constraints) {
                final compact =
                    constraints.maxWidth < 340 ||
                    MediaQuery.textScalerOf(context).scale(15) > 20;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _ColumnHeads(timed: exercise.isTimed, compact: compact),
                    const SizedBox(height: 4),
                    for (final ref in sets) ...[
                      _row(ref, compact),
                      const SizedBox(height: 4),
                    ],
                  ],
                );
              },
            ),
          ],
        ],
      ),
    );
  }

  Widget _row(TrainingSetReference ref, bool compact) {
    final isActive = session.activeSet == ref;
    final state = session.isCompleted(ref)
        ? PlayerSetState.done
        : session.isSkipped(ref)
        ? PlayerSetState.skipped
        : isActive
        ? PlayerSetState.active
        : PlayerSetState.upcoming;
    final exercise = _exercise;
    final timedIdle =
        exercise.isTimed &&
        (session.phase == TrainingSessionPhase.rest ||
            (!session.isRunning && session.remaining > Duration.zero));
    final kind = switch (state) {
      PlayerSetState.done =>
        ref == session.lastCompleted
            ? PlayerSetButtonKind.undo
            : PlayerSetButtonKind.done,
      PlayerSetState.skipped => PlayerSetButtonKind.skipped,
      PlayerSetState.upcoming => PlayerSetButtonKind.locked,
      PlayerSetState.active =>
        timedIdle ? PlayerSetButtonKind.start : PlayerSetButtonKind.complete,
    };
    return KeyedSubtree(
      key: rowKey(ref),
      child: PlayerSetRow(
        reference: ref,
        exercise: exercise,
        state: state,
        reps: session.shownReps(ref),
        weightKg: session.shownWeight(ref),
        button: kind,
        actions: actions,
        compact: compact,
        lastTime: _lastTimeFor(ref.setIndex),
        enabled: enabled,
        buttonEnabled: kind != PlayerSetButtonKind.complete || activeValid,
        onConfirmLegacy:
            enabled &&
                state == PlayerSetState.done &&
                exercise.isTimed &&
                session.actualFor(ref) == null
            ? () => actions.editCompleted(ref, null, null)
            : null,
      ),
    );
  }

  TrainingSetActual? _lastTimeFor(int setIndex) {
    for (final set in lastTime) {
      if (set.reference.setIndex == setIndex) return set;
    }
    return null;
  }

  /// The large countdown of an active timed set (spec A3).
  Widget _activeTimer(BuildContext context) {
    final exercise = _exercise;
    if (!exercise.isTimed) return const SizedBox.shrink();
    final l = context.l10n;
    final t = context.t;
    final inRest = session.phase == TrainingSessionPhase.rest;
    final remaining = inRest
        ? Duration(seconds: exercise.durationSeconds ?? 0)
        : session.remaining;
    final seconds = ceilSeconds(remaining);
    final lead = inRest ? 0 : ceilSeconds(session.getReadyRemaining);
    final running = !inRest && session.isRunning;
    final status = lead > 0
        ? l.trainingTimerGetReady(lead)
        : running
        ? l.trainingTimerRunning
        : !inRest && seconds == 0
        ? l.trainingTimerTapToFinish
        : !inRest && seconds < (exercise.durationSeconds ?? 0)
        ? l.trainingTimerPaused
        : null;
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: t.forest,
          borderRadius: BorderRadius.circular(rTile),
        ),
        child: Column(
          children: [
            Semantics(
              key: const ValueKey('training-timer-readout'),
              label: l.trainingTimerSecondsRemaining(seconds),
              child: ExcludeSemantics(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    formatClock(seconds),
                    textAlign: TextAlign.center,
                    style: AppType.display(56, color: t.onForest, height: 1),
                  ),
                ),
              ),
            ),
            if (status != null) ...[
              const SizedBox(height: 8),
              Text(
                status,
                key: const ValueKey('training-timer-status'),
                textAlign: TextAlign.center,
                style: AppType.ui(
                  14,
                  weight: FontWeight.w600,
                  color: t.onForest,
                ),
              ),
            ],
            if (running && lead == 0) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                key: const ValueKey('training-timer-done-early'),
                onPressed: enabled ? actions.complete : null,
                style: TextButton.styleFrom(
                  foregroundColor: t.onForest,
                  minimumSize: const Size(0, 48),
                ),
                icon: const Icon(Icons.check_rounded),
                label: Text(l.trainingTimerDoneEarly),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _IndexBadge extends StatelessWidget {
  const _IndexBadge({
    required this.number,
    required this.active,
    required this.done,
  });

  final int number;
  final bool active;
  final bool done;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return ExcludeSemantics(
      child: Container(
        width: 32,
        height: 32,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active
              ? t.accentFill
              : done
              ? t.accentTint
              : t.tile,
          shape: BoxShape.circle,
        ),
        child: done && !active
            ? Icon(Icons.check_rounded, size: 18, color: t.accentText)
            : Text(
                '$number',
                style: AppType.ui(
                  14,
                  weight: FontWeight.w800,
                  color: active ? t.onAccentFill : t.ink2,
                ),
              ),
      ),
    );
  }
}

class _ColumnHeads extends StatelessWidget {
  const _ColumnHeads({required this.timed, required this.compact});

  final bool timed;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final style = AppType.eyebrow(context.t.ink2, size: 10.5);
    Widget head(String text, {int flex = 1}) => Expanded(
      flex: flex,
      child: Text(
        text.toUpperCase(),
        textAlign: TextAlign.center,
        style: style,
      ),
    );
    final last = l.trainingTimerColumnLast;
    final values = Row(
      children: [
        head(l.trainingTimerColumnWeight, flex: 5),
        const SizedBox(width: 6),
        head(
          timed ? l.trainingTimerColumnTime : l.trainingTimerColumnReps,
          flex: 4,
        ),
      ],
    );
    return ExcludeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Row(
          children: [
            SizedBox(
              width: 28,
              child: Text(
                l.trainingTimerColumnSet.toUpperCase(),
                textAlign: TextAlign.center,
                style: style,
              ),
            ),
            const SizedBox(width: 6),
            if (!compact) ...[
              head(last, flex: 4),
              const SizedBox(width: 6),
              Expanded(flex: 9, child: values),
            ] else
              Expanded(child: values),
            const SizedBox(width: 8),
            const SizedBox(width: 56),
          ],
        ),
      ),
    );
  }
}
