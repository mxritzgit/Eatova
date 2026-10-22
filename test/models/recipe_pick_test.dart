import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/planned_meal.dart';
import 'package:eatova/src/models/recipe_pick.dart';
import 'package:eatova/src/models/user_profile.dart';

// "Tonight's pick" (Task 7): next open main meal, the plan first, else a
// fitting recipe with the most protein. Near-equal ones (within
// pickProteinTolerance of the best) rotate by calendar day (2026-10-22). The
// design scenario (18:30, dinner open, 902 kcal left) picks one of the
// high-protein dinners around the turkey steak's 58 g.

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
    test('design scenario: a high-protein dinner that fits, and what it '
        'leaves', () {
      final picks = [
        for (final catalog in [recipeCatalogEn, recipeCatalogDe])
          pickRecipeForNextMeal(
            now: evening,
            todaysMeals: [breakfastEaten, lunchEaten],
            remainingKcal: 902,
            recipes: catalog,
          )!,
      ];
      for (final pick in picks) {
        expect(pick.slot, MealSlot.dinner);
        expect(pick.source, RecipePickSource.suggested);
        // The turkey steak's 58 g are the catalog's best at 902 kcal.
        expect(
          pick.proteinG,
          greaterThanOrEqualTo(58 * (1 - pickProteinTolerance)),
        );
        expect(pick.fits, isTrue);
        expect(pick.kcalLeftAfter, 902 - pick.kcal!);
        expect(pick.servings, 1);
        expect(pick.plannedMeal, isNull);
      }
      // Both languages pick the same dish.
      expect(picks.first.recipe.slug, picks.last.recipe.slug);
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
    });

    test('diet preference filters before ranking', () {
      final vegan = pickRecipeForNextMeal(
        now: evening,
        todaysMeals: const [],
        remainingKcal: 902,
        recipes: recipeCatalogDe,
        diet: DietPreference.vegan,
      )!;
      expect(vegan.recipe.matchesDiet(DietPreference.vegan), isTrue);
      final pesc = pickRecipeForNextMeal(
        now: evening,
        todaysMeals: const [],
        remainingKcal: 902,
        recipes: recipeCatalogDe,
        diet: DietPreference.pescetarian,
      )!;
      expect(pesc.recipe.matchesDiet(DietPreference.pescetarian), isTrue);
      expect(pesc.recipe.categories, contains('Fisch'));
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
    test('near-equal picks rotate by calendar day and stay all day; a '
        'clearly leaner one never joins', () {
      final picks = [
        _recipe('b_heavy', kcal: 600, protein: 50),
        _recipe('c_close', kcal: 450, protein: 47),
        _recipe('a_light', kcal: 450, protein: 50),
        _recipe('z_lean', kcal: 300, protein: 30),
      ];
      String pickAt(DateTime at, List<FitnessRecipe> recipes) =>
          pickRecipeForSlot(
            slot: MealSlot.dinner,
            day: at,
            remainingKcal: 800,
            recipes: recipes,
          )!.recipe.slug;
      final seen = <String>[];
      // Across the October DST switch.
      for (var i = 0; i < 9; i++) {
        final day = DateTime(2026, 10, 21 + i);
        final morning = pickAt(day.add(const Duration(hours: 7)), picks);
        expect(
          pickAt(day.add(const Duration(hours: 19)), picks),
          morning,
          reason: 'the same all day',
        );
        // Order of the input does not matter.
        expect(pickAt(day, picks.reversed.toList()), morning);
        if (seen.isNotEmpty) expect(morning, isNot(seen.last));
        seen.add(morning);
      }
      expect(seen.toSet(), {'a_light', 'b_heavy', 'c_close'});
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

    test('a snack is never the lunch or dinner pick', () {
      // 250 kcal left: only the catalog's snacks fit, the cottage cheese
      // with 26 g protein first; a main meal pick stays empty instead.
      for (final slot in [MealSlot.lunch, MealSlot.dinner]) {
        expect(
          pickRecipeForSlot(
            slot: slot,
            day: evening,
            remainingKcal: 250,
            recipes: recipeCatalogDe,
          ),
          isNull,
          reason: slot.name,
        );
      }
      final snack = recipeCatalogDe.firstWhere(
        (r) => r.categories.contains(snackCategory),
      );
      expect(recipeSuitsSlot(snack, MealSlot.snack), isTrue);
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
        expect(
          pick.recipe.slug,
          pickRecipeForNextMeal(
            now: evening,
            todaysMeals: const [],
            remainingKcal: 902,
            recipes: recipeCatalogDe,
          )!.recipe.slug,
        );
      },
    );
  });
}
