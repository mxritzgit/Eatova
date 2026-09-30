// Shared fixtures of the Recipes tab redesign (Task 4): the design scenario
// (Mon 2026-09-28, a 2,123 kcal goal, 1,221 kcal logged, dinner open) and
// three own photo-less recipes named like the design's shelf cards.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/local_day.dart';

import '../flows/flow_test_helpers.dart' show storeOf;
import 'design_capture.dart';
import 'harness.dart';

/// The design scenario's daily goals.
const designProfile = UserProfile(
  dailyKcalGoal: 2123,
  proteinGoalG: 162,
  carbsGoalG: 222,
  fatGoalG: 57,
);

LoggedMeal _meal(
  String id,
  DateTime at,
  int kcal,
  String protein, {
  MealSlot? slot,
}) => LoggedMeal(
  id: id,
  loggedAt: at,
  localDay: localDayKey(at),
  forcedSlot: slot,
  result: MealAnalysisResult(
    mealName: 'Meal $id',
    caloriesKcal: kcal,
    estimatedGrams: 200,
    kcalPer100G: kcal / 2,
    protein: protein,
    carbs: '0 g',
    fat: '0 g',
    confidence: 'Hoch',
    portionNotes: '',
  ),
);

/// The design day: 401 + 597 + 223 = 1,221 kcal; dinner still open.
List<LoggedMeal> designDay() => [
  _meal('b1', DateTime(2026, 9, 28, 8, 10), 158, '25 g'),
  _meal('b2', DateTime(2026, 9, 28, 8, 12), 186, '7 g'),
  _meal('b3', DateTime(2026, 9, 28, 8, 11), 57, '1 g'),
  _meal('l1', DateTime(2026, 9, 28, 12, 45), 597, '50 g'),
  _meal('s1', DateTime(2026, 9, 28, 16, 20), 105, '1 g', slot: MealSlot.snack),
  _meal('s2', DateTime(2026, 9, 28, 16, 25), 118, '27 g', slot: MealSlot.snack),
];

FitnessRecipe _own(
  String slug,
  String title,
  int kcal,
  int protein, {
  List<String> categories = const <String>[],
}) => FitnessRecipe(
  slug: 'user_$slug',
  title: title,
  description: '',
  portion: '1 bowl',
  ingredients: '',
  preparation: '',
  professionalHint: '',
  imageAsset: '',
  caloriesKcal: kcal,
  proteinG: protein,
  carbsG: 30,
  fatG: 12,
  estimatedGrams: 350,
  categories: categories,
  userCreated: true,
);

/// The design's shelf cards, as own recipes without photos. Saved in reverse:
/// the store puts the newest first.
final designOwnRecipes = <FitnessRecipe>[
  _own('soup', 'Chicken Lentil Soup', 420, 38),
  _own('poke', 'Salmon & Greens Poke', 480, 36, categories: ['Fisch']),
  _own('yogurt', 'Greek Yogurt Berry Bowl', 380, 32),
];

/// Mounts the real home page at the design geometry, seeds the design
/// scenario ([profile], [meals], by default [designDay]; the own recipes when
/// [ownRecipes]) and opens Recipes.
Future<HomeStore> pumpDesignRecipes(
  WidgetTester tester, {
  UserProfile profile = designProfile,
  List<LoggedMeal>? meals,
  bool ownRecipes = true,
  HealthService? health,
}) async {
  pinDesignViewport(tester);
  await tester.pumpWidget(
    designCaptureBoundary(
      localizedApp(
        EatovaHomePage(healthService: health),
        locale: const Locale('en'),
        safeArea: false,
        scaffold: false,
      ),
    ),
  );
  await tester.pumpAndSettle();
  final store = storeOf(tester)
    ..profile = profile
    ..loggedMeals = meals ?? designDay();
  if (ownRecipes) {
    for (final recipe in designOwnRecipes) {
      await store.saveUserRecipe(recipe);
    }
  }
  await tester.tap(find.byKey(const ValueKey('nav-Rezepte')));
  await tester.pumpAndSettle();
  return store;
}
