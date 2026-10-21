part of 'meal_plan_screen.dart';

/// Names the planner's own refusals; anything else is a storage failure.
String _mealPlanErrorText(Object error, AppLocalizations l) => switch (error) {
  MealPlanLimitReached() => l.mealPlanLimitReached(kMaxOpenPlannedMeals),
  MealPlanAlreadyEaten() => l.mealPlanAlreadyEaten,
  _ => l.mealPlanSaveError,
};

class _PlanEditor extends StatefulWidget {
  const _PlanEditor({
    required this.store,
    required this.day,
    this.plan,
    this.recipe,
  });
  final HomeStore store;
  final DateTime day;
  final PlannedMeal? plan;

  /// A new plan's recipe chosen beforehand (a recipe detail's "Zum
  /// Speiseplan"); the editor opens on its details, still changeable.
  final FitnessRecipe? recipe;
  @override
  State<_PlanEditor> createState() => _PlanEditorState();
}

class _PlanEditorState extends State<_PlanEditor> {
  late final String _draftId = widget.plan?.id ?? uuidV4();
  // Filled on the first dependency pass with the locale's separator.
  final _servings = TextEditingController();
  bool _servingsFilled = false;
  // A breakfast dish or snack chosen beforehand starts on its slot.
  late MealSlot _slot =
      widget.plan?.slot ??
      [MealSlot.breakfast, MealSlot.snack].firstWhere(
        (slot) =>
            widget.recipe != null && recipeSuitsSlot(widget.recipe!, slot),
        orElse: () => MealSlot.dinner,
      );
  late DateTime _day = widget.day;
  FitnessRecipe? _recipe;
  bool _saving = false;
  String? _error;
  String _query = '';
  final _scroll = ScrollController();
  @override
  void initState() {
    super.initState();
    _recipe = widget.plan?.recipe ?? widget.recipe;
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
    } catch (error) {
      if (mounted) {
        setState(() => _error = _mealPlanErrorText(error, context.l10n));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// A save waits behind other plan writes and for its delivery window; a
  /// close in that time hid its outcome, refusals and errors included.
  @override
  Widget build(BuildContext context) => CommitDismissGuard(
    pending: _saving,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Outside the scroll area, so a pull on it moves the sheet.
        const SheetHandle(padding: EdgeInsets.only(top: 10, bottom: 12)),
        Flexible(child: _buildForm(context)),
      ],
    ),
  );

  Widget _buildForm(BuildContext context) {
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
    // A picker, not a suggestion: avoided foods stay listed with a hint.
    final avoided = widget.store.profile.foodAvoidances;
    // showEatovaSheet supplies the keyboard inset and the height cap; the
    // form only keeps clear of the home indicator.
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
                      style: sheetTitleStyle(t),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SheetCloseButton(
                  buttonKey: const ValueKey('meal-plan-editor-close'),
                  tooltip: l.commonClose,
                  onTap: _saving
                      ? null
                      : () => Navigator.of(context).maybePop(),
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
                                if (recipe
                                    .avoidedFoods(avoided)
                                    .isNotEmpty) ...[
                                  const SizedBox(height: 6),
                                  RecipeAvoidHint(
                                    recipe: recipe,
                                    avoided: avoided,
                                  ),
                                ],
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
              _EditorLabel(l.mealPlanServings),
              _ServingsStepper(
                controller: _servings,
                label: l.mealPlanServings,
                enabled: !_saving,
                onChanged: () => setState(() {}),
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
                SignalNote(
                  _error!,
                  tone: t.danger,
                  icon: Icons.error_outline_rounded,
                  boxed: true,
                ),
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

/// Servings as the app's stepper: round minus and plus in a pill capsule,
/// half a serving per step, with the typed value in the middle. The field
/// stays free text, so 1.25 servings or a pasted value still work; the
/// editor validates it as before.
class _ServingsStepper extends StatefulWidget {
  const _ServingsStepper({
    required this.controller,
    required this.label,
    required this.enabled,
    required this.onChanged,
    required this.errorText,
  });

  final TextEditingController controller;
  final String label;
  final bool enabled;
  final VoidCallback onChanged;
  final String? errorText;

  @override
  State<_ServingsStepper> createState() => _ServingsStepperState();
}

class _ServingsStepperState extends State<_ServingsStepper> {
  static const double _step = 0.5;
  static const double _max = 100;

  final _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  /// The next half serving above (+1) or below (-1) the current value, or
  /// null when there is none (an invalid entry, or the 0.5 / 100 ends).
  double? _neighbour(int direction) {
    final value = parseRecipeServings(widget.controller.text);
    if (value == null) return null;
    final steps = value / _step;
    final next = direction > 0
        ? (steps.floor() + 1) * _step
        : (steps.ceil() - 1) * _step;
    return next < _step || next > _max ? null : next;
  }

  void _stepBy(int direction) {
    final next = _neighbour(direction);
    if (next == null) return;
    widget.controller.text = formatDecimalInput(
      next,
      context.l10n,
      maxFractionDigits: 3,
    );
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l = context.l10n;
    final error = widget.errorText;
    Widget button(int direction) => _ServingsStepButton(
      actionKey: ValueKey(
        'meal-plan-servings-${direction < 0 ? 'dec' : 'inc'}',
      ),
      icon: direction < 0 ? Icons.remove_rounded : Icons.add_rounded,
      semanticLabel: direction < 0
          ? l.onboardingStepDownSemanticLabel
          : l.onboardingStepUpSemanticLabel,
      onTap: widget.enabled && _neighbour(direction) != null
          ? () => _stepBy(direction)
          : null,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FieldCapsule(
          focusNode: _focus,
          error: error != null,
          enabled: widget.enabled,
          shape: SheetFieldShape.pill,
          padding: const EdgeInsets.all(4),
          child: Row(
            children: [
              button(-1),
              Expanded(
                child: Semantics(
                  label: widget.label,
                  child: TextField(
                    key: const ValueKey('meal-plan-servings'),
                    controller: widget.controller,
                    focusNode: _focus,
                    enabled: widget.enabled,
                    textAlign: TextAlign.center,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    onChanged: (_) => widget.onChanged(),
                    cursorColor: t.accent,
                    cursorOpacityAnimates: false,
                    style: AppType.ui(
                      18,
                      weight: FontWeight.w700,
                      color: t.ink,
                    ).copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      disabledBorder: InputBorder.none,
                      errorBorder: InputBorder.none,
                      focusedErrorBorder: InputBorder.none,
                      filled: false,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 12),
                      hintText: formatDecimal(1.5, l),
                      hintStyle: AppType.ui(18, color: t.ink2),
                    ),
                  ),
                ),
              ),
              button(1),
            ],
          ),
        ),
        if (error != null) ...[
          const SizedBox(height: 6),
          Text(
            error,
            style: AppType.ui(11.5, weight: FontWeight.w500, color: t.danger),
          ),
        ],
      ],
    );
  }
}

/// Round 44 px stepper button in the accent tint (the training brief's).
class _ServingsStepButton extends StatelessWidget {
  const _ServingsStepButton({
    required this.actionKey,
    required this.icon,
    required this.semanticLabel,
    required this.onTap,
  });

  final Key actionKey;
  final IconData icon;
  final String semanticLabel;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final enabled = onTap != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: semanticLabel,
      child: PressScale(
        enabled: enabled,
        child: Opacity(
          opacity: enabled ? 1 : 0.4,
          child: Material(
            color: t.accentTint,
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: actionKey,
              onTap: onTap,
              customBorder: const CircleBorder(),
              child: SizedBox.square(
                dimension: 44,
                child: Icon(icon, size: 22, color: t.accentText),
              ),
            ),
          ),
        ),
      ),
    );
  }
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
