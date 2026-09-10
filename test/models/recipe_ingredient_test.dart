import 'dart:convert';

import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/open_food_facts_product_service.dart';
import 'package:eatova/src/services/sync_outbox.dart';
import 'package:flutter_test/flutter_test.dart';

RecipeIngredient _ingredient({double? calories = 100, double? protein = 10}) =>
    RecipeIngredient(
      name: 'Ingredient',
      grams: 400,
      per100g: RecipeNutrition(
        caloriesKcal: calories,
        proteinG: protein,
        carbsG: 0,
        fatG: 2,
      ),
    );

FitnessRecipe _recipe(List<RecipeIngredient> ingredients) => FitnessRecipe(
  slug: 'user_snapshot',
  title: 'Batch',
  description: '',
  portion: '',
  ingredients: 'Legacy notes',
  preparation: '',
  professionalHint: '',
  imageAsset: 'local:photo.jpg',
  caloriesKcal: 999,
  proteinG: 999,
  carbsG: 999,
  fatG: 999,
  estimatedGrams: 999,
  categories: const ['Eigene'],
  userCreated: true,
  structuredIngredients: ingredients,
  batchServings: 4,
);

void main() {
  test('four portions and half consumed uses one eighth of direct total', () {
    final recipe = _recipe([_ingredient(), _ingredient(calories: 200)]);
    final calculation = recipe.calculationForServings(0.5);
    expect(calculation.nutrition.caloriesKcal, 150);
    expect(calculation.nutrition.proteinG, 10);
    final meal = recipe.toMealResultForServings(0.5);
    expect(meal.caloriesKcal, 150);
    expect(meal.protein, '10 g');
    expect(meal.carbs, '0 g');
    expect(meal.estimatedGrams, 0, reason: 'Raw weight is not cooked yield');
    expect(meal.kcalPer100G, 0);
  });

  test(
    'unknown values keep known subtotal but cannot claim complete nutrition',
    () {
      final recipe = _recipe([_ingredient(), _ingredient(protein: null)]);
      final calculation = recipe.calculationForServings(0.5);
      expect(calculation.nutrition.proteinG, isNull);
      expect(calculation.knownNutrition.proteinG, 5);
      expect(calculation.isComplete, isFalse);
      expect(recipe.toMealResultForServings(0.5).protein, '-');
      expect(recipe.toMealResultForServings(0.5).carbs, '0 g');
      expect(
        () => _recipe([_ingredient(calories: null)]).toMealResult(),
        throwsFormatException,
      );
      expect(
        _recipe([_ingredient(calories: 0)]).toMealResult().explicitZeroKcal,
        isTrue,
      );
    },
  );

  test('ingredient snapshots do not mutate already logged meals', () {
    final original = _recipe([_ingredient()]);
    final logged = original.toMealResultForServings(0.5);
    final changed = _recipe([_ingredient(calories: 500)]);
    expect(changed.toMealResultForServings(0.5).caloriesKcal, 250);
    expect(logged.caloriesKcal, 50);
  });

  test(
    'row, cache and outbox preserve exact ingredients and batch servings',
    () async {
      final original = _recipe([_ingredient(protein: null)]);
      final row =
          jsonDecode(jsonEncode(original.toRow())) as Map<String, dynamic>;
      final restored = FitnessRecipe.fromRow(row);
      expect(restored.toRow(), original.toRow());
      expect(restored.structuredIngredients.first.per100g.proteinG, isNull);
      expect(
        () => restored.structuredIngredients.clear(),
        throwsUnsupportedError,
      );
      expect(SyncOp.recipeUpsert(original).recipe!.toRow(), original.toRow());
      final storage = InMemoryKeyValueStore();
      final cache = LocalCache(storage, 'owner');
      await cache.writeUserRecipes([original]);
      expect((await cache.readUserRecipes())!.single.toRow(), original.toRow());
      expect(
        await LocalCache(storage, 'another-owner').readUserRecipes(),
        isNull,
      );
    },
  );

  test('legacy servings reject overflow without silently capping totals', () {
    final legacy = _recipe([]);
    expect(legacy.canLogServings(1), isTrue);
    expect(legacy.canLogServings(2), isFalse);
    expect(() => legacy.toMealResultForServings(2), throwsFormatException);
    final energy = legacy.copyWith(proteinG: 0, carbsG: 0, fatG: 0);
    expect(() => energy.toMealResultForServings(11), throwsFormatException);
    expect(_recipe([_ingredient(protein: null)]).canLogServings(0.5), isTrue);
    expect(_recipe([_ingredient(calories: null)]).canLogServings(0.5), isFalse);
  });

  test('legacy rows remain manual per-serving recipes', () {
    final row = _recipe([]).toRow()
      ..remove('structured_ingredients')
      ..remove('batch_servings');
    final legacy = FitnessRecipe.fromRow(row);
    expect(legacy.hasStructuredIngredients, isFalse);
    expect(legacy.batchServings, 1);
    expect(legacy.toMealResult().caloriesKcal, 999);
    expect(legacy.toMealResultForServings(0.5).caloriesKcal, 500);
  });

  test(
    'aggregate per-serving overflow fails before persistence and logging',
    () {
      final huge = _recipe(
        List.generate(100, (_) => _ingredient(calories: 900)),
      );
      expect(huge.calculationForServings(1).fitsStorageLimits, isFalse);
      expect(huge.toRow, throwsFormatException);
      expect(huge.toMealResult, throwsFormatException);
      final copy = _recipe([_ingredient()]).copyWith(title: 'Edited');
      expect(copy.batchServings, 4);
      expect(copy.structuredIngredients.single.grams, 400);
      expect(copy.imageAsset, 'local:photo.jpg');
      expect(copy.toRow()['calories_kcal'], 100);
      expect(copy.toRow()['estimated_g'], 0);
    },
  );

  test(
    'numeric boundaries, malformed shapes and unsupported sources fail closed',
    () {
      for (final value in [double.nan, double.infinity, -1.0, 0.0, 100.1]) {
        expect(() => validateRecipeServings(value), throwsFormatException);
      }
      for (final value in [
        double.nan,
        double.infinity,
        -1,
        0,
        10001,
        '100',
        true,
      ]) {
        final json = _ingredient().toJson()..['grams'] = value;
        expect(() => RecipeIngredient.fromJson(json), throwsFormatException);
      }
      for (final value in [-1, 901, double.nan, '100', true]) {
        expect(
          () => RecipeNutrition.fromJson({'calories_kcal': value}),
          throwsFormatException,
        );
      }
      for (final raw in [
        false,
        {},
        [false],
        List.filled(101, _ingredient().toJson()),
      ]) {
        expect(() => RecipeIngredient.listFromJson(raw), throwsFormatException);
      }
      for (final patch in [
        {'source': 'ai'},
        {'name': ''},
        {'name': 'a\nname'},
        {'product_code': '../private'},
        {'other': 1},
        {'per_100g': false},
        {'source': 'manual', 'product_code': '123'},
      ]) {
        expect(
          () =>
              RecipeIngredient.fromJson({..._ingredient().toJson(), ...patch}),
          throwsFormatException,
        );
      }
      expect(
        () => FitnessRecipe.fromRow({
          ..._recipe([]).toRow(),
          'batch_servings': null,
        }),
        throwsFormatException,
      );
      expect(
        () => FitnessRecipe.fromRow({
          ..._recipe([]).toRow(),
          'structured_ingredients': null,
        }),
        throwsFormatException,
      );
      expect(
        () =>
            _recipe([_ingredient(calories: 900)]).toMealResultForServings(100),
        throwsFormatException,
      );
    },
  );

  test(
    'product snapshot retains per100g precision and unknown versus zero',
    () {
      final product = ProductSearchResult.fromOpenFoodFacts({
        'code': '1234',
        'product_name': 'Test',
        'serving_quantity': 7,
        'nutriments': {
          'energy-kcal_100g': 321.7,
          'proteins_100g': 12.345,
          'fat_100g': 0,
        },
      });
      expect(product.ingredientNutritionPer100g!.caloriesKcal, 321.7);
      expect(product.ingredientNutritionPer100g!.proteinG, 12.345);
      expect(product.ingredientNutritionPer100g!.carbsG, isNull);
      expect(product.ingredientNutritionPer100g!.fatG, 0);
      final missing = ProductSearchResult.fromOpenFoodFacts({'code': '1'});
      expect(missing.ingredientNutritionPer100g!.caloriesKcal, isNull);
      expect(parseRecipeServings('0,5'), 0.5);
      expect(parseRecipeServings('NaN'), isNull);
      expect(parseRecipeServings(''), isNull);
    },
  );
}
