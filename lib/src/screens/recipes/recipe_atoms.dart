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
// Nutrition and category labels shared by recipe cards, details and sheets.
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
