import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../l10n/l10n.dart';
import '../../../models/training_plan.dart';
import '../../../theme/app_tokens.dart';
import '../../../widgets/design/design.dart';

enum PlayerFinishChoice {
  /// Save the completed sets; open sets count as skipped.
  save,

  /// Log the open sets with the values shown, then save.
  logRest,

  /// Discard the workout (only offered with no completed set).
  discard,

  /// Close the sheet and keep going.
  keepTraining,
}

/// The finish sheet (spec A7): summary, note and an honest primary action.
/// With open sets the primary saves only what was done; with no completed
/// set there is nothing to save, only Discard or Keep training.
Future<PlayerFinishChoice?> showPlayerFinishSheet(
  BuildContext context, {
  required int completed,
  required int skipped,
  required int open,
  required int total,
  required bool valuesValid,
  required TextEditingController note,
  required VoidCallback onNoteChanged,
}) => showEatovaSheet<PlayerFinishChoice>(
  context,
  _FinishSheet(
    completed: completed,
    skipped: skipped,
    open: open,
    total: total,
    valuesValid: valuesValid,
    note: note,
    onNoteChanged: onNoteChanged,
  ),
);

class _FinishSheet extends StatelessWidget {
  const _FinishSheet({
    required this.completed,
    required this.skipped,
    required this.open,
    required this.total,
    required this.valuesValid,
    required this.note,
    required this.onNoteChanged,
  });

  final int completed;
  final int skipped;
  final int open;
  final int total;
  final bool valuesValid;
  final TextEditingController note;
  final VoidCallback onNoteChanged;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final t = context.t;
    void choose(PlayerFinishChoice choice) => Navigator.of(context).pop(choice);

    Widget secondary(
      String id,
      String label,
      PlayerFinishChoice choice, {
      bool enabled = true,
    }) => TextButton(
      key: ValueKey('training-finish-$id'),
      onPressed: enabled ? () => choose(choice) : null,
      style: TextButton.styleFrom(
        foregroundColor: choice == PlayerFinishChoice.discard
            ? t.danger
            : t.ink,
        minimumSize: const Size.fromHeight(48),
      ),
      child: Text(label, textAlign: TextAlign.center),
    );

    final nothing = completed == 0;
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        key: const ValueKey('training-finish-sheet'),
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            HeadingSemantics(
              level: 1,
              child: Text(
                l.trainingTimerFinish,
                style: AppType.display(22, color: t.ink),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              [
                l.trainingTimerProgress(completed, total),
                if (skipped + open > 0) l.trainingTimerSkipped(skipped + open),
              ].join(' · '),
              key: const ValueKey('training-finish-summary'),
              style: AppType.ui(14, color: t.ink2, height: 1.4),
            ),
            const SizedBox(height: 16),
            if (nothing)
              Text(
                l.trainingTimerNothingDone,
                style: AppType.ui(14, color: t.ink, height: 1.4),
              )
            else ...[
              SheetField(
                controller: note,
                fieldKey: const ValueKey('training-history-note'),
                label: l.trainingHistoryNote,
                semanticLabel: l.trainingHistoryNote,
                hint: l.trainingActualOptional,
                maxLines: 3,
                inputFormatters: [TrainingNoteFormatter()],
                onChanged: (_) => onNoteChanged(),
              ),
              if (!valuesValid) ...[
                Text(
                  l.trainingActualMissing,
                  style: AppType.ui(14, color: t.danger),
                ),
                const SizedBox(height: 12),
              ],
              PrimaryActionButton(
                key: const ValueKey('training-finish-save'),
                label: open == 0
                    ? l.trainingTimerSaveWorkout
                    : l.trainingTimerSaveSets(completed),
                icon: Icons.check_rounded,
                onTap: valuesValid
                    ? () => choose(PlayerFinishChoice.save)
                    : null,
              ),
              if (open > 0) ...[
                const SizedBox(height: 8),
                secondary(
                  'log-rest',
                  l.trainingTimerLogRest,
                  PlayerFinishChoice.logRest,
                  enabled: valuesValid,
                ),
              ],
            ],
            const SizedBox(height: 8),
            if (nothing)
              secondary(
                'discard',
                l.trainingTimerDiscard,
                PlayerFinishChoice.discard,
              ),
            secondary(
              'keep',
              l.trainingTimerKeepTraining,
              PlayerFinishChoice.keepTraining,
            ),
          ],
        ),
      ),
    );
  }
}

/// The model and Postgres count code points; retain whole characters.
class TrainingNoteFormatter extends TextInputFormatter {
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
