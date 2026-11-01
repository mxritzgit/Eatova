/// "Woche vorschlagen": the preview of a deterministic week plan
/// ([suggestWeekPlan]). Rows can be swapped or removed; nothing is written
/// before "Übernehmen", which adds them all in one local commit
/// ([HomeStore.addPlannedMeals]), offline too.
library;

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../app/home_store.dart';
import '../../l10n/l10n.dart';
import '../../models/fitness_recipe.dart';
import '../../models/logged_meal.dart';
import '../../models/planned_meal.dart';
import '../../models/user_profile.dart';
import '../../models/week_plan_suggestion.dart';
import '../../services/kcal_format.dart';
import '../../services/local_day.dart';
import '../../services/sync_error_messages.dart' show SyncDelivery;
import '../../theme/app_tokens.dart';
import '../../theme/meal_slot_style.dart';
import '../../widgets/common/app_snack.dart';
import '../../widgets/common/persistence_action.dart';
import '../../widgets/design/design.dart';
import '../../widgets/recipes/recipe_photo.dart';

/// Opens the suggestion for [days] of the week starting on [week] (its
/// Monday); the week's other days only count towards repeats.
Future<void> showWeekPlanSuggestion(
  BuildContext context, {
  required HomeStore store,
  required DateTime week,
  required List<DateTime> days,
}) => showEatovaSheet<void>(
  context,
  _WeekSuggestSheet(store: store, week: week, days: days),
  // A pull on Material's handle would bypass the apply guard.
  dragHandle: false,
);

class _WeekSuggestSheet extends StatefulWidget {
  const _WeekSuggestSheet({
    required this.store,
    required this.week,
    required this.days,
  });

  final HomeStore store;
  final DateTime week;
  final List<DateTime> days;

  @override
  State<_WeekSuggestSheet> createState() => _WeekSuggestSheetState();
}

class _WeekSuggestSheetState extends State<_WeekSuggestSheet> {
  Set<MealSlot> _slots = const {
    MealSlot.breakfast,
    MealSlot.lunch,
    MealSlot.dinner,
  };
  int _seed = 0;
  String? _locale;
  late WeekPlanSuggestion _plan;

  /// Whether the week had an open slot at all, before any row was removed.
  bool _anythingOpen = true;
  bool _saving = false;
  String? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final locale = context.l10n.localeName;
    if (locale != _locale) {
      _locale = locale;
      _plan = _suggest();
    }
  }

  WeekPlanSuggestion _suggest() {
    final store = widget.store;
    final now = clock.now();
    final first = localDayKey(widget.week);
    final last = localDayKey(
      DateTime(widget.week.year, widget.week.month, widget.week.day + 6),
    );
    final plan = suggestWeekPlan(
      days: widget.days,
      slots: _slots,
      profile: store.profile,
      recipes: [
        ...store.visibleUserRecipes,
        ...recipeCatalogForLocale(_locale!),
      ],
      existing: [
        for (final plan in store.plannedMeals)
          if (plan.day.compareTo(first) >= 0 && plan.day.compareTo(last) <= 0)
            plan,
      ],
      skipped: weekPlanSkipsForToday(
        now: now,
        todaysMeals: store.mealsForFoodDate(now),
      ),
      seed: _seed,
    );
    _anythingOpen = plan.meals.isNotEmpty || plan.unfilled.isNotEmpty;
    return plan;
  }

  void _toggleSlot(MealSlot slot) {
    final next = {..._slots};
    if (!next.remove(slot)) next.add(slot);
    if (next.isEmpty) return;
    setState(() {
      _slots = next;
      _plan = _suggest();
    });
  }

  void _shuffle() => setState(() {
    _seed++;
    _plan = _suggest();
  });

  Future<void> _apply() async {
    final meals = _plan.meals;
    if (_saving || meals.isEmpty) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final result = await widget.store.addPlannedMeals([
        for (final meal in meals) meal.toPlannedMeal(),
      ]);
      if (!mounted) return;
      final l = context.l10n;
      showAppSnack(
        context,
        result.added == 0
            ? l.mealPlanSuggestNoneAdded
            : result.delivery == SyncDelivery.delivered
            ? l.mealPlanSuggestApplied(result.added)
            : l.mealPlanSuggestAppliedOffline(result.added),
        icon: Icons.check_circle_outline_rounded,
        tone: result.added == 0 ? SnackTone.neutral : SnackTone.positive,
      );
      Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        final l = context.l10n;
        setState(
          () => _error = error is MealPlanLimitReached
              ? l.mealPlanLimitReached(kMaxOpenPlannedMeals)
              : l.mealPlanSaveError,
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final count = _plan.meals.length;
    return CommitDismissGuard(
      pending: _saving,
      child: Column(
        key: const ValueKey('meal-plan-suggest-sheet'),
        mainAxisSize: MainAxisSize.min,
        children: [
          const SheetHandle(padding: EdgeInsets.only(top: 10, bottom: 12)),
          Flexible(child: _content(context)),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
              child: PrimaryActionButton(
                key: const ValueKey('meal-plan-suggest-apply'),
                label: _saving
                    ? l.mealPlanSaving
                    : l.mealPlanSuggestApply(count),
                icon: Icons.check_rounded,
                busy: _saving,
                onTap: count == 0 ? null : _apply,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _content(BuildContext context) {
    final l = context.l10n;
    final t = context.t;
    final plan = _plan;
    final filter = _filterLabel(widget.store.profile, l);
    final days = [
      for (final day in widget.days)
        if (plan.meals.any((m) => m.day == localDayKey(day))) day,
    ];
    return SingleChildScrollView(
      key: const ValueKey('meal-plan-suggest-scroll'),
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: SheetTitle(l.mealPlanSuggestTitle)),
              const SizedBox(width: 8),
              SheetCloseButton(
                buttonKey: const ValueKey('meal-plan-suggest-close'),
                tooltip: l.commonClose,
                onTap: _saving ? null : () => Navigator.of(context).maybePop(),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            l.mealPlanSuggestIntro,
            style: AppType.ui(14, color: t.ink2, height: 1.45),
          ),
          if (filter != null) ...[
            const SizedBox(height: 8),
            Text(
              l.mealPlanSuggestProfile(filter),
              style: AppType.ui(
                13,
                weight: FontWeight.w600,
                color: t.ink2,
                height: 1.4,
              ),
            ),
          ],
          const SizedBox(height: 18),
          ExcludeSemantics(
            child: Text(
              l.mealPlanSuggestSlots.toUpperCase(),
              style: AppType.eyebrow(t.ink2, size: 9.5),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final slot in MealSlot.values)
                FilterChipPill(
                  key: ValueKey('meal-plan-suggest-slot-${slot.name}'),
                  label: slot.label(l),
                  selected: _slots.contains(slot),
                  tone: FilterChipTone.slot,
                  dotColor: slot.accentOn(t),
                  onTap: _saving ? null : () => _toggleSlot(slot),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: SoftPillButton(
              key: const ValueKey('meal-plan-suggest-shuffle'),
              label: l.mealPlanSuggestShuffle,
              icon: Icons.shuffle_rounded,
              tone: SoftPillTone.neutral,
              onTap: _saving ? null : _shuffle,
            ),
          ),
          for (final pool in plan.thinPools) ...[
            const SizedBox(height: 10),
            SignalNote(
              _thinText(pool, plan.poolSizes[pool]!, filter, l),
              key: ValueKey('meal-plan-suggest-thin-${pool.name}'),
              boxed: true,
            ),
          ],
          if (plan.unfilled.isNotEmpty) ...[
            const SizedBox(height: 10),
            SignalNote(
              l.mealPlanSuggestUnfilled(plan.unfilled.length),
              key: const ValueKey('meal-plan-suggest-unfilled'),
              boxed: true,
            ),
          ],
          if (!_anythingOpen) ...[
            const SizedBox(height: 10),
            SignalNote(
              l.mealPlanSuggestNothing,
              key: const ValueKey('meal-plan-suggest-nothing'),
              boxed: true,
            ),
          ],
          for (final day in days) _day(context, day),
          if (_error != null) ...[
            const SizedBox(height: 16),
            SignalNote(
              _error!,
              tone: t.danger,
              icon: Icons.error_outline_rounded,
              boxed: true,
              liveRegion: true,
            ),
          ],
        ],
      ),
    );
  }

  Widget _day(BuildContext context, DateTime date) {
    final l = context.l10n;
    final t = context.t;
    final day = localDayKey(date);
    final plan = _plan;
    final existing = plan.existingOn(day);
    final kcal = [
      l.mealPlanDayKcal(plan.kcalOn(day), plan.dailyKcalGoal),
      if (existing > 0) l.mealPlanSuggestAlreadyPlanned(existing),
    ].join(' · ');
    final meals = [
      for (final meal in plan.meals)
        if (meal.day == day) meal,
    ];
    return Padding(
      key: ValueKey('meal-plan-suggest-day-$day'),
      padding: const EdgeInsets.only(top: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HeadingSemantics(
            level: 2,
            child: Text(
              DateFormat.MMMMEEEEd(l.localeName).format(date),
              style: AppType.display(17, weight: FontWeight.w700, color: t.ink),
            ),
          ),
          const SizedBox(height: 2),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Flexible(
                child: Text(
                  kcal,
                  key: ValueKey('meal-plan-suggest-day-kcal-$day'),
                  style: AppType.ui(13, color: t.ink2, height: 1.35),
                ),
              ),
              if (plan.fitsGoal(day)) ...[
                const SizedBox(width: 6),
                Icon(
                  Icons.check_circle_rounded,
                  size: 16,
                  color: t.success,
                  semanticLabel: l.mealPlanSuggestInBand,
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          Material(
            color: t.surf,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(rCard),
              side: BorderSide(color: t.cardBorder),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < meals.length; i++) ...[
                  if (i > 0)
                    Divider(
                      height: 1,
                      thickness: 1,
                      indent: 14,
                      endIndent: 14,
                      color: t.line,
                    ),
                  _row(context, meals[i]),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, SuggestedMeal meal) {
    final l = context.l10n;
    final t = context.t;
    final id = '${meal.day}-${meal.slot.name}';
    final title = meal.recipe.displayTitle(l);
    final swapped = _plan.swapped(meal);
    final texts = MergeSemantics(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: AppType.ui(
              15,
              weight: FontWeight.w700,
              color: t.ink,
              height: 1.25,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            [
              meal.slot.label(l),
              l.mealPlanPortionCount(meal.servings),
              '${formatThousands(meal.kcal, l.localeName)} kcal',
              // "494 kcal" or "1,5 Portionen" never break inside.
            ].map((part) => part.replaceAll(' ', ' ')).join(' · '),
            style: AppType.ui(13, color: t.ink2, height: 1.3),
          ),
        ],
      ),
    );
    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: ValueKey('meal-plan-suggest-swap-$id'),
          tooltip: l.mealPlanSuggestSwap(title),
          onPressed: _saving || swapped == null
              ? null
              : () => setState(() => _plan = swapped),
          icon: Icon(Icons.swap_horiz_rounded, color: t.ink2),
        ),
        IconButton(
          key: ValueKey('meal-plan-suggest-remove-$id'),
          tooltip: l.mealPlanSuggestRemove(title),
          onPressed: _saving
              ? null
              : () => setState(() => _plan = _plan.without(meal)),
          icon: Icon(Icons.close_rounded, color: t.ink2),
        ),
      ],
    );
    final thumb = _Thumb(recipe: meal.recipe, slot: meal.slot);
    // From about 1.5x text the side-by-side row leaves the title a few
    // characters per line; it then moves under the photo and the actions.
    final large = MediaQuery.textScalerOf(context).scale(15) > 22;
    return Padding(
      key: ValueKey('meal-plan-suggest-row-$id'),
      padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
      child: large
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(children: [thumb, const Spacer(), actions]),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: texts,
                ),
              ],
            )
          : Row(
              children: [
                thumb,
                const SizedBox(width: 12),
                Expanded(child: texts),
                actions,
              ],
            ),
    );
  }
}

/// "Vegan · ohne Nüsse": the diet and avoided foods behind the suggestion,
/// or null without either.
String? _filterLabel(UserProfile profile, AppLocalizations l) {
  final parts = [
    if (profile.diet != DietPreference.none) profile.diet.label(l),
    if (profile.foodAvoidances.isNotEmpty)
      l.mealPlanSuggestWithout(
        sortedFoodAvoidances(
          profile.foodAvoidances,
        ).map((food) => food.label(l)).join(', '),
      ),
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

/// The honest note for a pool that repeats: "Für „Vegan“ gibt es nur 5
/// Hauptgerichte – einige wiederholen sich."
String _thinText(
  WeekPlanPool pool,
  int size,
  String? filter,
  AppLocalizations l,
) {
  final dishes = switch (pool) {
    WeekPlanPool.breakfast => l.mealPlanSuggestBreakfasts(size),
    WeekPlanPool.main => l.mealPlanSuggestMains(size),
    WeekPlanPool.snack => l.mealPlanSuggestSnacks(size),
  };
  return filter == null
      ? l.mealPlanSuggestThin(dishes)
      : l.mealPlanSuggestThinFor(filter, dishes);
}

/// The recipe photo with the slot's icon tile on its lower left corner, as
/// on the plan's own rows.
class _Thumb extends StatelessWidget {
  const _Thumb({required this.recipe, required this.slot});

  final FitnessRecipe recipe;
  final MealSlot slot;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return SizedBox.square(
      dimension: 52,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(rThumb - 2),
              child: ExcludeSemantics(child: RecipePhoto(recipe: recipe)),
            ),
          ),
          Positioned(
            left: -6,
            bottom: -6,
            child: Container(
              padding: const EdgeInsets.all(2.5),
              decoration: BoxDecoration(
                color: t.surf,
                borderRadius: BorderRadius.circular(rChip - 1),
              ),
              child: SlotIconTile(slot: slot, size: 24),
            ),
          ),
        ],
      ),
    );
  }
}
