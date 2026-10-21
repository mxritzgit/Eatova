import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../l10n/l10n.dart';
import '../../models/training_history.dart';
import '../../models/training_insights.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/design/design.dart';
import 'training_overview_widgets.dart';

/// One exercise across all workouts, plans and free logs: its best set per
/// workout, newest first, with the records marked
/// ([trainingExerciseProgress]).
class TrainingExerciseHistoryScreen extends StatelessWidget {
  const TrainingExerciseHistoryScreen({
    super.key,
    required this.exerciseName,
    required this.history,
  });

  final String exerciseName;
  final List<TrainingHistoryEntry> history;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final t = context.t;
    final rows = trainingExerciseProgress(history, exerciseName);
    return Scaffold(
      backgroundColor: t.bg,
      body: SafeArea(
        child: ReadableWidth(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
            children: [
              PageHeader(
                backKey: const ValueKey('training-exercise-history-back'),
                title: exerciseName,
                subtitle: l.trainingExerciseHistorySubtitle,
                prominent: true,
              ),
              const SizedBox(height: 16),
              // One hairline row per workout, each its own list child.
              for (var i = 0; i < rows.length; i++)
                _ProgressRow(row: rows[i], first: i == 0),
            ],
          ),
        ),
      ),
    );
  }
}

/// The day and workout on the left, the best set and a record mark on the
/// right.
class _ProgressRow extends StatelessWidget {
  const _ProgressRow({required this.row, required this.first});

  final TrainingExerciseBest row;
  final bool first;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final t = context.t;
    final finished = row.entry.finishedAt.toLocal();
    final day =
        (finished.year == clock.now().year
                ? DateFormat.MMMEd(l.localeName)
                : DateFormat.yMMMEd(l.localeName))
            .format(finished);
    final value = trainingSetSummary(l, row.set);
    final title = row.entry.snapshot.workout.title;
    return Semantics(
      key: ValueKey('training-exercise-history-${row.entry.id}'),
      container: true,
      label: [
        day,
        title,
        value,
        if (row.isRecord) l.trainingExerciseHistoryRecord,
      ].join(', '),
      excludeSemantics: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: first ? null : Border(top: BorderSide(color: t.line)),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        day,
                        style: AppType.ui(
                          15,
                          weight: FontWeight.w700,
                          color: t.ink,
                          height: kTrainingLine,
                        ),
                      ),
                      Text(
                        title,
                        style: AppType.ui(
                          13,
                          color: t.ink3,
                          height: kTrainingLine,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    value,
                    textAlign: TextAlign.end,
                    style: AppType.display(
                      16,
                      weight: FontWeight.w700,
                      color: t.ink,
                      height: kTrainingLine,
                      letterSpacing: 0,
                    ),
                  ),
                ),
                if (row.isRecord) ...[
                  const SizedBox(width: 8),
                  Icon(
                    Icons.emoji_events_outlined,
                    key: ValueKey(
                      'training-exercise-history-record-${row.entry.id}',
                    ),
                    size: 18,
                    color: t.fatInk,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
