import 'package:flutter/material.dart';

import '../../widgets/common/persistence_action.dart';

import '../../l10n/l10n.dart';
import '../../models/coach_training_proposal.dart';
import '../../models/training_history.dart';
import '../../models/training_insights.dart';
import '../../models/training_plan.dart';
import '../../models/training_session.dart';
import '../../services/sync_error_messages.dart';
import '../../services/uuid.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/common/app_snack.dart';
import '../../widgets/common/lively.dart';
import '../../widgets/common/motion.dart';
import '../../widgets/design/design.dart';
import 'training_overview_widgets.dart';
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
    this.activeSession,
    this.onResumeWorkout,
    this.onOpenHistory,
    this.onDiscussPlan,
    this.adoptionConflicts = const [],
    this.onReviewAdoption,
    this.onDiscardAdoption,
    this.nextWorkout,
    this.week,
    this.volume,
    this.recentWorkouts = const [],
    this.history = const [],
    this.onOpenWorkout,
  });

  final List<TrainingPlan> plans;
  final Future<SyncDelivery> Function(TrainingPlan) onCreatePlan;
  final Future<SyncDelivery> Function(TrainingPlan, CoachTrainingProposal)
  onUpdatePlan;
  final String? selectedPlanId;
  final PersistValueChanged<String> onSelectPlan;
  final Future<SyncDelivery> Function(String) onDeletePlan;
  final void Function(TrainingPlan, int workoutIndex) onStartWorkout;
  final VoidCallback onOpenCoach;
  final bool loading;
  final bool loadFailed;
  final VoidCallback? onRetry;
  final bool hasActiveSession;

  /// The saved session behind [hasActiveSession]: the card shows its
  /// workout, so "Resume" continues exactly what is on screen.
  final TrainingSessionSnapshot? activeSession;
  final VoidCallback? onResumeWorkout;
  final VoidCallback? onOpenHistory;
  final ValueChanged<TrainingPlan>? onDiscussPlan;
  final List<TrainingPlan> adoptionConflicts;
  final Future<void> Function(TrainingPlan)? onReviewAdoption;
  final Future<void> Function(TrainingPlan)? onDiscardAdoption;

  /// The selected plan's workout for today (`nextTrainingWorkoutForToday`);
  /// without it the card starts the plan at its first workout.
  final TrainingNextWorkout? nextWorkout;

  /// This week's finished workouts (`currentTrainingWeek`); hidden if null.
  final TrainingWeek? week;

  /// Weekly load (`weeklyTrainingVolume`); hidden if null.
  final TrainingVolumeTrend? volume;

  /// The newest workouts (`recentWorkoutSummaries`); the section hides when
  /// empty.
  final List<TrainingWorkoutSummary> recentWorkouts;

  /// Completed workouts, for "Last time" of a workout picked by hand.
  final List<TrainingHistoryEntry> history;

  /// Opens one finished workout (a "Recent" row).
  final ValueChanged<TrainingHistoryEntry>? onOpenWorkout;

  @override
  State<TrainingScreen> createState() => _TrainingScreenState();
}

class _TrainingScreenState extends State<TrainingScreen> {
  /// A workout picked with "Choose workout"; null follows the rotation.
  int? _chosenWorkout;
  bool _deleting = false;
  bool _reviewingAdoption = false;
  final _scroll = ScrollController();
  final _cardKey = GlobalKey();

  TrainingPlan? get _plan => _selectedPlan(widget);

  static TrainingPlan? _selectedPlan(TrainingScreen screen) {
    if (screen.plans.isEmpty) return null;
    return screen.plans.firstWhere(
      (plan) => plan.id == screen.selectedPlanId,
      orElse: () => screen.plans.first,
    );
  }

  /// The rotation's workout for [plan]: the store's pick when it belongs to
  /// this plan, else the plan's first workout (nothing trained yet).
  TrainingNextWorkout? _next(TrainingPlan? plan) {
    if (plan == null || plan.workouts.isEmpty) return null;
    final next = widget.nextWorkout;
    if (next != null &&
        next.plan.id == plan.id &&
        next.workoutIndex < plan.workouts.length) {
      return next;
    }
    return TrainingNextWorkout(
      plan: plan,
      workoutIndex: 0,
      completedToday: false,
      exercises: [
        for (final exercise in plan.workouts.first.exercises)
          TrainingExercisePreview(exercise: exercise),
      ],
    );
  }

  /// The saved session, if the card must show it (see [activeSession]).
  TrainingSessionSnapshot? get _session =>
      widget.hasActiveSession ? widget.activeSession : null;

  /// What the card shows: a saved session's workout, else the hand-picked
  /// one, else the rotation's.
  TrainingNextWorkout _shown(TrainingPlan plan, TrainingNextWorkout next) {
    final session = _session;
    if (session != null) {
      return _withLastTime(session.plan, session.workoutIndex);
    }
    final chosen = _chosenWorkout;
    if (chosen == null ||
        chosen == next.workoutIndex ||
        chosen >= plan.workouts.length) {
      return next;
    }
    return _withLastTime(plan, chosen);
  }

  /// Workout [index] of [plan] with "Last time" from the model helpers.
  TrainingNextWorkout _withLastTime(TrainingPlan plan, int index) {
    return TrainingNextWorkout(
      plan: plan,
      workoutIndex: index,
      completedToday: false,
      exercises: [
        for (final exercise in plan.workouts[index].exercises)
          TrainingExercisePreview(
            exercise: exercise,
            lastTopSet: exercise.id == null
                ? null
                : topTrainingSet(
                    lastTrainingPerformance(
                      widget.history,
                      plan.id,
                      exercise.id!,
                      isTimed: exercise.isTimed,
                    ),
                  ),
          ),
      ],
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
    final oldPlan = _selectedPlan(oldWidget);
    final plan = _plan;
    final sourceChanged =
        oldPlan?.id != plan?.id ||
        oldPlan?.incarnation != plan?.incarnation ||
        oldWidget.selectedPlanId != widget.selectedPlanId;
    // A finished (or deleted) workout moves the rotation: the card follows
    // it again instead of a pick made before.
    final historyChanged = !identical(oldWidget.history, widget.history);
    final chosen = _chosenWorkout;
    int? next;
    if (!sourceChanged &&
        !historyChanged &&
        chosen != null &&
        oldPlan != null &&
        plan != null &&
        chosen < oldPlan.workouts.length) {
      // Plan edits may reorder workouts; exercise ids keep the pick.
      final exerciseIds = oldPlan.workouts[chosen].exercises
          .map((exercise) => exercise.id)
          .whereType<String>()
          .toSet();
      final match = plan.workouts.indexWhere(
        (workout) => workout.exercises.any(
          (exercise) => exerciseIds.contains(exercise.id),
        ),
      );
      if (match >= 0) next = match;
    }
    _chosenWorkout = next;
    if (sourceChanged) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
      });
    }
  }

  Future<void> _edit(BuildContext context, [TrainingPlan? plan]) async {
    if (plan != null && widget.adoptionConflicts.any((p) => p.id == plan.id)) {
      await _reviewAdoption(plan);
      return;
    }
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

  Future<void> _reviewAdoption(TrainingPlan plan) async {
    final review = widget.onReviewAdoption;
    if (_reviewingAdoption || _deleting || review == null) return;
    setState(() => _reviewingAdoption = true);
    try {
      await review(plan);
    } finally {
      if (mounted) setState(() => _reviewingAdoption = false);
    }
  }

  Future<void> _delete(BuildContext context, TrainingPlan plan) async {
    if (_deleting) return;
    if (widget.adoptionConflicts.any((entry) => entry.id == plan.id)) {
      await _discardAdoption(plan);
      return;
    }
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

  Future<void> _discardAdoption(TrainingPlan plan) async {
    final discard = widget.onDiscardAdoption;
    if (_deleting || _reviewingAdoption || discard == null) return;
    setState(() => _deleting = true);
    try {
      await discard(plan);
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
      if (!await tryPersistChange(context, () => select(result)) || !mounted) {
        return;
      }
      setState(() => _chosenWorkout = null);
      if (_scroll.hasClients) _scroll.jumpTo(0);
    }
  }

  /// A popup menu anchored at [anchor] (the tapped control).
  Future<T?> _menu<T>(BuildContext anchor, List<PopupMenuEntry<T>> items) {
    final box = anchor.findRenderObject()! as RenderBox;
    final overlay =
        Navigator.of(anchor).overlay!.context.findRenderObject()! as RenderBox;
    return showMenu<T>(
      context: anchor,
      position: RelativeRect.fromRect(
        Rect.fromPoints(
          box.localToGlobal(Offset.zero, ancestor: overlay),
          box.localToGlobal(
            box.size.bottomRight(Offset.zero),
            ancestor: overlay,
          ),
        ),
        Offset.zero & overlay.size,
      ),
      items: items,
    );
  }

  /// "Choose workout": shows the picked workout on the card and scrolls the
  /// card (with its Start) into view. Starting stays an explicit tap.
  Future<void> _chooseWorkout(
    BuildContext anchor,
    TrainingPlan plan,
    int shown,
  ) async {
    final t = context.t;
    final l10n = context.l10n;
    final picked = await _menu<int>(anchor, [
      for (var i = 0; i < plan.workouts.length; i++)
        PopupMenuItem<int>(
          key: ValueKey('training-workout-$i'),
          value: i,
          child: Semantics(
            selected: i == shown,
            label:
                '${l10n.trainingPageWorkoutNumber(i + 1)}: '
                '${plan.workouts[i].title}',
            excludeSemantics: true,
            child: Row(
              children: [
                SizedBox(
                  width: 24,
                  child: i == shown
                      ? Icon(Icons.check_rounded, size: 20, color: t.accentText)
                      : null,
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    plan.workouts[i].title,
                    style: AppType.ui(
                      15,
                      weight: FontWeight.w600,
                      color: t.ink,
                      height: kTrainingLine,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
    ]);
    final current = _plan;
    if (!mounted ||
        picked == null ||
        current == null ||
        current.id != plan.id ||
        picked >= current.workouts.length) {
      return;
    }
    setState(() => _chosenWorkout = picked);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final card = _cardKey.currentContext;
      if (!mounted || card == null || !card.mounted) return;
      Scrollable.ensureVisible(
        card,
        duration: motionDuration(context, const Duration(milliseconds: 280)),
        curve: Curves.easeOutCubic,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart,
      );
    });
  }

  /// The round "adjust" button: edit or delete the plan.
  Future<void> _planMenu(BuildContext anchor, TrainingPlan plan) async {
    final l10n = context.l10n;
    final conflict = widget.adoptionConflicts.any(
      (entry) => entry.id == plan.id,
    );
    final action = await _menu<String>(anchor, [
      PopupMenuItem(value: 'edit', child: Text(l10n.trainingPageEdit)),
      PopupMenuItem(
        value: 'delete',
        child: Text(
          conflict
              ? l10n.trainingAdoptionDiscardAction
              : l10n.trainingPageDelete,
        ),
      ),
    ]);
    if (!mounted) return;
    if (action == 'edit') {
      await _edit(context, plan);
    } else if (action == 'delete') {
      await _delete(context, plan);
    }
  }

  @override
  Widget build(BuildContext context) => SnackHost(
    enabled: TickerMode.valuesOf(context).enabled,
    currentRouteOnly: true,
    // First view of the tab: the sections enter top to bottom, once per
    // session (the shell keeps a visited tab mounted).
    child: LivelyStaggerScope(child: _pageBody(context)),
  );

  Widget _pageBody(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final plan = _plan;
    final next = _next(plan);
    final selectedConflict = widget.adoptionConflicts
        .where((entry) => entry.id == plan?.id)
        .firstOrNull;
    final conflict = selectedConflict ?? widget.adoptionConflicts.firstOrNull;
    final volume = widget.volume;
    final hasHistory = widget.recentWorkouts.isNotEmpty;
    // The floating tab bar's band (from the shell): the page scrolls under
    // the glass and its end clears the bar like the design (150 px at 102).
    final navInset = MediaQuery.paddingOf(context).bottom;
    const gap = SizedBox(height: 14);
    return ColoredBox(
      color: t.bg,
      child: SingleChildScrollView(
        key: const PageStorageKey('training-scroll'),
        controller: _scroll,
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: EdgeInsets.fromLTRB(
          20,
          TabChrome.topInset(context),
          20,
          navInset + 48,
        ),
        // Own layer: scrolling moves the recorded page instead of
        // re-recording it every frame.
        child: RepaintBoundary(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
          children: livelyStagger([
              _header(context, plan),
              gap,
              if (conflict != null) ...[
                _notice(
                  context,
                  l10n.trainingAdoptionReviewBody(conflict.title),
                  icon: Icons.sync_problem_rounded,
                  action: Wrap(
                    children: [
                      TextButton(
                        key: const ValueKey('training-review-adoption'),
                        onPressed: _reviewingAdoption || _deleting
                            ? null
                            : () => _reviewAdoption(conflict),
                        child: Text(l10n.trainingAdoptionReviewAction),
                      ),
                      if (widget.onDiscardAdoption != null)
                        TextButton(
                          key: const ValueKey('training-discard-adoption'),
                          onPressed: _reviewingAdoption || _deleting
                              ? null
                              : () => _discardAdoption(conflict),
                          child: Text(l10n.trainingAdoptionDiscardAction),
                        ),
                    ],
                  ),
                ),
                gap,
              ],
              if (widget.hasActiveSession) ...[
                _notice(
                  context,
                  l10n.trainingPageInProgress,
                  icon: Icons.pause_circle_outline_rounded,
                ),
                gap,
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
                gap,
              ],
              if (widget.week case final week?) ...[
                TrainingWeekCard(
                  key: const ValueKey('training-week'),
                  week: week,
                ),
                gap,
              ],
              if (plan != null && next != null)
                _workoutCard(context, plan, next, selectedConflict)
              else if (widget.loading)
                _loadingState(context)
              else if (!widget.loadFailed)
                _empty(context),
              if (plan != null && next != null) ...[
                const SizedBox(height: 20),
                _quickStart(context, plan, next),
              ],
              if (volume != null &&
                  (hasHistory || volume.weeks.any((w) => w.volumeKg > 0))) ...[
                gap,
                TrainingVolumeCard(
                  key: const ValueKey('training-volume'),
                  trend: volume,
                ),
              ],
              if (hasHistory) ...[
                gap,
                TrainingRecentSection(
                  key: const ValueKey('training-recent'),
                  workouts: widget.recentWorkouts,
                  onOpen: widget.onOpenWorkout,
                  onOpenAll: widget.onOpenHistory,
                ),
              ],
          ]),
          ),
        ),
      ),
    );
  }

  Widget _workoutCard(
    BuildContext context,
    TrainingPlan plan,
    TrainingNextWorkout next,
    TrainingPlan? selectedConflict,
  ) {
    final t = context.t;
    final l10n = context.l10n;
    final shown = _shown(plan, next);
    final workout = shown.workout;
    final done = shown.completedToday;
    final eyebrow = done
        ? l10n.trainingDoneToday
        : _session != null
        ? l10n.trainingInProgress
        : identical(shown, next)
        ? l10n.trainingNextWorkout
        : l10n.trainingPageWorkoutNumber(shown.workoutIndex + 1);
    final eyebrowColor = done ? t.success : t.accentText;
    final action = selectedConflict != null
        ? TrainingStartButton(
            key: const ValueKey('training-review-adoption-primary'),
            label: l10n.trainingAdoptionReviewAction,
            icon: Icons.sync_problem_rounded,
            onPressed: _reviewingAdoption
                ? null
                : () => _reviewAdoption(selectedConflict),
          )
        : widget.hasActiveSession
        ? TrainingStartButton(
            key: const ValueKey('training-resume'),
            label: l10n.trainingPageResume,
            onPressed: widget.onResumeWorkout,
          )
        : TrainingStartButton(
            key: const ValueKey('training-start'),
            label: l10n.trainingPageStart,
            onPressed: () => widget.onStartWorkout(plan, shown.workoutIndex),
          );
    return TrainingHeroCard(
      key: _cardKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            key: const ValueKey('training-card-eyebrow'),
            children: [
              if (done) ...[
                Icon(Icons.check_circle_rounded, size: 15, color: eyebrowColor),
                const SizedBox(width: 6),
              ],
              Flexible(
                child: Text(
                  eyebrow.toUpperCase(),
                  semanticsLabel: eyebrow,
                  style: AppType.ui(
                    12,
                    weight: FontWeight.w800,
                    color: eyebrowColor,
                    letterSpacing: 0.96,
                    height: kTrainingLine,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          HeadingSemantics(
            level: 2,
            child: Text(
              workout.title,
              key: const ValueKey('training-card-title'),
              textScaler: trainingHeadingScaler(context),
              style: AppType.display(30, color: t.ink, height: 1.05),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 14,
            runSpacing: 6,
            children: [
              TrainingMetaItem(
                icon: Icons.sort_rounded,
                text: l10n.trainingPageExerciseCount(shown.exerciseCount),
              ),
              TrainingMetaItem(
                icon: Icons.schedule_rounded,
                text: l10n.trainingMinutesEstimate(shown.estimatedMinutes),
              ),
            ],
          ),
          if (workout.description.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              workout.description,
              style: AppType.ui(13, color: t.ink2, height: 1.45),
            ),
          ],
          const SizedBox(height: 14),
          TrainingExerciseRows(
            key: ValueKey('training-rows-${plan.id}'),
            exercises: shown.exercises,
          ),
          // The 44 px names line already ends in the design's 14 px gap.
          SizedBox(height: shown.exercises.length > 3 ? 0 : 14),
          Row(
            children: [
              Expanded(child: action),
              const SizedBox(width: 10),
              Builder(
                builder: (anchor) => TrainingRoundButton(
                  key: const ValueKey('training-plan-menu'),
                  icon: Icons.tune_rounded,
                  semanticLabel: l10n.trainingPageMore,
                  busy: _deleting,
                  onTap: _deleting ? null : () => _planMenu(anchor, plan),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _quickStart(
    BuildContext context,
    TrainingPlan plan,
    TrainingNextWorkout next,
  ) {
    final t = context.t;
    final l10n = context.l10n;
    final discuss = widget.onDiscussPlan;
    final shown = _shown(plan, next).workoutIndex;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: HeadingSemantics(
            level: 2,
            child: Text(
              l10n.trainingQuickStartTitle,
              style: AppType.display(
                20,
                weight: FontWeight.w700,
                color: t.ink,
                letterSpacing: -0.2,
                height: kTrainingLine,
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        TrainingQuickGrid(
          tiles: [
            TrainingQuickTile(
              key: const ValueKey('training-quick-create'),
              icon: const Icon(Icons.add_rounded),
              label: l10n.trainingPageCreateTitle,
              tint: t.accentTintStrong,
              ink: t.accentText,
              onTap: () => _edit(context),
            ),
            // A saved session owns the card until it is resumed or ended.
            if (plan.workouts.length > 1 && !widget.hasActiveSession)
              Builder(
                builder: (anchor) => TrainingQuickTile(
                  key: const ValueKey('training-quick-workouts'),
                  icon: const Icon(Icons.format_list_numbered_rounded),
                  label: l10n.trainingQuickWorkouts,
                  semanticLabel: l10n.trainingQuickChooseWorkout,
                  tint: t.activityTint,
                  ink: t.activityInk,
                  onTap: () => _chooseWorkout(anchor, plan, shown),
                ),
              ),
            TrainingQuickTile(
              key: const ValueKey('training-open-plans'),
              icon: const Icon(Icons.menu_book_rounded),
              label: l10n.trainingStudioPlans,
              tint: t.carbsSurface,
              ink: t.carbsInk,
              onTap: () => _choosePlan(context),
            ),
            TrainingQuickTile(
              key: const ValueKey('training-discuss-plan'),
              icon: const AppIcon(AppSymbol.coach),
              label: l10n.trainingQuickCoach,
              tint: t.proteinSurface,
              ink: t.proteinInk,
              onTap: discuss != null ? () => discuss(plan) : widget.onOpenCoach,
            ),
          ],
        ),
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
    return AppCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[
            Icon(icon, color: t.accentText),
            const SizedBox(height: 10),
          ],
          Text(text, style: AppType.ui(14, color: t.ink2, height: 1.45)),
          ?action,
        ],
      ),
    );
  }

  Widget _loadingState(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return Semantics(
      label: l10n.trainingPageLoading,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LinearProgressIndicator(color: t.accent),
            const SizedBox(height: 20),
            Text(
              l10n.trainingPageLoading,
              style: AppType.ui(15, color: t.ink, height: kTrainingLine),
            ),
          ],
        ),
      ),
    );
  }

  Widget _empty(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return TrainingHeroCard(
      key: const ValueKey('training-empty'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HeadingSemantics(
            level: 2,
            child: Text(
              l10n.trainingPageEmptyTitle,
              textScaler: trainingHeadingScaler(context),
              style: AppType.display(30, color: t.ink, height: 1.1),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            l10n.trainingPageEmptyBody,
            style: AppType.ui(14, color: t.ink2, height: 1.45),
          ),
          const SizedBox(height: 20),
          TrainingStartButton(
            key: const ValueKey('training-empty-coach'),
            label: l10n.trainingPageCoach,
            icon: Icons.chat_bubble_outline_rounded,
            onPressed: widget.onOpenCoach,
          ),
          const SizedBox(height: 10),
          OutlinedButton(
            key: const ValueKey('training-empty-create'),
            onPressed: () => _edit(context),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(kPrimaryButtonHeight),
            ),
            child: Text(l10n.trainingPageCreate),
          ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context, TrainingPlan? plan) => LayoutBuilder(
    key: TabChrome.headerKey,
    builder: (context, constraints) {
      final t = context.t;
      final l10n = context.l10n;
      final titleStyle = AppType.pageTitle(t.ink);
      final painter = TextPainter(
        text: TextSpan(text: l10n.trainingPageTitle, style: titleStyle),
        textDirection: Directionality.of(context),
        textScaler: AppType.pageTitleScaler(context),
      )..layout();
      final titleWidth = painter.width;
      painter.dispose();
      final actionsWidth =
          HeaderIconButton.size +
          (widget.onOpenHistory != null ? HeaderIconButton.size + 8 : 0);
      final inline = titleWidth + 12 + actionsWidth <= constraints.maxWidth;
      final heading = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (plan != null) ...[
            Text(
              plan.title,
              key: const ValueKey('training-plan-title'),
              style: AppType.ui(
                14,
                weight: FontWeight.w600,
                color: t.ink2,
                height: kTrainingLine,
              ),
            ),
            const SizedBox(height: 2),
          ],
          HeadingSemantics(
            level: 1,
            child: Text(
              l10n.trainingPageTitle,
              style: titleStyle,
              textScaler: AppType.pageTitleScaler(context),
            ),
          ),
        ],
      );
      final actions = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.onOpenHistory != null) ...[
            HeaderIconButton(
              key: const ValueKey('training-open-history'),
              icon: Icons.history_rounded,
              semanticLabel: l10n.trainingHistoryTitle,
              onTap: widget.onOpenHistory,
            ),
            const SizedBox(width: 8),
          ],
          HeaderIconButton(
            key: const ValueKey('training-create'),
            icon: Icons.add_rounded,
            tone: HeaderIconTone.primary,
            semanticLabel: l10n.trainingPageCreateTitle,
            onTap: () => _edit(context),
          ),
        ],
      );
      return inline
          ? Row(
              children: [
                Expanded(child: heading),
                const SizedBox(width: 12),
                actions,
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [heading, const SizedBox(height: 12), actions],
            );
    },
  );
}
