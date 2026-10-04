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
import '../../widgets/common/lively.dart';
import '../../widgets/common/motion.dart';
import '../../widgets/design/design.dart';
import '../../widgets/kcal/food_date_picker.dart';
import '../../widgets/kcal/meal_slot_picker.dart';
import '../../widgets/recipes/recipe_photo.dart';
import '../../widgets/recipes/recipe_navigation.dart';
import '../today/today_texts.dart' show kcalThousands, todayWeekdayShort;

part 'meal_plan_editor.dart';

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

/// Free-text ingredient lines without their list markers ("- ", "• ").
List<String> _ingredientLines(String text) => [
  for (final line in text.split('\n'))
    if (line.trim().replaceFirst(RegExp(r'^[-–—•*·]+\s*'), '')
        case final clean when clean.isNotEmpty)
      clean,
];

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
    final done = items.where((i) => store.shoppingChecks[i.id] ?? false).length;
    final complete = items.isNotEmpty && done == items.length;
    final showProgress = _shopping && ready && items.isNotEmpty;

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
                  : l.mealPlanShoppingProgress(done, items.length),
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
              tween: Tween(end: done / items.length),
              duration: motionDuration(context, kMotionValue),
              curve: kMotionCurve,
              builder: (context, value, _) => ClipRRect(
                borderRadius: BorderRadius.circular(rPill),
                child: LinearProgressIndicator(
                  minHeight: 6,
                  value: value,
                  color: complete ? t.success : t.progressAccent,
                  backgroundColor: t.tile,
                  semanticsLabel: l.mealPlanShoppingProgress(
                    done,
                    items.length,
                  ),
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
    final weighed = items.where((i) => i.grams != null).toList();
    final freeText = items.where((i) => i.grams == null).toList();
    return [
      if (items.isEmpty && ready)
        Padding(
          padding: const EdgeInsets.only(top: 16),
          child: _ShoppingEmpty(
            key: const ValueKey('shopping-summary'),
            onPlan: () => _edit(_defaultPlanDay),
          ),
        ),
      if (weighed.isNotEmpty) ...[
        const SizedBox(height: 26),
        SectionHeading(title: l.mealPlanWeighed),
        const SizedBox(height: 10),
        _GroupCard(
          dividerIndent: 54,
          children: [for (final item in weighed) _shoppingRow(context, item)],
        ),
        const SizedBox(height: 10),
        _Footnote(l.mealPlanShoppingIntro),
      ],
      if (freeText.isNotEmpty) ...[
        const SizedBox(height: 26),
        SectionHeading(title: l.mealPlanUnquantified),
        const SizedBox(height: 10),
        for (final item in freeText) ...[
          _recipeCard(context, item),
          const SizedBox(height: 10),
        ],
        _Footnote(l.mealPlanUnquantifiedHint),
        if (weighed.isEmpty) ...[
          const SizedBox(height: 6),
          _Footnote(l.mealPlanShoppingIntro),
        ],
      ],
    ];
  }

  VoidCallback? _toggleCheck(ShoppingItem item, bool checked) =>
      _busy.contains(item.id)
      ? null
      : () => _run(
          item.id,
          () => store.setShoppingChecked(
            ShoppingCheck(id: item.id, checked: !checked),
          ),
          feedback: false,
        );

  /// A weighed ingredient: check, name and amount; a checked row dims in
  /// place, so nothing moves under the finger.
  Widget _shoppingRow(BuildContext context, ShoppingItem item) {
    final l = context.l10n;
    final t = context.t;
    final checked = store.shoppingChecks[item.id] ?? false;
    final name = Text(
      item.name,
      style: AppType.ui(
        15,
        weight: FontWeight.w600,
        color: checked ? t.ink3 : t.ink,
        height: 1.3,
      ).copyWith(
        decoration: checked ? TextDecoration.lineThrough : null,
        decorationColor: t.ink3,
      ),
    );
    final amount = _AmountCapsule(
      value: NumberFormat('0.##', l.localeName).format(item.grams),
      unit: 'g',
      dimmed: checked,
    );
    final large = _largeText(context);
    // One merged node like a checkbox list tile: checked state, name and
    // amount, and the row's tap.
    return MergeSemantics(
      child: Semantics(
        checked: checked,
        enabled: !_busy.contains(item.id),
        child: InkWell(
          key: ValueKey('shopping-item-${item.id}'),
          onTap: _toggleCheck(item, checked),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 14, 10),
              child: Row(
                crossAxisAlignment: large
                    ? CrossAxisAlignment.start
                    : CrossAxisAlignment.center,
                children: [
                  _ShoppingCheck(checked: checked),
                  const SizedBox(width: 14),
                  Expanded(
                    child: large
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [name, const SizedBox(height: 6), amount],
                          )
                        : name,
                  ),
                  if (!large) ...[const SizedBox(width: 12), amount],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// A recipe with free-text ingredients: one check for the whole recipe,
  /// its photo, the planned servings and the ingredient lines.
  Widget _recipeCard(BuildContext context, ShoppingItem item) {
    final l = context.l10n;
    final t = context.t;
    final checked = store.shoppingChecks[item.id] ?? false;
    final plan = store.plannedMeals.where((p) => p.id == item.planId).firstOrNull;
    final lines = _ingredientLines(item.name);
    final basis = item.originalQuantities
        ? (item.originalBatchServings == null
              ? l.recipeIngredientsOriginalUnknown
              : l.recipeIngredientsOriginalBatch(
                  NumberFormat('0.##', l.localeName)
                      .format(item.originalBatchServings),
                ))
        : null;
    final lineStyle = AppType.ui(
      14,
      color: checked ? t.ink3 : t.ink2,
      height: 1.4,
    );
    final radius = BorderRadius.circular(rCard);
    final title = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          item.recipeTitle!,
          style: AppType.ui(
            15,
            weight: FontWeight.w700,
            color: checked ? t.ink3 : t.ink,
            height: 1.3,
          ).copyWith(
            decoration: checked ? TextDecoration.lineThrough : null,
            decorationColor: t.ink3,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          l.mealPlanPortionCount(item.servings!),
          style: AppType.ui(13, color: t.ink2, height: 1.3),
        ),
      ],
    );
    final large = _largeText(context);
    return MergeSemantics(
      child: Semantics(
        checked: checked,
        enabled: !_busy.contains(item.id),
        child: Material(
          color: t.surf,
          shape: RoundedRectangleBorder(
            borderRadius: radius,
            side: BorderSide(color: t.cardBorder),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: ValueKey('shopping-item-${item.id}'),
            onTap: _toggleCheck(item, checked),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      _ShoppingCheck(checked: checked),
                      const SizedBox(width: 14),
                      if (plan != null) ...[
                        Opacity(
                          opacity: checked ? 0.5 : 1,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(rControl),
                            child: SizedBox.square(
                              dimension: 48,
                              child: ExcludeSemantics(
                                child: RecipePhoto(recipe: plan.recipe),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                      ],
                      if (!large) Expanded(child: title),
                    ],
                  ),
                  if (large) ...[const SizedBox(height: 10), title],
                  const SizedBox(height: 12),
                  Container(height: 1, color: t.line),
                  const SizedBox(height: 10),
                  if (basis != null) ...[
                    Text(
                      basis,
                      style: AppType.ui(12.5, color: t.ink3, height: 1.4),
                    ),
                    const SizedBox(height: 6),
                  ],
                  if (lines.isEmpty)
                    Text(l.mealPlanNoIngredients, style: lineStyle)
                  else
                    for (var i = 0; i < lines.length; i++)
                      Padding(
                        padding: EdgeInsets.only(top: i == 0 ? 0 : 5),
                        child: Text(lines[i], style: lineStyle),
                      ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A day's heading: weekday, short date and the Today badge, with the
/// day's add button on the right once it has meals.
class _DayHeader extends StatelessWidget {
  const _DayHeader({required this.day, required this.isToday, this.add});

  final DateTime day;
  final bool isToday;
  final Widget? add;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final t = context.t;
    return ConstrainedBox(
      // As tall as the add button where there is one.
      constraints: BoxConstraints(minHeight: add == null ? 0 : 44),
      child: Row(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: 2),
              child: Wrap(
                spacing: 10,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  HeadingSemantics(
                    level: 2,
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: DateFormat.EEEE(l.localeName).format(day),
                            style: AppType.display(
                              19,
                              weight: FontWeight.w700,
                              color: t.ink,
                            ),
                          ),
                          TextSpan(
                            text:
                                '  ${_keepTogether(DateFormat.MMMd(l.localeName).format(day))}',
                            style: AppType.ui(
                              14,
                              weight: FontWeight.w600,
                              color: t.ink3,
                            ),
                          ),
                        ],
                      ),
                      semanticsLabel: DateFormat.MMMMEEEEd(
                        l.localeName,
                      ).format(day),
                    ),
                  ),
                  if (isToday)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: t.accentTint,
                        borderRadius: BorderRadius.circular(rPill),
                      ),
                      child: Text(
                        l.mealPlanToday,
                        style: AppType.ui(
                          12,
                          weight: FontWeight.w700,
                          color: t.accentText,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          ?add,
        ],
      ),
    );
  }
}

/// One day of the week strip: weekday, date and a dot per planned meal in
/// its slot's hue (dimmed once eaten); today carries the accent. A tap
/// scrolls to the day.
class _StripDay extends StatelessWidget {
  const _StripDay({
    required this.date,
    required this.meals,
    required this.isToday,
    required this.onTap,
  });

  final DateTime date;
  final List<PlannedMeal> meals;
  final bool isToday;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final t = context.t;
    final radius = BorderRadius.circular(rControl);
    final label = [
      DateFormat.MMMMEEEEd(l.localeName).format(date),
      if (isToday) l.mealPlanToday,
      l.mealPlanPlannedCount(meals.length),
    ].join(', ');
    return Semantics(
      container: true,
      button: true,
      selected: isToday,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      child: Material(
        color: isToday ? t.accent.withValues(alpha: 0.1) : Colors.transparent,
        borderRadius: radius,
        child: InkWell(
          key: ValueKey('meal-plan-strip-${localDayKey(date)}'),
          borderRadius: radius,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(2, 8, 2, 9),
            child: Column(
              children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    todayWeekdayShort(date, l),
                    maxLines: 1,
                    style: AppType.ui(
                      12,
                      weight: isToday ? FontWeight.w700 : FontWeight.w600,
                      color: isToday ? t.accentText : t.ink3,
                    ),
                  ),
                ),
                const SizedBox(height: 3),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    '${date.day}',
                    maxLines: 1,
                    style: AppType.display(
                      18,
                      weight: FontWeight.w700,
                      color: isToday ? t.accentText : t.ink,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                SizedBox(
                  height: 6,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (var i = 0; i < meals.length && i < 4; i++) ...[
                        if (i > 0) const SizedBox(width: 3),
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: meals[i].slot
                                .tileInk(t)
                                .withValues(alpha: meals[i].isEaten ? 0.4 : 1),
                            shape: BoxShape.circle,
                          ),
                        ),
                      ],
                    ],
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

/// A planned meal: photo with its slot tile, name, "slot · servings · kcal",
/// then the eaten toggle and the menu. At large text the actions move up
/// beside the photo and the text gets the full width.
class _MealRow extends StatelessWidget {
  const _MealRow({
    super.key,
    required this.recipe,
    required this.slot,
    required this.title,
    required this.meta,
    required this.toggle,
    required this.noteColor,
    this.note,
    this.menu,
  });

  final FitnessRecipe recipe;
  final MealSlot slot;
  final String title, meta;
  final String? note;
  final Color noteColor;
  final Widget toggle;
  final Widget? menu;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final texts = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: AppType.ui(
            15.5,
            weight: FontWeight.w700,
            color: t.ink,
            height: 1.25,
          ),
        ),
        const SizedBox(height: 3),
        Text(meta, style: AppType.ui(13, color: t.ink2, height: 1.3)),
        if (note != null) ...[
          const SizedBox(height: 4),
          Text(
            note!,
            style: AppType.ui(
              12.5,
              weight: FontWeight.w600,
              color: noteColor,
              height: 1.35,
            ),
          ),
        ],
      ],
    );
    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [toggle, ?menu],
    );
    final thumb = _MealThumb(recipe: recipe, slot: slot);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
      child: _largeText(context)
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(children: [thumb, const Spacer(), actions]),
                const SizedBox(height: 10),
                Padding(padding: const EdgeInsets.only(right: 8), child: texts),
              ],
            )
          : Row(
              children: [
                thumb,
                const SizedBox(width: 13),
                Expanded(child: texts),
                const SizedBox(width: 2),
                actions,
              ],
            ),
    );
  }
}

/// The recipe photo with the slot's icon tile on its lower left corner
/// (the right one keeps the photos' "AI Generated" mark visible).
class _MealThumb extends StatelessWidget {
  const _MealThumb({required this.recipe, required this.slot});

  final FitnessRecipe recipe;
  final MealSlot slot;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return SizedBox.square(
      dimension: 56,
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
              child: SlotIconTile(slot: slot, size: 26),
            ),
          ),
        ],
      ),
    );
  }
}

/// "Eaten today" as a compact toggle: a tinted disc with a fork while the
/// meal is open, the accent fill with a check once it is in the diary. An
/// eaten meal cannot be unticked (the diary entry is real).
class _EatToggle extends StatelessWidget {
  const _EatToggle({
    super.key,
    required this.eaten,
    required this.label,
    required this.onTap,
  });

  final bool eaten;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final enabled = onTap != null;
    final motion = motionDuration(context, kMotionEnter);
    return Semantics(
      container: true,
      button: !eaten,
      checked: eaten,
      enabled: enabled,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      child: Tooltip(
        message: label,
        excludeFromSemantics: true,
        child: Opacity(
          opacity: enabled || eaten ? 1 : 0.45,
          child: PressScale(
            enabled: enabled,
            child: SizedBox.square(
              dimension: 44,
              child: Material(
                type: MaterialType.transparency,
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: onTap,
                  child: Center(
                    child: AnimatedContainer(
                      duration: motion,
                      curve: kMotionCurve,
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: eaten ? t.selectedFill : t.accentTint,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        eaten ? Icons.check_rounded : Icons.restaurant_rounded,
                        size: eaten ? 20 : 17,
                        color: eaten ? t.onSelected : t.accentText,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The add button beside a planned day's heading: a 34 px tinted disc in a
/// 44 px target, as on the Today tab.
class _RoundAddButton extends StatelessWidget {
  const _RoundAddButton({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final enabled = onTap != null;
    return Semantics(
      container: true,
      button: true,
      enabled: enabled,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      child: Opacity(
        opacity: enabled ? 1 : 0.45,
        child: PressScale(
          enabled: enabled,
          child: SizedBox.square(
            dimension: 44,
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: onTap,
                child: Center(
                  child: Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: t.accentTint,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.add_rounded, size: 20, color: t.accentText),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// An empty day's "Plan a meal": one soft row with a dashed edge, an open
/// slot to fill, that opens the editor. Outside the planning window it
/// stays, dimmed and disabled.
class _PlanMealRow extends StatelessWidget {
  const _PlanMealRow({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final enabled = onTap != null;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(rCard),
    );
    return Semantics(
      container: true,
      button: true,
      enabled: enabled,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      child: Opacity(
        opacity: enabled ? 1 : 0.45,
        child: PressScale(
          enabled: enabled,
          scale: kPressScaleCard,
          child: CustomPaint(
            foregroundPainter: _DashedEdge(color: t.inkFaint, radius: rCard),
            child: Material(
              color: Colors.transparent,
              shape: shape,
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: onTap,
                customBorder: shape,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 52),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 16, 8),
                    child: Row(
                      children: [
                        Container(
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(
                            color: t.accentTint,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            Icons.add_rounded,
                            size: 18,
                            color: t.accentText,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            label,
                            style: AppType.ui(
                              14.5,
                              weight: FontWeight.w600,
                              color: t.ink2,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A dashed rounded edge, inset by half the stroke.
class _DashedEdge extends CustomPainter {
  const _DashedEdge({required this.color, required this.radius});

  final Color color;
  final double radius;

  static const double _dash = 6, _gap = 5, _stroke = 1.2;

  @override
  void paint(Canvas canvas, Size size) {
    final edge = RRect.fromRectAndRadius(
      (Offset.zero & size).deflate(_stroke / 2),
      Radius.circular(radius),
    );
    final pen = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = _stroke;
    for (final metric in (Path()..addRRect(edge)).computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += _dash + _gap) {
        final stop = d + _dash < metric.length ? d + _dash : metric.length;
        canvas.drawPath(metric.extractPath(d, stop), pen);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedEdge old) =>
      old.color != color || old.radius != radius;
}

/// The shopping list before anything is planned for the week.
class _ShoppingEmpty extends StatelessWidget {
  const _ShoppingEmpty({super.key, required this.onPlan});

  final VoidCallback onPlan;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final t = context.t;
    return AppCard(
      padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: t.accentTint,
              borderRadius: BorderRadius.circular(rControl),
            ),
            child: Icon(
              Icons.shopping_basket_outlined,
              size: 22,
              color: t.accentText,
            ),
          ),
          const SizedBox(height: 14),
          HeadingSemantics(
            level: 2,
            child: Text(
              l.mealPlanShoppingEmptyHeading,
              style: AppType.display(19, weight: FontWeight.w700, color: t.ink),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            l.mealPlanShoppingEmpty,
            style: AppType.ui(14, color: t.ink2, height: 1.45),
          ),
          const SizedBox(height: 16),
          SoftPillButton(
            key: const ValueKey('shopping-empty-plan'),
            label: l.mealPlanAdd,
            icon: Icons.add_rounded,
            onTap: onPlan,
          ),
        ],
      ),
    );
  }
}

/// A weighed amount as a quiet capsule: the number in the display face, the
/// unit muted. Dimmed (bought) it keeps `ink3`, still AA on `surf2`.
class _AmountCapsule extends StatelessWidget {
  const _AmountCapsule({
    required this.value,
    required this.unit,
    required this.dimmed,
  });

  final String value, unit;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
      decoration: BoxDecoration(
        color: t.surf2,
        borderRadius: BorderRadius.circular(rPill),
      ),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: value,
              style: AppType.display(
                15,
                weight: FontWeight.w700,
                color: dimmed ? t.ink3 : t.ink,
              ),
            ),
            TextSpan(
              text: ' $unit',
              style: AppType.ui(
                12.5,
                weight: FontWeight.w600,
                color: dimmed ? t.ink3 : t.ink2,
              ),
            ),
          ],
        ),
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

/// The round check of a shopping row: an accent disc with a tick when
/// bought, a quiet ring before.
class _ShoppingCheck extends StatelessWidget {
  const _ShoppingCheck({required this.checked});
  final bool checked;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final motion = motionDuration(context, kMotionEnter);
    return AnimatedContainer(
      duration: motion,
      curve: kMotionCurve,
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        color: checked ? t.selectedFill : Colors.transparent,
        shape: BoxShape.circle,
        border: Border.all(
          color: checked ? t.selectedFill : t.ink3,
          width: 2,
        ),
      ),
      child: checked
          ? Icon(Icons.check_rounded, size: 16, color: t.onSelected)
          : null,
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
