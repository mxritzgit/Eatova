part of 'recipes_screen.dart';

// ---------------------------------------------------------------------------
// Recipe detail view (own route push). [RecipeDetailScreen] is public.
// ---------------------------------------------------------------------------

/// [recipe] as plain text to share or copy: title, kcal and protein,
/// portion, then ingredients and preparation as the detail shows them, for
/// [servings] like a planned meal's detail. A section an own recipe leaves
/// empty is omitted, not filled with the detail's placeholder.
String recipeAsPlainText(
  FitnessRecipe recipe,
  AppLocalizations l10n, {
  double servings = 1,
}) {
  final nutrition = recipe.displayNutrition;
  final kcal = nutrition.caloriesKcal, protein = nutrition.proteinG;
  final freeIngredients = recipe.ingredients.trim();
  final planned = servings == 1 ||
          (freeIngredients.isEmpty && !recipe.hasStructuredIngredients)
      ? null
      : _plannedIngredients(recipe, servings, l10n);
  final ingredients = planned != null
      ? '${planned.hint}\n${planned.text.trim()}'
      : recipe.hasStructuredIngredients
      ? [
          for (final i in recipe.structuredIngredients)
            '${_nutritionNumber(i.grams, l10n)} g ${i.displayName(l10n)}',
          if (freeIngredients.isNotEmpty) freeIngredients,
        ].join('\n')
      : freeIngredients.isEmpty
      ? ''
      : recipe.displayIngredients(l10n).trim();
  final preparation = recipe.preparation.trim().isEmpty
      ? ''
      : recipe.displayPreparation(l10n).trim();
  final portion = recipe.displayPortion(l10n).trim();
  return [
    recipe.displayTitle(l10n),
    if (kcal != null && protein != null)
      l10n.recipesKcalProteinSummary(kcal.round(), protein.round()),
    if (portion.isNotEmpty) '${l10n.recipesSectionPortion}: $portion',
    if (ingredients.isNotEmpty) ...[
      '',
      l10n.recipesSectionIngredients,
      ingredients,
    ],
    if (preparation.isNotEmpty) ...[
      '',
      l10n.recipesSectionPreparation,
      preparation,
    ],
  ].join('\n');
}

/// The catalogs' ingredient texts, which are written for one serving. A meal
/// plan snapshot of a catalog recipe is a user row with the same slug and
/// text; the shopping list reads it the same way.
final Set<(String, String)> _catalogIngredientTexts = {
  for (final recipe in [...recipeCatalogDe, ...recipeCatalogEn])
    (recipe.slug, recipe.ingredients),
};

bool _isCatalogText(FitnessRecipe recipe) =>
    _catalogIngredientTexts.contains((recipe.slug, recipe.ingredients));

/// The ingredient lines and their hint for [servings] portions of [recipe],
/// as a planned meal opens them. Amounts are converted where that is safe:
/// structured ingredients, an import with a confirmed basis, or a catalog
/// text whose every line converts. Otherwise they stay as written and the
/// hint says so.
({String text, String hint}) _plannedIngredients(
  FitnessRecipe recipe,
  double servings,
  AppLocalizations l10n,
) {
  final count = formatDecimal(servings, l10n, maxFractionDigits: 3);
  if (recipe.hasStructuredIngredients) {
    final factor = servings / recipe.batchServings;
    return (
      text: [
        for (final i in recipe.structuredIngredients)
          '${_nutritionNumber(i.grams * factor, l10n)} g ${i.displayName(l10n)}',
        if (recipe.ingredients.isNotEmpty) recipe.ingredients,
      ].join('\n'),
      hint: l10n.recipeIngredientsForServings(count),
    );
  }
  if (recipe.hasImportedIngredientContext) {
    return (
      text: recipe.displayIngredients(l10n, servings: servings),
      hint: recipe.ingredientQuantityHint(l10n, servings: servings),
    );
  }
  if (_isCatalogText(recipe)) {
    final projection = projectRecipeIngredients(
      recipe.ingredients,
      basis: RecipeIngredientsBasis.perServing,
      batchServings: null,
      servings: servings,
      decimalSeparator: l10n.localeName == 'de' ? ',' : '.',
    );
    if (projection.isScaled) {
      return (
        text: projection.text,
        hint: l10n.recipeIngredientsForServings(count),
      );
    }
  }
  return (
    text: recipe.displayIngredients(l10n),
    hint: l10n.recipeIngredientsPlannedPerServing(count),
  );
}

class RecipeDetailScreen extends StatefulWidget {
  const RecipeDetailScreen({
    super.key,
    required this.recipe,
    required this.onAddMeal,
    this.onDelete,
    this.onEdit,
    this.onOpenHistory,
    this.photoInput,
    this.isSessionCurrent,
    this.productService,
    this.showAddAction = true,
    this.avoidances = const <FoodAvoidance>{},
    this.onPlan,
    this.servings = 1,
  });

  /// The portions the ingredients are shown for: a planned meal's servings
  /// ([_plannedIngredients]). Nutrition stays per portion.
  final double servings;

  /// "Zum Speiseplan": opens the plan editor with this recipe chosen
  /// (`MealPlanScreen.planRecipe`). Null hides the action.
  final Future<void> Function(BuildContext context, FitnessRecipe recipe)?
  onPlan;

  final FitnessRecipe recipe;

  /// The user's avoided foods: a recipe containing some says so under its
  /// hero ([RecipeAvoidHint]).
  final Set<FoodAvoidance> avoidances;
  final FutureOr<void> Function(MealAnalysisResult result, MealSlot slot)
  onAddMeal;
  final Future<bool> Function(String slug)? onOpenHistory;

  /// Optional delete hook, set only for own recipes.
  final ValueChanged<String>? onDelete;
  final Future<RecipeSaveResult> Function(FitnessRecipe)? onEdit;
  final MealPhotoInput? photoInput;
  final bool Function()? isSessionCurrent;
  final ProductLookupService? productService;

  /// False opens the recipe read-only for logging: no "add to tracker" card.
  /// A planned meal from the Recipes hero is logged through the meal plan
  /// (planned servings, plan marked eaten), never through this generic path.
  final bool showAddAction;

  @override
  State<RecipeDetailScreen> createState() => _RecipeDetailScreenState();
}

class _RecipeDetailScreenState extends State<RecipeDetailScreen>
    with WidgetsBindingObserver {
  late FitnessRecipe recipe = widget.recipe;
  ValueChanged<String>? get onDelete => widget.onDelete;
  bool _adding = false;
  bool _editing = false;
  RecipeSaveHandle? _saveHandle;
  bool get _canUseRecipe => _saveHandle?.value.canEdit ?? true;
  String? get _historySlug => _saveHandle == null
      ? recipe.slug
      : _saveHandle!.value.recipe?.slug ?? _saveHandle!.value.targetSlug;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_saveHandle?.refresh());
  }

  void _refreshSavedRecipe() {
    if (!mounted || widget.isSessionCurrent?.call() == false) return;
    setState(() {
      final current = _saveHandle?.value.recipe;
      if (current != null) recipe = current;
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _saveHandle?.removeListener(_refreshSavedRecipe);
    _saveHandle?.dispose();
    super.dispose();
  }

  Future<bool> _edit() async {
    if (_editing ||
        widget.onEdit == null ||
        !_canUseRecipe ||
        widget.isSessionCurrent?.call() == false) {
      return false;
    }
    _editing = true;
    final editingRecipe = recipe;
    RecipeSaveResult? saved;
    var sheetClosed = false;
    final result = await showModalBottomSheet<RezeptEntwurfErgebnis>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: context.t.scrim,
      builder: (_) => _CreateRecipeSheet(
        initialRecipe: editingRecipe,
        photoInput: widget.photoInput ?? DeviceMealPhotoInput(),
        productService: widget.productService,
        onSave: (draft) async {
          final receipt = await widget.onEdit!(draft);
          if (sheetClosed ||
              !mounted ||
              widget.isSessionCurrent?.call() == false) {
            receipt.handle.dispose();
            throw StateError('Recipe edit session ended');
          }
          saved = receipt;
          return receipt.delivery;
        },
        isSessionCurrent: widget.isSessionCurrent,
      ),
    );
    sheetClosed = true;
    _editing = false;
    if (!mounted ||
        result == null ||
        widget.isSessionCurrent?.call() == false) {
      saved?.handle.dispose();
      return false;
    }
    _saveHandle?.removeListener(_refreshSavedRecipe);
    _saveHandle?.dispose();
    _saveHandle = saved?.handle;
    _saveHandle?.addListener(_refreshSavedRecipe);
    setState(() => recipe = _saveHandle?.value.recipe ?? result.rezept);
    showAppSnack(
      context,
      deliveryHint(
        _saveHandle?.value.conflictSaved == true
            ? context.l10n.recipeEditConflictSaved
            : result.fotoFehlgeschlagen
            ? context.l10n.recipeEditPhotoRetained
            : context.l10n.recipeEditSaved,
        result.delivery ?? SyncDelivery.delivered,
        context.l10n,
      ),
      icon: Icons.check_circle_rounded,
    );
    return true;
  }

  /// The recipe as plain text ([recipeAsPlainText]) through the share sheet;
  /// where that cannot open, on the clipboard, confirmed by a toast.
  Future<void> _share(Rect? origin) async {
    final l10n = context.l10n;
    final outcome = await shareText(
      recipeAsPlainText(recipe, l10n, servings: widget.servings),
      subject: recipe.displayTitle(l10n),
      origin: origin,
    );
    if (!mounted || outcome != TextShareOutcome.copied) return;
    showAppSnack(context, l10n.recipesCopied, icon: Icons.check_circle_rounded);
  }

  Future<bool> _confirmNutritionBasis() async {
    if (_editing || widget.onEdit == null || !_canUseRecipe) return false;
    _editing = true;
    final original = recipe;
    final saved = await showEatovaSheet<RecipeSaveResult>(
      context,
      _RecipeNutritionBasisSheet(
        recipe: original,
        isSessionCurrent: () =>
            mounted && widget.isSessionCurrent?.call() != false,
        onSave: (draft) {
          if (!mounted ||
              widget.isSessionCurrent?.call() == false ||
              !identical(recipe, original) ||
              !_canUseRecipe) {
            throw StateError('Recipe confirmation is no longer current');
          }
          return widget.onEdit!(draft);
        },
      ),
      isDismissible: false,
      enableDrag: false,
    );
    _editing = false;
    if (!mounted || widget.isSessionCurrent?.call() == false) {
      saved?.handle.dispose();
      return false;
    }
    if (saved == null) return false;
    _saveHandle?.removeListener(_refreshSavedRecipe);
    _saveHandle?.dispose();
    _saveHandle = saved.handle;
    _saveHandle!.addListener(_refreshSavedRecipe);
    setState(() {
      final current = _saveHandle!.value.recipe;
      if (current != null) recipe = current;
    });
    return _canUseRecipe && recipe.canLogServings(1);
  }

  Future<void> _showMealPicker(BuildContext context) async {
    if (_adding ||
        _editing ||
        !_canUseRecipe ||
        widget.isSessionCurrent?.call() == false) {
      return;
    }
    if (!recipe.canLogServings(1) && recipe.userCreated && widget.onEdit != null) {
      final prepared =
          recipe.hasUnclearNutritionBasis && !recipe.hasMissingNutrition
          ? await _confirmNutritionBasis()
          : await _edit();
      if (!prepared ||
          !context.mounted ||
          !_canUseRecipe ||
          widget.isSessionCurrent?.call() == false ||
          !recipe.canLogServings(1)) {
        return;
      }
    }
    final selectedRecipe = recipe;
    final selection = await showEatovaSheet<({MealSlot slot, double servings})>(
      context,
      _MealSlotPickerSheet(
        recipe: selectedRecipe,
        onSave: (slot, servings) =>
            _add(context, selectedRecipe, slot, servings),
      ),
      enableDrag: false,
    );
    if (!context.mounted || selection == null) return;
  }

  Future<bool> _add(
    BuildContext context,
    FitnessRecipe selectedRecipe,
    MealSlot slot,
    double servings,
  ) async {
    if (_adding || !_canUseRecipe || widget.isSessionCurrent?.call() == false) {
      return false;
    }
    final l10n = context.l10n;
    final result = selectedRecipe.toMealResultForServings(servings, l10n);
    setState(() => _adding = true);
    final saved = await tryPersistChange(
      context,
      () => widget.onAddMeal(result, slot),
    );
    if (!mounted) return false;
    setState(() => _adding = false);
    if (!saved ||
        !context.mounted ||
        widget.isSessionCurrent?.call() == false) {
      return false;
    }
    showAppSnack(
      context,
      l10n.commonKcalAddedToSlot(result.caloriesKcal, slot.label(l10n)),
      icon: Icons.check_circle_rounded,
    );
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final pinAction =
        MediaQuery.sizeOf(context).height >= 700 &&
        MediaQuery.textScalerOf(context).scale(14) <= 19;
    final planned = widget.servings == 1
        ? null
        : _plannedIngredients(recipe, widget.servings, l10n);
    return Scaffold(
      backgroundColor: t.bg,
      bottomNavigationBar: pinAction && widget.showAddAction
          ? SafeArea(
              top: false,
              child: ReadableWidth(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                  child: _AddToMealCard(
                    recipe: recipe,
                    onTap: _canUseRecipe ? () => _showMealPicker(context) : null,
                  ),
                ),
              ),
            )
          : null,
      body: SafeArea(
        bottom: false,
        child: ReadableWidth(
          child: SingleChildScrollView(
            key: const ValueKey('recipe-detail-scroll'),
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                PageHeader(
                  // A planned catalog recipe is a snapshot row, not an own one.
                  title: recipe.userCreated && !_isCatalogText(recipe)
                      ? l10n.recipesOwnTitle
                      : l10n.recipesBrandTitle,
                  backKey: const ValueKey('recipe-detail-back'),
                  onBack: () => Navigator.of(context).pop(),
                  trailing: onDelete == null
                      // Counterweight to the back button, so the title centres.
                      ? const SizedBox(width: 34)
                      : SquareIconButton(
                          key: const ValueKey('recipe-detail-delete'),
                          icon: Icons.delete_outline_rounded,
                          semanticLabel: l10n.recipesDeleteSemantics,
                          onTap: !_canUseRecipe
                              ? null
                              : () {
                                  // Pop first: the toast belongs on the recipe list.
                                  Navigator.of(context).pop();
                                  onDelete!(recipe.slug);
                                },
                        ),
                ),
                const SizedBox(height: 16),
                if (!_canUseRecipe || recipe.conflictOf != null) ...[
                  Text(
                    _saveHandle?.value.resolving == true
                        ? l10n.recipeEditResolving
                        : _saveHandle?.value.recipe == null && _saveHandle != null
                        ? l10n.recipeEditUnavailable
                        : l10n.recipeEditConflictSaved,
                    key: const ValueKey('recipe-edit-current-state'),
                    style: AppType.ui(14, color: t.ink2, height: 1.5),
                  ),
                  if (_saveHandle?.value.resolving == true) ...[
                    const SizedBox(height: 10),
                    SoftPillButton(
                      key: const ValueKey('recipe-edit-refresh-result'),
                      onTap: () => _saveHandle?.refresh(),
                      icon: Icons.refresh_rounded,
                      label: l10n.commonBootUnansweredRetry,
                    ),
                  ],
                  const SizedBox(height: 16),
                ],
                Container(
                  key: const ValueKey('recipe-detail-hero'),
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: t.brandSurface,
                    borderRadius: BorderRadius.circular(rSheet),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      AspectRatio(
                        aspectRatio: 1.35,
                        child: RecipePhoto(
                          recipe: recipe,
                          // The default clamps at 56 px, small in a 260 px
                          // hero; 72 is the Recipes hero's share (56 of 200).
                          placeholder: (_) =>
                              RecipeArt.of(recipe, iconSize: 72),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (recipe.displayCategories.isNotEmpty) ...[
                              Text(
                                recipeCategoryLabel(
                                  recipe.displayCategories.first,
                                  l10n,
                                ),
                                style: AppType.ui(
                                  13,
                                  color: t.accent,
                                  weight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 8),
                            ],
                            HeadingSemantics(
                              level: 1,
                              child: Text(
                                recipe.displayTitle(l10n),
                                key: ValueKey('recipe-detail-${recipe.slug}'),
                                style: AppType.display(
                                  28,
                                  color: t.onBrandSurface,
                                  height: 1.12,
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              recipe.displayDescription(l10n),
                              style: AppType.ui(14, color: t.ink2, height: 1.5),
                            ),
                            if (recipe.slug.startsWith('user_coach_')) ...[
                              const SizedBox(height: 12),
                              Text(
                                l10n.recipeEditCoachSource,
                                style: AppType.ui(13, color: t.accent),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                if (recipe.avoidedFoods(widget.avoidances).isNotEmpty) ...[
                  const SizedBox(height: 14),
                  RecipeAvoidHint(recipe: recipe, avoided: widget.avoidances),
                ],
                if (recipe.displayCategories.length > 1) ...[
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final category in recipe.displayCategories.skip(1))
                        _CategoryPill(label: recipeCategoryLabel(category, l10n)),
                    ],
                  ),
                ],
                const SizedBox(height: 14),
                // One row of soft pills; at large text they wrap. Copying
                // is always there, so the row is too.
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (widget.onEdit != null && recipe.userCreated)
                      SoftPillButton(
                        key: const ValueKey('recipe-detail-edit'),
                        onTap: _canUseRecipe ? _edit : null,
                        icon: Icons.edit_outlined,
                        label: l10n.recipeEditTitle,
                      ),
                    if (widget.onPlan case final plan?)
                      SoftPillButton(
                        key: const ValueKey('recipe-detail-plan'),
                        onTap: _canUseRecipe &&
                                widget.isSessionCurrent?.call() != false
                            ? () => plan(context, recipe)
                            : null,
                        icon: Icons.event_note_outlined,
                        label: l10n.mealPlanAddRecipe,
                      ),
                    Builder(
                      builder: (button) => SoftPillButton(
                        key: const ValueKey('recipe-detail-share'),
                        onTap: () => _share(shareOriginOf(button)),
                        icon: Icons.ios_share_rounded,
                        label: l10n.shareTextAction,
                        tone: SoftPillTone.neutral,
                      ),
                    ),
                    if (widget.onOpenHistory != null)
                      SoftPillButton(
                        key: const ValueKey('recipe-detail-history'),
                        tone: SoftPillTone.neutral,
                        onTap:
                            _saveHandle?.value.resolving == true ||
                                _historySlug == null
                            ? null
                            : () async {
                                final restored = await widget
                                    .onOpenHistory!(_historySlug!);
                                if (restored && context.mounted) {
                                  Navigator.pop(context);
                                }
                              },
                        icon: Icons.history_rounded,
                        label: l10n.recipeHistoryTitle,
                      ),
                  ],
                ),
                const SizedBox(height: 24),
                SectionHeading(
                  title: recipe.hasUnclearNutritionBasis
                      ? l10n.recipeImportNutritionSource
                      : l10n.recipesNutritionPerPortionHeading,
                ),
                const SizedBox(height: 12),
                _NutritionGrid(recipe: recipe),
                if (recipe.hasPendingNutrition ||
                    (recipe.hasStructuredIngredients &&
                    !recipe.calculationForServings(1).isComplete)) ...[
                  const SizedBox(height: 8),
                  Text(
                    recipe.hasPendingNutrition
                        ? recipe.nutritionReviewHint(l10n)
                        : l10n.recipeEditIncompleteNutrition,
                    key: const ValueKey('recipe-nutrition-incomplete'),
                    style: AppType.ui(14, color: t.ink2, height: 1.4),
                  ),
                ],
                const SizedBox(height: 18),
                if (!pinAction && widget.showAddAction)
                  _AddToMealCard(
                    recipe: recipe,
                    onTap: _canUseRecipe ? () => _showMealPicker(context) : null,
                  ),
                const SizedBox(height: 18),
                // The import preview's section cards: one recipe reads the
                // same before and after it is saved.
                RecipeSectionCard(
                  key: const ValueKey('recipe-detail-portion'),
                  icon: Icons.restaurant_rounded,
                  title: l10n.recipesSectionPortion,
                  child: RecipeParagraph(
                    text: recipe.hasStructuredIngredients
                        ? '${l10n.recipeEditBatchServings}: ${_nutritionNumber(recipe.batchServings, l10n)}\n${recipe.displayPortion(l10n)}'
                        : recipe.displayPortion(l10n),
                    empty: l10n.recipesNoDataProvided,
                  ),
                ),
                const SizedBox(height: 12),
                RecipeSectionCard(
                  key: const ValueKey('recipe-detail-ingredients'),
                  icon: Icons.shopping_basket_outlined,
                  title: l10n.recipesSectionIngredients,
                  child: RecipeIngredientLines(
                    hint:
                        planned?.hint ??
                        (recipe.hasImportedIngredientContext &&
                                !recipe.hasStructuredIngredients
                            ? recipe.ingredientQuantityHint(l10n)
                            : l10n.recipeDetailIngredientsHint),
                    text:
                        planned?.text ??
                        (recipe.hasStructuredIngredients
                            ? '${recipe.structuredIngredients.map((i) => '${_nutritionNumber(i.grams, l10n)} g ${i.displayName(l10n)}').join('\n')}${recipe.ingredients.isEmpty ? '' : '\n${recipe.ingredients}'}'
                            : recipe.displayIngredients(l10n)),
                  ),
                ),
                const SizedBox(height: 12),
                RecipeSectionCard(
                  key: const ValueKey('recipe-detail-preparation'),
                  icon: Icons.soup_kitchen_outlined,
                  title: l10n.recipesSectionPreparation,
                  child: RecipePreparationSteps(
                    hint: l10n.recipeDetailPreparationHint,
                    text: recipe.displayPreparation(l10n),
                    empty: l10n.recipesNoDataProvided,
                  ),
                ),
                const SizedBox(height: 12),
                RecipeSectionCard(
                  key: const ValueKey('recipe-detail-pro-hint'),
                  icon: Icons.lightbulb_outline_rounded,
                  title: l10n.recipesSectionProHint,
                  highlight: true,
                  child: RecipeParagraph(
                    text: recipe.displayProfessionalHint(l10n),
                    empty: l10n.recipesNoDataProvided,
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

class _AddToMealCard extends StatelessWidget {
  const _AddToMealCard({required this.recipe, required this.onTap});
  final FitnessRecipe recipe;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l = context.l10n;
    // A calm card: the accent lives on the one primary action only.
    return Container(
      key: const ValueKey('recipe-add-card'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: t.surf,
        borderRadius: BorderRadius.circular(rCard),
        border: Border.all(color: t.cardBorder),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _recipeSummary(recipe, l),
            style: AppType.ui(13, color: t.ink2),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          PrimaryActionButton(
            key: const ValueKey('recipe-add-button'),
            onTap: onTap,
            icon: recipe.hasPendingNutrition
                ? Icons.fact_check_outlined
                : Icons.add_rounded,
            label: recipe.hasPendingNutrition
                ? recipe.hasMissingNutrition
                    ? recipe.nutritionConflicts.isNotEmpty ? l.recipeNutritionCorrect : l.recipeNutritionComplete
                    : l.recipeNutritionBasisCheck
                : l.recipesAddToTrackerTitle,
          ),
          const SizedBox(height: 10),
          Text(
            recipe.hasPendingNutrition
                ? recipe.hasMissingNutrition
                    ? recipe.nutritionReviewHint(l)
                    : l.recipeNutritionBasisBeforeLog
                : l.recipesAddToTrackerHint,
            textAlign: TextAlign.center,
            style: AppType.ui(12, color: t.ink2, height: 1.4),
          ),
        ],
      ),
    );
  }
}

class _NutritionGrid extends StatelessWidget {
  const _NutritionGrid({required this.recipe});

  final FitnessRecipe recipe;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final n = _recipeNutrition(recipe);
    final tiles = [
      _NutritionTile(
        label: l10n.recipesNutritionKcalLabel,
        value: _kcalNumber(n.caloriesKcal, l10n),
        color: t.accent,
        surface: t.brandSurface,
      ),
      _NutritionTile(
        label: l10n.todayMacroProtein,
        value: '${_nutritionNumber(n.proteinG, l10n)} g',
        color: t.protein,
        surface: t.proteinSurface,
      ),
      _NutritionTile(
        label: l10n.recipesNutritionCarbsLabel,
        value: '${_nutritionNumber(n.carbsG, l10n)} g',
        color: t.carbs,
        surface: t.carbsSurface,
      ),
      _NutritionTile(
        label: l10n.todayMacroFat,
        value: '${_nutritionNumber(n.fatG, l10n)} g',
        color: t.fat,
        surface: t.fatSurface,
      ),
    ];
    var minimumWidth = 0.0;
    for (final tile in tiles) {
      for (final (text, style) in [
        (tile.value, _NutritionTile.valueStyle(t)),
        (tile.label.toUpperCase(), _NutritionTile.labelStyle(t)),
      ]) {
        final resolvedStyle = DefaultTextStyle.of(context).style.merge(style);
        final painter = TextPainter(
          text: TextSpan(
            text: text,
            style: MediaQuery.boldTextOf(context)
                ? resolvedStyle.copyWith(fontWeight: FontWeight.bold)
                : resolvedStyle,
          ),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          locale: Localizations.maybeLocaleOf(context),
        )..layout();
        // Card padding and its two 1 px borders also consume width.
        final width = painter.width.ceilToDouble() + 18;
        painter.dispose();
        if (width > minimumWidth) minimumWidth = width;
      }
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = [4, 2, 1].firstWhere(
          (count) =>
              count * minimumWidth + (count - 1) * 8 <= constraints.maxWidth,
          orElse: () => 1,
        );
        final width = (constraints.maxWidth - (columns - 1) * 8) / columns;
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final tile in tiles) SizedBox(width: width, child: tile),
          ],
        );
      },
    );
  }
}

class _NutritionTile extends StatelessWidget {
  const _NutritionTile({
    required this.label,
    required this.value,
    required this.color,
    required this.surface,
  });

  final String label;
  final String value;

  /// Nutrient tone for the MARKER only, never for the number: on `surf` in
  /// light mode `carbs` reaches 3.39:1 and `fat` 3.73:1 — enough for a
  /// graphical object (WCAG 1.4.11, 3:1), short of text (4.5:1). Same rule as
  /// `trends_screen`: coloured dot, text in text tokens. `accent` would carry
  /// text, but the kcal tile keeps the row's one shape.
  final Color color;
  final Color surface;

  static TextStyle valueStyle(AppTokens t) =>
      AppType.display(22, weight: FontWeight.w700, color: t.ink);

  static TextStyle labelStyle(AppTokens t) =>
      AppType.eyebrow(t.ink, size: 10.5);

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Container(
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(rCard),
      ),
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
      child: Column(
        children: [
          // Keep nutrient color separate from the readable value.
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(height: 7),
          Text(value, textAlign: TextAlign.center, style: valueStyle(t)),
          const SizedBox(height: 4),
          Text(
            label.toUpperCase(),
            textAlign: TextAlign.center,
            style: labelStyle(t),
          ),
        ],
      ),
    );
  }
}
