import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../l10n/l10n.dart';
import '../../models/training_history.dart';
import '../../models/training_session.dart';
import '../../services/sync_error_messages.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/common/app_snack.dart';
import '../../widgets/design/design.dart';

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
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: IconButton(
                tooltip: l.trainingTimerBack,
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.arrow_back_rounded),
              ),
            ),
            ScreenTitle(
              title: l.trainingHistoryTitle,
              subtitle: l.trainingHistorySubtitle,
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
              TextButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded),
                label: Text(l.trainingPageRetry),
              ),
              const SizedBox(height: 16),
            ],
            if (entries.isEmpty && !loading)
              Text(
                l.trainingHistoryEmpty,
                style: AppType.ui(15, color: t.ink2, height: 1.5),
              ),
            for (final entry in entries) ...[
              ListTile(
                contentPadding: EdgeInsets.zero,
                key: ValueKey('training-history-${entry.id}'),
                title: Text(
                  entry.snapshot.workout.title,
                  style: AppType.display(20, color: t.ink),
                ),
                subtitle: Text(
                  '${_date(context, entry.finishedAt)}\n${l.trainingTimerProgress(entry.snapshot.completedSets.length, entry.snapshot.totalSets)}',
                  style: AppType.ui(14, color: t.ink2, height: 1.5),
                ),
                trailing: Icon(Icons.chevron_right_rounded, color: t.ink2),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        TrainingHistoryDetail(entry: entry, onDelete: onDelete),
                  ),
                ),
              ),
              Divider(color: t.line),
            ],
          ],
        ),
      ),
    );
  }
}

String _date(BuildContext context, DateTime date) =>
    DateFormat.yMMMd(context.l10n.localeName).add_Hm().format(date.toLocal());

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
        body: l.trainingHistoryDeleteBody,
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
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: IconButton(
                tooltip: l.trainingTimerBack,
                onPressed: _busy ? null : () => Navigator.pop(context),
                icon: const Icon(Icons.arrow_back_rounded),
              ),
            ),
            ScreenTitle(
              title: snapshot.workout.title,
              subtitle: snapshot.plan.title,
            ),
            const SizedBox(height: 16),
            Text(
              l.trainingHistoryStarted(_date(context, snapshot.startedAt)),
              style: AppType.ui(14, color: t.ink2),
            ),
            const SizedBox(height: 6),
            Text(
              l.trainingHistoryFinished(_date(context, entry.finishedAt)),
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
            if (_error != null)
              Text(_error!, style: AppType.ui(14, color: t.danger)),
            TextButton.icon(
              key: const ValueKey('training-history-delete'),
              style: TextButton.styleFrom(
                foregroundColor: t.danger,
                minimumSize: const Size(0, 48),
              ),
              onPressed: _busy ? null : _delete,
              icon: const Icon(Icons.delete_outline_rounded),
              label: Text(_busy ? l.trainingTimerSaving : l.trainingHistoryDeleteAction),
            ),
          ],
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
          : l.trainingHistoryWeightValue(actual.weightKg!.toString()),
    );
  }
}
