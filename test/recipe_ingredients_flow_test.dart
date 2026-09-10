import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/screens/recipes/recipes_screen.dart';
import 'package:eatova/src/services/sync_error_messages.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'recipe_edit_feature_test.dart' show original;
import 'support/harness.dart';

Future<void> tap(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> enter(WidgetTester tester, String key, String value) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.enterText(finder, value);
  await tester.pumpAndSettle();
}

FitnessRecipe batch({bool caloriesKnown = true, bool proteinKnown = true}) =>
    original.copyWith(
      title: 'Four servings',
      ingredients: '',
      structuredIngredients: [
        RecipeIngredient(
          name: 'Oats',
          grams: 400,
          per100g: RecipeNutrition(
            caloriesKcal: caloriesKnown ? 300 : null,
            proteinG: proteinKnown ? 20 : null,
            carbsG: 40,
            fatG: 10,
          ),
        ),
      ],
      batchServings: 4,
    );

void main() {
  testWidgets(
    'manual ingredients calculate four servings and persist on editor save',
    (tester) async {
      pinPhoneViewport(tester);
      FitnessRecipe? saved;
      await pumpLocalized(
        tester,
        RecipesScreen(
          onAddMeal: (_, _) {},
          onCreateRecipe: (recipe) async {
            saved = recipe;
            return SyncDelivery.delivered;
          },
        ),
        locale: const Locale('en'),
        safeArea: false,
      );
      await tap(tester, 'recipe-create-button');
      await enter(tester, 'recipe-create-name', 'Batch oats');
      await tap(tester, 'recipe-create-structured');
      await tap(tester, 'ingredient-add');
      await tap(tester, 'ingredient-manual');
      for (final entry in {
        0: 'Oats',
        1: '400',
        2: '300',
        3: '20',
        4: '40',
        5: '10',
      }.entries) {
        await enter(tester, 'ingredient-field-${entry.key}', entry.value);
      }
      await tester.ensureVisible(find.text(enL10n.ingredientSave));
      await tester.tap(find.text(enL10n.ingredientSave));
      await tester.pumpAndSettle();
      await enter(tester, 'recipe-portion-field', '4');
      await enter(tester, 'recipe-create-preparation', 'Mix and cook.');
      await tap(tester, 'recipe-create-save');
      expect(saved, isNotNull);
      expect(saved!.structuredIngredients.single.name, 'Oats');
      expect(saved!.batchServings, 4);
      expect(saved!.caloriesKcal, 300);
      expect(saved!.proteinG, 20);
      expect(saved!.estimatedGrams, 0);
      expect(saved!.preparation, 'Mix and cook.');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'half serving logs one eighth of the batch and snapshot stays unchanged',
    (tester) async {
      pinPhoneViewport(tester);
      MealAnalysisResult? logged;
      final recipe = batch();
      await pumpLocalized(
        tester,
        RecipeDetailScreen(
          recipe: recipe,
          onAddMeal: (result, _) => logged = result,
        ),
        locale: const Locale('en'),
        safeArea: false,
      );
      await tap(tester, 'recipe-add-button');
      await enter(tester, 'recipe-portion-field', '0.5');
      await tap(tester, 'recipe-meal-picker-lunch');
      expect(logged!.caloriesKcal, 150);
      expect(logged!.protein, '10 g');
      expect(logged!.estimatedGrams, 0);
      final changed = recipe.copyWith(
        structuredIngredients: [
          RecipeIngredient(
            name: 'Oats',
            grams: 800,
            per100g: recipe.structuredIngredients.single.per100g,
          ),
        ],
      );
      expect(changed.toMealResultForServings(0.5).caloriesKcal, 300);
      expect(logged!.caloriesKcal, 150);
    },
  );

  testWidgets(
    'unknown macros display incomplete and remain unknown when logged',
    (tester) async {
      pinPhoneViewport(tester);
      MealAnalysisResult? logged;
      await pumpLocalized(
        tester,
        RecipeDetailScreen(
          recipe: batch(proteinKnown: false),
          onAddMeal: (result, _) => logged = result,
        ),
        locale: const Locale('en'),
        safeArea: false,
      );
      expect(
        find.byKey(const ValueKey('recipe-nutrition-incomplete')),
        findsOneWidget,
      );
      expect(find.text('— g'), findsOneWidget);
      await tap(tester, 'recipe-add-button');
      await tap(tester, 'recipe-meal-picker-dinner');
      expect(logged!.protein, '-');
      expect(logged!.caloriesKcal, 300);
    },
  );

  testWidgets(
    'missing calories and invalid fractional portions disable logging',
    (tester) async {
      pinPhoneViewport(tester);
      var writes = 0;
      await pumpLocalized(
        tester,
        RecipeDetailScreen(
          recipe: batch(caloriesKnown: false),
          onAddMeal: (_, _) => writes++,
        ),
        locale: const Locale('en'),
        safeArea: false,
      );
      await tap(tester, 'recipe-add-button');
      expect(
        find.byKey(const ValueKey('recipe-log-unavailable')),
        findsOneWidget,
      );
      await tap(tester, 'recipe-meal-picker-lunch');
      expect(writes, 0);
      await enter(tester, 'recipe-portion-field', '0');
      await tap(tester, 'recipe-meal-picker-lunch');
      expect(writes, 0);
    },
  );

  testWidgets(
    'editing structured recipe preserves ingredients and batch yield',
    (tester) async {
      pinPhoneViewport(tester);
      FitnessRecipe? saved;
      final recipe = batch(proteinKnown: false);
      await pumpLocalized(
        tester,
        RecipeDetailScreen(
          recipe: recipe,
          onAddMeal: (_, _) {},
          onEdit: (value) async {
            saved = value;
            return SyncDelivery.delivered;
          },
        ),
        locale: const Locale('en'),
        safeArea: false,
      );
      await tap(tester, 'recipe-detail-edit');
      expect(find.byKey(const ValueKey('ingredient-edit-0')), findsOneWidget);
      await enter(tester, 'recipe-create-name', 'Edited batch');
      await tap(tester, 'recipe-create-save');
      expect(saved!.slug, recipe.slug);
      expect(saved!.batchServings, 4);
      expect(saved!.structuredIngredients.single.per100g.proteinG, isNull);
      expect(saved!.imageAsset, recipe.imageAsset);
      expect(saved!.caloriesKcal, 300);
    },
  );
}
