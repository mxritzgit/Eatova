import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../app/home_store.dart';
import '../../l10n/l10n.dart';
import '../../models/fitness_recipe.dart';
import '../../models/logged_meal.dart';
import '../../models/planned_meal.dart';
import '../../models/shopping_list.dart';
import '../../services/local_day.dart';
import '../../services/sync_error_messages.dart';
import '../../services/uuid.dart';
import '../../theme/app_tokens.dart';
import '../../theme/meal_slot_style.dart';
import '../../widgets/common/app_snack.dart';
import '../../widgets/design/design.dart';
import '../../widgets/recipes/recipe_photo.dart';
import '../../widgets/recipes/recipe_navigation.dart';

part 'meal_plan_editor.dart';

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

  Future<void> _edit(DateTime day, {PlannedMeal? plan}) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: context.t.bg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(rSheet)),
      ),
      clipBehavior: Clip.antiAlias,
      builder: (_) => _PlanEditor(store: store, day: day, plan: plan),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final t = context.t;
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) => Scaffold(
        backgroundColor: t.bg,
        body: SafeArea(
          child: ListView(
            key: const PageStorageKey('meal-plan-scroll'),
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
            children: [
              Row(
                children: [
                  SquareIconButton(
                    key: const ValueKey('meal-plan-back'),
                    icon: Icons.arrow_back_rounded,
                    semanticLabel: MaterialLocalizations.of(
                      context,
                    ).backButtonTooltip,
                    onTap: () => Navigator.of(context).maybePop(),
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: ScreenTitle(title: l.mealPlanTitle)),
                ],
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
                        style: AppType.ui(14, color: t.ink),
                      ),
                      TextButton.icon(
                        onPressed: store.mealPlansLoading
                            ? null
                            : store.retryMealPlans,
                        icon: const Icon(Icons.refresh_rounded),
                        label: Text(l.mealPlanRetry),
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
    );
  }

  Widget _weekNavigation(BuildContext context) {
    final l = context.l10n;
    final t = context.t;
    final end = DateTime(_week.year, _week.month, _week.day + 6);
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
          onPressed:
              _week.isAfter(
                DateUtils.dateOnly(
                  clock.now(),
                ).subtract(const Duration(days: 28)),
              )
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
          onPressed: _week.isBefore(clock.now().add(const Duration(days: 350)))
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

  bool _canLog(PlannedMeal plan) {
    try {
      plan.recipe.toMealResultForServings(plan.servings);
      return true;
    } on FormatException {
      return false;
    }
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
                width: 54,
                padding: const EdgeInsets.symmetric(vertical: 10),
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
            const SizedBox(height: 4),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                onPressed: () => _edit(day),
                icon: const Icon(Icons.add_rounded, size: 18),
                label: Text(l.mealPlanAdd),
              ),
            ),
            Divider(height: 8, color: t.line),
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
                      recipe.title,
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
            if (!_canLog(plan))
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
                  child: FilledButton.tonalIcon(
                    key: ValueKey('meal-plan-eat-${plan.id}'),
                    style: FilledButton.styleFrom(
                      backgroundColor: t.brandSurface,
                      foregroundColor: t.onBrandSurface,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 14,
                      ),
                      minimumSize: const Size(48, 48),
                    ),
                    onPressed: busy || !_canLog(plan)
                        ? null
                        : () => _run(
                            plan.id,
                            () => store.eatPlannedMeal(plan.id),
                          ),
                    icon: busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.restaurant_rounded, size: 18),
                    label: Text(
                      l.mealPlanEatToday,
                      textAlign: TextAlign.center,
                      style: AppType.ui(14, weight: FontWeight.w700),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                PopupMenuButton<String>(
                  key: ValueKey('meal-plan-menu-${plan.id}'),
                  tooltip: l.mealPlanMenuLabel,
                  enabled: !busy,
                  icon: Icon(Icons.more_horiz_rounded, color: t.ink2),
                  onSelected: (value) {
                    if (value == 'edit') {
                      _edit(day, plan: plan);
                    } else if (value == 'delete') {
                      _run(plan.id, () => store.removePlannedMeal(plan));
                    }
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(value: 'edit', child: Text(l.mealPlanEdit)),
                    PopupMenuItem(value: 'delete', child: Text(l.commonDelete)),
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
    final items = buildShoppingList(store.plannedMeals, _week);
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
              TextButton.icon(
                onPressed: () => setState(() => _shopping = false),
                icon: const Icon(Icons.calendar_month_outlined),
                label: Text(l.mealPlanWeek),
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: checked ? t.tile : t.surf,
        borderRadius: BorderRadius.circular(rCard),
        child: CheckboxListTile(
          key: ValueKey('shopping-item-${item.id}'),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(rCard),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 10,
          ),
          controlAffinity: ListTileControlAffinity.leading,
          checkboxShape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(6),
          ),
          activeColor: t.accent,
          checkColor: t.onLime,
          value: checked,
          onChanged: _busy.contains(item.id)
              ? null
              : (v) => _run(
                  item.id,
                  () => store.setShoppingChecked(
                    ShoppingCheck(id: item.id, checked: v ?? false),
                  ),
                  feedback: false,
                ),
          title: Text(
            item.grams != null ? item.name : item.recipeTitle!,
            style: AppType.ui(
              16,
              color: checked ? t.ink2 : t.ink,
              weight: FontWeight.w600,
            ).copyWith(decoration: checked ? TextDecoration.lineThrough : null),
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 5),
            child: Text(
              item.grams != null
                  ? '${NumberFormat('0.##', l.localeName).format(item.grams)} g'
                  : '${l.mealPlanPortionCount(item.servings!)}\n'
                        '${item.name.isEmpty ? l.mealPlanNoIngredients : item.name}',
              style: AppType.ui(14, color: t.ink2, height: 1.45),
            ),
          ),
        ),
      ),
    );
  }
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
