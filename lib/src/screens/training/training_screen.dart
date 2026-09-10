import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/coach_training_proposal.dart';
import '../../models/training_plan.dart';
import '../../services/sync_error_messages.dart';
import '../../services/uuid.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/common/app_snack.dart';
import '../../widgets/design/design.dart';
import 'training_exercise_list.dart';
import 'training_plan_editor.dart';

class TrainingScreen extends StatefulWidget {
  const TrainingScreen({
    super.key,
    required this.plans,
    required this.onCreatePlan,
    required this.onUpdatePlan,
    required this.onSelectPlan,
    this.selectedPlanId,
    required this.onDeletePlan,
    required this.onStartWorkout,
    required this.onOpenCoach,
    this.loading = false,
    this.loadFailed = false,
    this.onRetry,
    this.hasActiveSession = false,
    this.onResumeWorkout,
    this.onOpenHistory,
    this.onDiscussPlan,
    this.discussPlanLabel,
  });

  final List<TrainingPlan> plans;
  final Future<SyncDelivery> Function(TrainingPlan) onCreatePlan;
  final Future<SyncDelivery> Function(TrainingPlan, CoachTrainingProposal)
  onUpdatePlan;
  final String? selectedPlanId;
  final ValueChanged<String> onSelectPlan;
  final Future<SyncDelivery> Function(String) onDeletePlan;
  final void Function(TrainingPlan, int workoutIndex) onStartWorkout;
  final VoidCallback onOpenCoach;
  final bool loading;
  final bool loadFailed;
  final VoidCallback? onRetry;
  final bool hasActiveSession;
  final VoidCallback? onResumeWorkout;
  final VoidCallback? onOpenHistory;
  final ValueChanged<TrainingPlan>? onDiscussPlan;
  final String? discussPlanLabel;

  @override
  State<TrainingScreen> createState() => _TrainingScreenState();
}

class _TrainingScreenState extends State<TrainingScreen> {
  int _workoutIndex = 0;
  bool _deleting = false;

  TrainingPlan? get _plan {
    if (widget.plans.isEmpty) return null;
    return widget.plans.firstWhere(
      (plan) => plan.id == widget.selectedPlanId,
      orElse: () => widget.plans.first,
    );
  }

  @override
  void didUpdateWidget(covariant TrainingScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedPlanId != widget.selectedPlanId) {
      _workoutIndex = 0;
    }
    final plan = _plan;
    if (plan != null && _workoutIndex >= plan.workouts.length) {
      _workoutIndex = 0;
    }
  }

  Future<void> _edit([TrainingPlan? plan]) async {
    // Capture the account-bound callback before opening the route.
    final create = widget.onCreatePlan;
    final update = widget.onUpdatePlan;
    final newId = plan == null ? uuidV4() : null;
    await showTrainingPlanEditor(
      context,
      initialDraft: plan?.proposal,
      onSave: (draft) => plan == null
          ? create(TrainingPlan(id: newId!, proposal: draft))
          : update(plan, draft),
    );
  }

  Future<void> _delete(TrainingPlan plan) async {
    if (_deleting) return;
    final delete = widget.onDeletePlan;
    final l10n = context.l10n;
    final confirmed = await showEatovaDialog<bool>(
      context: context,
      builder: (dialogContext) => EatovaConfirmDialog(
        title: l10n.trainingPageDeleteTitle,
        body: l10n.trainingPageDeleteBody,
        icon: Icons.delete_outline_rounded,
        destructive: true,
        cancelLabel: l10n.trainingPageCancel,
        onCancel: () => Navigator.pop(dialogContext, false),
        confirmKey: const ValueKey('training-delete-confirm'),
        confirmLabel: l10n.trainingPageDelete,
        onConfirm: () => Navigator.pop(dialogContext, true),
      ),
    );
    if (!mounted || confirmed != true) return;
    setState(() => _deleting = true);
    try {
      final delivery = await delete(plan.id);
      if (!mounted) return;
      showAppSnack(
        context,
        deliveryHint(l10n.trainingPageDeleted, delivery, l10n),
      );
    } catch (_) {
      if (!mounted) return;
      showAppSnack(
        context,
        l10n.trainingPageDeleteError,
        tone: SnackTone.error,
      );
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  Future<void> _choosePlan() async {
    final selected = await showEatovaSheet<String>(
      context,
      SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SectionHeading(title: context.l10n.trainingPagePlans),
              const SizedBox(height: 12),
              for (final plan in widget.plans)
                ListTile(
                  key: ValueKey('training-select-${plan.id}'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    plan.title,
                    style: AppType.ui(
                      15,
                      weight: FontWeight.w600,
                      color: context.t.ink,
                    ),
                  ),
                  subtitle: Text(
                    context.l10n.trainingPageWorkoutCount(plan.workouts.length),
                  ),
                  selected: plan.id == _plan?.id,
                  trailing: plan.id == _plan?.id
                      ? Icon(Icons.check_rounded, color: context.t.accent)
                      : Icon(
                          Icons.chevron_right_rounded,
                          color: context.t.ink2,
                        ),
                  onTap: () => Navigator.pop(context, plan.id),
                ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || selected == null) return;
    widget.onSelectPlan(selected);
    setState(() => _workoutIndex = 0);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final plan = _plan;
    final workout = plan?.workouts[_workoutIndex];
    return ListView(
      key: const PageStorageKey('training-scroll'),
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 28),
      children: [
        _header(context),
        if (widget.onOpenHistory != null) ...[
          const SizedBox(height: 12),
          Align(alignment: Alignment.centerLeft, child: TextButton.icon(
            key: const ValueKey('training-open-history'), onPressed: widget.onOpenHistory,
            icon: const Icon(Icons.history_rounded), label: Text(l10n.trainingHistoryTitle))),
        ],
        const SizedBox(height: 24),
        if (widget.hasActiveSession) ...[
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.trainingPageInProgress,
                  style: AppType.display(19, color: t.ink),
                ),
                const SizedBox(height: 14),
                PrimaryActionButton(
                  key: const ValueKey('training-resume'),
                  label: l10n.trainingPageResume,
                  icon: Icons.play_arrow_rounded,
                  onTap: widget.onResumeWorkout,
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
        ],
        if (widget.loadFailed) ...[
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.trainingPageLoadError,
                  style: AppType.ui(14, color: t.ink2, height: 1.45),
                ),
                TextButton.icon(
                  onPressed: widget.onRetry,
                  icon: const Icon(Icons.refresh_rounded),
                  label: Text(l10n.trainingPageRetry),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
        ],
        if (plan == null && widget.loading)
          Semantics(
            label: l10n.trainingPageLoading,
            child: AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LinearProgressIndicator(color: t.accent),
                  const SizedBox(height: 20),
                  Text(
                    l10n.trainingPageLoading,
                    style: AppType.ui(14, color: t.ink2),
                  ),
                ],
              ),
            ),
          )
        else if (plan == null && !widget.loadFailed)
          _empty(context)
        else if (plan != null && workout != null) ...[
          Container(
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              color: t.forest,
              borderRadius: BorderRadius.circular(rHero),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.trainingPageCurrentPlan,
                  style: AppType.eyebrow(t.onForest),
                ),
                const SizedBox(height: 12),
                Text(
                  plan.title,
                  style: AppType.display(26, color: t.onForest, height: 1.12),
                ),
                if (plan.description.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    plan.description,
                    style: AppType.ui(14, color: t.onForest, height: 1.45),
                  ),
                ],
                if (plan.goal.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    plan.goal,
                    style: AppType.ui(
                      14,
                      weight: FontWeight.w600,
                      color: t.lime,
                    ),
                  ),
                ],
                const SizedBox(height: 18),
                Text(
                  l10n.trainingPageWorkoutCount(plan.workouts.length),
                  style: AppType.ui(13, color: t.onForest),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            children: [
              TextButton.icon(
                key: const ValueKey('training-switch-plan'),
                onPressed: _choosePlan,
                icon: const Icon(Icons.swap_horiz_rounded),
                label: Text(l10n.trainingPageSwitchPlan),
              ),
              PopupMenuButton<String>(
                key: const ValueKey('training-plan-menu'),
                enabled: !_deleting,
                tooltip: l10n.trainingPageMore,
                onSelected: (action) {
                  if (action == 'edit') _edit(plan);
                  if (action == 'delete') _delete(plan);
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'edit',
                    child: Text(l10n.trainingPageEdit),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: Text(l10n.trainingPageDelete),
                  ),
                ],
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: _deleting
                      ? SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: t.accent,
                          ),
                        )
                      : Icon(Icons.more_horiz_rounded, color: t.ink2),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (plan.workouts.length > 1) ...[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var i = 0; i < plan.workouts.length; i++)
                  Semantics(
                    selected: i == _workoutIndex,
                    child: ChoiceChip(
                      key: ValueKey('training-workout-$i'),
                      label: Text(l10n.trainingPageWorkoutNumber(i + 1)),
                      selected: i == _workoutIndex,
                      onSelected: (_) => setState(() => _workoutIndex = i),
                      selectedColor: t.lime,
                      checkmarkColor: t.onLime,
                      labelStyle: AppType.ui(
                        14,
                        color: i == _workoutIndex ? t.onLime : t.ink2,
                      ),
                      materialTapTargetSize: MaterialTapTargetSize.padded,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 20),
          ],
          SectionHeading(title: workout.title),
          const SizedBox(height: 6),
          Text(
            l10n.trainingPageExerciseCount(workout.exercises.length),
            style: AppType.ui(13, color: t.ink2),
          ),
          if (workout.description.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              workout.description,
              style: AppType.ui(14, color: t.ink2, height: 1.45),
            ),
          ],
          const SizedBox(height: 18),
          if (!widget.hasActiveSession)
            PrimaryActionButton(
              key: const ValueKey('training-start'),
              label: l10n.trainingPageStart,
              icon: Icons.play_arrow_rounded,
              onTap: () => widget.onStartWorkout(plan, _workoutIndex),
            ),
          const SizedBox(height: 12),
          TrainingExerciseList(exercises: workout.exercises),
          const SizedBox(height: 16),
          if (widget.onDiscussPlan != null)
            TextButton.icon(key: const ValueKey('training-discuss-plan'),
              onPressed: () => widget.onDiscussPlan!(plan),
              icon: const Icon(Icons.chat_bubble_outline_rounded),
              label: Text(widget.discussPlanLabel ?? l10n.trainingPageCoach)),
          TextButton.icon(
            onPressed: widget.onOpenCoach,
            icon: const Icon(Icons.forum_outlined),
            label: Text(l10n.trainingPageCoach),
          ),
        ],
      ],
    );
  }

  Widget _empty(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: t.forest,
            borderRadius: BorderRadius.circular(rHero),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.fitness_center_rounded, size: 32, color: t.lime),
              const SizedBox(height: 28),
              Text(
                l10n.trainingPageEmptyTitle,
                style: AppType.display(28, color: t.onForest, height: 1.12),
              ),
              const SizedBox(height: 16),
              Text(
                l10n.trainingPageEmptyBody,
                style: AppType.ui(14.5, color: t.onForest, height: 1.5),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        PrimaryActionButton(
          key: const ValueKey('training-empty-coach'),
          label: l10n.trainingPageCoach,
          icon: Icons.forum_outlined,
          onTap: widget.onOpenCoach,
        ),
        const SizedBox(height: 8),
        TextButton(onPressed: _edit, child: Text(l10n.trainingPageCreate)),
      ],
    );
  }

  Widget _header(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final l10n = context.l10n;
      final titleMeasure = TextPainter(
        text: TextSpan(
          text: l10n.trainingPageTitle,
          style: AppType.display(30, color: context.t.ink, height: 1.1),
        ),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout();
      final inline = titleMeasure.width <= constraints.maxWidth - 44;
      titleMeasure.dispose();
      final create = SquareIconButton(
        key: const ValueKey('training-create'),
        icon: Icons.add_rounded,
        onTap: _edit,
        semanticLabel: l10n.trainingPageCreate,
      );
      if (inline) {
        return ScreenTitle(
          title: l10n.trainingPageTitle,
          subtitle: l10n.trainingPageSubtitle,
          trailing: create,
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ScreenTitle(title: l10n.trainingPageTitle),
          const SizedBox(height: 3),
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.trainingPageSubtitle,
                  style: AppType.ui(
                    12,
                    weight: FontWeight.w500,
                    color: context.t.ink2,
                  ),
                ),
              ),
              create,
            ],
          ),
        ],
      );
    },
  );
}
