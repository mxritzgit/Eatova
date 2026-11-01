import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../../models/training_plan.dart';
import '../../../models/training_session.dart';
import '../../../theme/app_tokens.dart';
import '../../../widgets/common/motion.dart';
import '../../../widgets/design/design.dart';
import '../training_actual_fields.dart';
import 'player_format.dart';

/// What a list row or card may ask the player to do.
final class PlayerActions {
  const PlayerActions({
    required this.complete,
    required this.start,
    required this.undo,
    required this.skipSet,
    required this.skipExercise,
    required this.completeRemaining,
    required this.editActive,
    required this.editCompleted,
    required this.validity,
    required this.copyLast,
  });

  /// ✓ on the active row (also "Done early").
  final VoidCallback complete;

  /// ▶ on the active timed row.
  final VoidCallback start;

  /// Unchecks the most recent completed set.
  final VoidCallback undo;
  final VoidCallback skipSet;
  final VoidCallback skipExercise;
  final VoidCallback completeRemaining;
  final void Function(int? reps, double? weightKg) editActive;
  final void Function(
    TrainingSetReference reference,
    int? reps,
    double? weightKg,
  )
  editCompleted;

  /// One cell ('reps' or 'weight') of a row turned valid or invalid.
  final void Function(TrainingSetReference reference, String cell, bool valid)
  validity;
  final void Function(TrainingSetActual last) copyLast;
}

enum PlayerSetState { done, active, upcoming, skipped }

/// The trailing control of a row; ≥ 56 dp on the active row (spec A3).
enum PlayerSetButtonKind { complete, start, undo, done, locked, skipped }

/// One set: `#  ·  last time  ·  kg  ·  reps  ·  ✓`. Completed and active
/// rows edit their values in place; upcoming rows show their prefill.
class PlayerSetRow extends StatelessWidget {
  const PlayerSetRow({
    super.key,
    required this.reference,
    required this.exercise,
    required this.state,
    required this.reps,
    required this.weightKg,
    required this.button,
    required this.actions,
    required this.compact,
    this.lastTime,
    this.enabled = true,
    this.buttonEnabled = true,
    this.onConfirmLegacy,
    this.replaceRevision,
  });

  final TrainingSetReference reference;
  final TrainingExercise exercise;
  final PlayerSetState state;
  final int? reps;
  final double? weightKg;
  final PlayerSetButtonKind button;
  final PlayerActions actions;
  final bool compact;
  final TrainingSetActual? lastTime;
  final bool enabled;
  final bool buttonEnabled;

  /// A timed set completed by a #70 build has no values yet; confirming it
  /// records them (the save needs one per completed set).
  final VoidCallback? onConfirmLegacy;

  /// Bumped by Copy last time on the active row; see
  /// [TrainingSetValueField.replaceRevision].
  final int? replaceRevision;

  String get _id => '${reference.exerciseIndex}-${reference.setIndex}';
  int get _number => reference.setIndex + 1;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final t = context.t;
    final active = state == PlayerSetState.active;
    final editable = enabled && (active || state == PlayerSetState.done);

    Widget cell(Widget child, {int flex = 1}) =>
        Expanded(flex: flex, child: child);

    Widget valueText(String text) => SizedBox(
      height: 48,
      child: Center(
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: AppType.ui(
            15,
            weight: FontWeight.w600,
            color: state == PlayerSetState.skipped ? t.ink3 : t.ink2,
          ),
        ),
      ),
    );

    Widget weightCell() {
      if (state == PlayerSetState.skipped) {
        return valueText('–');
      }
      if (!editable) {
        return valueText(
          weightKg == null ? '–' : formatTrainingWeight(weightKg!, l),
        );
      }
      return TrainingSetValueField(
        key: ValueKey('training-set-weight-cell-$_id'),
        fieldKey: ValueKey('training-set-weight-$_id'),
        value: weightKg,
        decimal: true,
        muted: active,
        enabled: enabled,
        replaceRevision: replaceRevision,
        semanticLabel: l.trainingTimerWeightField(_number),
        onValidityChanged: (valid) =>
            actions.validity(reference, 'weight', valid),
        onChanged: (value) {
          if (active) {
            actions.editActive(reps, value?.toDouble());
          } else {
            actions.editCompleted(reference, reps, value?.toDouble());
          }
        },
      );
    }

    Widget repsCell() {
      if (onConfirmLegacy != null) {
        return EatovaTextAction(
          buttonKey: ValueKey('training-set-confirm-$_id'),
          onTap: onConfirmLegacy,
          label: l.trainingActualConfirmLegacyTimed,
        );
      }
      if (exercise.isTimed) {
        return valueText(formatClock(exercise.durationSeconds ?? 0));
      }
      if (state == PlayerSetState.skipped) return valueText('–');
      if (!editable) return valueText('${reps ?? exercise.reps}');
      return TrainingSetValueField(
        key: ValueKey('training-set-reps-cell-$_id'),
        fieldKey: ValueKey('training-set-reps-$_id'),
        value: reps,
        decimal: false,
        muted: active,
        enabled: enabled,
        replaceRevision: replaceRevision,
        semanticLabel: l.trainingTimerRepsField(_number),
        onValidityChanged: (valid) =>
            actions.validity(reference, 'reps', valid),
        onChanged: (value) {
          if (active) {
            actions.editActive(value?.toInt(), weightKg);
          } else {
            actions.editCompleted(reference, value?.toInt(), weightKg);
          }
        },
      );
    }

    // Aligned under the "SET" head, so the column keeps its width: at large
    // text a two-digit number shrinks to fit instead of breaking into "1 / 0".
    final number = SizedBox(
      width: 28,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          '$_number',
          textAlign: TextAlign.center,
          maxLines: 1,
          style: AppType.ui(
            15,
            weight: FontWeight.w800,
            color: active ? t.accentText : t.ink2,
          ),
        ),
      ),
    );

    final last = _LastTimeCell(
      id: _id,
      exercise: exercise,
      lastTime: lastTime,
      onCopy: active && enabled && lastTime != null
          ? () => actions.copyLast(lastTime!)
          : null,
    );

    final trailing = SizedBox(
      width: 56,
      child: Center(
        child: PlayerSetButton(
          key: ValueKey('training-set-check-$_id'),
          kind: button,
          setNumber: _number,
          large: active,
          onPressed: !enabled || !buttonEnabled
              ? null
              : switch (button) {
                  PlayerSetButtonKind.complete => actions.complete,
                  PlayerSetButtonKind.start => actions.start,
                  PlayerSetButtonKind.undo => actions.undo,
                  _ => null,
                },
        ),
      ),
    );

    final values = Row(
      children: [
        cell(weightCell(), flex: 5),
        const SizedBox(width: 6),
        cell(repsCell(), flex: 4),
      ],
    );

    final row = compact
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              number,
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    values,
                    if (lastTime != null) ...[const SizedBox(height: 4), last],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              trailing,
            ],
          )
        : Row(
            children: [
              number,
              const SizedBox(width: 6),
              cell(last, flex: 4),
              const SizedBox(width: 6),
              Expanded(flex: 9, child: values),
              const SizedBox(width: 8),
              trailing,
            ],
          );

    return AnimatedContainer(
      duration: motionDuration(context, const Duration(milliseconds: 160)),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: active ? t.accentTint : null,
        borderRadius: BorderRadius.circular(rControl),
      ),
      child: row,
    );
  }
}

class _LastTimeCell extends StatelessWidget {
  const _LastTimeCell({
    required this.id,
    required this.exercise,
    required this.lastTime,
    required this.onCopy,
  });

  final String id;
  final TrainingExercise exercise;
  final TrainingSetActual? lastTime;
  final VoidCallback? onCopy;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final t = context.t;
    final set = lastTime;
    final text = set == null ? '–' : lastTimeValue(set, exercise, l);
    final label = Text(
      text,
      textAlign: TextAlign.center,
      style: AppType.ui(13, weight: FontWeight.w600, color: t.ink2),
    );
    if (onCopy == null) {
      return ExcludeSemantics(
        excluding: set == null,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 24),
          child: Center(child: label),
        ),
      );
    }
    return Semantics(
      button: true,
      label: l.trainingTimerCopyLast(text),
      excludeSemantics: true,
      onTap: onCopy,
      child: InkWell(
        key: ValueKey('training-set-last-$id'),
        onTap: onCopy,
        borderRadius: BorderRadius.circular(rChip),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Center(child: label),
        ),
      ),
    );
  }
}

/// ✓ / ▶ of a row, in the app's icon-button family (spec A1: sequential
/// order this round). The active set's ✓ is the view's one lit action, a
/// large disc (56 dp) that waits in the "not yet" tint during the get-ready;
/// the most recent done set undoes in the accent tint; upcoming sets show a
/// visibly disabled ✓. Done and skipped sets are marks, not buttons: the
/// same 44 px disc without the dimming.
class PlayerSetButton extends StatelessWidget {
  const PlayerSetButton({
    super.key,
    required this.kind,
    required this.setNumber,
    required this.large,
    required this.onPressed,
  });

  final PlayerSetButtonKind kind;
  final int setNumber;
  final bool large;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final t = context.t;
    final size = large ? IconButtonSize.large : IconButtonSize.regular;
    final target = large ? null : 48.0;
    switch (kind) {
      case PlayerSetButtonKind.complete:
      case PlayerSetButtonKind.start:
        return AppIconButton(
          icon: kind == PlayerSetButtonKind.start
              ? AppIcons.playArrow
              : AppIcons.check,
          semanticLabel: kind == PlayerSetButtonKind.start
              ? l.trainingTimerStartSetLabel(setNumber)
              : l.trainingTimerCompleteSetLabel(setNumber),
          tone: IconButtonTone.primary,
          size: size,
          target: target,
          onTap: onPressed,
        );
      case PlayerSetButtonKind.undo:
        return AppIconButton(
          icon: AppIcons.check,
          semanticLabel: l.trainingTimerUndoSetLabel(setNumber),
          tone: IconButtonTone.accent,
          size: size,
          target: target,
          onTap: onPressed,
        );
      case PlayerSetButtonKind.locked:
        return AppIconButton(
          icon: AppIcons.check,
          semanticLabel: l.trainingTimerSetLocked(setNumber),
          size: size,
          target: target,
          onTap: null,
        );
      case PlayerSetButtonKind.done:
      case PlayerSetButtonKind.skipped:
        final done = kind == PlayerSetButtonKind.done;
        return Semantics(
          button: true,
          enabled: false,
          label: done
              ? l.trainingTimerSetDoneLabel(setNumber)
              : l.trainingTimerSkippedSet,
          excludeSemantics: true,
          child: SizedBox.square(
            dimension: target ?? size.target,
            child: Center(
              child: Container(
                width: size.disc,
                height: size.disc,
                decoration: BoxDecoration(
                  color: done ? t.accentTint : t.tile,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  done ? AppIcons.check : AppIcons.remove,
                  size: size.glyph,
                  color: done ? t.accentText : t.ink3,
                ),
              ),
            ),
          ),
        );
    }
  }
}
