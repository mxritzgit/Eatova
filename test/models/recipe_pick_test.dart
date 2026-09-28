import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/planned_meal.dart';
import 'package:eatova/src/models/recipe_pick.dart';
import 'package:eatova/src/models/user_profile.dart';

// "Tonight's pick" (Task 7): next open main meal, the plan first, else the
// fitting recipe with the most protein. The design scenario (18:30, dinner
// open, 902 kcal left) must pick the turkey steak: 610 kcal, 58 g protein,
// leaving 292 kcal.

FitnessRecipe _recipe(
  String slug, {
  int kcal = 500,
  int protein = 40,
  List<String> categories = const ['Hauptgericht'],
  bool userCreated = false,
}) => FitnessRecipe(
  slug: slug,
  title: 'Recipe $slug',
  description: '',
  portion: '1 plate',
  ingredients: '',
  preparation: '',
  professionalHint: '',
  imageAsset: '',
  caloriesKcal: kcal,
  proteinG: protein,
  carbsG: 40,
  fatG: 15,
  estimatedGrams: 400,
  categories: categories,
  userCreated: userCreated,
);

LoggedMeal _eaten(String name, DateTime at, {MealSlot? slot}) => LoggedMeal(
  id: 'meal-$name-$at',
  loggedAt: at,
  forcedSlot: slot,
  result: MealAnalysisResult(
    mealName: name,
    caloriesKcal: 400,
    estimatedGrams: 300,
    kcalPer100G: 133,
    protein: '30 g',
    carbs: '40 g',
    fat: '10 g',
    confidence: 'Hoch',
    portionNotes: '',
  ),
);

void main() {
  final evening = DateTime(2026, 9, 28, 18, 30);
  final breakfastEaten = _eaten('Skyr', DateTime(2026, 9, 28, 8, 10));
  final lunchEaten = _eaten('Chicken rice', DateTime(2026, 9, 28, 12, 45));

  group('pickRecipeForNextMeal (catalog)', () {
    test('design scenario: turkey steak for dinner, 292 kcal left after', () {
      for (final catalog in [recipeCatalogEn, recipeCatalogDe]) {
        final pick = pickRecipeForNextMeal(
          now: evening,
          todaysMeals: [breakfastEaten, lunchEaten],
          remainingKcal: 902,
          recipes: catalog,
        )!;
        expect(pick.slot, MealSlot.dinner);
        expect(pick.source, RecipePickSource.suggested);
        expect(pick.recipe.slug, 'putensteak_mit_quinoa_and_ofengemuse');
        expect(pick.kcal, 610);
        expect(pick.proteinG, 58);
        expect(pick.fits, isTrue);
        expect(pick.kcalLeftAfter, 292);
        expect(pick.servings, 1);
        expect(pick.plannedMeal, isNull);
      }
      final en = pickRecipeForNextMeal(
        now: evening,
        todaysMeals: [breakfastEaten, lunchEaten],
        remainingKcal: 902,
        recipes: recipeCatalogEn,
      )!;
      expect(en.recipe.title, 'Turkey Steak with Quinoa & Roasted Vegetables');
    });

    test('never exceeds the remaining kcal', () {
      final pick = pickRecipeForNextMeal(
        now: evening,
        todaysMeals: [lunchEaten],
        remainingKcal: 500,
        recipes: recipeCatalogDe,
      )!;
      // 470 kcal, 50 g: the only main dish of the catalog at <= 500 kcal
      // with more protein than the fish plates.
      expect(pick.recipe.slug, 'hahnchen_caesar_salat');
      expect(pick.kcalLeftAfter, 30);
    });

    test('breakfast slot takes only breakfast dishes', () {
      final pick = pickRecipeForNextMeal(
        now: DateTime(2026, 9, 28, 7),
        todaysMeals: const [],
        remainingKcal: 2100,
        recipes: recipeCatalogDe,
      )!;
      expect(pick.slot, MealSlot.breakfast);
      expect(pick.recipe.categories, contains(breakfastCategory));
      expect(pick.recipe.slug, 'skyr_bowl_mit_beeren_and_granola'); // 38 g
    });

    test('diet preference filters before ranking', () {
      final vegan = pickRecipeForNextMeal(
        now: evening,
        todaysMeals: const [],
        remainingKcal: 902,
        recipes: recipeCatalogDe,
        diet: DietPreference.vegan,
      )!;
      expect(vegan.recipe.slug, 'tofu_mit_reis_and_edamame'); // 35 g vegan
      final pesc = pickRecipeForNextMeal(
        now: evening,
        todaysMeals: const [],
        remainingKcal: 902,
        recipes: recipeCatalogDe,
        diet: DietPreference.pescetarian,
      )!;
      expect(pesc.recipe.slug, 'thunfisch_mit_couscous_and_gemuse'); // 56 g
    });

    test(
      'null when nothing fits, no kcal are left, or no main meal is open',
      () {
        expect(
          pickRecipeForNextMeal(
            now: evening,
            todaysMeals: const [],
            remainingKcal: 300,
            recipes: recipeCatalogDe,
          ),
          isNull,
        );
        expect(
          pickRecipeForNextMeal(
            now: evening,
            todaysMeals: const [],
            remainingKcal: -120,
            recipes: recipeCatalogDe,
          ),
          isNull,
        );
        // 21:30 is snack time: no main meal left to pick for.
        expect(
          pickRecipeForNextMeal(
            now: DateTime(2026, 9, 28, 21, 30),
            todaysMeals: const [],
            remainingKcal: 900,
            recipes: recipeCatalogDe,
          ),
          isNull,
        );
        final dinner = _eaten('Pasta', DateTime(2026, 9, 28, 18));
        expect(
          pickRecipeForNextMeal(
            now: evening,
            todaysMeals: [dinner],
            remainingKcal: 900,
            recipes: recipeCatalogDe,
          ),
          isNull,
        );
        expect(
          pickRecipeForNextMeal(
            now: evening,
            todaysMeals: const [],
            remainingKcal: 900,
            recipes: const [],
          ),
          isNull,
        );
      },
    );
  });

  group('pickRecipeForSlot', () {
    test('ties: more protein, then fewer kcal, then slug', () {
      final picks = [
        _recipe('b_heavy', kcal: 600, protein: 50),
        _recipe('c_light', kcal: 450, protein: 50),
        _recipe('a_light', kcal: 450, protein: 50),
        _recipe('z_lean', kcal: 300, protein: 30),
      ];
      final pick = pickRecipeForSlot(
        slot: MealSlot.dinner,
        day: evening,
        remainingKcal: 800,
        recipes: picks,
      )!;
      expect(pick.recipe.slug, 'a_light');
      // Order of the input does not matter.
      expect(
        pickRecipeForSlot(
          slot: MealSlot.dinner,
          day: evening,
          remainingKcal: 800,
          recipes: picks.reversed.toList(),
        )!.recipe.slug,
        'a_light',
      );
    });

    test('own recipes compete, untagged ones count as main dishes', () {
      final own = _recipe(
        'user_1',
        kcal: 700,
        protein: 70,
        categories: const ['Eigene'],
        userCreated: true,
      );
      final pick = pickRecipeForSlot(
        slot: MealSlot.lunch,
        day: evening,
        remainingKcal: 900,
        recipes: [own, ...recipeCatalogDe],
      )!;
      expect(pick.recipe.slug, 'user_1');
      expect(
        pickRecipeForSlot(
          slot: MealSlot.breakfast,
          day: evening,
          remainingKcal: 900,
          recipes: [own],
        ),
        isNull,
      );
    });

    test('skips pending nutrition, zero kcal, and meals already eaten', () {
      final pending = _recipe(
        'user_pending',
        kcal: 500,
        protein: 90,
        categories: const [recipeNutritionPendingCategory],
        userCreated: true,
      );
      final zero = _recipe('zero', kcal: 0, protein: 80);
      final eatenAlready = _recipe('eaten', kcal: 500, protein: 70);
      final fallback = _recipe('fallback', kcal: 500, protein: 20);
      final pick = pickRecipeForSlot(
        slot: MealSlot.dinner,
        day: evening,
        remainingKcal: 900,
        recipes: [pending, zero, eatenAlready, fallback],
        alreadyEaten: [_eaten('  recipe EATEN ', DateTime(2026, 9, 28, 12))],
      )!;
      expect(pick.recipe.slug, 'fallback');
    });

    test('snacks never get a pick', () {
      expect(
        pickRecipeForSlot(
          slot: MealSlot.snack,
          day: evening,
          remainingKcal: 900,
          recipes: [_recipe('any', kcal: 100, protein: 10)],
        ),
        isNull,
      );
    });
  });

  group('meal plan comes first', () {
    PlannedMeal planned(
      FitnessRecipe recipe, {
      DateTime? day,
      MealSlot slot = MealSlot.dinner,
      double servings = 1,
    }) => PlannedMeal.create(
      recipe: recipe,
      day: day ?? evening,
      slot: slot,
      servings: servings,
    );

    test('a planned dinner wins over a better suggestion', () {
      final plan = planned(_recipe('planned', kcal: 520, protein: 20));
      final pick = pickRecipeForNextMeal(
        now: evening,
        todaysMeals: const [],
        remainingKcal: 902,
        recipes: recipeCatalogDe,
        plannedMeals: [plan],
      )!;
      expect(pick.source, RecipePickSource.planned);
      expect(pick.plannedMeal?.id, plan.id);
      expect(pick.recipe.slug, 'planned');
      expect(pick.kcal, 520);
      expect(pick.fits, isTrue);
      expect(pick.kcalLeftAfter, 382);
    });

    test('a planned meal is shown even when it does not fit', () {
      final plan = planned(_recipe('big', kcal: 600, protein: 40), servings: 2);
      final pick = pickRecipeForNextMeal(
        now: evening,
        todaysMeals: const [],
        remainingKcal: 902,
        recipes: const [],
        plannedMeals: [plan],
      )!;
      expect(pick.servings, 2);
      expect(pick.kcal, 1200);
      expect(pick.proteinG, 80);
      expect(pick.fits, isFalse);
      expect(pick.kcalLeftAfter, -298);
      // Planned also survives a day with nothing left.
      expect(
        pickRecipeForNextMeal(
          now: evening,
          todaysMeals: const [],
          remainingKcal: -50,
          recipes: const [],
          plannedMeals: [plan],
        )!.fits,
        isFalse,
      );
    });

    test(
      'plans for another day or slot, eaten or removed ones are ignored',
      () {
        final recipe = _recipe('planned', kcal: 520, protein: 20);
        final plans = [
          planned(recipe, day: DateTime(2026, 9, 29, 18)),
          planned(recipe, slot: MealSlot.lunch),
          planned(recipe).copyWith(eatenAt: evening),
          planned(recipe).copyWith(removed: true),
        ];
        final pick = pickRecipeForNextMeal(
          now: evening,
          todaysMeals: const [],
          remainingKcal: 902,
          recipes: recipeCatalogDe,
          plannedMeals: plans,
        )!;
        expect(pick.source, RecipePickSource.suggested);
        expect(pick.recipe.slug, 'putensteak_mit_quinoa_and_ofengemuse');
      },
    );
  });
}
