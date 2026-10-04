import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../app/home_store.dart';
import '../../l10n/l10n.dart';
import '../../models/fitness_recipe.dart';
import '../../models/logged_meal.dart';
import '../../models/number_input.dart';
import '../../models/planned_meal.dart';
import '../../models/shopping_list.dart';
import '../../services/local_day.dart';
import '../../services/sync_error_messages.dart';
import '../../services/uuid.dart';
import '../../theme/app_tokens.dart';
import '../../theme/meal_slot_style.dart';
import '../../widgets/common/app_snack.dart';
import '../../widgets/common/decimal_text.dart';
import '../../widgets/common/motion.dart';
import '../../widgets/design/design.dart';
import '../../widgets/kcal/food_date_picker.dart';
import '../../widgets/kcal/meal_slot_picker.dart';
import '../../widgets/recipes/recipe_photo.dart';
import '../../widgets/recipes/recipe_navigation.dart';

part 'meal_plan_editor.dart';

/// The planning window: the editor's calendar and the week navigation share
/// it, so every plannable day has a reachable week. Calendar arithmetic keeps
/// a DST change from shifting either end by a day.
DateTime _firstPlanDay(DateTime today) =>
    DateTime(today.year, today.month, today.day - 35);
DateTime _lastPlanDay(DateTime today) =>
    DateTime(today.year, today.month, today.day + 365);

class MealPlanScreen extends StatefulWidget {
  const MealPlanScreen({super.key, required this.store});
  final HomeStore store;
  static Future<void> open(BuildContext context, HomeStore store) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => MealPlanScreen(store: store)),
      );
  @override
  State<MealPlanScreen> createState() => _MealPlanScreenState();
}

class _MealPlanScreenState extends State<MealPlanScreen> {
  late DateTime _week = DateTime(
    clock.now().year,
    clock.now().month,
    clock.now().day - clock.now().weekday + 1,
  );
  bool _shopping = false;
  final Set<String> _busy = {};
  HomeStore get store => widget.store;

  Future<void> _run(
    String id,
    Future<SyncDelivery> Function() action, {
    bool feedback = true,
  }) async {
    if (_busy.contains(id)) return;
    setState(() => _busy.add(id));
    try {
      final result = await action();
      if (!mounted || !feedback) return;
      showAppSnack(
        context,
        result == SyncDelivery.delivered
            ? context.l10n.mealPlanSaved
            : context.l10n.mealPlanSavedOffline,
        icon: Icons.check_circle_outline_rounded,
      );
    } catch (_) {
      if (mounted) {
        showAppSnack(
          context,
          context.l10n.mealPlanSaveError,
          icon: Icons.error_outline_rounded,
          tone: SnackTone.error,
        );
      }
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  Future<void> _edit(DateTime day, {PlannedMeal? plan}) =>
      showEatovaSheet<void>(
        context,
        _PlanEditor(store: store, day: day, plan: plan),
      );

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final t = context.t;
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) => Scaffold(
        backgroundColor: t.bg,
        body: SafeArea(
          child: ReadableWidth(
            child: ListView(
              key: const PageStorageKey('meal-plan-scroll'),
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
              children: [
                PageHeader(
                  backKey: const ValueKey('meal-plan-back'),
                  title: l.mealPlanTitle,
                ),
                const SizedBox(height: 22),
                RecipeNavigation(
                  labels: [l.mealPlanWeek, l.mealPlanShopping],
                  itemKeys: const [
                    ValueKey('meal-plan-tab-week'),
                    ValueKey('meal-plan-tab-shopping'),
                  ],
                  selected: _shopping ? 1 : 0,
                  onSelected: (index) => setState(() => _shopping = index == 1),
                ),
                const SizedBox(height: 22),
                _weekNavigation(context),
                const SizedBox(height: 20),
                if (store.mealPlansLoading)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: LinearProgressIndicator(
                      semanticsLabel: l.mealPlanTitle,
                      color: t.accent,
                    ),
                  ),
                if (store.mealPlansLoadFailed)
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: t.tile,
                      borderRadius: BorderRadius.circular(rCard),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l.mealPlanLoadError,
                          style: AppType.ui(14, color: t.ink, height: 1.4),
                        ),
                        const SizedBox(height: 12),
                        SoftPillButton(
                          key: const ValueKey('meal-plan-retry'),
                          label: l.mealPlanRetry,
                          icon: Icons.refresh_rounded,
                          onTap: store.mealPlansLoading
                              ? null
                              : store.retryMealPlans,
                        ),
                      ],
                    ),
                  ),
                if (_shopping)
                  ..._shoppingList(context)
                else ...[
                  if (!store.mealPlansLoading && !store.mealPlansLoadFailed)
                    _weekSummary(context),
                  const SizedBox(height: 20),
                  for (var i = 0; i < 7; i++)
                    _day(
                      context,
                      DateTime(_week.year, _week.month, _week.day + i),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _weekNavigation(BuildContext context) {
    final l = context.l10n;
    final t = context.t;
    final end = DateTime(_week.year, _week.month, _week.day + 6);
    final today = DateUtils.dateOnly(clock.now());
    final formatter = _week.year == clock.now().year && end.year == _week.year
        ? DateFormat.MMMd(l.localeName)
        : DateFormat.yMMMd(l.localeName);
    return Row(
      children: [
        IconButton(
          key: const ValueKey('meal-plan-previous-week'),
          tooltip: l.mealPlanPreviousWeek,
          style: IconButton.styleFrom(
            backgroundColor: t.surf,
            minimumSize: const Size(48, 48),
            foregroundColor: t.ink,
          ),
          icon: const Icon(Icons.chevron_left_rounded),
          onPressed: _week.isAfter(_firstPlanDay(today))
              ? () => setState(
                  () =>
                      _week = DateTime(_week.year, _week.month, _week.day - 7),
                )
              : null,
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              '${formatter.format(_week)} – ${formatter.format(end)}',
              key: const ValueKey('meal-plan-week-range'),
              textAlign: TextAlign.center,
              style: AppType.ui(15, weight: FontWeight.w600, color: t.ink),
            ),
          ),
        ),
        IconButton(
          key: const ValueKey('meal-plan-next-week'),
          tooltip: l.mealPlanNextWeek,
          style: IconButton.styleFrom(
            backgroundColor: t.surf,
            minimumSize: const Size(48, 48),
            foregroundColor: t.ink,
          ),
          icon: const Icon(Icons.chevron_right_rounded),
          onPressed: end.isBefore(_lastPlanDay(today))
              ? () => setState(
                  () =>
                      _week = DateTime(_week.year, _week.month, _week.day + 7),
                )
              : null,
        ),
      ],
    );
  }

  Widget _weekSummary(BuildContext context) {
    final l = context.l10n;
    final start = localDayKey(_week);
    final end = localDayKey(DateTime(_week.year, _week.month, _week.day + 7));
    final count = store.plannedMeals
        .where(
          (p) =>
              !p.isEaten &&
              p.day.compareTo(start) >= 0 &&
              p.day.compareTo(end) < 0,
        )
        .length;
    return _PlannerSurface(
      color: context.t.brandSurface,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l.mealPlanWeekHeading,
                  style: AppType.display(
                    23,
                    color: context.t.onBrandSurface,
                    height: 1.15,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  l.mealPlanPlannedCount(count),
                  style: AppType.ui(
                    14,
                    color: context.t.accent,
                    weight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  l.mealPlanIntro,
                  style: AppType.ui(13, color: context.t.ink2, height: 1.4),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Icon(Icons.calendar_month_rounded, size: 36, color: context.t.accent),
        ],
      ),
    );
  }

  Widget _day(BuildContext context, DateTime day) {
    final l = context.l10n;
    final t = context.t;
    final entries =
        store.plannedMeals.where((p) => p.day == localDayKey(day)).toList()
          ..sort((a, b) => a.slot.index.compareTo(b.slot.index));
    final today = DateUtils.isSameDay(day, clock.now());
    return Padding(
      key: ValueKey('meal-plan-day-${localDayKey(day)}'),
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                // Minimum, not fixed: at 2x text a fixed 54 broke "28" over
                // two lines.
                constraints: const BoxConstraints(minWidth: 54),
                padding: const EdgeInsets.symmetric(
                  vertical: 10,
                  horizontal: 8,
                ),
                decoration: BoxDecoration(
                  color: today ? t.brandSurface : t.tile,
                  borderRadius: BorderRadius.circular(rControl),
                ),
                child: Text(
                  '${day.day}',
                  textAlign: TextAlign.center,
                  style: AppType.display(22, color: t.ink),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    HeadingSemantics(
                      level: 2,
                      child: Text(
                        DateFormat.EEEE(l.localeName).format(day),
                        style: AppType.display(18, color: t.ink),
                      ),
                    ),
                    if (today)
                      Text(
                        l.mealPlanToday,
                        style: AppType.ui(
                          12,
                          color: t.accent,
                          weight: FontWeight.w600,
                        ),
                      ),
                    if (entries.isEmpty)
                      Text(
                        l.mealPlanEmptyDay,
                        style: AppType.ui(13, color: t.ink2, height: 1.4),
                      ),
                  ],
                ),
              ),
              IconButton(
                key: ValueKey('meal-plan-add-${localDayKey(day)}'),
                tooltip: l.mealPlanAdd,
                onPressed: () => _edit(day),
                style: IconButton.styleFrom(
                  backgroundColor: t.brandSurface,
                  foregroundColor: t.onBrandSurface,
                  minimumSize: const Size(48, 48),
                ),
                icon: const Icon(Icons.add_rounded),
              ),
            ],
          ),
          if (entries.isEmpty) ...[
            const SizedBox(height: 12),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: SoftPillButton(
                key: ValueKey('meal-plan-empty-${localDayKey(day)}'),
                label: l.mealPlanAdd,
                icon: Icons.add_rounded,
                tone: SoftPillTone.neutral,
                onTap: () => _edit(day),
              ),
            ),
          ],
          for (final plan in entries) ...[
            const SizedBox(height: 12),
            _planCard(context, day, plan),
          ],
        ],
      ),
    );
  }

  Widget _planCard(BuildContext context, DateTime day, PlannedMeal plan) {
    final t = context.t;
    final l = context.l10n;
    final recipe = plan.recipe;
    final busy = _busy.contains(plan.id);
    return _PlannerSurface(
      key: ValueKey('meal-plan-card-${plan.id}'),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(rControl),
                child: SizedBox(
                  width: 82,
                  height: 92,
                  child: RecipePhoto(recipe: recipe),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      plan.slot.label(l),
                      style: AppType.ui(
                        12,
                        color: t.accent,
                        weight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      recipe.displayTitle(l),
                      style: AppType.display(18, color: t.ink, height: 1.2),
                    ),
                    const SizedBox(height: 7),
                    Text(
                      l.mealPlanPortionCount(plan.servings),
                      style: AppType.ui(13, color: t.ink2),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (plan.isEaten)
            Row(
              children: [
                Icon(
                  Icons.check_circle_outline_rounded,
                  color: t.accent,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l.mealPlanEatenOn(
                      DateFormat.yMMMd(
                        l.localeName,
                      ).format(plan.eatenAt!.toLocal()),
                    ),
                    style: AppType.ui(13, color: t.ink2),
                  ),
                ),
              ],
            )
          else ...[
            if (!plan.recipe.canLogServings(plan.servings))
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  l.mealPlanCannotLog,
                  style: AppType.ui(13, color: t.ink2),
                ),
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: SoftPillButton(
                    key: ValueKey('meal-plan-eat-${plan.id}'),
                    label: l.mealPlanEatToday,
                    icon: Icons.restaurant_rounded,
                    expand: true,
                    onTap: busy || !plan.recipe.canLogServings(plan.servings)
                        ? null
                        : () => _run(
                            plan.id,
                            () => store.eatPlannedMeal(plan.id),
                          ),
                  ),
                ),
                const SizedBox(width: 8),
                PopupMenuButton<String>(
                  key: ValueKey('meal-plan-menu-${plan.id}'),
                  tooltip: l.mealPlanMenuLabel,
                  enabled: !busy,
                  position: PopupMenuPosition.under,
                  // A round quiet button beside the soft action, like the
                  // sheets' close button; 48 px is the touch floor.
                  style: IconButton.styleFrom(
                    backgroundColor: t.surf2,
                    minimumSize: const Size(48, 48),
                  ),
                  icon: Icon(Icons.more_horiz_rounded, color: t.ink2),
                  onSelected: (value) {
                    if (value == 'edit') {
                      _edit(day, plan: plan);
                    } else if (value == 'delete') {
                      _run(plan.id, () => store.removePlannedMeal(plan));
                    }
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'edit',
                      child: _MenuRow(
                        icon: Icons.edit_outlined,
                        label: l.mealPlanEdit,
                        color: t.ink,
                      ),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      child: _MenuRow(
                        icon: Icons.delete_outline_rounded,
                        label: l.commonDelete,
                        color: t.danger,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  List<Widget> _shoppingList(BuildContext context) {
    final l = context.l10n;
    final t = context.t;
    final items = buildShoppingList(store.plannedMeals, _week,
        decimalSeparator: l.localeName == 'de' ? ',' : '.', l10n: l);
    final done = items.where((i) => store.shoppingChecks[i.id] ?? false).length;
    final complete = items.isNotEmpty && done == items.length;
    return [
      if (!store.mealPlansLoading && !store.mealPlansLoadFailed)
        _PlannerSurface(
          key: const ValueKey('shopping-summary'),
          color: t.brandSurface,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                complete ? Icons.task_alt_rounded : Icons.shopping_bag_outlined,
                color: t.accent,
                size: 30,
              ),
              const SizedBox(height: 14),
              Text(
                complete ? l.mealPlanShoppingDone : l.mealPlanShoppingHeading,
                style: AppType.display(
                  24,
                  color: t.onBrandSurface,
                  height: 1.15,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                items.isEmpty
                    ? l.mealPlanShoppingIntro
                    : l.mealPlanShoppingProgress(done, items.length),
                key: const ValueKey('shopping-progress-label'),
                style: AppType.ui(14, color: t.ink2, height: 1.4),
              ),
              if (items.isNotEmpty) ...[
                const SizedBox(height: 16),
                ClipRRect(
                  borderRadius: BorderRadius.circular(rPill),
                  child: LinearProgressIndicator(
                    minHeight: 6,
                    value: done / items.length,
                    color: t.accent,
                    backgroundColor: t.surf,
                    semanticsLabel: l.mealPlanShoppingProgress(
                      done,
                      items.length,
                    ),
                  ),
                ),
              ],
              if (complete) ...[
                const SizedBox(height: 12),
                Text(
                  l.mealPlanShoppingDoneBody,
                  style: AppType.ui(13, color: t.ink2, height: 1.4),
                ),
              ],
            ],
          ),
        ),
      const SizedBox(height: 24),
      if (items.isEmpty &&
          !store.mealPlansLoading &&
          !store.mealPlansLoadFailed)
        _PlannerSurface(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l.mealPlanShoppingEmptyHeading,
                style: AppType.display(20, color: t.ink),
              ),
              const SizedBox(height: 10),
              Text(
                l.mealPlanShoppingEmpty,
                style: AppType.ui(14, color: t.ink2, height: 1.5),
              ),
              const SizedBox(height: 16),
              SoftPillButton(
                key: const ValueKey('shopping-empty-week'),
                label: l.mealPlanWeek,
                icon: Icons.calendar_month_rounded,
                onTap: () => setState(() => _shopping = false),
              ),
            ],
          ),
        ),
      for (final quantified in [true, false])
        if (items.any((i) => (i.grams != null) == quantified)) ...[
          SectionHeading(
            title: quantified ? l.mealPlanWeighed : l.mealPlanUnquantified,
          ),
          if (!quantified) ...[
            const SizedBox(height: 6),
            Text(
              l.mealPlanUnquantifiedHint,
              style: AppType.ui(13, color: t.ink2, height: 1.4),
            ),
          ],
          const SizedBox(height: 12),
          for (final item in items.where(
            (i) => (i.grams != null) == quantified,
          ))
            _shoppingItem(context, item),
          const SizedBox(height: 24),
        ],
    ];
  }

  Widget _shoppingItem(BuildContext context, ShoppingItem item) {
    final l = context.l10n;
    final t = context.t;
    final checked = store.shoppingChecks[item.id] ?? false;
    final busy = _busy.contains(item.id);
    final radius = BorderRadius.circular(rCard);
    // One merged node like a checkbox list tile: checked state, name and
    // amount, and the row's tap.
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: MergeSemantics(
        child: Semantics(
          checked: checked,
          enabled: !busy,
          child: Material(
            color: checked ? t.tile : t.surf,
            borderRadius: radius,
            child: InkWell(
              key: ValueKey('shopping-item-${item.id}'),
              borderRadius: radius,
              onTap: busy
                  ? null
                  : () => _run(
                      item.id,
                      () => store.setShoppingChecked(
                        ShoppingCheck(id: item.id, checked: !checked),
                      ),
                      feedback: false,
                    ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _ShoppingCheck(checked: checked),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.grams != null ? item.name : item.recipeTitle!,
                            style:
                                AppType.ui(
                                  16,
                                  color: checked ? t.ink2 : t.ink,
                                  weight: FontWeight.w600,
                                  height: 1.35,
                                ).copyWith(
                                  decoration: checked
                                      ? TextDecoration.lineThrough
                                      : null,
                                ),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            item.grams != null
                                ? '${NumberFormat('0.##', l.localeName).format(item.grams)} g'
                                : '${l.mealPlanPortionCount(item.servings!)}\n'
                                      '${item.originalQuantities ? (item.originalBatchServings == null ? l.recipeIngredientsOriginalUnknown : l.recipeIngredientsOriginalBatch(NumberFormat('0.##', l.localeName).format(item.originalBatchServings))) : ''}${item.originalQuantities ? '\n' : ''}'
                                      '${item.name.isEmpty ? l.mealPlanNoIngredients : item.name}',
                            style: AppType.ui(14, color: t.ink2, height: 1.45),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The round check of a shopping row: an accent disc with a tick when
/// bought, a quiet ring before.
class _ShoppingCheck extends StatelessWidget {
  const _ShoppingCheck({required this.checked});
  final bool checked;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final motion = motionDuration(context, kMotionEnter);
    // Lined up with the first text line (16 px at 1.35).
    return Padding(
      padding: const EdgeInsets.only(top: 1),
      child: AnimatedContainer(
        duration: motion,
        curve: kMotionCurve,
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          color: checked ? t.selectedFill : Colors.transparent,
          shape: BoxShape.circle,
          border: Border.all(
            color: checked ? t.selectedFill : t.ink2,
            width: 2,
          ),
        ),
        child: checked
            ? Icon(Icons.check_rounded, size: 16, color: t.onSelected)
            : null,
      ),
    );
  }
}

/// One popup menu entry: icon and label in the entry's tone.
class _MenuRow extends StatelessWidget {
  const _MenuRow({
    required this.icon,
    required this.label,
    required this.color,
  });
  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, size: 20, color: color),
      const SizedBox(width: 12),
      Flexible(
        child: Text(
          label,
          style: AppType.ui(15, weight: FontWeight.w600, color: color),
        ),
      ),
    ],
  );
}

class _PlannerSurface extends StatelessWidget {
  const _PlannerSurface({
    super.key,
    required this.child,
    this.color,
    this.padding = const EdgeInsets.all(20),
  });
  final Widget child;
  final Color? color;
  final EdgeInsets padding;
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: padding,
    decoration: BoxDecoration(
      color: color ?? context.t.surf,
      borderRadius: BorderRadius.circular(rSheet),
    ),
    child: child,
  );
}
