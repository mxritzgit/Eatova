part of 'coach_chat_screen.dart';

// ---------------------------------------------------------------------------
// Workout log proposal (/log): the card in the coach bubble. DISPLAY ONLY —
// the history row is written by `_CoachChatScreenState._reviewWorkoutLog`
// after the review sheet's explicit Add; the coach has no write rights.
// ---------------------------------------------------------------------------

/// Where a /log card stands, derived from the live training history.
enum _WorkoutLogCardStatus {
  /// Can be reviewed and added.
  open,

  /// History not known yet (or no usable id): Add waits, disabled.
  waiting,

  /// The card's history id is in the history.
  added,

  /// The id was deleted; the server refuses it for good.
  removed,
}

/// The history row a /log card writes: derived from a stored answer's id, or
/// the id allocated for a local-only answer. null: it cannot be added.
String? _workoutLogHistoryId(ChatMessage message) =>
    deriveCoachWorkoutLogId(message.id) ?? message.workoutLogLocalId;

/// Whether a /log answer ends with the server's fixed D4 line (pain was
/// mentioned). The content is its only trace on a reloaded row, and the
/// answer's language need not be the app's.
bool _workoutLogSafetyLineIn(String content) {
  final text = content.trimRight();
  return [
    deL10n,
    enL10n,
  ].any((l10n) => text.endsWith(l10n.coachWorkoutLogSafetyLine));
}

/// "Workout · Draft", the title, the day, one line per exercise and, when the
/// message named several days, which one was taken. Once added the card says
/// so and offers the Training tab; a removed entry is never offered again.
/// A log that mentioned pain keeps the fixed safety line (spec D4).
class _WorkoutLogProposalCard extends StatelessWidget {
  const _WorkoutLogProposalCard({
    required this.proposal,
    required this.status,
    required this.safetyLine,
    required this.canAdd,
    required this.enabled,
    this.onAdd,
    this.onOpenTraining,
  });

  final CoachWorkoutLog proposal;
  final _WorkoutLogCardStatus status;

  /// The answer ended with the D4 line: the card shows it in the app language.
  final bool safetyLine;

  /// A save hook exists; without one the card shows no Add at all.
  final bool canAdd;

  /// No other review is running.
  final bool enabled;
  final VoidCallback? onAdd;
  final VoidCallback? onOpenTraining;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final day = parseLocalDayKey(proposal.performedOn);
    final added = status == _WorkoutLogCardStatus.added;
    final action = _action(context);
    return Column(
      key: const ValueKey('coach-workout-log-card'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(
              added ? Icons.check_circle_rounded : _CoachCommand.log.icon,
              size: 18,
              color: t.accent,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                added
                    ? l10n.coachWorkoutLogAddedLabel
                    : l10n.coachWorkoutLogCardEyebrow,
                style: AppType.ui(12, weight: FontWeight.w600, color: t.accent),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          proposal.title,
          style: AppType.display(20, color: t.ink, height: 1.15),
        ),
        const SizedBox(height: 6),
        Text(
          day == null
              ? l10n.coachWorkoutLogDayMissing
              : _workoutLogDayLabel(day, l10n),
          style: AppType.ui(14, color: t.ink2, height: 1.4),
        ),
        const SizedBox(height: 10),
        for (final exercise in proposal.exercises)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text.rich(
              TextSpan(
                children: <InlineSpan>[
                  TextSpan(
                    text: exercise.name,
                    style: AppType.ui(
                      14,
                      weight: FontWeight.w600,
                      color: t.ink,
                      height: 1.45,
                    ),
                  ),
                  TextSpan(
                    text: ' · ${_workoutLogSets(exercise, l10n)}',
                    style: AppType.ui(14, color: t.ink2, height: 1.45),
                  ),
                ],
              ),
            ),
          ),
        if (proposal.otherDaysOmitted) ...<Widget>[
          const SizedBox(height: 6),
          Text(
            day == null
                ? l10n.coachWorkoutLogOnlyOneDay
                : l10n.coachWorkoutLogOnlyDay(
                    DateFormat.MMMEd(l10n.localeName).format(day),
                  ),
            style: AppType.ui(13, color: t.ink2, height: 1.4),
          ),
        ],
        if (safetyLine) ...<Widget>[
          const SizedBox(height: 10),
          Text(
            l10n.coachWorkoutLogSafetyLine,
            style: AppType.ui(13, color: t.ink2, height: 1.4),
          ),
        ],
        if (action != null) ...<Widget>[const SizedBox(height: 16), action],
      ],
    );
  }

  Widget? _action(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    switch (status) {
      case _WorkoutLogCardStatus.added:
        // Live region like the plan card's: the state changes after the sheet
        // closes, without focus moving to it.
        return Semantics(
          liveRegion: true,
          child: onOpenTraining == null
              ? Icon(Icons.check_circle_rounded, color: t.accent, size: 22)
              : TextButton.icon(
                  key: const ValueKey('coach-workout-log-open-training'),
                  onPressed: onOpenTraining,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 48),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    alignment: Alignment.centerLeft,
                  ),
                  icon: const Icon(Icons.check_circle_outline_rounded),
                  label: Text(l10n.coachWorkoutLogOpenTraining),
                ),
        );
      case _WorkoutLogCardStatus.removed:
        return Semantics(
          container: true,
          liveRegion: true,
          child: Row(
            children: <Widget>[
              Icon(
                Icons.remove_circle_outline_rounded,
                size: 18,
                color: t.ink2,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.coachWorkoutLogRemovedLabel,
                  style: AppType.ui(14, weight: FontWeight.w600, color: t.ink2),
                ),
              ),
            ],
          ),
        );
      case _WorkoutLogCardStatus.open || _WorkoutLogCardStatus.waiting:
        if (!canAdd) return null;
        return PrimaryActionButton(
          key: const ValueKey('coach-workout-log-add'),
          label: l10n.coachWorkoutLogAddButton,
          icon: Icons.arrow_forward_rounded,
          onTap: status == _WorkoutLogCardStatus.open && enabled ? onAdd : null,
        );
    }
  }
}

/// "Today", "Yesterday" or the short date of the device's calendar.
String _workoutLogDayLabel(DateTime day, AppLocalizations l10n) {
  final now = clock.now();
  if (day == DateTime(now.year, now.month, now.day)) {
    return l10n.trainingLogToday;
  }
  if (day == DateTime(now.year, now.month, now.day - 1)) {
    return l10n.trainingLogYesterday;
  }
  return DateFormat.MMMEd(l10n.localeName).format(day);
}

/// The sets of one exercise, runs of equal sets merged:
/// "2 × 8 reps · 100 kg, 1 × 6 reps · 110 kg". A value the user did not say
/// shows as missing; the review sheet asks for it before Add.
String _workoutLogSets(
  CoachWorkoutLogExercise exercise,
  AppLocalizations l10n,
) {
  final runs = <({CoachWorkoutLogSet set, int count})>[];
  for (final set in exercise.sets) {
    final last = runs.isEmpty ? null : runs.last;
    if (last != null &&
        last.set.reps == set.reps &&
        last.set.weightKg == set.weightKg) {
      runs[runs.length - 1] = (set: last.set, count: last.count + 1);
    } else {
      runs.add((set: set, count: 1));
    }
  }
  return [
    for (final (:set, :count) in runs)
      [
        _workoutLogAmount(exercise, set, count, l10n),
        if (set.weightKg case final kg?)
          l10n.trainingHistoryWeightValue(formatDecimal(kg, l10n)),
      ].join(' · '),
  ].join(', ');
}

String _workoutLogAmount(
  CoachWorkoutLogExercise exercise,
  CoachWorkoutLogSet set,
  int count,
  AppLocalizations l10n,
) {
  if (exercise.kind == CoachWorkoutLogKind.timed) {
    final seconds = exercise.durationSeconds;
    if (seconds == null) return l10n.coachWorkoutLogSetsTimeMissing(count);
    return seconds >= 120 && seconds % 60 == 0
        ? l10n.coachWorkoutLogSetsMinutes(count, seconds ~/ 60)
        : l10n.trainingPageSetsTime(count, seconds);
  }
  final reps = set.reps;
  return reps == null
      ? l10n.coachWorkoutLogSetsRepsMissing(count)
      : l10n.trainingPageSetsReps(count, reps);
}
