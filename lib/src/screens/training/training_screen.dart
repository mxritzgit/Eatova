import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/coach_training_proposal.dart';
import '../../models/training_plan.dart';
import '../../services/sync_error_messages.dart';
import '../../services/uuid.dart';
import '../../theme/app_tokens.dart';
import '../../theme/training_studio_theme.dart';
import '../../widgets/common/app_snack.dart';
import '../../widgets/design/design.dart';
import 'training_plan_picker.dart';
import 'training_studio_widgets.dart';
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
  final _scroll = ScrollController();

  TrainingPlan? get _plan {
    if (widget.plans.isEmpty) return null;
    return widget.plans.firstWhere(
      (plan) => plan.id == widget.selectedPlanId,
      orElse: () => widget.plans.first,
    );
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant TrainingScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldPlan = oldWidget.plans.isEmpty
        ? null
        : oldWidget.plans.firstWhere(
            (plan) => plan.id == oldWidget.selectedPlanId,
            orElse: () => oldWidget.plans.first,
          );
    final plan = _plan;
    if (oldPlan?.id != plan?.id ||
        oldWidget.selectedPlanId != widget.selectedPlanId ||
        (plan != null && _workoutIndex >= plan.workouts.length)) {
      _workoutIndex = 0;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
      });
    }
  }

  Future<void> _edit(BuildContext context, [TrainingPlan? plan]) async {
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

  Future<void> _delete(BuildContext context, TrainingPlan plan) async {
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
      if (!mounted || !context.mounted) return;
      showAppSnack(
        context,
        deliveryHint(l10n.trainingPageDeleted, delivery, l10n),
      );
    } catch (_) {
      if (!mounted || !context.mounted) return;
      showAppSnack(
        context,
        l10n.trainingPageDeleteError,
        tone: SnackTone.error,
      );
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  Future<void> _choosePlan(BuildContext context) async {
    final select = widget.onSelectPlan;
    final coach = widget.onOpenCoach;
    final result = await showEatovaSheet<Object>(
      context,
      TrainingPlanPicker(plans: widget.plans, selectedPlanId: _plan?.id),
    );
    if (!mounted || !context.mounted || result == null) return;
    if (result == TrainingPlanLibraryAction.create) {
      await _edit(context);
    } else if (result == TrainingPlanLibraryAction.coach) {
      coach();
    } else if (result is String &&
        widget.plans.any((plan) => plan.id == result)) {
      select(result);
      setState(() => _workoutIndex = 0);
      if (_scroll.hasClients) _scroll.jumpTo(0);
    }
  }

  @override
  Widget build(BuildContext context) =>
      TrainingStudioTheme(child: Builder(builder: _page));

  Widget _page(BuildContext context) {
    return SnackHost(
      enabled: TickerMode.valuesOf(context).enabled,
      currentRouteOnly: true,
      child: _pageBody(context),
    );
  }

  Widget _pageBody(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final plan = _plan;
    final workout = plan?.workouts[_workoutIndex];
    final action = widget.hasActiveSession
        ? TrainingStartButton(
            key: const ValueKey('training-resume'),
            label: l10n.trainingPageResume,
            onPressed: widget.onResumeWorkout,
          )
        : plan != null && workout != null
        ? TrainingStartButton(
            key: const ValueKey('training-start'),
            label: l10n.trainingPageStart,
            onPressed: () => widget.onStartWorkout(plan, _workoutIndex),
          )
        : null;

    return ColoredBox(
      color: t.bg,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final pinned =
              constraints.maxHeight >= 560 &&
              MediaQuery.textScalerOf(context).scale(16) <= 24;
          return Column(
            children: [
              Expanded(
                child: ListView(
                  key: const PageStorageKey('training-scroll'),
                  controller: _scroll,
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: const EdgeInsets.only(bottom: 16),
                  children: [
                    Stack(
                      children: [
                        const Positioned.fill(
                          child: Align(
                            alignment: Alignment.topCenter,
                            child: SizedBox(
                              height: 350,
                              width: double.infinity,
                              child: TrainingStudioArtwork(),
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _header(context),
                              const SizedBox(height: 18),
                              if (widget.hasActiveSession) ...[
                                _notice(
                                  context,
                                  l10n.trainingPageInProgress,
                                  icon: Icons.pause_circle_outline_rounded,
                                ),
                                const SizedBox(height: 16),
                              ],
                              if (widget.loadFailed) ...[
                                _notice(
                                  context,
                                  l10n.trainingPageLoadError,
                                  action: TextButton.icon(
                                    onPressed: widget.onRetry,
                                    icon: const Icon(Icons.refresh_rounded),
                                    label: Text(l10n.trainingPageRetry),
                                  ),
                                ),
                                const SizedBox(height: 16),
                              ],
                              if (plan != null && workout != null)
                                _hero(context, plan, workout)
                              else if (widget.loading)
                                Semantics(
                                  label: l10n.trainingPageLoading,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 32,
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        LinearProgressIndicator(color: t.lime),
                                        const SizedBox(height: 20),
                                        Text(
                                          l10n.trainingPageLoading,
                                          style: AppType.ui(15, color: t.ink),
                                        ),
                                      ],
                                    ),
                                  ),
                                )
                              else if (!widget.loadFailed)
                                _empty(context),
                            ],
                          ),
                        ),
                      ],
                    ),
                    if (plan != null && workout != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            TrainingExercisePreview(
                              key: ValueKey(
                                'training-preview-${plan.id}-$_workoutIndex',
                              ),
                              exercises: workout.exercises,
                            ),
                            const SizedBox(height: 12),
                            _coachAction(context, plan),
                          ],
                        ),
                      ),
                    if (action != null && !pinned)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                        child: action,
                      ),
                  ],
                ),
              ),
              if (action != null && pinned)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 10, 20, 18),
                  child: action,
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _hero(
    BuildContext context,
    TrainingPlan plan,
    TrainingWorkout workout,
  ) {
    final t = context.t;
    final l10n = context.l10n;
    final largeText = MediaQuery.textScalerOf(context).scale(16) > 24;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  key: const ValueKey('training-switch-plan'),
                  onPressed: () => _choosePlan(context),
                  style: TextButton.styleFrom(
                    foregroundColor: t.ink2,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          plan.title,
                          style: AppType.ui(16, weight: FontWeight.w600),
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Icon(Icons.keyboard_arrow_down_rounded, size: 20),
                    ],
                  ),
                ),
              ),
            ),
            PopupMenuButton<String>(
              key: const ValueKey('training-plan-menu'),
              enabled: !_deleting,
              tooltip: l10n.trainingPageMore,
              onSelected: (action) {
                if (action == 'edit') _edit(context, plan);
                if (action == 'delete') _delete(context, plan);
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
              icon: _deleting
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(color: t.lime),
                    )
                  : Icon(Icons.more_horiz_rounded, color: t.ink2),
            ),
          ],
        ),
        const SizedBox(height: 20),
        Text(
          workout.title,
          style: AppType.display(
            largeText ? 24 : 34,
            color: t.ink,
            height: 1.08,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          l10n.trainingPageExerciseCount(workout.exercises.length),
          style: AppType.ui(15, color: t.ink2),
        ),
        if (workout.description.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(
            workout.description,
            style: AppType.ui(14, color: t.ink2, height: 1.45),
          ),
        ],
        const SizedBox(height: 22),
        if (plan.workouts.length > 1)
          TrainingWorkoutTabs(
            workouts: plan.workouts,
            selected: _workoutIndex,
            onSelected: (index) => setState(() => _workoutIndex = index),
          ),
        const SizedBox(height: 26),
      ],
    );
  }

  Widget _notice(
    BuildContext context,
    String text, {
    IconData? icon,
    Widget? action,
  }) {
    final t = context.t;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: t.surf,
        borderRadius: BorderRadius.circular(rControl),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[
            Icon(icon, color: t.lime),
            const SizedBox(height: 10),
          ],
          Text(text, style: AppType.ui(14, color: t.ink2, height: 1.45)),
          if (action != null) action,
        ],
      ),
    );
  }

  Widget _coachAction(BuildContext context, TrainingPlan plan) {
    final discuss = widget.onDiscussPlan;
    return TextButton(
      key: const ValueKey('training-discuss-plan'),
      onPressed: discuss != null ? () => discuss(plan) : widget.onOpenCoach,
      style: TextButton.styleFrom(
        foregroundColor: context.t.ink2,
        backgroundColor: context.t.surf,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(rControl),
          side: BorderSide(color: context.t.line),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.chat_bubble_outline_rounded, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              discuss != null
                  ? widget.discussPlanLabel ??
                        context.l10n.coachBriefDiscussAction
                  : context.l10n.trainingPageCoach,
              style: AppType.ui(14, weight: FontWeight.w600),
            ),
          ),
          const Icon(Icons.chevron_right_rounded, size: 20),
        ],
      ),
    );
  }

  Widget _empty(BuildContext context) {
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.only(top: 56, bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.trainingPageEmptyTitle,
            style: AppType.display(32, color: context.t.ink, height: 1.15),
          ),
          const SizedBox(height: 16),
          Text(
            l10n.trainingPageEmptyBody,
            style: AppType.ui(15, color: context.t.ink2, height: 1.5),
          ),
          const SizedBox(height: 32),
          TrainingStartButton(
            key: const ValueKey('training-empty-coach'),
            label: l10n.trainingPageCoach,
            icon: Icons.chat_bubble_outline_rounded,
            onPressed: widget.onOpenCoach,
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () => _edit(context),
            child: Text(l10n.trainingPageCreate),
          ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final l10n = context.l10n;
      final titleStyle = AppType.display(30, color: context.t.ink, height: 1.1);
      double measure(String text, TextStyle style) {
        final painter = TextPainter(
          text: TextSpan(text: text, style: style),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout();
        final width = painter.width;
        painter.dispose();
        return width;
      }

      final inline =
          measure(l10n.trainingPageTitle, titleStyle) +
              measure(
                l10n.trainingStudioPlans,
                AppType.ui(14, weight: FontWeight.w600),
              ) +
              24 +
              44 +
              (widget.onOpenHistory != null ? 44 : 0) +
              16 <=
          constraints.maxWidth;
      final title = Text(l10n.trainingPageTitle, style: titleStyle);
      final actions = Wrap(
        spacing: 2,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          TextButton(
            key: const ValueKey('training-open-plans'),
            onPressed: () => _choosePlan(context),
            style: TextButton.styleFrom(
              foregroundColor: context.t.ink,
              backgroundColor: context.t.surf,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            ),
            child: Text(
              l10n.trainingStudioPlans,
              style: AppType.ui(14, weight: FontWeight.w600),
            ),
          ),
          if (widget.onOpenHistory != null)
            IconButton(
              key: const ValueKey('training-open-history'),
              onPressed: widget.onOpenHistory,
              tooltip: l10n.trainingHistoryTitle,
              icon: const Icon(Icons.history_rounded),
            ),
          IconButton(
            key: const ValueKey('training-create'),
            onPressed: () => _edit(context),
            tooltip: l10n.trainingPageCreate,
            icon: const Icon(Icons.add_rounded),
          ),
        ],
      );
      return inline
          ? Row(children: [title, const Spacer(), actions])
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [title, const SizedBox(height: 12), actions],
            );
    },
  );
}
