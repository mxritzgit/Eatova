import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/logged_meal.dart';
import '../../models/meal_analysis_result.dart';
import '../../models/recipe_pick.dart';
import '../../screens/recipes/recipes_screen.dart' show RecipeDetailScreen;
import '../../services/meal_photo_input.dart';
import '../../services/open_food_facts_product_service.dart';
import '../common/persistence_action.dart';

// ---------------------------------------------------------------------------
// The two actions on a recipe pick (`HomeStore.nextMealPick`), shared by
// Today's "Tonight's pick", Food's "Fits tonight" row and the Recipes hero.
//
// Rule (controller ruling, 2026-09-29): a PLANNED pick is only ever logged
// through the meal-plan conversion (`HomeStore.eatPlannedMeal`): planned
// servings, one atomic write, the plan entry marked eaten. It never goes
// through the generic recipe add, which would log a second, one-serving row.
// ---------------------------------------------------------------------------

/// Logs a result into a slot on the shown day (the generic add path).
typedef RecipePickAdd =
    FutureOr<void> Function(MealAnalysisResult result, MealSlot slot);

/// Opens [pick].
///
/// - A suggestion opens its [RecipeDetailScreen]; adding there asks for the
///   slot and servings and logs through [addMeal].
/// - A planned meal opens the meal plan ([openMealPlan]), whose "Eat" action
///   is the plan conversion. The recipe detail's generic add cannot log the
///   planned servings, and a plan entry without loggable nutrition would be a
///   dead end there.
///
/// [isSessionCurrent] guards every write against an account change while the
/// detail is open; nothing opens once it is false.
void openRecipePick(
  BuildContext context,
  RecipePick pick, {
  required RecipePickAdd addMeal,
  required VoidCallback openMealPlan,
  bool Function()? isSessionCurrent,
  MealPhotoInput? photoInput,
  ProductLookupService? productService,
}) {
  if (isSessionCurrent?.call() == false) return;
  if (pick.source == RecipePickSource.planned) {
    openMealPlan();
    return;
  }
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => RecipeDetailScreen(
        recipe: pick.recipe,
        onAddMeal: (result, slot) async {
          if (isSessionCurrent?.call() == false) {
            throw StateError('Meal owner changed');
          }
          await addMeal(result, slot);
        },
        photoInput: photoInput,
        productService: productService,
        isSessionCurrent: isSessionCurrent,
      ),
    ),
  );
}

/// Logs [pick] in one tap, the one right way per source:
///
/// - planned: [eatPlannedMeal] with the plan entry's id (planned servings,
///   marks it eaten); without loggable nutrition it opens the meal plan
///   instead ([openMealPlan]) and logs nothing;
/// - suggested: [addMeal] with the pick's servings into the pick's slot.
///
/// Returns true when a meal was committed. A failed write shows the app's
/// "could not save" snack ([tryPersistChange]).
Future<bool> logRecipePick(
  BuildContext context,
  RecipePick pick, {
  required RecipePickAdd addMeal,
  required Future<void> Function(String plannedMealId) eatPlannedMeal,
  required VoidCallback openMealPlan,
  bool Function()? isSessionCurrent,
}) async {
  if (isSessionCurrent?.call() == false) return false;
  final planned = pick.plannedMeal;
  if (pick.source == RecipePickSource.planned && planned != null) {
    if (pick.kcal == null) {
      openMealPlan();
      return false;
    }
    return tryPersistChange(context, () => eatPlannedMeal(planned.id));
  }
  final result = pick.recipe.toMealResultForServings(
    pick.servings,
    context.l10n,
  );
  return tryPersistChange(context, () => addMeal(result, pick.slot));
}
