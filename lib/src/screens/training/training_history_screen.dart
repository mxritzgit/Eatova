import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../l10n/l10n.dart';
import '../../models/training_exercise.dart';
import '../../models/training_history.dart';
import '../../models/training_insights.dart';
import '../../models/training_log.dart';
import '../../models/training_session.dart';
import '../../services/sync_error_messages.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/common/app_snack.dart';
import '../../widgets/design/design.dart';
import 'training_actual_fields.dart' show formatTrainingWeight;
import 'training_exercise_history_screen.dart';
import 'training_overview_widgets.dart';

class TrainingHistoryScreen extends StatelessWidget {
  const TrainingHistoryScreen({
    super.key,
    required this.entries,
    required this.onDelete,
    this.loading = false,
    this.loadFailed = false,
    this.onRetry,
    this.onLogWorkout,
  });
  final List<TrainingHistoryEntry> entries;
  final Future<SyncDelivery> Function(String) onDelete;
  final bool loading, loadFailed;
  final VoidCallback? onRetry;

  /// Logs a finished workout; the empty history's way forward. Null (no
  /// account, so nothing to write) leaves the empty state without it.
  final VoidCallback? onLogWorkout;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final t = context.t;
    // The Training tab's records rule, over the whole list.
    final records = personalRecordCounts(entries);
    return Scaffold(
      backgroundColor: t.bg,
      body: SafeArea(
        child: ReadableWidth(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            children: [
              PageHeader(
                backKey: const ValueKey('training-history-back'),
                title: l.trainingHistoryTitle,
                subtitle: l.trainingHistorySubtitle,
                prominent: true,
              ),
              const SizedBox(height: 24),
              // A refresh over cached entries: the theme's rounded bar.
              if (loading && entries.isNotEmpty) ...[
                LinearProgressIndicator(
                  semanticsLabel: l.trainingPageLoading,
                ),
                const SizedBox(height: 16),
              ],
              // Nothing cached yet: three workout cards in outline.
              if (loading && entries.isEmpty) ...[
                Semantics(
                  key: const ValueKey('training-history-loading'),
                  container: true,
                  label: l.trainingPageLoading,
                  child: ExcludeSemantics(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var i = 0; i < 3; i++) ...const [
                          SkeletonCard(
                            rows: 1,
                            tileSize: 44,
                            tileRadius: rControl,
                          ),
                          SizedBox(height: 10),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
              if (loadFailed) ...[
                CalmState(
                  key: const ValueKey('training-history-error'),
                  card: true,
                  icon: Icons.cloud_off_rounded,
                  text: l.trainingHistoryLoadError,
                  actions: [
                    SoftPillButton(
                      onTap: onRetry,
                      icon: Icons.refresh_rounded,
                      label: l.trainingPageRetry,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
              ],
              if (entries.isEmpty && !loading && !loadFailed)
                CalmState(
                  key: const ValueKey('training-history-empty'),
                  card: true,
                  // The app's own training glyph, as on the history rows.
                  glyph: const AppIcon(AppSymbol.training),
                  title: l.trainingHistoryEmptyTitle,
                  text: l.trainingHistoryEmpty,
                  actions: [
                    if (onLogWorkout case final log?)
                      SoftPillButton(
                        key: const ValueKey('training-history-empty-log'),
                        onTap: log,
                        icon: Icons.edit_note_rounded,
                        label: l.trainingLogTitle,
                      ),
                  ],
                ),
              // One card per workout, each its own list child: the history
              // holds up to 500 entries and stays lazily built.
              for (final entry in entries) ...[
                _HistoryRow(
                  entry: entry,
                  records: records[entry.id] ?? 0,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => TrainingHistoryDetail(
                        entry: entry,
                        onDelete: onDelete,
                        history: entries,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// One finished workout as a calm card in the language of the Training
/// tab's "Recent" rows: tinted glyph tile, title, day with the duration (or
/// the Logged tag), the set count only when sets were skipped, and the record
/// badge or a chevron; the whole card opens it.
class _HistoryRow extends StatelessWidget {
  const _HistoryRow({
    required this.entry,
    required this.records,
    required this.onTap,
  });

  final TrainingHistoryEntry entry;
  final int records;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l = context.l10n;
    final snapshot = entry.snapshot;
    final title = snapshot.workout.title;
    final meta = trainingWorkoutMeta(l, entry);
    final done = snapshot.completedSets.length;
    final progress = done < snapshot.totalSets
        ? l.trainingTimerProgress(done, snapshot.totalSets)
        : null;
    final badge = records > 0 ? l.trainingRecentPrs(records) : null;
    final line = AppType.ui(13, color: t.ink3, height: kTrainingLine);
    // From 1.5x text the tile gives its width to the text, and the record
    // badge moves under it.
    final large = MediaQuery.textScalerOf(context).scale(16) > 24;
    final record = badge == null
        ? null
        : TrainingRecordBadge(
            key: ValueKey('training-history-pr-${entry.id}'),
            count: records,
          );
    final content = Row(
      children: [
        if (!large) ...[
          TrainingWorkoutGlyph(workoutIndex: snapshot.workoutIndex),
          const SizedBox(width: 12),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: AppType.ui(
                  16,
                  weight: FontWeight.w700,
                  color: t.ink,
                  height: kTrainingLine,
                ),
              ),
              const SizedBox(height: 2),
              Text(meta, style: line),
              if (progress != null) Text(progress, style: line),
              if (large && record != null) ...[
                const SizedBox(height: 6),
                record,
              ],
            ],
          ),
        ),
        const SizedBox(width: 8),
        if (!large && record != null)
          record
        else
          Icon(Icons.chevron_right_rounded, size: 22, color: t.ink3),
      ],
    );
    return Semantics(
      container: true,
      button: true,
      label: [title, meta, ?progress, ?badge].join(', '),
      child: Material(
        color: t.surf,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(rTile),
          side: BorderSide(color: t.cardBorder),
        ),
        child: InkWell(
          key: ValueKey('training-history-${entry.id}'),
          onTap: onTap,
          child: ExcludeSemantics(
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 64),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
                child: content,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _date(BuildContext context, DateTime date) {
  final day = DateFormat.yMMMd(context.l10n.localeName);
  return (_use24Hours(context) ? day.add_Hm() : day.add_jm()).format(
    date.toLocal(),
  );
}

/// Whether times read on a 24-hour clock: the device asks for it, or the
/// locale's own clock is one (`jm` is "15:05" in German, "3:05 PM" in
/// English).
bool _use24Hours(BuildContext context) =>
    MediaQuery.alwaysUse24HourFormatOf(context);

/// The time of day in the locale's clock, or 24 hours when the device asks.
DateFormat _timeOfDay(BuildContext context) => _use24Hours(context)
    ? DateFormat.Hm(context.l10n.localeName)
    : DateFormat.jm(context.l10n.localeName);

/// The finish date; its time only when the entry has a duration (a log
/// without one carries a synthetic time of day).
String _finished(BuildContext context, TrainingHistoryEntry entry) =>
    trainingEntryHasDuration(entry)
    ? _date(context, entry.finishedAt)
    : DateFormat.yMMMd(
        context.l10n.localeName,
      ).format(entry.finishedAt.toLocal());

/// Only a free log is tagged "Logged": a played workout can end without a
/// duration too (one set, saved > 5 min later, finishes at that set).
bool _logged(TrainingHistoryEntry entry) => isLoggedTrainingEntry(entry);

class TrainingHistoryDetail extends StatefulWidget {
  const TrainingHistoryDetail({
    super.key,
    required this.entry,
    required this.onDelete,
    this.history = const [],
  });
  final TrainingHistoryEntry entry;
  final Future<SyncDelivery> Function(String) onDelete;

  /// The whole history: the records this workout set ([personalRecords])
  /// and each exercise's progress ([trainingExerciseProgress]). Empty shows
  /// neither.
  final List<TrainingHistoryEntry> history;
  @override
  State<TrainingHistoryDetail> createState() => _TrainingHistoryDetailState();
}

class _TrainingHistoryDetailState extends State<TrainingHistoryDetail> {
  bool _busy = false;
  String? _error;

  Future<void> _delete() async {
    if (_busy) return;
    final l = context.l10n;
    final delete = widget.onDelete;
    final id = widget.entry.id;
    final confirmed = await showEatovaDialog<bool>(
      context: context,
      builder: (dialogContext) => EatovaConfirmDialog(
        title: l.trainingHistoryDeleteTitle,
        // A free log has no plan that could "stay saved".
        body: isLoggedTrainingEntry(widget.entry)
            ? l.trainingHistoryDeleteLogBody
            : l.trainingHistoryDeleteBody,
        icon: Icons.delete_outline_rounded,
        destructive: true,
        cancelLabel: l.trainingPageCancel,
        onCancel: () => Navigator.pop(dialogContext, false),
        confirmLabel: l.trainingHistoryDeleteAction,
        onConfirm: () => Navigator.pop(dialogContext, true),
      ),
    );
    if (!mounted || confirmed != true) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final delivery = await delete(id);
      if (!mounted) return;
      showAppSnack(
        context,
        deliveryHint(l.trainingHistoryDeleted, delivery, l),
        icon: Icons.delete_outline_rounded,
        tone: SnackTone.error,
      );
      Navigator.pop(context);
    } catch (_) {
      if (mounted) setState(() => _error = l.trainingHistoryDeleteError);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Opens exercise [index]'s progress; null without the history, for a
  /// timed exercise and for one without a done set.
  VoidCallback? _progressOpener(int index) {
    final snapshot = widget.entry.snapshot;
    final exercise = snapshot.workout.exercises[index];
    if (widget.history.isEmpty ||
        exercise.isTimed ||
        !snapshot.actualSets.any((a) => a.reference.exerciseIndex == index)) {
      return null;
    }
    return () {
      if (_busy) return;
      Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => TrainingExerciseHistoryScreen(
            exerciseName: exercise.name,
            history: widget.history,
          ),
        ),
      );
    };
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final t = context.t;
    final entry = widget.entry;
    final snapshot = entry.snapshot;
    final history = widget.history;
    final records = history.isEmpty
        ? const <TrainingRecord>[]
        : personalRecords(history)[entry.id] ?? const <TrainingRecord>[];
    return Scaffold(
      backgroundColor: t.bg,
      body: SafeArea(
        child: ReadableWidth(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
            children: [
              PageHeader(
                backKey: const ValueKey('training-history-detail-back'),
                backEnabled: !_busy,
                title: snapshot.workout.title,
                // A free log's plan only repeats the workout title.
                subtitle: _logged(entry)
                    ? l.trainingHistoryLogged
                    : snapshot.plan.title,
                prominent: true,
              ),
              const SizedBox(height: 24),
              _SummaryCard(entry: entry, records: records.length),
              if (records.isNotEmpty) ...[
                const SizedBox(height: 12),
                TrainingRecordList(
                  key: const ValueKey('training-history-detail-records'),
                  records: records,
                ),
              ],
              for (var e = 0; e < snapshot.workout.exercises.length; e++) ...[
                const SizedBox(height: 12),
                _ExerciseCard(
                  entry: entry,
                  index: e,
                  onShowProgress: _progressOpener(e),
                ),
              ],
              if (entry.note.isNotEmpty) ...[
                const SizedBox(height: 12),
                _NoteCard(note: entry.note),
              ],
              const SizedBox(height: 24),
              if (_error != null) ...[
                SignalNote(
                  _error!,
                  tone: t.danger,
                  icon: Icons.error_outline_rounded,
                  boxed: true,
                ),
                const SizedBox(height: 12),
              ],
              SoftPillButton(
                key: const ValueKey('training-history-delete'),
                tone: SoftPillTone.danger,
                expand: true,
                onTap: _busy ? null : _delete,
                icon: Icons.delete_outline_rounded,
                label: _busy
                    ? l.trainingHistoryDeleting
                    : l.trainingHistoryDeleteAction,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The workout at a glance: sets done of planned in display numbers, the
/// record badge, skipped sets, then the day and, with a duration, the time
/// span.
class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.entry, required this.records});

  final TrainingHistoryEntry entry;
  final int records;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final t = context.t;
    final locale = l.localeName;
    final snapshot = entry.snapshot;
    final done = snapshot.completedSets.length;
    final total = snapshot.totalSets;
    final skipped = snapshot.skippedSets.length;
    final finished = entry.finishedAt.toLocal();
    final day =
        (finished.year == clock.now().year
                ? DateFormat.MMMEd(locale)
                : DateFormat.yMMMEd(locale))
            .format(finished);
    final timed = trainingEntryHasDuration(entry);
    String? span;
    String? minutes;
    if (timed) {
      final time = _timeOfDay(context);
      final started = snapshot.startedAt.toLocal();
      span = '${time.format(started)}–${time.format(finished)}';
      minutes = l.trainingDurationMinutes(
        (entry.finishedAt.difference(snapshot.startedAt).inSeconds / 60)
            .round(),
      );
    }
    final sets = Semantics(
      container: true,
      label: l.trainingTimerProgress(done, total),
      excludeSemantics: true,
      child: Text(
        l.trainingTimerSetsDone(done, total),
        key: const ValueKey('training-history-detail-sets'),
        style: AppType.display(28, color: t.ink, height: 1.1),
      ),
    );
    final badge = records > 0
        ? TrainingRecordBadge(
            key: const ValueKey('training-history-detail-pr'),
            count: records,
          )
        : null;
    // From 1.5x text the badge goes under the number instead of squeezing it.
    final large = MediaQuery.textScalerOf(context).scale(16) > 24;
    return AppCard(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (large) ...[
            sets,
            if (badge != null) ...[
              const SizedBox(height: 8),
              Align(alignment: AlignmentDirectional.centerStart, child: badge),
            ],
          ] else
            Row(
              children: [
                Expanded(child: sets),
                if (badge != null) ...[const SizedBox(width: 12), badge],
              ],
            ),
          if (skipped > 0) ...[
            const SizedBox(height: 4),
            Text(
              l.trainingTimerSkipped(skipped),
              style: AppType.ui(13, color: t.ink2, height: kTrainingLine),
            ),
          ],
          const SizedBox(height: 14),
          Divider(height: 1, thickness: 1, color: t.line),
          const SizedBox(height: 12),
          Wrap(
            spacing: 16,
            runSpacing: 8,
            children: [
              Semantics(
                container: true,
                label: l.trainingHistoryFinished(_finished(context, entry)),
                excludeSemantics: true,
                child: TrainingMetaItem(
                  key: const ValueKey('training-history-detail-day'),
                  icon: Icons.calendar_today_rounded,
                  text: day,
                ),
              ),
              if (span != null && minutes != null)
                Semantics(
                  container: true,
                  label: [
                    l.trainingHistoryStarted(
                      _date(context, snapshot.startedAt),
                    ),
                    minutes,
                  ].join(', '),
                  excludeSemantics: true,
                  child: TrainingMetaItem(
                    key: const ValueKey('training-history-detail-time'),
                    icon: Icons.schedule_rounded,
                    text: '$span · $minutes',
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One exercise in the workout card's row language: its number tile and
/// name, then one hairline row per set with the values on the right; a
/// skipped set shows a dash.
class _ExerciseCard extends StatelessWidget {
  const _ExerciseCard({
    required this.entry,
    required this.index,
    this.onShowProgress,
  });

  final TrainingHistoryEntry entry;
  final int index;

  /// Opens this exercise's best set per workout; null hides the button.
  final VoidCallback? onShowProgress;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l = context.l10n;
    final exercise = entry.snapshot.workout.exercises[index];
    // From 1.5x text the rows give the tile's indent to the values.
    final large = MediaQuery.textScalerOf(context).scale(16) > 24;
    return AppCard(
      key: ValueKey('training-history-exercise-$index'),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              TrainingIndexBadge(number: index + 1),
              const SizedBox(width: 12),
              Expanded(
                child: HeadingSemantics(
                  level: 2,
                  child: Text(
                    exercise.name,
                    style: AppType.ui(
                      16,
                      weight: FontWeight.w700,
                      color: t.ink,
                      height: kTrainingLine,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Padding(
            padding: EdgeInsetsDirectional.only(start: large ? 0 : 40),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var s = 0; s < exercise.sets; s++)
                  _setRow(context, exercise, s),
              ],
            ),
          ),
          if (onShowProgress case final open?)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 12),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: SoftPillButton(
                  key: ValueKey('training-history-progress-$index'),
                  tone: SoftPillTone.neutral,
                  icon: Icons.show_chart_rounded,
                  label: l.trainingExerciseHistoryOpen,
                  semanticLabel: l.trainingExerciseHistoryOpenLabel(
                    exercise.name,
                  ),
                  onTap: open,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _setRow(BuildContext context, TrainingExercise exercise, int set) {
    final l = context.l10n;
    final t = context.t;
    final reference = TrainingSetReference(exerciseIndex: index, setIndex: set);
    final actual = entry.snapshot.actualSets
        .where((a) => a.reference == reference)
        .firstOrNull;
    final weight = actual?.weightKg == null
        ? null
        : formatTrainingWeight(actual!.weightKg!, l);
    final String? value;
    final String spoken;
    if (actual == null) {
      value = null;
      spoken = l.trainingHistorySkippedSet(set + 1);
    } else {
      final reps = actual.reps;
      final seconds = exercise.durationSeconds;
      // A timed set shows and speaks its interval; a weight stays beside it.
      final (timed, timedSpoken) = seconds == null
          ? (l.trainingHistoryTimed, l.trainingHistoryTimed)
          : (
              l.trainingHistorySetSeconds(seconds),
              l.trainingHistorySetSecondsLabel(seconds),
            );
      value = switch ((reps, weight)) {
        (final reps?, final weight?) => l.trainingHistorySetRepsWeight(
          reps,
          weight,
        ),
        (final reps?, null) => l.trainingHistoryRepsValue(reps),
        (null, final weight?) =>
          '$timed · ${l.trainingHistoryWeightValue(weight)}',
        (null, null) => timed,
      };
      spoken = l.trainingHistorySetValue(
        set + 1,
        reps == null ? timedSpoken : l.trainingHistoryRepsValue(reps),
        weight == null
            ? l.trainingActualNoWeight
            : l.trainingHistoryWeightValue(weight),
      );
    }
    return Semantics(
      key: ValueKey('training-history-set-$index-$set'),
      container: true,
      label: spoken,
      excludeSemantics: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: t.line)),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              children: [
                Text(
                  l.trainingHistorySetLabel(set + 1),
                  style: AppType.ui(14, color: t.ink2, height: kTrainingLine),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    value ?? '–',
                    textAlign: TextAlign.end,
                    style: AppType.display(
                      16,
                      weight: FontWeight.w700,
                      color: value == null ? t.ink3 : t.ink,
                      height: kTrainingLine,
                      letterSpacing: 0,
                    ),
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

/// The workout's note in its own card.
class _NoteCard extends StatelessWidget {
  const _NoteCard({required this.note});

  final String note;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return AppCard(
      key: const ValueKey('training-history-note'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.notes_rounded, size: 18, color: t.ink2),
              const SizedBox(width: 8),
              Expanded(
                child: HeadingSemantics(
                  level: 2,
                  child: Text(
                    context.l10n.trainingHistoryNote,
                    style: AppType.ui(
                      16,
                      weight: FontWeight.w700,
                      color: t.ink,
                      height: kTrainingLine,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(note, style: AppType.ui(15, color: t.ink, height: 1.5)),
        ],
      ),
    );
  }
}
