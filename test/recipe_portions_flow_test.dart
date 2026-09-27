import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/recipe_import_result.dart';
import 'package:eatova/src/screens/recipes/recipes_screen.dart';
import 'package:eatova/src/services/recipe_save_result.dart';
import 'package:eatova/src/services/sync_error_messages.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/harness.dart';

final _recipe = const RecipeImportCandidate(
  id: 'mince',
  title: 'Mince pockets',
  ingredients: '800 g mince',
  preparation: 'Bake at 180 C for 20 minutes.',
  portion: '4 portions',
  servings: 4,
  ingredientsBasis: RecipeIngredientsBasis.perRecipe,
  caloriesKcal: 350,
  proteinG: 30,
  carbsG: 25,
  fatG: 10,
).toRecipe(slug: 'user_import_mince', sourceLabel: 'Source');

Future<void> _openEditor(WidgetTester tester, List<FitnessRecipe> saved) async {
  pinPhoneViewport(tester);
  await pumpLocalized(
    tester,
    RecipeDetailScreen(
      recipe: _recipe,
      onAddMeal: (_, _) {},
      onEdit: (recipe) async {
        saved.add(recipe);
        return RecipeSaveResult.detached(recipe, SyncDelivery.queuedOffline);
      },
    ),
    locale: const Locale('en'),
    safeArea: false,
  );
  expect(find.text('200 g mince'), findsOneWidget);
  await tester.ensureVisible(find.byKey(const ValueKey('recipe-detail-edit')));
  await tester.tap(find.byKey(const ValueKey('recipe-detail-edit')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'structured ingredients retain their batch context after import',
    (tester) async {
      final recipe = _recipe.copyWith(
        ingredients: '',
        structuredIngredients: [
          RecipeIngredient(
            name: 'mince',
            grams: 800,
            per100g: const RecipeNutrition(caloriesKcal: 200),
          ),
        ],
      );
      await pumpLocalized(
        tester,
        RecipeDetailScreen(recipe: recipe, onAddMeal: (_, _) {}),
        locale: const Locale('en'),
      );
      expect(find.text(enL10n.recipeDetailIngredientsHint), findsOneWidget);
      expect(find.text('800 g mince'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'saved import title edit retains yield basis source and projected display',
    (tester) async {
      final saved = <FitnessRecipe>[];
      await _openEditor(tester, saved);
      final ingredients = find.byKey(
        const ValueKey('recipe-create-ingredients'),
      );
      expect(
        tester.widget<TextField>(ingredients).controller!.text,
        '800 g mince',
      );
      await tester.enterText(
        find.byKey(const ValueKey('recipe-create-name')),
        'Renamed pockets',
      );
      final save = find.byKey(const ValueKey('recipe-create-save'));
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      final restored = FitnessRecipe.fromRow(saved.single.toRow());
      expect(restored.batchServings, 4);
      expect(restored.ingredients, '800 g mince');
      expect(restored.displayIngredients(enL10n), '200 g mince');
      expect(restored.toMealResultForServings(2).caloriesKcal, 700);
    },
  );

  testWidgets(
    'editing source quantity invalidates source basis without silently dividing',
    (tester) async {
      final saved = <FitnessRecipe>[];
      await _openEditor(tester, saved);
      final ingredients = find.byKey(
        const ValueKey('recipe-create-ingredients'),
      );
      await tester.ensureVisible(ingredients);
      await tester.enterText(ingredients, '200 g mince');
      final save = find.byKey(const ValueKey('recipe-create-save'));
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(saved.single.batchServings, 4);
      expect(saved.single.ingredientsBasis, RecipeIngredientsBasis.unspecified);
      expect(saved.single.displayIngredients(enL10n), '200 g mince');
    },
  );
}
