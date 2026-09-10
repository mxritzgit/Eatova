part of 'recipes_screen.dart';

String _nutritionNumber(double? value) => value == null
    ? '—'
    : value == value.roundToDouble()
    ? value.round().toString()
    : value.toStringAsFixed(1);

RecipeNutrition _recipeNutrition(FitnessRecipe recipe) =>
    recipe.hasStructuredIngredients
    ? recipe.calculationForServings(1).nutrition
    : RecipeNutrition(
        caloriesKcal: recipe.caloriesKcal.toDouble(),
        proteinG: recipe.proteinG.toDouble(),
        carbsG: recipe.carbsG.toDouble(),
        fatG: recipe.fatG.toDouble(),
      );

String _recipeSummary(FitnessRecipe recipe, AppLocalizations l10n) {
  final n = _recipeNutrition(recipe);
  return '${_nutritionNumber(n.caloriesKcal)} kcal · ${_nutritionNumber(n.proteinG)} g ${l10n.todayMacroProtein}';
}

class _CalculatedNutrition extends StatelessWidget {
  const _CalculatedNutrition({required this.calculation});
  final RecipeCalculation calculation;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final t = context.t;
    final n = calculation.nutrition;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.recipesPerPortion,
          style: AppType.ui(14, weight: FontWeight.w600, color: t.ink),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 16,
          runSpacing: 8,
          children: [
            for (final pair in [
              (l10n.foodAddItemCaloriesLabel, n.caloriesKcal, 'kcal'),
              (l10n.todayMacroProtein, n.proteinG, 'g'),
              (l10n.todayMacroCarbs, n.carbsG, 'g'),
              (l10n.todayMacroFat, n.fatG, 'g'),
            ])
              Text(
                '${pair.$1}: ${_nutritionNumber(pair.$2)} ${pair.$3}',
                style: AppType.ui(14, color: t.ink, height: 1.4),
              ),
          ],
        ),
        if (!calculation.isComplete) ...[
          const SizedBox(height: 8),
          Text(
            l10n.recipeEditIncompleteNutrition,
            key: const ValueKey('recipe-nutrition-incomplete'),
            style: AppType.ui(14, color: t.ink2, height: 1.4),
          ),
        ],
        if (!calculation.fitsStorageLimits) ...[
          const SizedBox(height: 8),
          Text(
            l10n.recipeEditNutritionTooLarge,
            style: AppType.ui(14, color: t.danger, height: 1.4),
          ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Shared atoms used by cards, detail view and slot picker: badge, category
// pill, recipe image and metrics row.
// ---------------------------------------------------------------------------

/// Renders a neutral category/filter value in the active language.
///
/// The value itself stays the logic identity (filter comparison, diet
/// matching, `ValueKey`s), so [recipeFilters] is never touched — same split as
/// `MealSlot`, where the enum carries identity and `label(l10n)` the display.
/// An unknown value passes through unchanged instead of crashing.
///
/// The comparison literals are double-quoted on purpose: they are content
/// identity, not translatable UI text, so the hardcoded-string guard (which
/// only checks `'...'`) skips them.
String recipeCategoryLabel(String category, AppLocalizations l10n) {
  return switch (category) {
    "Alle" => l10n.recipesFilterAll,
    "High Protein" => l10n.recipesFilterHighProtein,
    "Hauptgericht" => l10n.recipesFilterMainCourse,
    "Frühstück" => l10n.recipesFilterBreakfast,
    "Fisch" => l10n.recipesFilterFish,
    "Vegetarisch" => l10n.recipesFilterVegetarian,
    "Vegan" => l10n.recipesFilterVegan,
    "Low Carb" => l10n.recipesFilterLowCarb,
    "Eigene" => l10n.recipesCategoryOwn,
    _ => category,
  };
}

/// Small label: filled as a marker on a photo, unfilled as a quiet hint on a
/// card.
///
/// Filled = forest with `onForest`, the one selection language of every chip
/// in the app; lime stays reserved for the nav capsule (F8-07).
class _RecipeBadge extends StatelessWidget {
  const _RecipeBadge({required this.text, this.icon, this.filled = false});

  final String text;
  final IconData? icon;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final foreground = filled ? t.onForest : t.ink;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: filled ? t.forest : t.surf,
        borderRadius: BorderRadius.circular(rChip),
        border: filled ? null : Border.all(color: t.line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: foreground),
            const SizedBox(width: 4),
          ],
          Text(
            text,
            style: AppType.ui(
              9.5,
              weight: FontWeight.w700,
              color: foreground,
              letterSpacing: 1,
            ),
          ),
        ],
      ),
    );
  }
}

/// Compact category pill of the detail view. Always [AppTokens.accent]:
/// macro colors are reserved for nutrient values by the token contract.
class _CategoryPill extends StatelessWidget {
  const _CategoryPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: t.tile,
        borderRadius: BorderRadius.circular(rChip),
      ),
      child: Text(
        label,
        style: AppType.ui(10.5, weight: FontWeight.w600, color: t.accent),
      ),
    );
  }
}

/// Image of a recipe card. Three cases, in this order:
///  1. `local:<slug>.jpg` from [RecipeImageStore]; a missing file (other
///     device, cleared cache) falls back to the placeholder, never a broken
///     icon.
///  2. Catalog recipes show their bundle asset.
///  3. Everything else gets the striped [ImagePlaceholder].
class _RecipeImage extends StatelessWidget {
  const _RecipeImage({required this.recipe, this.placeholderRadius = 0});

  final FitnessRecipe recipe;

  /// The placeholder draws its own corner; real assets are clipped by the
  /// calling card.
  final double placeholderRadius;

  @override
  Widget build(BuildContext context) {
    if (RecipeImageStore.isLocalReference(recipe.imageAsset)) {
      return _LocalRecipeImage(
        reference: recipe.imageAsset,
        placeholderRadius: placeholderRadius,
      );
    }
    if (recipe.userCreated || recipe.imageAsset.isEmpty) {
      return ImagePlaceholder(
        radius: placeholderRadius,
        label: context.l10n.recipesImagePlaceholderLabel,
      );
    }
    // Tie decode resolution to the actual slot width: the recipe PNGs are
    // ~1800px/2.4MB and would otherwise decode in full for every size.
    return LayoutBuilder(
      builder: (context, constraints) {
        final dpr = MediaQuery.devicePixelRatioOf(context);
        final logicalWidth =
            constraints.maxWidth.isFinite ? constraints.maxWidth : 400.0;
        return Image.asset(
          recipe.imageAsset,
          fit: BoxFit.cover,
          cacheWidth: (logicalWidth * dpr).round().clamp(1, 1600),
        );
      },
    );
  }
}

/// A user-taken recipe photo from the app documents directory.
///
/// Stateful rather than a [FutureBuilder]: once the base is resolved,
/// [RecipeImageStore.resolveSync] answers without a frame delay, so scrolling
/// never flashes a placeholder. Only the first access per session is async.
class _LocalRecipeImage extends StatefulWidget {
  const _LocalRecipeImage({
    required this.reference,
    required this.placeholderRadius,
  });

  final String reference;
  final double placeholderRadius;

  @override
  State<_LocalRecipeImage> createState() => _LocalRecipeImageState();
}

class _LocalRecipeImageState extends State<_LocalRecipeImage> {
  File? _file;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant _LocalRecipeImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reference != widget.reference) {
      _file = null;
      _resolve();
    }
  }

  void _resolve() {
    final store = RecipeImageStore.instance;
    if (store.baseResolved) {
      _file = store.resolveSync(widget.reference);
      return;
    }
    final gesucht = widget.reference;
    store.resolve(gesucht).then((datei) {
      // Disposed meanwhile, or switched to another recipe.
      if (!mounted || gesucht != widget.reference) return;
      setState(() => _file = datei);
    });
  }

  @override
  Widget build(BuildContext context) {
    final datei = _file;
    if (datei == null) {
      return ImagePlaceholder(
        radius: widget.placeholderRadius,
        label: context.l10n.recipesImagePlaceholderLabel,
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final dpr = MediaQuery.devicePixelRatioOf(context);
        final logicalWidth =
            constraints.maxWidth.isFinite ? constraints.maxWidth : 400.0;
        return Image.file(
          datei,
          fit: BoxFit.cover,
          cacheWidth: (logicalWidth * dpr).round().clamp(1, 1600),
          // The file can vanish between the existence check and decoding.
          errorBuilder: (context, error, stack) => ImagePlaceholder(
            radius: widget.placeholderRadius,
            label: context.l10n.recipesImagePlaceholderLabel,
          ),
        );
      },
    );
  }
}

/// Metrics row under a recipe title: calories (emphasized) plus the full
/// macro trio. [FitnessRecipe] knows neither prep time nor servings, so
/// nothing is invented.
///
/// [FitnessRecipe.portion] is deliberately left out: it is prose, not a
/// measure, and ran over four lines here. `Wrap`, not `Row`, so doubled font
/// sizes break instead of overflowing.
class _RecipeMetrics extends StatelessWidget {
  const _RecipeMetrics({required this.recipe, this.onImage = false});

  final FitnessRecipe recipe;

  /// On a photo even the muted value needs a light tone; `ink2` would be too
  /// dark in both modes.
  final bool onImage;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final n = _recipeNutrition(recipe);
    final stark = onImage ? t.onForest : t.ink;
    final leise = onImage ? t.onForest.withValues(alpha: 0.78) : t.ink2;
    // No macro tones here: the value is already in the text and three colors
    // next to the photo would be noise. The detail grid carries the coding.
    TextStyle stil(Color color) =>
        AppType.ui(11, weight: FontWeight.w600, color: color);
    return Wrap(
      spacing: 12,
      runSpacing: 4,
      children: [
        Text('${_nutritionNumber(n.caloriesKcal)} kcal', style: stil(stark)),
        Text(
          recipe.hasStructuredIngredients
              ? '${_nutritionNumber(n.proteinG)} g ${l10n.todayMacroProtein}'
              : l10n.recipesMetricProtein(recipe.proteinG),
          style: stil(leise),
        ),
        Text(
          recipe.hasStructuredIngredients
              ? '${_nutritionNumber(n.carbsG)} g ${l10n.todayMacroCarbs}'
              : l10n.recipesMetricCarbs(recipe.carbsG),
          style: stil(leise),
        ),
        Text(
          recipe.hasStructuredIngredients
              ? '${_nutritionNumber(n.fatG)} g ${l10n.todayMacroFat}'
              : l10n.recipesMetricFat(recipe.fatG),
          style: stil(leise),
        ),
      ],
    );
  }
}
