part of 'meal_plan_screen.dart';

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
  final _scroll = ScrollController();
  @override
  void initState() {
    super.initState();
    _recipe = widget.plan?.recipe;
  }

  @override
  void dispose() {
    _scroll.dispose();
    _servings.dispose();
    super.dispose();
  }

  double? get _amount => double.tryParse(_servings.text.replaceAll(',', '.'));

  void _chooseRecipe(FitnessRecipe? recipe) {
    setState(() {
      _recipe = recipe;
      if (recipe == null) _query = '';
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

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
    final t = context.t;
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
          20,
          12,
          20,
          20 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SingleChildScrollView(
          key: const ValueKey('meal-plan-editor-scroll'),
          controller: _scroll,
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Center(child: SheetHandle()),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: HeadingSemantics(
                      level: 1,
                      child: Text(
                        widget.plan == null ? l.mealPlanAdd : l.mealPlanEdit,
                        style: AppType.display(25, color: t.ink, height: 1.15),
                      ),
                    ),
                  ),
                  SquareIconButton(
                    icon: Icons.close_rounded,
                    semanticLabel: MaterialLocalizations.of(
                      context,
                    ).closeButtonTooltip,
                    onTap: _saving ? null : () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                _recipe == null
                    ? l.mealPlanEditorIntro
                    : l.mealPlanEditorDetails,
                style: AppType.ui(14, color: t.ink2, height: 1.4),
              ),
              const SizedBox(height: 22),
              if (_recipe == null) ...[
                SheetField(
                  label: l.mealPlanChooseRecipe,
                  hint: l.mealPlanSearchRecipe,
                  onChanged: (value) => setState(() => _query = value),
                ),
                const SizedBox(height: 16),
                if (recipes.isEmpty)
                  Text(
                    l.mealPlanNoRecipes,
                    style: AppType.ui(14, color: t.ink2),
                  ),
                for (final recipe in recipes.take(50))
                  Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () => _chooseRecipe(recipe),
                      borderRadius: BorderRadius.circular(rControl),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Row(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(rControl),
                              child: SizedBox(
                                width: 64,
                                height: 70,
                                child: RecipePhoto(recipe: recipe),
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    recipe.title,
                                    style: AppType.display(
                                      16,
                                      color: t.ink,
                                      height: 1.25,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    recipe.displayPortion(l),
                                    style: AppType.ui(
                                      13,
                                      color: t.ink2,
                                      height: 1.4,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Icon(
                              Icons.chevron_right_rounded,
                              color: t.ink2,
                              size: 20,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ] else ...[
                _PlannerSurface(
                  color: t.brandSurface,
                  padding: const EdgeInsets.all(14),
                  child: RecipePhotoRow(
                    recipe: _recipe!,
                    photoWidth: 86,
                    photoHeight: 98,
                    child: Text(
                      _recipe!.title,
                      style: AppType.display(
                        20,
                        color: t.onBrandSurface,
                        height: 1.2,
                      ),
                    ),
                  ),
                ),
                if (widget.plan == null)
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton(
                      onPressed: _saving ? null : () => _chooseRecipe(null),
                      child: Text(l.mealPlanEditorChange),
                    ),
                  ),
                const SizedBox(height: 16),
                Material(
                  color: t.surf,
                  borderRadius: BorderRadius.circular(rControl),
                  child: ListTile(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(rControl),
                    ),
                    leading: Icon(
                      Icons.calendar_month_outlined,
                      color: t.accent,
                    ),
                    title: Text(
                      DateFormat.yMMMMEEEEd(l.localeName).format(_day),
                      style: AppType.ui(
                        15,
                        color: t.ink,
                        weight: FontWeight.w600,
                      ),
                    ),
                    trailing: Icon(Icons.expand_more_rounded, color: t.ink2),
                    onTap: _saving
                        ? null
                        : () async {
                            final today = DateUtils.dateOnly(clock.now());
                            final first = today.subtract(
                              const Duration(days: 35),
                            );
                            final last = today.add(const Duration(days: 365));
                            final selected = await showDatePicker(
                              context: context,
                              initialDate: _day.isBefore(first)
                                  ? first
                                  : _day.isAfter(last)
                                  ? last
                                  : _day,
                              firstDate: first,
                              lastDate: last,
                            );
                            if (selected != null && mounted) {
                              setState(() => _day = selected);
                            }
                          },
                  ),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final slot in MealSlot.values)
                      ChoiceChip(
                        label: Text(slot.label(l)),
                        selected: _slot == slot,
                        selectedColor: t.brandSurface,
                        backgroundColor: t.surf,
                        side: BorderSide.none,
                        checkmarkColor: t.accent,
                        labelStyle: AppType.ui(
                          14,
                          color: t.ink,
                          weight: _slot == slot
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 10,
                        ),
                        onSelected: _saving
                            ? null
                            : (_) => setState(() => _slot = slot),
                      ),
                  ],
                ),
                const SizedBox(height: 22),
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
                      _amount == null ||
                          !_amount!.isFinite ||
                          _amount! < .1 ||
                          _amount! > 100
                      ? l.mealPlanServingsError
                      : null,
                ),
                const SizedBox(height: 10),
                Text(
                  l.mealPlanSnapshotHint,
                  style: AppType.ui(13, color: t.ink2, height: 1.45),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: AppType.ui(14, color: t.danger)),
                ],
                const SizedBox(height: 22),
                FilledButton(
                  key: const ValueKey('meal-plan-save'),
                  style: FilledButton.styleFrom(
                    backgroundColor: t.ink,
                    foregroundColor: t.bg,
                    minimumSize: const Size(48, 54),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 16,
                    ),
                  ),
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
                      : Text(
                          l.commonSave,
                          style: AppType.ui(15, weight: FontWeight.w700),
                        ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
