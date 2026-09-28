/// One recipe for the next open main meal: "Tonight's pick" (Today), the
/// "Fits tonight" row (Food) and the "Picked for tonight" hero (Recipes).
///
/// Pure and widget-free; `HomeStore.nextMealPick` binds the store state.
library;

import '../services/local_day.dart';
import 'day_nutrition.dart';
import 'fitness_recipe.dart';
import 'logged_meal.dart';
import 'macro_progress.dart';
import 'planned_meal.dart';
import 'user_profile.dart';

/// The language-neutral category of breakfast dishes in both catalogs.
///
/// Double-quoted like [recipeFilters]: matching data, not UI text.
const String breakfastCategory = "Frühstück";

/// Where a [RecipePick] came from.
enum RecipePickSource {
  /// The user's own meal plan for that day and slot.
  planned,

  /// Chosen from the user's recipes and the catalog.
  suggested,
}

/// A recipe proposed for [slot], with the numbers the cards print.
final class RecipePick {
  const RecipePick({
    required this.recipe,
    required this.slot,
    required this.source,
    required this.servings,
    required this.kcal,
    required this.proteinG,
    required this.remainingKcalBefore,
    this.plannedMeal,
  });

  final FitnessRecipe recipe;
  final MealSlot slot;
  final RecipePickSource source;

  /// 1 for suggestions; the planned portion for [RecipePickSource.planned].
  final double servings;

  /// kcal and protein of [servings] exactly as logging would record them;
  /// null only for a planned recipe whose nutrition is not loggable yet.
  final int? kcal;
  final int? proteinG;

  /// The day's remaining kcal (budget incl. activity minus eaten) at pick time.
  final int remainingKcalBefore;

  /// The meal-plan entry behind a [RecipePickSource.planned] pick.
  final PlannedMeal? plannedMeal;

  /// "Fits your day": known kcal no larger than [remainingKcalBefore].
  /// Always true for suggestions; a planned meal is shown even when it does
  /// not fit, so the flag matters there.
  bool get fits => kcal != null && kcal! <= remainingKcalBefore;

  /// "Leaves 292 kcal for today"; negative when a planned meal overshoots,
  /// null when its kcal are unknown.
  int? get kcalLeftAfter => kcal == null ? null : remainingKcalBefore - kcal!;
}

/// Whether [recipe] is offered for [slot]: breakfast takes only dishes tagged
/// [breakfastCategory]; lunch and dinner take everything else, including
/// untagged own recipes. Snacks get no pick.
bool recipeSuitsSlot(FitnessRecipe recipe, MealSlot slot) {
  final breakfastDish = recipe.categories.contains(breakfastCategory);
  return switch (slot) {
    MealSlot.breakfast => breakfastDish,
    MealSlot.lunch || MealSlot.dinner => !breakfastDish,
    MealSlot.snack => false,
  };
}

/// Picks the recipe for the next open main meal of [now]'s day, or null.
///
/// The slot is [nextOpenMainMealSlot]; the recipe comes from
/// [pickRecipeForSlot]. [todaysMeals] are the meals of [now]'s local day and
/// [remainingKcal] is that day's `DayNutritionSummary.remainingKcal`.
RecipePick? pickRecipeForNextMeal({
  required DateTime now,
  required List<LoggedMeal> todaysMeals,
  required int remainingKcal,
  required List<FitnessRecipe> recipes,
  DietPreference diet = DietPreference.none,
  List<PlannedMeal> plannedMeals = const <PlannedMeal>[],
}) {
  final slot = nextOpenMainMealSlot(now: now, todaysMeals: todaysMeals);
  if (slot == null) return null;
  return pickRecipeForSlot(
    slot: slot,
    day: now,
    remainingKcal: remainingKcal,
    recipes: recipes,
    diet: diet,
    plannedMeals: plannedMeals,
    alreadyEaten: todaysMeals,
  );
}

/// Picks one recipe for [slot] on [day], or null when nothing fits.
///
/// Rule, in order:
///  1. **The meal plan wins.** The first not-yet-eaten [plannedMeals] entry
///     for [day] and [slot] (list order; the store keeps newest first) is
///     returned as planned, even when it does not fit ([RecipePick.fits]).
///  2. **Otherwise a fitting suggestion.** Candidates are [recipes] that match
///     [diet] ([FitnessRecipe.matchesDiet]), suit the slot
///     ([recipeSuitsSlot]), are loggable with known kcal > 0, need no more
///     than [remainingKcal], and are not already eaten today (same meal name
///     as an entry in [alreadyEaten]).
///  3. **Ranking:** most protein first, then fewer kcal, then slug ascending,
///     so equal inputs always give the same pick.
///
/// kcal and protein are read from [FitnessRecipe.toMealResultForServings],
/// i.e. exactly what "Add to dinner" would log.
RecipePick? pickRecipeForSlot({
  required MealSlot slot,
  required DateTime day,
  required int remainingKcal,
  required List<FitnessRecipe> recipes,
  DietPreference diet = DietPreference.none,
  List<PlannedMeal> plannedMeals = const <PlannedMeal>[],
  Iterable<LoggedMeal> alreadyEaten = const <LoggedMeal>[],
}) {
  final dayKey = localDayKey(day.toLocal());
  for (final plan in plannedMeals) {
    if (plan.day != dayKey || plan.slot != slot) continue;
    if (plan.isEaten || plan.removed) continue;
    final recipe = plan.recipe;
    final portion = _loggedPortion(recipe, plan.servings);
    return RecipePick(
      recipe: recipe,
      slot: slot,
      source: RecipePickSource.planned,
      servings: plan.servings,
      kcal: portion?.kcal,
      proteinG: portion?.proteinG.round(),
      remainingKcalBefore: remainingKcal,
      plannedMeal: plan,
    );
  }

  if (remainingKcal <= 0 || !mainMealSlots.contains(slot)) return null;
  final eatenNames = <String>{
    for (final meal in alreadyEaten) _nameKey(meal.result.mealName),
  };
  _Candidate? best;
  for (final recipe in recipes) {
    if (!recipe.matchesDiet(diet) || !recipeSuitsSlot(recipe, slot)) continue;
    final portion = _loggedPortion(recipe, 1);
    if (portion == null ||
        portion.kcal <= 0 ||
        portion.kcal > remainingKcal ||
        eatenNames.contains(portion.nameKey)) {
      continue;
    }
    final candidate = _Candidate(recipe, portion.kcal, portion.proteinG);
    if (best == null || candidate.ranksBefore(best)) best = candidate;
  }
  if (best == null) return null;
  return RecipePick(
    recipe: best.recipe,
    slot: slot,
    source: RecipePickSource.suggested,
    servings: 1,
    kcal: best.kcal,
    proteinG: best.proteinG.round(),
    remainingKcalBefore: remainingKcal,
  );
}

final class _Candidate {
  const _Candidate(this.recipe, this.kcal, this.proteinG);

  final FitnessRecipe recipe;
  final int kcal;
  final double proteinG;

  bool ranksBefore(_Candidate other) {
    if (proteinG != other.proteinG) return proteinG > other.proteinG;
    if (kcal != other.kcal) return kcal < other.kcal;
    return recipe.slug.compareTo(other.recipe.slug) < 0;
  }
}

/// What logging [servings] of [recipe] would record, or null when the recipe
/// cannot be logged (pending or out-of-range nutrition).
({int kcal, double proteinG, String nameKey})? _loggedPortion(
  FitnessRecipe recipe,
  double servings,
) {
  try {
    final result = recipe.toMealResultForServings(servings);
    return (
      kcal: result.caloriesKcal,
      // Parsed like the diary parses a logged meal (MacroProgress.add).
      proteinG: MacroProgress.empty.add(result).proteinG,
      nameKey: _nameKey(result.mealName),
    );
  } on FormatException {
    return null;
  }
}

String _nameKey(String name) => name.trim().toLowerCase();
