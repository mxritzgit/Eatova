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

  Future<void> _run(String id, Future<SyncDelivery> Function() action) async {
    if (_busy.contains(id)) return;
    setState(() => _busy.add(id));
    try {
      final result = await action();
      if (!mounted) return;
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
      builder: (_) => _PlanEditor(store: store, day: day, plan: plan),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: Text(l.mealPlanTitle)),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                l.mealPlanIntro,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ChoiceChip(
                    label: Text(l.mealPlanWeek),
                    selected: !_shopping,
                    onSelected: (_) => setState(() => _shopping = false),
                  ),
                  ChoiceChip(
                    label: Text(l.mealPlanShopping),
                    selected: _shopping,
                    onSelected: (_) => setState(() => _shopping = true),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  IconButton(
                    tooltip: l.mealPlanPreviousWeek,
                    icon: const Icon(Icons.chevron_left),
                    onPressed:
                        _week.isAfter(
                          DateUtils.dateOnly(
                            clock.now(),
                          ).subtract(const Duration(days: 28)),
                        )
                        ? () => setState(
                            () => _week = DateTime(
                              _week.year,
                              _week.month,
                              _week.day - 7,
                            ),
                          )
                        : null,
                  ),
                  Expanded(
                    child: Text(
                      '${DateFormat.MMMd(l.localeName).format(_week)} – '
                      '${DateFormat.MMMd(l.localeName).format(DateTime(_week.year, _week.month, _week.day + 6))}',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    tooltip: l.mealPlanNextWeek,
                    icon: const Icon(Icons.chevron_right),
                    onPressed:
                        _week.isBefore(
                          clock.now().add(const Duration(days: 350)),
                        )
                        ? () => setState(
                            () => _week = DateTime(
                              _week.year,
                              _week.month,
                              _week.day + 7,
                            ),
                          )
                        : null,
                  ),
                ],
              ),
              if (store.mealPlansLoading) const LinearProgressIndicator(),
              if (store.mealPlansLoadFailed) ...[
                Text(l.mealPlanLoadError),
                TextButton.icon(
                  onPressed: store.mealPlansLoading
                      ? null
                      : store.retryMealPlans,
                  icon: const Icon(Icons.refresh),
                  label: Text(l.mealPlanRetry),
                ),
              ],
              const SizedBox(height: 16),
              if (_shopping)
                ..._shoppingList(context)
              else
                for (var i = 0; i < 7; i++)
                  _day(
                    context,
                    DateTime(_week.year, _week.month, _week.day + i),
                  ),
            ],
          ),
        ),
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
    final entries =
        store.plannedMeals.where((p) => p.day == localDayKey(day)).toList()
          ..sort((a, b) => a.slot.index.compareTo(b.slot.index));
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            DateFormat.yMMMMEEEEd(l.localeName).format(day),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          if (entries.isEmpty)
            Text(
              l.mealPlanEmptyDay,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: context.t.ink2),
            ),
          for (final plan in entries)
            Card(
              color: context.t.surf,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      plan.slot.label(l),
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      plan.recipe.title,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(l.mealPlanPortionCount(plan.servings)),
                    if (plan.isEaten) ...[
                      const SizedBox(height: 8),
                      Text(
                        l.mealPlanEatenOn(
                          DateFormat.yMMMd(
                            l.localeName,
                          ).format(plan.eatenAt!.toLocal()),
                        ),
                      ),
                    ] else ...[
                      const SizedBox(height: 8),
                      if (!_canLog(plan)) Text(l.mealPlanCannotLog),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          TextButton.icon(
                            onPressed: _busy.contains(plan.id)
                                ? null
                                : () => _edit(day, plan: plan),
                            icon: const Icon(Icons.edit_outlined),
                            label: Text(l.mealPlanEdit),
                          ),
                          TextButton.icon(
                            onPressed: _busy.contains(plan.id)
                                ? null
                                : () => _run(
                                    plan.id,
                                    () => store.removePlannedMeal(plan),
                                  ),
                            icon: const Icon(Icons.delete_outline),
                            label: Text(l.commonDelete),
                          ),
                          FilledButton.tonalIcon(
                            key: ValueKey('meal-plan-eat-${plan.id}'),
                            onPressed: _busy.contains(plan.id) || !_canLog(plan)
                                ? null
                                : () => _run(
                                    plan.id,
                                    () => store.eatPlannedMeal(plan.id),
                                  ),
                            icon: _busy.contains(plan.id)
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.restaurant),
                            label: Text(l.mealPlanEatToday),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: () => _edit(day),
              icon: const Icon(Icons.add),
              label: Text(l.mealPlanAdd),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _shoppingList(BuildContext context) {
    final l = context.l10n;
    final items = buildShoppingList(store.plannedMeals, _week);
    return [
      Text(l.mealPlanShoppingIntro),
      const SizedBox(height: 16),
      if (items.isEmpty) Text(l.mealPlanShoppingEmpty),
      for (final quantified in [true, false]) ...[
        if (items.any((i) => (i.grams != null) == quantified)) ...[
          Text(
            quantified ? l.mealPlanWeighed : l.mealPlanUnquantified,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          if (!quantified) Text(l.mealPlanUnquantifiedHint),
          for (final item in items.where(
            (i) => (i.grams != null) == quantified,
          ))
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: store.shoppingChecks[item.id] ?? false,
              onChanged: _busy.contains(item.id)
                  ? null
                  : (v) => _run(
                      item.id,
                      () => store.setShoppingChecked(
                        ShoppingCheck(id: item.id, checked: v ?? false),
                      ),
                    ),
              title: Text(item.grams != null ? item.name : item.recipeTitle!),
              subtitle: Text(
                item.grams != null
                    ? '${NumberFormat('0.##', l.localeName).format(item.grams)} g'
                    : '${l.mealPlanPortionCount(item.servings!)}\n'
                          '${item.name.isEmpty ? l.mealPlanNoIngredients : item.name}',
              ),
            ),
          const SizedBox(height: 24),
        ],
      ],
    ];
  }
}

class _PlanEditor extends StatefulWidget {
  const _PlanEditor({required this.store, required this.day, this.plan});
  final HomeStore store;
  final DateTime day;
  final PlannedMeal? plan;
  @override
  State<_PlanEditor> createState() => _PlanEditorState();
}

class _PlanEditorState extends State<_PlanEditor> {
  late final String _draftId = widget.plan?.id ?? uuidV4();
  late final _servings = TextEditingController(
    text: '${widget.plan?.servings ?? 1}',
  );
  late MealSlot _slot = widget.plan?.slot ?? MealSlot.dinner;
  late DateTime _day = widget.day;
  FitnessRecipe? _recipe;
  bool _saving = false;
  String? _error;
  String _query = '';
  @override
  void initState() {
    super.initState();
    _recipe = widget.plan?.recipe;
  }

  @override
  void dispose() {
    _servings.dispose();
    super.dispose();
  }

  double? get _amount => double.tryParse(_servings.text.replaceAll(',', '.'));

  Future<void> _save() async {
    final amount = _amount;
    if (_saving ||
        _recipe == null ||
        amount == null ||
        !amount.isFinite ||
        amount < .1 ||
        amount > 100) {
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final plan =
          widget.plan?.copyWith(day: _day, slot: _slot, servings: amount) ??
          PlannedMeal.create(
            id: _draftId,
            recipe: _recipe!,
            day: _day,
            slot: _slot,
            servings: amount,
          );
      final result = await widget.store.savePlannedMeal(plan);
      if (!mounted) return;
      showAppSnack(
        context,
        result == SyncDelivery.delivered
            ? context.l10n.mealPlanSaved
            : context.l10n.mealPlanSavedOffline,
        icon: Icons.check_circle_outline,
      );
      Navigator.pop(context);
    } catch (_) {
      if (mounted) setState(() => _error = context.l10n.mealPlanSaveError);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final recipes =
        [
              ...widget.store.visibleUserRecipes,
              ...recipeCatalogForLocale(l.localeName),
            ]
            .where(
              (r) => foldRecipeSearchText(
                r.title,
              ).contains(foldRecipeSearchText(_query)),
            )
            .toList();
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          16,
          16,
          16 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.plan == null ? l.mealPlanAdd : l.mealPlanEdit,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              if (_recipe == null) ...[
                SheetField(
                  label: l.mealPlanChooseRecipe,
                  hint: l.mealPlanSearchRecipe,
                  onChanged: (value) => setState(() => _query = value),
                ),
                if (recipes.isEmpty) Text(l.mealPlanNoRecipes),
                for (final recipe in recipes.take(50))
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(recipe.title),
                    subtitle: Text(recipe.displayPortion(l)),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => setState(() => _recipe = recipe),
                  ),
              ] else ...[
                Text(
                  _recipe!.title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                if (widget.plan == null)
                  TextButton(
                    onPressed: _saving
                        ? null
                        : () => setState(() => _recipe = null),
                    child: Text(l.mealPlanChooseRecipe),
                  ),
                TextButton.icon(
                  icon: const Icon(Icons.calendar_today_outlined),
                  label: Text(DateFormat.yMMMMEEEEd(l.localeName).format(_day)),
                  onPressed: _saving
                      ? null
                      : () async {
                          final today = DateUtils.dateOnly(clock.now());
                          final selected = await showDatePicker(
                            context: context,
                            initialDate: _day,
                            firstDate: today.subtract(const Duration(days: 35)),
                            lastDate: today.add(const Duration(days: 365)),
                          );
                          if (selected != null && mounted) {
                            setState(() => _day = selected);
                          }
                        },
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final slot in MealSlot.values)
                      ChoiceChip(
                        label: Text(slot.label(l)),
                        selected: _slot == slot,
                        onSelected: _saving
                            ? null
                            : (_) => setState(() => _slot = slot),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                SheetField(
                  fieldKey: const ValueKey('meal-plan-servings'),
                  controller: _servings,
                  label: l.mealPlanServings,
                  hint: '1.5',
                  enabled: !_saving,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  onChanged: (_) => setState(() {}),
                  errorText:
                      (_amount == null ||
                          !_amount!.isFinite ||
                          _amount! < .1 ||
                          _amount! > 100)
                      ? l.mealPlanServingsError
                      : null,
                ),
                Text(l.mealPlanSnapshotHint),
                if (_error != null)
                  Text(_error!, style: TextStyle(color: context.t.danger)),
                const SizedBox(height: 16),
                FilledButton(
                  key: const ValueKey('meal-plan-save'),
                  onPressed:
                      _saving ||
                          _amount == null ||
                          !_amount!.isFinite ||
                          _amount! < .1 ||
                          _amount! > 100
                      ? null
                      : _save,
                  child: _saving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(l.commonSave),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
