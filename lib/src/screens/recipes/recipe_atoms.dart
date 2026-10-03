part of 'recipes_screen.dart';

String _nutritionNumber(double? value, AppLocalizations l10n) =>
    value == null ? '—' : formatDecimal(value, l10n, maxFractionDigits: 1);

RecipeNutrition _recipeNutrition(FitnessRecipe recipe) =>
    recipe.displayNutrition;

String _recipeSummary(FitnessRecipe recipe, AppLocalizations l10n) {
  final n = _recipeNutrition(recipe);
  return '${_nutritionNumber(n.caloriesKcal, l10n)} kcal · ${_nutritionNumber(n.proteinG, l10n)} g ${l10n.todayMacroProtein}';
}

/// The per-portion result of a batch recipe: one calm card with the kcal as
/// the figure and the macros as the app's coloured dots; warnings follow as
/// tinted lines.
class _CalculatedNutrition extends StatelessWidget {
  const _CalculatedNutrition({required this.calculation});
  final RecipeCalculation calculation;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final t = context.t;
    final n = calculation.nutrition;
    final macros = <(Color, String, double?)>[
      (t.protein, l10n.todayMacroProtein, n.proteinG),
      (t.carbs, l10n.todayMacroCarbs, n.carbsG),
      (t.fat, l10n.todayMacroFat, n.fatG),
    ];
    Widget note(String text, Color color, IconData icon, {Key? key}) => Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        key: key,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 16, color: color),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: AppType.ui(13, color: color, height: 1.4),
            ),
          ),
        ],
      ),
    );
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: t.surf,
        borderRadius: BorderRadius.circular(rTile),
        border: Border.all(color: t.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.recipesPerPortion.toUpperCase(),
            style: AppType.eyebrow(t.ink2, size: 11),
          ),
          const SizedBox(height: 6),
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: _nutritionNumber(n.caloriesKcal, l10n),
                  style: AppType.display(26, color: t.ink, height: 1.1),
                ),
                TextSpan(
                  text: ' kcal',
                  style: AppType.ui(14, weight: FontWeight.w600, color: t.ink2),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 14,
            runSpacing: 6,
            children: [
              for (final (color, label, value) in macros)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '$label ${_nutritionNumber(value, l10n)} g',
                      style: AppType.ui(13, weight: FontWeight.w600, color: t.ink2),
                    ),
                  ],
                ),
            ],
          ),
          if (!calculation.isComplete)
            note(
              l10n.recipeEditIncompleteNutrition,
              t.ink2,
              Icons.info_outline_rounded,
              key: const ValueKey('recipe-nutrition-incomplete'),
            ),
          if (!calculation.fitsStorageLimits)
            note(
              l10n.recipeEditNutritionTooLarge,
              t.danger,
              Icons.error_outline_rounded,
            ),
        ],
      ),
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
    recipeNutritionPendingCategory => l10n.recipeImportNutritionPendingLabel,
    recipeNutritionBasisPendingCategory => l10n.recipeNutritionBasisCheck,
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
