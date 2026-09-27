import 'dart:convert';
import 'dart:io';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/export_document.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/planned_meal.dart';
import 'package:eatova/src/models/recipe_import_result.dart';
import 'package:eatova/src/models/shopping_list.dart';
import 'package:eatova/src/screens/recipes/recipe_import_sheet.dart';
import 'package:eatova/src/screens/recipes/recipes_screen.dart';
import 'package:eatova/src/services/recipe_import_service.dart';
import 'package:eatova/src/services/sync_error_messages.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

class _FixtureService implements RecipeImportService {
  _FixtureService(this.response);
  final Map<String, dynamic> response;

  @override
  Future<RecipeImportResult> extract(
    String text, {
    required String locale,
  }) async => parseRecipeImportResponse(200, jsonEncode(response));
}

void main() {
  // The Deno contract suite verifies these responses against the real parser.
  final fixtures =
      (jsonDecode(
                File(
                  'test/fixtures/recipe_import/portions_contract.json',
                ).readAsStringSync(),
              )
              as List)
          .cast<Map<String, dynamic>>();

  for (final fixture in fixtures) {
    test(
      'parser response survives storage, plan and export: ${fixture['name']}',
      () {
        final result = parseRecipeImportResponse(
          200,
          jsonEncode(fixture['response']),
        );
        final candidate = result.candidates.single;
        final raw = candidate.ingredients;
        final saved = candidate.toRecipe(
          slug: candidate.stableSlug(result.sourceUrl),
          sourceUrl: result.sourceUrl,
          sourceLabel: 'Source',
        );
        final recipe = FitnessRecipe.fromRow(
          (jsonDecode(jsonEncode(saved.toRow())) as Map)
              .cast<String, dynamic>(),
        );
        final expected = fixture['expected_serving_ingredients'] as String;
        expect(recipe.ingredients, raw);
        expect(recipe.displayIngredients(enL10n), expected);
        expect(recipe.displayIngredients(deL10n), expected);
        expect(recipe.displayNutrition.caloriesKcal, fixture['expected_kcal']);
        expect(recipe.preparation, 'Bei 180 °C für 20 Minuten backen.');

        final knownNutrition =
            fixture['expected_nutrition_basis'] == 'per_serving';
        expect(recipe.canLogServings(2), knownNutrition);
        if (knownNutrition) {
          final meal = recipe.toMealResultForServings(2, enL10n);
          expect(meal.caloriesKcal, 1000);
          expect(meal.protein, '80 g');
          expect(meal.carbs, '40 g');
          expect(meal.fat, '20 g');
        }

        final day = DateTime(2026, 9, 27);
        final plan = PlannedMeal.fromJson(
          PlannedMeal.create(
            id: '11111111-1111-4111-8111-111111111111',
            recipe: recipe,
            day: day,
            slot: MealSlot.lunch,
            servings: 2,
          ).toJson(),
        );
        expect(plan.recipe.ingredients, raw);
        expect(plan.recipe.displayIngredients(enL10n), expected);
        final shopping = buildShoppingList([plan], day);
        final expectedShopping =
            fixture['expected_ingredients_basis'] == 'unspecified'
            ? raw
            : '400 g Hackfleisch\n200 g Tomaten';
        expect(shopping.single.name, contains(expectedShopping));

        final sourceExport = {
          'user_recipes': [recipe.toRow()],
        };
        final export = ExportDocument.parse(jsonEncode(sourceExport));
        expect(jsonDecode(export.json), sourceExport);
        expect(export.report('Data', (key) => key), contains(expected));
        expect(export.sections.single.csv, contains(expected));
        if (fixture['expected_ingredients_basis'] == 'per_recipe') {
          expect(export.json, contains('800 g Hackfleisch'));
          expect(export.json, isNot(contains('200 g Hackfleisch')));
        }
        if (fixture['expected_ingredients_basis'] == 'unspecified') {
          final confirmed = recipe.withConfirmedNutritionBasis(4);
          expect(confirmed.toMealResultForServings(1).caloriesKcal, 500);
          expect(confirmed.displayIngredients(enL10n), raw);
        }
      },
    );
  }

  for (final fixture in fixtures.take(2)) {
    for (final locale in [const Locale('de'), const Locale('en')]) {
      testWidgets('preview and explicit save: ${fixture['name']}, $locale', (
        tester,
      ) async {
        final saved = <FitnessRecipe>[];
        final response = fixture['response'] as Map<String, dynamic>;
        await pumpLocalized(
          tester,
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showRecipeImportSheet(
                context: context,
                service: _FixtureService(response),
                initialText: (fixture['source'] as Map)['text'] as String,
                sessionIsCurrent: () => true,
                onSave: (recipe) async {
                  saved.add(recipe);
                  return SyncDelivery.delivered;
                },
              ),
              child: const Text('Open import'),
            ),
          ),
          locale: locale,
          surfaceSize: const Size(390, 844),
        );
        await tester.tap(find.text('Open import'));
        await tester.pumpAndSettle();
        expect(saved, isEmpty);
        expect(
          find.textContaining('200 g Hackfleisch', findRichText: true),
          findsWidgets,
        );
        expect(find.text('500'), findsWidgets);
        expect(tester.takeException(), isNull);
        final save = find.byKey(const ValueKey('recipe-import-save'));
        await tester.ensureVisible(save);
        await tester.pumpAndSettle();
        await tester.tap(save);
        await tester.pumpAndSettle();
        expect(saved, hasLength(1));
        final restored = FitnessRecipe.fromRow(saved.single.toRow());
        expect(restored.ingredients, '800 g Hackfleisch\n400 g Tomaten');
        await pumpLocalized(
          tester,
          RecipeDetailScreen(recipe: restored, onAddMeal: (_, __) {}),
          locale: locale,
          surfaceSize: const Size(390, 844),
        );
        await tester.pumpAndSettle();
        expect(
          find.textContaining('200 g Hackfleisch', findRichText: true),
          findsWidgets,
        );
        expect(find.text('500'), findsWidgets);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
