// The Recipes tab's "High protein, under 500 kcal" shelf (dark redesign,
// Task 4): which recipes qualify, and how the shelf orders and caps them.

import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/recipe_shelf.dart';
import 'package:eatova/src/models/user_profile.dart';

FitnessRecipe _own(
  String slug, {
  int kcal = 420,
  int protein = 38,
  List<String> categories = const <String>[],
  List<RecipeIngredient> ingredients = const <RecipeIngredient>[],
}) => FitnessRecipe(
  slug: 'user_$slug',
  title: slug,
  description: '',
  portion: '',
  ingredients: '',
  preparation: '',
  professionalHint: '',
  imageAsset: '',
  caloriesKcal: kcal,
  proteinG: protein,
  carbsG: 30,
  fatG: 10,
  estimatedGrams: 300,
  categories: categories,
  userCreated: true,
  structuredIngredients: ingredients,
);

final _day = DateTime(2026, 9, 28, 18, 30);

void main() {
  group('isLeanHighProtein', () {
    test('the German catalog has exactly three shelf recipes', () {
      final lean = recipeCatalogDe
          .where(isLeanHighProtein)
          .map((r) => r.slug)
          .toSet();
      expect(lean, {
        'overnight_oats_mit_skyr_and_banane',
        'skyr_bowl_mit_beeren_and_granola',
        'hahnchen_caesar_salat',
      });
      // Both catalogs carry the same numbers.
      expect(
        recipeCatalogEn.where(isLeanHighProtein).map((r) => r.slug).toSet(),
        lean,
      );
    });

    test('"under 500" excludes 500 itself', () {
      expect(isLeanHighProtein(_own('a', kcal: 499, protein: 30)), isTrue);
      expect(isLeanHighProtein(_own('b', kcal: 500, protein: 37)), isFalse);
      // The catalog's 500 kcal pancakes are the real boundary case.
      final pancakes = recipeCatalogDe.firstWhere(
        (r) => r.slug == 'protein_pancakes_mit_beeren',
      );
      expect(pancakes.caloriesKcal, 500);
      expect(isLeanHighProtein(pancakes), isFalse);
    });

    test('protein needs the HighProteinRule minimum of 30 g', () {
      expect(isLeanHighProtein(_own('a', protein: 30)), isTrue);
      expect(isLeanHighProtein(_own('b', protein: 29)), isFalse);
    });

    test('own recipes qualify by their numbers, not by a tag', () {
      final untagged = _own('plain', kcal: 380, protein: 32);
      expect(untagged.categories, isEmpty);
      expect(isLeanHighProtein(untagged), isTrue);
    });

    test('unknown or zero energy never qualifies', () {
      expect(isLeanHighProtein(_own('zero', kcal: 0, protein: 40)), isFalse);
      final pending = _own(
        'pending',
        categories: const <String>[recipeNutritionPendingCategory],
      );
      expect(pending.hasPendingNutrition, isTrue);
      expect(isLeanHighProtein(pending), isFalse);
    });
  });

  group('leanHighProteinShelf', () {
    final soup = _own('soup');
    final poke = _own('poke', categories: const <String>['Fisch']);
    final heavy = _own('heavy', kcal: 650, protein: 50);

    test('own hits first in list order, then the catalog, capped', () {
      final shelf = leanHighProteinShelf(<FitnessRecipe>[
        soup,
        heavy,
        poke,
        ...recipeCatalogDe,
      ], now: _day);
      expect(shelf.take(2), <FitnessRecipe>[soup, poke]);
      expect(shelf, isNot(contains(heavy)));
      expect(
        shelf.skip(2).map((r) => r.slug).toSet(),
        recipeCatalogDe.where(isLeanHighProtein).map((r) => r.slug).toSet(),
      );

      final capped = leanHighProteinShelf(
        <FitnessRecipe>[
          for (var i = 0; i < 9; i++) _own('own$i'),
          ...recipeCatalogDe,
        ],
        now: _day,
        count: leanShelfCount,
      );
      expect(capped, hasLength(leanShelfCount));
      expect(capped.every((r) => r.userCreated), isTrue);
    });

    test('the catalog part rotates with the calendar day', () {
      final catalogHits = recipeCatalogDe
          .where(isLeanHighProtein)
          .toList(growable: false);
      final day1 = leanHighProteinShelf(recipeCatalogDe, now: _day);
      final day2 = leanHighProteinShelf(
        recipeCatalogDe,
        now: _day.add(const Duration(days: 1)),
      );
      expect(day1, rotatedRecommendations(catalogHits, _day, count: 3));
      expect(day2.first.slug, isNot(day1.first.slug));
      expect(day2.toSet(), day1.toSet());
    });

    test('the diet filter applies; own recipes always pass it', () {
      final vegan = leanHighProteinShelf(
        <FitnessRecipe>[soup, ...recipeCatalogDe],
        now: _day,
        diet: DietPreference.vegan,
      );
      expect(vegan, <FitnessRecipe>[soup]);

      final vegetarian = leanHighProteinShelf(
        recipeCatalogDe,
        now: _day,
        diet: DietPreference.vegetarian,
      );
      expect(vegetarian.map((r) => r.slug).toSet(), {
        'overnight_oats_mit_skyr_and_banane',
        'skyr_bowl_mit_beeren_and_granola',
      });
    });

    test('the hero recipe is left out', () {
      final shelf = leanHighProteinShelf(
        <FitnessRecipe>[soup, poke],
        now: _day,
        excludeSlug: soup.slug,
      );
      expect(shelf, <FitnessRecipe>[poke]);
    });

    test('empty when nothing qualifies', () {
      expect(leanHighProteinShelf(<FitnessRecipe>[heavy], now: _day), isEmpty);
      expect(
        leanHighProteinShelf(<FitnessRecipe>[soup], now: _day, count: 0),
        isEmpty,
      );
    });
  });

  test('leanHighProteinRecipes is the complete "See all" set', () {
    final all = leanHighProteinRecipes(<FitnessRecipe>[
      _own('soup'),
      ...recipeCatalogDe,
    ]);
    expect(all.first.slug, 'user_soup');
    expect(all, hasLength(4));
  });
}
