part of 'recipes_screen.dart';

// ---------------------------------------------------------------------------
// Recipe detail view (own route push). [RecipeDetailScreen] is public.
// ---------------------------------------------------------------------------
class RecipeDetailScreen extends StatefulWidget {
  const RecipeDetailScreen({
    super.key,
    required this.recipe,
    required this.onAddMeal,
    this.onDelete,
    this.onEdit,
    this.photoInput,
    this.isSessionCurrent,
    this.productService,
  });

  final FitnessRecipe recipe;
  final void Function(MealAnalysisResult result, MealSlot slot) onAddMeal;

  /// Optional delete hook, set only for own recipes.
  final VoidCallback? onDelete;
  final Future<SyncDelivery> Function(FitnessRecipe)? onEdit;
  final MealPhotoInput? photoInput;
  final bool Function()? isSessionCurrent;
  final ProductLookupService? productService;

  @override
  State<RecipeDetailScreen> createState() => _RecipeDetailScreenState();
}

class _RecipeDetailScreenState extends State<RecipeDetailScreen> {
  late FitnessRecipe recipe = widget.recipe;
  VoidCallback? get onDelete => widget.onDelete;

  Future<void> _edit() async {
    if (widget.isSessionCurrent?.call() == false) return;
    final result = await showModalBottomSheet<RezeptEntwurfErgebnis>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _CreateRecipeSheet(
        initialRecipe: recipe,
        photoInput: widget.photoInput ?? DeviceMealPhotoInput(),
        productService: widget.productService,
        onSave: widget.onEdit,
        isSessionCurrent: widget.isSessionCurrent,
      ),
    );
    if (!mounted ||
        result == null ||
        widget.isSessionCurrent?.call() == false) {
      return;
    }
    setState(() => recipe = result.rezept);
    showAppSnack(
      context,
      deliveryHint(
        result.fotoFehlgeschlagen
            ? context.l10n.recipeEditPhotoRetained
            : context.l10n.recipeEditSaved,
        result.delivery ?? SyncDelivery.delivered,
        context.l10n,
      ),
      icon: Icons.check_circle_rounded,
    );
  }

  Future<void> _showMealPicker(BuildContext context) async {
    if (widget.isSessionCurrent?.call() == false) return;
    final selection = await showEatovaSheet<({MealSlot slot, double servings})>(
      context,
      _MealSlotPickerSheet(recipe: recipe),
    );
    if (!context.mounted || selection == null) return;
    _add(context, selection.slot, selection.servings);
  }

  void _add(BuildContext context, MealSlot slot, double servings) {
    final l10n = context.l10n;
    if (widget.isSessionCurrent?.call() == false) return;
    final result = recipe.toMealResultForServings(servings, l10n);
    widget.onAddMeal(result, slot);
    showAppSnack(
      context,
      l10n.commonKcalAddedToSlot(result.caloriesKcal, slot.label(l10n)),
      icon: Icons.check_circle_rounded,
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final pinAction =
        MediaQuery.sizeOf(context).height >= 700 &&
        MediaQuery.textScalerOf(context).scale(14) <= 19;
    return Scaffold(
      backgroundColor: t.bg,
      bottomNavigationBar: pinAction
          ? SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                child: _AddToMealCard(
                  recipe: recipe,
                  onTap: () => _showMealPicker(context),
                ),
              ),
            )
          : null,
      body: SafeArea(
        bottom: false,
        child: SingleChildScrollView(
          key: const ValueKey('recipe-detail-scroll'),
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              PageHeader(
                title: recipe.userCreated
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
                        onTap: () {
                          // Pop first: the toast belongs on the recipe list.
                          Navigator.of(context).pop();
                          onDelete!();
                        },
                      ),
              ),
              const SizedBox(height: 16),
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
                      child: RecipePhoto(recipe: recipe),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (recipe.categories.isNotEmpty) ...[
                            Text(
                              recipeCategoryLabel(
                                recipe.categories.first,
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
                              recipe.title,
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
              if (recipe.categories.length > 1) ...[
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final category in recipe.categories.skip(1))
                      _CategoryPill(label: recipeCategoryLabel(category, l10n)),
                  ],
                ),
              ],
              if (widget.onEdit != null && recipe.userCreated) ...[
                const SizedBox(height: 14),
                TextButton.icon(
                  key: const ValueKey('recipe-detail-edit'),
                  onPressed: _edit,
                  icon: const Icon(Icons.edit_outlined),
                  label: Text(l10n.recipeEditTitle),
                ),
              ],
              const SizedBox(height: 24),
              SectionHeading(title: l10n.recipesPerPortion),
              const SizedBox(height: 12),
              _NutritionGrid(recipe: recipe),
              if (recipe.hasStructuredIngredients &&
                  !recipe.calculationForServings(1).isComplete) ...[
                const SizedBox(height: 8),
                Text(
                  l10n.recipeEditIncompleteNutrition,
                  key: const ValueKey('recipe-nutrition-incomplete'),
                  style: AppType.ui(14, color: t.ink2, height: 1.4),
                ),
              ],
              const SizedBox(height: 18),
              if (!pinAction)
                _AddToMealCard(
                  recipe: recipe,
                  onTap: () => _showMealPicker(context),
                ),
              const SizedBox(height: 18),
              _RecipeInfoSection(
                title: l10n.recipesSectionPortion,
                body: recipe.hasStructuredIngredients
                    ? '${l10n.recipeEditBatchServings}: ${_nutritionNumber(recipe.batchServings)}\n${recipe.displayPortion(l10n)}'
                    : recipe.displayPortion(l10n),
              ),
              _RecipeInfoSection(
                title: l10n.recipesSectionIngredients,
                hint: l10n.recipeDetailIngredientsHint,
                body: recipe.hasStructuredIngredients
                    ? '${recipe.structuredIngredients.map((i) => '${_nutritionNumber(i.grams)} g ${i.name}').join('\n')}${recipe.ingredients.isEmpty ? '' : '\n\n${recipe.ingredients}'}'
                    : recipe.displayIngredients(l10n),
              ),
              _RecipeInfoSection(
                title: l10n.recipesSectionPreparation,
                hint: l10n.recipeDetailPreparationHint,
                numbered: true,
                body: recipe.displayPreparation(l10n),
              ),
              _RecipeInfoSection(
                title: l10n.recipesSectionProHint,
                body: recipe.displayProfessionalHint(l10n),
                highlight: true,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AddToMealCard extends StatelessWidget {
  const _AddToMealCard({required this.recipe, required this.onTap});
  final FitnessRecipe recipe;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l = context.l10n;
    return Container(
      key: const ValueKey('recipe-add-card'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: t.brandSurface,
        borderRadius: BorderRadius.circular(rSheet),
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
          FilledButton.icon(
            key: const ValueKey('recipe-add-button'),
            style: FilledButton.styleFrom(
              backgroundColor: t.ink,
              foregroundColor: t.bg,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              minimumSize: const Size(48, 52),
            ),
            onPressed: onTap,
            icon: const Icon(Icons.add_rounded, size: 22),
            label: Text(
              l.recipesAddToTrackerTitle,
              textAlign: TextAlign.center,
              style: AppType.ui(15, weight: FontWeight.w700),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            l.recipesAddToTrackerHint,
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
        value: _nutritionNumber(n.caloriesKcal),
        color: t.accent,
        surface: t.brandSurface,
      ),
      _NutritionTile(
        label: l10n.todayMacroProtein,
        value: '${_nutritionNumber(n.proteinG)} g',
        color: t.protein,
        surface: t.proteinSurface,
      ),
      _NutritionTile(
        label: l10n.recipesNutritionCarbsLabel,
        value: '${_nutritionNumber(n.carbsG)} g',
        color: t.carbs,
        surface: t.carbsSurface,
      ),
      _NutritionTile(
        label: l10n.todayMacroFat,
        value: '${_nutritionNumber(n.fatG)} g',
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

class _RecipeInfoSection extends StatelessWidget {
  const _RecipeInfoSection({
    required this.title,
    required this.body,
    this.highlight = false,
    this.numbered = false,
    this.hint,
  });
  final String title, body;
  final String? hint;
  final bool highlight, numbered;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final lines = body
        .split(RegExp(r'\n+'))
        .where((line) => line.trim().isNotEmpty)
        .toList();
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeading(title: title),
          if (hint != null) ...[
            const SizedBox(height: 6),
            Text(hint!, style: AppType.ui(13, color: t.ink2, height: 1.4)),
          ],
          const SizedBox(height: 14),
          Container(
            width: double.infinity,
            padding: EdgeInsets.all(highlight ? 20 : 0),
            decoration: BoxDecoration(
              color: highlight ? t.brandSurface : Colors.transparent,
              borderRadius: BorderRadius.circular(rSheet),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < lines.length; i++) ...[
                  if (numbered && lines.length > 1)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          constraints: const BoxConstraints(
                            minWidth: 30,
                            minHeight: 30,
                          ),
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: t.brandSurface,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '${i + 1}',
                            textAlign: TextAlign.center,
                            style: AppType.ui(
                              13,
                              color: t.accent,
                              weight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            lines[i].replaceFirst(RegExp(r'^\d+[.)]\s*'), ''),
                            style: AppType.ui(15, color: t.ink, height: 1.6),
                          ),
                        ),
                      ],
                    )
                  else
                    Text(
                      lines[i],
                      style: AppType.ui(15, color: t.ink, height: 1.6),
                    ),
                  if (i < lines.length - 1) ...[
                    const SizedBox(height: 12),
                    if (!numbered) Divider(height: 1, color: t.line),
                    const SizedBox(height: 12),
                  ],
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
