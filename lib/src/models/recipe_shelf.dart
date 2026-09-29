/// The Recipes tab's "High protein, under 500 kcal" shelf (dark redesign,
/// 2026-09-28): a client-side filter over the recipes the tab already shows.
///
/// Pure and widget-free; the screen passes its visible recipes and the clock.
library;

import 'fitness_recipe.dart';
import 'user_profile.dart';

/// Exclusive kcal ceiling of the shelf: "under 500" means below 500.
const int leanShelfMaxKcal = 500;

/// Cards on the shelf before "See all".
const int leanShelfCount = 6;

/// Filter identity of the shelf's "See all" list. Never a category and never
/// part of [recipeFilters]; double-quoted because it is matching data, not UI
/// text.
const String leanShelfFilter = "High Protein <500";

/// Whether [recipe] belongs on the shelf: kcal and protein per portion are
/// known (the values the list shows, [FitnessRecipe.displayNutrition]), the
/// kcal lie in (0, [leanShelfMaxKcal]), and the protein meets the
/// [HighProteinRule] (at least 30 g and at least 20 % of the energy).
///
/// The rule is applied to the numbers instead of the "High Protein" tag, so
/// own recipes, which carry no tag, qualify by what they contain.
bool isLeanHighProtein(FitnessRecipe recipe) {
  if (recipe.hasPendingNutrition) return false;
  final nutrition = recipe.displayNutrition;
  final kcal = nutrition.caloriesKcal;
  final protein = nutrition.proteinG;
  if (kcal == null || protein == null) return false;
  if (kcal <= 0 || kcal >= leanShelfMaxKcal) return false;
  return protein >= HighProteinRule.minProteinG &&
      protein * HighProteinRule.kcalPerProteinG >=
          kcal * HighProteinRule.minEnergyShare;
}

/// The recipes of [recipes] that match [diet] and [isLeanHighProtein], in
/// list order: the complete set behind "See all".
///
/// The shelf is actively promoted, so the diet pre-filter applies like on the
/// other recommendations ([FitnessRecipe.matchesDiet]; own recipes always
/// pass).
List<FitnessRecipe> leanHighProteinRecipes(
  List<FitnessRecipe> recipes, {
  DietPreference diet = DietPreference.none,
}) => recipes
    .where((recipe) => recipe.matchesDiet(diet) && isLeanHighProtein(recipe))
    .toList(growable: false);

/// The cards of the shelf, at most [count]:
///
///  1. own recipes first, in list order (the user's own dishes are the most
///     relevant hits of a filter);
///  2. then the catalog hits, rotated by calendar day
///     ([rotatedRecommendations]) so the shelf does not show the same cards
///     every day;
///
/// [excludeSlug] (the recipe the hero card already shows) is left out.
List<FitnessRecipe> leanHighProteinShelf(
  List<FitnessRecipe> recipes, {
  required DateTime now,
  DietPreference diet = DietPreference.none,
  String? excludeSlug,
  int count = leanShelfCount,
}) {
  if (count <= 0) return const <FitnessRecipe>[];
  final hits = leanHighProteinRecipes(
    recipes,
    diet: diet,
  ).where((recipe) => recipe.slug != excludeSlug).toList(growable: false);
  final own = hits.where((recipe) => recipe.userCreated);
  final catalog = hits
      .where((recipe) => !recipe.userCreated)
      .toList(growable: false);
  return <FitnessRecipe>[
    ...own,
    ...rotatedRecommendations(catalog, now, count: catalog.length),
  ].take(count).toList(growable: false);
}

/// Exclusive kcal ceiling of the "Under 600 kcal" chip.
const int lightMealMaxKcal = 600;

/// Filter identity of the "Under 600 kcal" chip. Never a category and never
/// part of [recipeFilters]; double-quoted because it is matching data.
const String lightMealFilter = "Unter 600 kcal";

/// Whether [recipe] belongs under the "Under 600 kcal" chip: its per-portion
/// kcal (the value the list shows) is known and in (0, [lightMealMaxKcal]).
/// A list filter like the categories, so no diet pre-filter.
bool isUnder600Kcal(FitnessRecipe recipe) {
  if (recipe.hasPendingNutrition) return false;
  final kcal = recipe.displayNutrition.caloriesKcal;
  return kcal != null && kcal > 0 && kcal < lightMealMaxKcal;
}
