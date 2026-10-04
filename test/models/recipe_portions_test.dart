import 'dart:convert';
import 'package:eatova/src/models/export_document.dart';
import 'package:eatova/src/models/planned_meal.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/shopping_list.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/recipe_import_result.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> portionCandidate({
  String basis = 'per_recipe',
  double? servings = 4,
}) => {
  'id': 'mince',
  'title': 'Mince pockets',
  'ingredients': '800 g mince',
  'preparation': 'Bake at 180 C for 20 minutes.',
  'portion': '4 portions',
  'nutrition_estimated': false,
  'nutrition_basis': 'per_serving',
  'ingredients_basis': basis,
  'servings': servings,
  'calories_kcal': 350,
  'protein_g': 30,
  'carbs_g': 25,
  'fat_g': 10,
};
FitnessRecipe importedPortions(Map<String, dynamic> json) {
  final candidate = RecipeImportCandidate.fromJson(json);
  return candidate.toRecipe(
    slug: candidate.stableSlug(),
    sourceLabel: 'Source',
  );
}

void main() {
  test('source batch of 800 g for four displays 200 g for one serving', () {
    final recipe = importedPortions(portionCandidate());
    expect(recipe.displayIngredients(enL10n), '200 g mince');
    expect(recipe.ingredients, '800 g mince');
    expect(recipe.toMealResult().protein, '30 g');
    expect(
      FitnessRecipe.fromRow(recipe.toRow()).displayIngredients(enL10n),
      '200 g mince',
    );
  });

  test(
    'consumed servings multiply canonical nutrition and projected quantities once',
    () {
      final recipe = importedPortions(portionCandidate());
      expect(recipe.displayIngredients(enL10n, servings: 2), '400 g mince');
      expect(recipe.displayIngredients(enL10n, servings: .5), '100 g mince');
      expect(recipe.toMealResultForServings(2).caloriesKcal, 700);
      expect(recipe.toMealResultForServings(2).protein, '60 g');
      expect(recipe.batchServings, 4);
      expect(recipe.displayCategories, ['Eigene']);
    },
  );

  test(
    'per-serving ingredients never divide by the independent recipe yield',
    () {
      final recipe = importedPortions({
        ...portionCandidate(basis: 'per_serving'),
        'ingredients': '200 g mince',
      });
      expect(recipe.displayIngredients(enL10n), '200 g mince');
      expect(recipe.displayIngredients(enL10n, servings: 2), '400 g mince');
      expect(recipe.toMealResult().caloriesKcal, 350);
    },
  );

  for (final basis in ['unspecified', 'absent', 'per_recipe_without_yield']) {
    test('$basis remains original despite per-serving nutrition', () {
      final json = portionCandidate(
        basis: basis == 'per_recipe_without_yield'
            ? 'per_recipe'
            : 'unspecified',
      );
      if (basis == 'absent') json.remove('ingredients_basis');
      if (basis == 'per_recipe_without_yield') json['servings'] = null;
      final recipe = importedPortions(json);
      expect(recipe.displayIngredients(enL10n, servings: 2), '800 g mince');
      expect(recipe.ingredientProjectionForServings(2).isScaled, isFalse);
      expect(
        recipe.ingredientQuantityHint(enL10n),
        enL10n.recipeIngredientsOriginalUnknown,
      );
    });
  }

  test(
    'legacy saved imports retain source quantities and visible uncertainty',
    () {
      final row = importedPortions(portionCandidate()).toRow();
      row['categories'] = ['Eigene'];
      final legacy = FitnessRecipe.fromRow(row);
      expect(legacy.batchServings, 4);
      expect(legacy.displayIngredients(enL10n), '800 g mince');
      expect(
        legacy.ingredientQuantityHint(enL10n),
        enL10n.recipeIngredientsOriginalUnknown,
      );
    },
  );

  test('conflicting persisted ingredient markers fail closed', () {
    final recipe = importedPortions(portionCandidate()).copyWith(
      categories: [
        '${recipeIngredientsBasisPrefix}per_recipe',
        '${recipeIngredientsBasisPrefix}per_serving',
      ],
    );
    expect(recipe.ingredientProjectionForServings(1).isScaled, isFalse);
  });

  test('unknown nutrition stays unknown while proven ingredients scale', () {
    final recipe = importedPortions({...portionCandidate(), 'protein_g': null});
    expect(recipe.displayIngredients(enL10n), '200 g mince');
    expect(recipe.displayNutrition.proteinG, isNull);
    expect(recipe.displayNutrition.caloriesKcal, 350);
    expect(recipe.canLogServings(1), isFalse);
  });

  test(
    'nutrition confirmation does not change ingredient basis or batch yield',
    () {
      final recipe = importedPortions({
        ...portionCandidate(),
        'nutrition_basis': 'unspecified',
      });
      expect(recipe.canLogServings(1), isFalse);
      final confirmed = recipe.withConfirmedNutritionBasis(2);
      expect(confirmed.batchServings, 4);
      expect(confirmed.displayIngredients(enL10n), '200 g mince');
      expect(confirmed.toMealResult().caloriesKcal, 175);
    },
  );

  test(
    'draft edits keep source yield but invalidate basis only for ingredient/portion edits',
    () {
      final candidate = RecipeImportCandidate.fromJson(portionCandidate());
      expect(
        candidate.copyWith(title: 'Renamed').ingredientsBasis,
        RecipeIngredientsBasis.perRecipe,
      );
      for (final edited in [
        candidate.copyWith(ingredients: '200 g mince', clearNutrition: true),
        candidate.copyWith(portion: 'One portion', clearNutrition: true),
      ]) {
        expect(edited.servings, 4);
        expect(edited.ingredientsBasis, RecipeIngredientsBasis.unspecified);
        expect(edited.hasNutrition, isFalse);
      }
    },
  );

  test('meal-plan snapshot and shopping use the same requested quantity', () {
    final day = DateTime(2026, 9, 21);
    final recipe = importedPortions(portionCandidate());
    final plan = PlannedMeal.create(
      recipe: recipe,
      day: day,
      slot: MealSlot.lunch,
      servings: 2,
    );
    final restored = PlannedMeal.fromJson(plan.toJson());
    expect(restored.recipe.ingredients, '800 g mince');
    final item = buildShoppingList([restored], day).single;
    expect(item.name, '400 g mince');
    expect(item.originalQuantities, isFalse);
    final uncertain = PlannedMeal.create(
      recipe: importedPortions(portionCandidate(basis: 'unspecified')),
      day: day,
      slot: MealSlot.lunch,
      servings: 2,
    );
    expect(
      buildShoppingList([uncertain], day).single.originalQuantities,
      isTrue,
    );
    expect(buildShoppingList([uncertain], day).single.name, '800 g mince');
  });

  test(
    'German display uses a decimal comma while shopping ids stay locale-neutral',
    () {
      final day = DateTime(2026, 9, 21);
      final recipe = importedPortions({
        ...portionCandidate(),
        'ingredients': '½ Zwiebel\n1 kg Kartoffeln',
      });
      // A dot after zero reads as a thousands separator in German.
      expect(
        recipe.displayIngredients(deL10n),
        '0,125 Zwiebel\n0,25 kg Kartoffeln',
      );
      expect(
        recipe.displayIngredients(enL10n),
        '0.125 Zwiebel\n0.25 kg Kartoffeln',
      );
      expect(recipe.ingredients, '½ Zwiebel\n1 kg Kartoffeln');
      final plan = PlannedMeal.create(
        recipe: recipe,
        day: day,
        slot: MealSlot.lunch,
        servings: 1,
      );
      final german = buildShoppingList([plan], day, decimalSeparator: ',');
      final english = buildShoppingList([plan], day);
      expect(german.single.name, '0,125 Zwiebel\n0,25 kg Kartoffeln');
      expect(english.single.name, '0.125 Zwiebel\n0.25 kg Kartoffeln');
      // Checked items are keyed by id and must survive a language switch.
      expect(german.single.id, english.single.id);
    },
  );

  test(
    'readable export adds context without mutating lossless JSON or source quantities',
    () {
      final row = importedPortions(portionCandidate()).toRow();
      final raw = {
        'user_recipes': [row],
      };
      final doc = ExportDocument.parse(jsonEncode(raw));
      expect(jsonDecode(doc.json), raw);
      final report = doc.report('Export', (key) => key);
      expect(report, contains('800 g mince'));
      expect(report, contains('200 g mince'));
      expect(doc.sections.single.csv, contains('200 g mince'));
      expect(row.containsKey('eatova_serving_projection'), isFalse);
      final unknown = ExportDocument.parse(
        jsonEncode({
          'user_recipes': [
            importedPortions(portionCandidate(basis: 'unspecified')).toRow(),
          ],
        }),
      );
      expect(
        unknown
            .sections
            .single
            .records
            .single['eatova_serving_projection']['ingredients_per_serving'],
        isNull,
      );
    },
  );

  test('partial invalid and collision export rows survive unchanged', () {
    final valid = importedPortions(portionCandidate()).toRow();
    for (final row in [
      {...valid}..remove('batch_servings'),
      {...valid}..remove('protein_g'),
      {...valid, 'protein_g': 'not numeric'},
      {...valid, 'categories': 'Eigene'},
      {...valid, 'batch_servings': -2},
      {
        ...valid,
        'eatova_serving_projection': {'original': true},
      },
      {'ingredients': '800 g mince'},
    ]) {
      final doc = ExportDocument.parse(
        jsonEncode({
          'user_recipes': [row],
        }),
      );
      expect(doc.sections.single.records.single, row);
    }
  });

  test(
    'non-imported catalog and structured recipes preserve existing behavior',
    () {
      for (final recipe in recipeCatalogDe) {
        expect(recipe.displayIngredients(deL10n), recipe.ingredients);
      }
      final recipe = importedPortions(
        portionCandidate(),
      ).copyWith(slug: 'user_regular', categories: ['Eigene']);
      expect(recipe.hasImportedIngredientContext, isFalse);
      expect(recipe.displayIngredients(enL10n), '800 g mince');
    },
  );

  test('invalid wire basis and yield are rejected', () {
    expect(
      () => RecipeImportCandidate.fromJson(portionCandidate(basis: 'per_100g')),
      throwsFormatException,
    );
    for (final yield in [-1, 0, 101, double.nan, '4']) {
      expect(
        () => RecipeImportCandidate.fromJson({
          ...portionCandidate(),
          'servings': yield,
        }),
        throwsFormatException,
      );
    }
  });

  final scalable = <String, String>{
    '800g mince': '200g mince',
    '800 g mince\nSalt': '200 g mince\nSalt',
    '• 800 g mince': '• 200 g mince',
    'ca. 800 g mince': 'ca. 200 g mince',
    '400–800 g mince': '100–200 g mince',
    '1/2 kg mince': '0.125 kg mince',
    '1 1/2 kg mince': '0.375 kg mince',
    '½ kg mince': '0.125 kg mince',
    '1½ kg mince': '0.375 kg mince',
    '1,5 kg mince': '0.375 kg mince',
    '800 g 5% mince': '200 g 5% mince',
    '4 eggs': '1 eggs',
    '• 4–8 eggs': '• 1–2 eggs',
    '8 Tortillas': '2 Tortillas',
    '4 Eier, getrennt': '1 Eier, getrennt',
    '2 cups flour': '0.5 cups flour',
    '0 g salt': '0 g salt',
    'Füllung:\n800 g mince\nSalz und Pfeffer nach Geschmack':
        'Füllung:\n200 g mince\nSalz und Pfeffer nach Geschmack',
    '800 g mince\n\n* Salt and pepper to taste':
        '200 g mince\n\n* Salt and pepper to taste',
  };
  for (final entry in scalable.entries) {
    test('bounded quantity projection: ${entry.key}', () {
      final result = projectRecipeIngredients(
        entry.key,
        basis: RecipeIngredientsBasis.perRecipe,
        batchServings: 4,
      );
      expect(result.text, entry.value);
      expect(result.isScaled, isTrue);
    });
  }
  for (final text in [
    '800 g mince\n2 x 400 g tomatoes',
    '800 g mince, 200 g cheese',
    '180 C oven',
    '٨٠٠ g mince',
    '８００ g mince',
    'four eggs',
    'eine Zwiebel',
    'a handful of basil',
    '800 g mince\nthree tomatoes',
    '800 g mince\nhundert Gramm Tomaten',
    '800 g mince\nzweihundert Gramm Tomaten',
    '800 g mince\neleven eggs',
    '800 g mince\nhundred grams tomatoes',
    '800 g mince\nein Dutzend Eier',
    '800 g mince\nun puñado de nueces',
    '20 minutes',
    '5% fat',
    '7 spice mix',
    'B12 vitamin mix',
    '1,000 g mince',
    '1.000 g mince',
    '1/0 kg mince',
    '800 g mince (cook 20 minutes)',
    '400 g to 800 g mince',
    '800-400 g mince',
    '800 g',
    '1e3 g mince',
    '100 g B12 powder',
    '-200 g mince',
    '0.0001 g spice',
    '800 g mince\n2 tomatoes (400 g)',
  ]) {
    test('ambiguous quantities remain entirely original: $text', () {
      final result = projectRecipeIngredients(
        text,
        basis: RecipeIngredientsBasis.perRecipe,
        batchServings: 4,
      );
      expect(result.text, text);
      expect(result.isScaled, isFalse);
    });
  }
}
