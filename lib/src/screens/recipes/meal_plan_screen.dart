import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import '../../widgets/common/lively.dart';
import '../../widgets/common/motion.dart';
import '../../widgets/design/design.dart';
import '../../widgets/kcal/food_date_picker.dart';
import '../../widgets/kcal/meal_slot_picker.dart';
import '../../widgets/recipes/recipe_photo.dart';
import '../../widgets/recipes/recipe_navigation.dart';
import '../today/today_texts.dart' show kcalThousands, todayWeekdayShort;

part 'meal_plan_editor.dart';
part 'meal_plan_shopping.dart';
part 'meal_plan_week.dart';

/// The planning window: the editor's calendar and the week navigation share
/// it, so every plannable day has a reachable week. Calendar arithmetic keeps
/// a DST change from shifting either end by a day.
DateTime _firstPlanDay(DateTime today) =>
    DateTime(today.year, today.month, today.day - 35);
DateTime _lastPlanDay(DateTime today) =>
    DateTime(today.year, today.month, today.day + 365);

/// From about 1.5x text a row's side-by-side layout leaves its title only a
/// few characters per line; rows then stack.
bool _largeText(BuildContext context) =>
    MediaQuery.textScalerOf(context).scale(15) > 22;

/// [text] that only breaks between words of different parts: "1,340 kcal"
/// or "Sep 28" stay on one line.
String _keepTogether(String text) => text.replaceAll(' ', '\u00A0');

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

  /// The shown days' sections, so a tap in the week strip can scroll to one.
  final Map<String, GlobalKey> _dayKeys = {};
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

  void _showWeek(int deltaDays) => setState(() {
    _week = DateTime(_week.year, _week.month, _week.day + deltaDays);
    _dayKeys.clear();
  });

  List<DateTime> get _days => [
    for (var i = 0; i < 7; i++) DateTime(_week.year, _week.month, _week.day + i),
  ];

  bool _plannable(DateTime day) {
    final now = DateUtils.dateOnly(clock.now());
    return !day.isBefore(_firstPlanDay(now)) && !day.isAfter(_lastPlanDay(now));
  }

  /// Today when the shown week holds it, else the week's first plannable day.
  DateTime get _defaultPlanDay {
    final today = DateUtils.dateOnly(clock.now());
    final days = _days;
    if (days.any((d) => DateUtils.isSameDay(d, today))) return today;
    return days.firstWhere(_plannable, orElse: () => days.first);
  }

  List<PlannedMeal> _plansOn(DateTime day) {
    final key = localDayKey(day);
    return store.plannedMeals.where((p) => p.day == key).toList()
      ..sort((a, b) => a.slot.index.compareTo(b.slot.index));
  }

  void _scrollToDay(DateTime day) {
    final target = _dayKeys[localDayKey(day)]?.currentContext;
    if (target == null) return;
    Scrollable.ensureVisible(
      target,
      duration: motionDuration(context, const Duration(milliseconds: 420)),
      curve: kMotionCurve,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final t = context.t;
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) {
        final ready = !store.mealPlansLoading && !store.mealPlansLoadFailed;
        final items = _shopping
            ? buildShoppingList(
                store.plannedMeals,
                _week,
                decimalSeparator: l.localeName == 'de' ? ',' : '.',
                l10n: l,
              )
            : const <ShoppingItem>[];
        return Scaffold(
          backgroundColor: t.bg,
          body: SafeArea(
            child: ReadableWidth(
              child: ListView(
                key: const PageStorageKey('meal-plan-scroll'),
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
                children: [
                  PageHeader(
                    backKey: const ValueKey('meal-plan-back'),
                    title: l.mealPlanTitle,
                    prominent: true,
                  ),
                  const SizedBox(height: 22),
                  RecipeNavigation(
                    labels: [l.mealPlanWeek, l.mealPlanShopping],
                    itemKeys: const [
                      ValueKey('meal-plan-tab-week'),
                      ValueKey('meal-plan-tab-shopping'),
                    ],
                    selected: _shopping ? 1 : 0,
                    onSelected: (index) =>
                        setState(() => _shopping = index == 1),
                  ),
                  const SizedBox(height: 14),
                  _weekCard(context, ready: ready, items: items),
                  if (store.mealPlansLoading)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(rPill),
                        child: LinearProgressIndicator(
                          minHeight: 3,
                          semanticsLabel: l.mealPlanTitle,
                          color: t.accent,
                          backgroundColor: t.tile,
                        ),
                      ),
                    ),
                  if (store.mealPlansLoadFailed)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: AppCard(
                        padding: const EdgeInsets.all(16),
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
                    ),
                  if (_shopping)
                    ..._shoppingList(context, items, ready: ready)
                  else ...[
                    // One child, so every day is built and the strip can
                    // scroll to any of them.
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [for (final day in _days) _day(context, day)],
                    ),
                    const SizedBox(height: 22),
                    _Footnote(l.mealPlanDiaryFootnote),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// The week's range with its arrows, then the day strip (week) or the
  /// shopping progress (list).
  Widget _weekCard(
    BuildContext context, {
    required bool ready,
    required List<ShoppingItem> items,
  }) {
    final l = context.l10n;
    final t = context.t;
    final days = _days;
    final end = days.last;
    final today = DateUtils.dateOnly(clock.now());
    final formatter = _week.year == today.year && end.year == _week.year
        ? DateFormat.MMMd(l.localeName)
        : DateFormat.yMMMd(l.localeName);
    final (:done, :total) = shoppingProgress(items, store.shoppingChecks);
    final complete = total > 0 && done == total;
    final showProgress = _shopping && ready && total > 0;

    Widget? summary;
    if (!_shopping && ready) {
      final (first, last) = (localDayKey(_week), localDayKey(end));
      final week = store.plannedMeals.where(
        (p) => p.day.compareTo(first) >= 0 && p.day.compareTo(last) <= 0,
      );
      final eaten = week.where((p) => p.isEaten).length;
      summary = Text.rich(
        key: const ValueKey('meal-plan-week-summary'),
        TextSpan(
          children: [
            TextSpan(
              text: l.mealPlanPlannedCount(week.length),
              style: TextStyle(color: t.ink, fontWeight: FontWeight.w700),
            ),
            if (eaten > 0) TextSpan(text: ' · ${l.mealPlanEatenCount(eaten)}'),
          ],
        ),
        style: AppType.ui(13.5, color: t.ink2, height: 1.35),
      );
    } else if (showProgress) {
      summary = Row(
        children: [
          if (complete) ...[
            Icon(Icons.check_circle_rounded, size: 16, color: t.success),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Text(
              complete
                  ? l.mealPlanShoppingDone
                  : l.mealPlanShoppingProgress(done, total),
              key: const ValueKey('shopping-progress-label'),
              style: AppType.ui(
                13.5,
                weight: complete ? FontWeight.w700 : FontWeight.w600,
                color: complete ? t.success : t.ink2,
                height: 1.35,
              ),
            ),
          ),
        ],
      );
    }

    Widget arrow({
      required String key,
      required IconData icon,
      required String label,
      required VoidCallback? onTap,
    }) => Opacity(
      opacity: onTap == null ? 0.4 : 1,
      child: HeaderIconButton(
        key: ValueKey(key),
        icon: icon,
        semanticLabel: label,
        onTap: onTap,
      ),
    );

    final heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Read out when the week changes.
        Semantics(
          liveRegion: true,
          child: Text(
            '${formatter.format(_week)} – ${formatter.format(end)}',
            key: const ValueKey('meal-plan-week-range'),
            // Large text already; capped so a range keeps its dates whole
            // on a narrow phone.
            textScaler: MediaQuery.textScalerOf(
              context,
            ).clamp(maxScaleFactor: 1.6),
            style: AppType.display(
              19,
              weight: FontWeight.w700,
              color: t.ink,
              height: 1.2,
            ),
          ),
        ),
        if (summary != null) ...[const SizedBox(height: 3), summary],
      ],
    );
    final arrows = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        arrow(
          key: 'meal-plan-previous-week',
          icon: Icons.chevron_left_rounded,
          label: l.mealPlanPreviousWeek,
          onTap: _week.isAfter(_firstPlanDay(today))
              ? () => _showWeek(-7)
              : null,
        ),
        const SizedBox(width: 6),
        arrow(
          key: 'meal-plan-next-week',
          icon: Icons.chevron_right_rounded,
          label: l.mealPlanNextWeek,
          onTap: end.isBefore(_lastPlanDay(today)) ? () => _showWeek(7) : null,
        ),
      ],
    );

    return AppCard(
      key: showProgress ? const ValueKey('shopping-summary') : null,
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_largeText(context)) ...[
            heading,
            const SizedBox(height: 10),
            Align(alignment: AlignmentDirectional.centerEnd, child: arrows),
          ] else
            Row(
              children: [
                Expanded(child: heading),
                const SizedBox(width: 8),
                arrows,
              ],
            ),
          if (!_shopping) ...[
            const SizedBox(height: 12),
            // A glanceable index: its labels grow to 1.3x at most, the
            // cells' spoken labels carry the full text.
            MediaQuery.withClampedTextScaling(
              maxScaleFactor: 1.3,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < days.length; i++) ...[
                    if (i > 0) const SizedBox(width: 2),
                    Expanded(
                      child: _StripDay(
                        date: days[i],
                        meals: _plansOn(days[i]),
                        isToday: DateUtils.isSameDay(days[i], today),
                        onTap: () => _scrollToDay(days[i]),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
          if (showProgress) ...[
            const SizedBox(height: 12),
            TweenAnimationBuilder<double>(
              tween: Tween(end: done / total),
              duration: motionDuration(context, kMotionValue),
              curve: kMotionCurve,
              builder: (context, value, _) => ClipRRect(
                borderRadius: BorderRadius.circular(rPill),
                child: LinearProgressIndicator(
                  minHeight: 6,
                  value: value,
                  color: complete ? t.success : t.progressAccent,
                  backgroundColor: t.tile,
                  semanticsLabel: l.mealPlanShoppingProgress(done, total),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _day(BuildContext context, DateTime day) {
    final l = context.l10n;
    final key = localDayKey(day);
    final entries = _plansOn(day);
    final isToday = DateUtils.isSameDay(day, clock.now());
    // The window's first and last week also show days outside it.
    final plannable = _plannable(day);
    final add = plannable ? () => _edit(day) : null;
    return KeyedSubtree(
      key: _dayKeys.putIfAbsent(key, GlobalKey.new),
      child: Padding(
        key: ValueKey('meal-plan-day-$key'),
        padding: const EdgeInsets.only(top: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _DayHeader(
              day: day,
              isToday: isToday,
              // One add control per day: the header's for a planned day, the
              // row below for an empty one.
              add: entries.isEmpty
                  ? null
                  : _RoundAddButton(
                      key: ValueKey('meal-plan-add-$key'),
                      label: l.mealPlanAdd,
                      onTap: add,
                    ),
            ),
            const SizedBox(height: 8),
            if (entries.isEmpty)
              _PlanMealRow(
                key: ValueKey('meal-plan-add-$key'),
                label: l.mealPlanAdd,
                onTap: add,
              )
            else
              _GroupCard(
                // Where the text starts: beside the photo, or under it.
                dividerIndent: _largeText(context) ? 14 : 83,
                children: [
                  for (final plan in entries) _mealRow(context, day, plan),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _mealRow(BuildContext context, DateTime day, PlannedMeal plan) {
    final l = context.l10n;
    final t = context.t;
    final recipe = plan.recipe;
    final busy = _busy.contains(plan.id);
    // The kcal the diary row will get; null when it cannot be logged.
    int? kcal;
    try {
      kcal = recipe.toMealResultForServings(plan.servings, l).caloriesKcal;
    } on FormatException {
      kcal = null;
    }
    final eatenAt = plan.eatenAt?.toLocal();
    final eatenOn = eatenAt == null
        ? null
        : l.mealPlanEatenOn(
            (eatenAt.year == clock.now().year
                    ? DateFormat.MMMd(l.localeName)
                    : DateFormat.yMMMd(l.localeName))
                .format(eatenAt),
          );
    final note = eatenOn ?? (kcal == null ? l.mealPlanCannotLog : null);
    return _MealRow(
      key: ValueKey('meal-plan-card-${plan.id}'),
      recipe: recipe,
      slot: plan.slot,
      title: recipe.displayTitle(l),
      meta: [
        plan.slot.label(l),
        l.mealPlanPortionCount(plan.servings),
        if (kcal != null) '${kcalThousands(kcal, l)} kcal',
      ].map(_keepTogether).join(' · '),
      note: note,
      noteColor: plan.isEaten ? t.accentText : t.ink2,
      toggle: _EatToggle(
        key: ValueKey(
          plan.isEaten ? 'meal-plan-eaten-${plan.id}' : 'meal-plan-eat-${plan.id}',
        ),
        eaten: plan.isEaten,
        label: eatenOn ?? l.mealPlanEatToday,
        onTap: plan.isEaten || busy || kcal == null
            ? null
            : () => _run(plan.id, () => store.eatPlannedMeal(plan.id)),
      ),
      // An eaten plan is a diary entry now: nothing left to edit or delete.
      menu: plan.isEaten
          ? null
          : PopupMenuButton<String>(
              key: ValueKey('meal-plan-menu-${plan.id}'),
              tooltip: l.mealPlanMenuLabel,
              enabled: !busy,
              position: PopupMenuPosition.under,
              style: IconButton.styleFrom(minimumSize: const Size(44, 44)),
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
    );
  }

  List<Widget> _shoppingList(
    BuildContext context,
    List<ShoppingItem> items, {
    required bool ready,
  }) {
    final l = context.l10n;
    final freeText = items.any((i) => i.grams == null);
    return [
      if (items.isEmpty && ready)
        Padding(
          padding: const EdgeInsets.only(top: 16),
          child: _ShoppingEmpty(
            key: const ValueKey('shopping-summary'),
            onPlan: () => _edit(_defaultPlanDay),
          ),
        ),
      if (items.isNotEmpty) ...[
        const SizedBox(height: 18),
        _receipt(context, items),
        const SizedBox(height: 14),
        _Footnote(l.mealPlanShoppingIntro),
        if (freeText) ...[
          const SizedBox(height: 6),
          _Footnote(l.mealPlanUnquantifiedHint),
        ],
      ],
    ];
  }

  /// Toggles the check [id]; a light tick confirms it under the finger.
  VoidCallback? _toggleCheck(String id, bool checked) => _busy.contains(id)
      ? null
      : () {
          HapticFeedback.selectionClick();
          _run(
            id,
            () => store.setShoppingChecked(
              ShoppingCheck(id: id, checked: !checked),
            ),
            feedback: false,
          );
        };

  /// The week's list as one receipt: the weighed ingredients summed across
  /// meals, then every recipe with free-text ingredients line by line.
  Widget _receipt(BuildContext context, List<ShoppingItem> items) {
    final l = context.l10n;
    final checks = store.shoppingChecks;
    final weighed = items.where((i) => i.grams != null).toList();
    final freeText = items.where((i) => i.grams == null).toList();
    final (:done, :total) = shoppingProgress(items, checks);
    final sections = <Widget>[
      if (weighed.isNotEmpty)
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _ReceiptHeading(title: l.mealPlanWeighed),
            for (final item in weighed)
              _ReceiptRow(
                key: ValueKey('shopping-item-${item.id}'),
                label: item.name,
                amount:
                    '${NumberFormat('0.##', l.localeName).format(item.grams)} g',
                checked: checks[item.id] ?? false,
                onTap: _toggleCheck(item.id, checks[item.id] ?? false),
              ),
          ],
        ),
      for (final item in freeText) _receiptRecipe(context, item),
    ];
    return _ReceiptPaper(
      key: const ValueKey('shopping-receipt'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ReceiptHeader(
            week: _isoWeek(_week),
            meals: shoppingPlans(store.plannedMeals, _week).length,
          ),
          for (final section in sections) ...[
            const _ReceiptRule(),
            section,
          ],
          const _ReceiptRule(doubled: true),
          _ReceiptTotals(done: done, total: total),
          _ReceiptFooter(seed: localDayKey(_week)),
        ],
      ),
    );
  }

  /// A recipe with free-text ingredients: its title, day, slot and servings,
  /// then each ingredient line with its own check.
  Widget _receiptRecipe(BuildContext context, ShoppingItem item) {
    final l = context.l10n;
    final checks = store.shoppingChecks;
    final plan = store.plannedMeals.where((p) => p.id == item.planId).firstOrNull;
    final note = item.originalQuantities
        ? (item.originalBatchServings == null
              ? l.recipeIngredientsOriginalUnknown
              : l.recipeIngredientsOriginalBatch(
                  NumberFormat('0.##', l.localeName)
                      .format(item.originalBatchServings),
                ))
        : null;
    final meta = [
      if (plan != null) ...[
        todayWeekdayShort(DateTime.parse(plan.day), l),
        plan.slot.label(l),
      ],
      l.mealPlanPortionCount(item.servings!),
    ].map(_keepTogether).join(' · ');
    return Column(
      key: ValueKey('shopping-recipe-${item.id}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ReceiptHeading(title: item.recipeTitle!, meta: meta, note: note),
        if (item.lines.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
            child: Text(
              l.mealPlanNoIngredients,
              style: AppType.ui(13.5, color: context.t.ink2, height: 1.4),
            ),
          )
        else
          for (final line in item.lines)
            if (line.heading)
              _ReceiptSubheading(line.label)
            else
              _ReceiptRow(
                key: ValueKey('shopping-item-${line.id}'),
                label: line.label,
                amount: line.amount,
                checked: shoppingLineChecked(checks, item, line),
                onTap: _toggleCheck(
                  line.id,
                  shoppingLineChecked(checks, item, line),
                ),
              ),
      ],
    );
  }
}

/// Rows in one calm card, separated by hairlines that start at the text.
class _GroupCard extends StatelessWidget {
  const _GroupCard({required this.children, required this.dividerIndent});

  final List<Widget> children;
  final double dividerIndent;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Material(
      color: t.surf,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(rCard),
        side: BorderSide(color: t.cardBorder),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0)
              Divider(
                height: 1,
                thickness: 1,
                indent: dividerIndent,
                endIndent: 14,
                color: t.line,
              ),
            children[i],
          ],
        ],
      ),
    );
  }
}

/// A quiet explanation under a section: no icon, no frame.
class _Footnote extends StatelessWidget {
  const _Footnote(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4),
    child: Text(
      text,
      style: AppType.ui(12.5, color: context.t.ink3, height: 1.45),
    ),
  );
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
