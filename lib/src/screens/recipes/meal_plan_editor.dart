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
  // Filled on the first dependency pass with the locale's separator.
  final _servings = TextEditingController();
  bool _servingsFilled = false;
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
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_servingsFilled) {
      _servingsFilled = true;
      _servings.text = formatDecimalInput(
        widget.plan?.servings ?? 1,
        context.l10n,
        maxFractionDigits: 3,
      );
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    _servings.dispose();
    super.dispose();
  }

  /// Valid servings (0.1..100) or null; the shared recipe rule.
  double? get _amount => parseRecipeServings(_servings.text);

  void _chooseRecipe(FitnessRecipe? recipe) {
    setState(() {
      _recipe = recipe;
      if (recipe == null) _query = '';
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  /// The app's calendar sheet over the planning window: five weeks back,
  /// a year ahead.
  Future<void> _chooseDay() async {
    final today = DateUtils.dateOnly(clock.now());
    final first = _firstPlanDay(today);
    final last = _lastPlanDay(today);
    final selected = await showFoodDatePicker(
      context,
      initialDate: _day.isBefore(first)
          ? first
          : _day.isAfter(last)
          ? last
          : _day,
      firstDate: first,
      today: today,
      contextLabel: context.l10n.mealPlanTitle,
      lastDate: last,
      confirmLabel: context.l10n.mealPlanDateConfirm,
    );
    if (selected != null && mounted) setState(() => _day = selected);
  }

  Future<void> _save() async {
    final amount = _amount;
    if (_saving || _recipe == null || amount == null) return;
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
    // showEatovaSheet supplies the handle, the keyboard inset and the height
    // cap; the editor only keeps clear of the home indicator.
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        key: const ValueKey('meal-plan-editor-scroll'),
        controller: _scroll,
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: HeadingSemantics(
                    level: 1,
                    child: Text(
                      widget.plan == null ? l.mealPlanAdd : l.mealPlanEdit,
                      style: AppType.display(24, color: t.ink, height: 1.15),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  key: const ValueKey('meal-plan-editor-close'),
                  tooltip: l.commonClose,
                  onPressed: _saving
                      ? null
                      : () => Navigator.of(context).maybePop(),
                  style: IconButton.styleFrom(backgroundColor: t.surf2),
                  icon: Icon(Icons.close_rounded, color: t.ink2, size: 21),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              _recipe == null ? l.mealPlanEditorIntro : l.mealPlanEditorDetails,
              style: AppType.ui(14, color: t.ink2, height: 1.4),
            ),
            const SizedBox(height: 20),
            if (_recipe == null) ...[
              SheetField(
                label: l.mealPlanChooseRecipe,
                hint: l.mealPlanSearchRecipe,
                onChanged: (value) => setState(() => _query = value),
              ),
              const SizedBox(height: 8),
              if (recipes.isEmpty)
                Text(l.mealPlanNoRecipes, style: AppType.ui(14, color: t.ink2)),
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
                                  recipe.displayTitle(context.l10n),
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
                    _recipe!.displayTitle(context.l10n),
                    style: AppType.display(
                      20,
                      color: t.onBrandSurface,
                      height: 1.2,
                    ),
                  ),
                ),
              ),
              if (widget.plan == null) ...[
                const SizedBox(height: 12),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: SoftPillButton(
                    key: const ValueKey('meal-plan-editor-change'),
                    label: l.mealPlanEditorChange,
                    icon: Icons.swap_horiz_rounded,
                    tone: SoftPillTone.neutral,
                    onTap: _saving ? null : () => _chooseRecipe(null),
                  ),
                ),
              ],
              const SizedBox(height: 24),
              _EditorLabel(l.mealPlanDayLabel),
              _DayField(
                label: l.mealPlanDayLabel,
                text: DateFormat.yMMMMEEEEd(l.localeName).format(_day),
                onTap: _saving ? null : _chooseDay,
              ),
              const SizedBox(height: 20),
              _EditorLabel(l.mealPlanSlotLabel),
              IgnorePointer(
                ignoring: _saving,
                child: MealSlotPicker(
                  keyPrefix: 'meal-plan-slot-',
                  selected: _slot,
                  onSelected: (slot) => setState(() => _slot = slot),
                ),
              ),
              const SizedBox(height: 20),
              SheetField(
                fieldKey: const ValueKey('meal-plan-servings'),
                controller: _servings,
                label: l.mealPlanServings,
                hint: formatDecimal(1.5, l),
                enabled: !_saving,
                bottomGap: 0,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                onChanged: (_) => setState(() {}),
                errorText: _amount == null
                    ? numberInputHint(NumberInput.parse(_servings.text), l) ??
                          l.mealPlanServingsError
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
              PrimaryActionButton(
                key: const ValueKey('meal-plan-save'),
                label: _saving ? l.mealPlanSaving : l.commonSave,
                icon: Icons.check_rounded,
                onTap: _saving || _amount == null ? null : _save,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The eyebrow above an editor field, in [SheetField]'s own label style.
/// Silent for screen readers: the field below speaks its name itself.
class _EditorLabel extends StatelessWidget {
  const _EditorLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Text(
        text.toUpperCase(),
        style: AppType.eyebrow(context.t.ink2, size: 9.5),
      ),
    ),
  );
}

/// The planned day as a borderless field capsule; a tap opens the calendar.
class _DayField extends StatefulWidget {
  const _DayField({
    required this.label,
    required this.text,
    required this.onTap,
  });
  final String label;
  final String text;
  final VoidCallback? onTap;

  @override
  State<_DayField> createState() => _DayFieldState();
}

class _DayFieldState extends State<_DayField> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final radius = BorderRadius.circular(rControl);
    return Semantics(
      container: true,
      button: true,
      enabled: widget.onTap != null,
      label: '${widget.label}, ${widget.text}',
      onTap: widget.onTap,
      excludeSemantics: true,
      child: FieldCapsule(
        focused: _focused,
        enabled: widget.onTap != null,
        padding: EdgeInsets.zero,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            key: const ValueKey('meal-plan-day'),
            onTap: widget.onTap,
            onFocusChange: (focused) => setState(() => _focused = focused),
            borderRadius: radius,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 52),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 15,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.calendar_month_rounded,
                      size: 20,
                      color: t.accent,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        widget.text,
                        style: AppType.ui(
                          15,
                          weight: FontWeight.w600,
                          color: t.ink,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(Icons.chevron_right_rounded, size: 20, color: t.ink2),
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
