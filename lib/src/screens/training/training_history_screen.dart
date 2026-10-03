import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../l10n/l10n.dart';
import '../../models/training_history.dart';
import '../../models/training_log.dart';
import '../../models/training_session.dart';
import '../../services/sync_error_messages.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/common/app_snack.dart';
import '../../widgets/design/design.dart';
import 'training_actual_fields.dart' show formatTrainingWeight;

class TrainingHistoryScreen extends StatelessWidget {
  const TrainingHistoryScreen({
    super.key,
    required this.entries,
    required this.onDelete,
    this.loading = false,
    this.loadFailed = false,
    this.onRetry,
  });
  final List<TrainingHistoryEntry> entries;
  final Future<SyncDelivery> Function(String) onDelete;
  final bool loading, loadFailed;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final t = context.t;
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
              ),
              const SizedBox(height: 12),
              Text(
                l.trainingHistorySubtitle,
                style: AppType.ui(12, weight: FontWeight.w500, color: t.ink2),
              ),
              const SizedBox(height: 24),
              if (loading) ...[
                LinearProgressIndicator(color: t.accent),
                const SizedBox(height: 16),
              ],
              if (loadFailed) ...[
                Text(
                  l.trainingHistoryLoadError,
                  style: AppType.ui(14, color: t.ink2),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: SoftPillButton(
                    onTap: onRetry,
                    icon: Icons.refresh_rounded,
                    label: l.trainingPageRetry,
                  ),
                ),
                const SizedBox(height: 16),
              ],
              if (entries.isEmpty && !loading)
                Text(
                  l.trainingHistoryEmpty,
                  style: AppType.ui(15, color: t.ink2, height: 1.5),
                ),
              // One card per workout, each its own list child: the history
              // holds up to 500 entries and stays lazily built.
              for (final entry in entries) ...[
                _HistoryRow(
                  entry: entry,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          TrainingHistoryDetail(entry: entry, onDelete: onDelete),
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

/// One finished workout as a calm card in the Training tab's row language:
/// tinted glyph tile, title, finish date (and the Logged tag), the set count
/// and a chevron; the whole card opens it.
class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.entry, required this.onTap});

  final TrainingHistoryEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l = context.l10n;
    final snapshot = entry.snapshot;
    final title = snapshot.workout.title;
    final finished = _finished(context, entry);
    final meta = _logged(entry)
        ? '$finished · ${l.trainingHistoryLogged}'
        : finished;
    final progress = l.trainingTimerProgress(
      snapshot.completedSets.length,
      snapshot.totalSets,
    );
    // The same stable hue per plan workout as the tab's "Recent" rows.
    final (tint, ink) = switch (snapshot.workoutIndex % 3) {
      0 => (t.accentTintStrong, t.accentText),
      1 => (t.carbsSurface, t.carbsInk),
      _ => (t.proteinSurface, t.proteinInk),
    };
    // From 1.5x text the tile gives its width to the text.
    final large = MediaQuery.textScalerOf(context).scale(16) > 24;
    final content = Row(
      children: [
        if (!large) ...[
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: tint,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Center(
              child: AppIcon(AppSymbol.training, size: 22, color: ink),
            ),
          ),
          const SizedBox(width: 12),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: AppType.ui(16, weight: FontWeight.w700, color: t.ink),
              ),
              const SizedBox(height: 2),
              Text(
                '$meta\n$progress',
                style: AppType.ui(13, color: t.ink2, height: 1.45),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Icon(Icons.chevron_right_rounded, size: 22, color: t.ink3),
      ],
    );
    return Semantics(
      container: true,
      button: true,
      label: [title, meta, progress].join(', '),
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

String _date(BuildContext context, DateTime date) =>
    DateFormat.yMMMd(context.l10n.localeName).add_Hm().format(date.toLocal());

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
  });
  final TrainingHistoryEntry entry;
  final Future<SyncDelivery> Function(String) onDelete;
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
      );
      Navigator.pop(context);
    } catch (_) {
      if (mounted) setState(() => _error = l.trainingHistoryDeleteError);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final t = context.t;
    final entry = widget.entry;
    final snapshot = entry.snapshot;
    return Scaffold(
      backgroundColor: t.bg,
      body: SafeArea(
        child: ReadableWidth(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            children: [
              PageHeader(
                backKey: const ValueKey('training-history-detail-back'),
                backEnabled: !_busy,
                title: snapshot.workout.title,
              ),
              const SizedBox(height: 12),
              Text(
                [
                  // A free log's plan only repeats the workout title.
                  if (!isLoggedTrainingEntry(entry)) snapshot.plan.title,
                  if (_logged(entry)) l.trainingHistoryLogged,
                ].join(' · '),
                style: AppType.ui(12, weight: FontWeight.w500, color: t.ink2),
              ),
              const SizedBox(height: 16),
              if (trainingEntryHasDuration(entry)) ...[
                Text(
                  l.trainingHistoryStarted(_date(context, snapshot.startedAt)),
                  style: AppType.ui(14, color: t.ink2),
                ),
                const SizedBox(height: 6),
              ],
              Text(
                l.trainingHistoryFinished(_finished(context, entry)),
                style: AppType.ui(14, color: t.ink2),
              ),
              const SizedBox(height: 16),
              Text(
                l.trainingTimerProgress(
                  snapshot.completedSets.length,
                  snapshot.totalSets,
                ),
                style: AppType.display(24, color: t.ink),
              ),
              Text(
                l.trainingTimerSkipped(snapshot.skippedSets.length),
                style: AppType.ui(14, color: t.ink2),
              ),
              const SizedBox(height: 24),
              for (var e = 0; e < snapshot.workout.exercises.length; e++) ...[
                SectionHeading(title: snapshot.workout.exercises[e].name),
                const SizedBox(height: 10),
                for (var s = 0; s < snapshot.workout.exercises[e].sets; s++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Text(
                      _setText(context, e, s),
                      style: AppType.ui(15, color: t.ink, height: 1.5),
                    ),
                  ),
                Divider(color: t.line),
                const SizedBox(height: 16),
              ],
              if (entry.note.isNotEmpty) ...[
                SectionHeading(title: l.trainingHistoryNote),
                const SizedBox(height: 8),
                Text(
                  entry.note,
                  style: AppType.ui(15, color: t.ink, height: 1.5),
                ),
                const SizedBox(height: 24),
              ],
              if (_error != null) ...[
                Text(_error!, style: AppType.ui(14, color: t.danger)),
                const SizedBox(height: 12),
              ],
              SoftPillButton(
                key: const ValueKey('training-history-delete'),
                tone: SoftPillTone.danger,
                expand: true,
                onTap: _busy ? null : _delete,
                icon: Icons.delete_outline_rounded,
                label: _busy
                    ? l.trainingTimerSaving
                    : l.trainingHistoryDeleteAction,
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _setText(BuildContext context, int exerciseIndex, int setIndex) {
    final l = context.l10n;
    final snapshot = widget.entry.snapshot;
    final reference = TrainingSetReference(
      exerciseIndex: exerciseIndex,
      setIndex: setIndex,
    );
    final actual = snapshot.actualSets
        .where((a) => a.reference == reference)
        .firstOrNull;
    if (actual == null) return l.trainingHistorySkippedSet(setIndex + 1);
    return l.trainingHistorySetValue(
      setIndex + 1,
      actual.reps == null
          ? l.trainingHistoryTimed
          : l.trainingHistoryRepsValue(actual.reps!),
      actual.weightKg == null
          ? l.trainingActualNoWeight
          : l.trainingHistoryWeightValue(formatTrainingWeight(actual.weightKg!, l)),
    );
  }
}
