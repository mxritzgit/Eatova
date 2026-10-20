// Review 2026-10-19: own recipes were always "Eigene". The create/edit sheet
// now lets them join the catalog's editorial categories; nothing picked keeps
// today's plain "Eigene", and the wire format stays the `categories` array.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/recipe_pick.dart';
import 'package:eatova/src/screens/recipes/recipes_screen.dart';
import 'package:eatova/src/services/recipe_save_result.dart';
import 'package:eatova/src/services/sync_error_messages.dart';

import '../support/harness.dart';

Future<List<FitnessRecipe>> _openCreate(WidgetTester tester) async {
  final created = <FitnessRecipe>[];
  await pumpLocalized(
    tester,
    RecipesScreen(
      onAddMeal: (MealAnalysisResult _, MealSlot __) {},
      onCreateRecipe: (recipe) async {
        created.add(recipe);
        return SyncDelivery.delivered;
      },
    ),
    safeArea: false,
  );
  await tester.tap(find.byKey(const ValueKey('recipe-create-button')));
  await tester.pumpAndSettle();
  return created;
}

Future<void> _type(WidgetTester tester, String key, String text) async {
  await tester.enterText(find.byKey(ValueKey(key)), text);
  await tester.pumpAndSettle();
}

Finder _chip(String category) =>
    find.byKey(ValueKey('recipe-create-category-$category'));

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

bool _selected(WidgetTester tester, String category) => tester
    .getSemantics(_chip(category))
    .flagsCollection
    .isSelected
    .toBoolOrNull()!;

const _imported = FitnessRecipe(
  slug: 'user_import_bowl',
  title: 'Bowl',
  description: '',
  portion: '1 bowl',
  ingredients: 'Rice',
  preparation: '',
  professionalHint: '',
  imageAsset: '',
  caloriesKcal: 480,
  proteinG: 21,
  carbsG: 60,
  fatG: 12,
  estimatedGrams: 340,
  categories: ['Eigene', 'Vegan', '${recipeIngredientsBasisPrefix}per_serving'],
  userCreated: true,
  serverRevision: 3,
);

void main() {
  test('die Auswahl sind die redaktionellen Katalog-Kategorien', () {
    expect(ownRecipeCategoryChoices, [
      for (final filter in recipeFilters.skip(1))
        if (filter != highProteinCategory) filter,
    ]);
  });

  testWidgetsRobust('ohne Auswahl bleibt ein neues Rezept „Eigene"', (
    tester,
  ) async {
    final created = await _openCreate(tester);
    await _type(tester, 'recipe-create-name', 'Porridge');
    await _type(tester, 'recipe-create-kcal', '420');
    await _tap(tester, find.byKey(const ValueKey('recipe-create-save')));
    expect(created.single.categories, ['Eigene']);
  });

  testWidgetsRobust('gewählte Kategorien landen im Rezept, im Filter und in '
      'der Mahlzeit-Zuordnung', (tester) async {
    final created = await _openCreate(tester);
    await _type(tester, 'recipe-create-name', 'Porridge');
    await _type(tester, 'recipe-create-kcal', '420');
    await _tap(tester, _chip('Vegetarisch'));
    await _tap(tester, _chip('Frühstück'));
    expect(_selected(tester, 'Frühstück'), isTrue);
    expect(_selected(tester, 'Fisch'), isFalse);
    await _tap(tester, find.byKey(const ValueKey('recipe-create-save')));

    final recipe = created.single;
    // Picker order, after "Eigene".
    expect(recipe.categories, ['Eigene', 'Frühstück', 'Vegetarisch']);
    expect(recipe.displayCategories, recipe.categories);
    // Same array on the wire and back.
    expect(FitnessRecipe.fromRow(recipe.toRow()).categories, recipe.categories);
    // A breakfast dish is offered for breakfast only.
    expect(recipeSuitsSlot(recipe, MealSlot.breakfast), isTrue);
    expect(recipeSuitsSlot(recipe, MealSlot.dinner), isFalse);

    final breakfastChip = find.byKey(const ValueKey('recipe-filter-Frühstück'));
    await tester.scrollUntilVisible(
      breakfastChip,
      120,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('recipes-chip-bar')),
        matching: find.byType(Scrollable),
      ),
    );
    await _tap(tester, breakfastChip);
    expect(find.byKey(ValueKey('recipe-tile-${recipe.slug}')), findsOneWidget);
  });

  testWidgets('die Auswahl bricht bei 320 px und doppelter Schrift um', (
    tester,
  ) async {
    await pumpLocalized(
      tester,
      RecipesScreen(onAddMeal: (MealAnalysisResult _, MealSlot __) {}),
      surfaceSize: const Size(320, 640),
      textScale: 2,
      safeArea: false,
    );
    // Without an import hook the header's "+" opens the create sheet.
    await tester.tap(find.byKey(const ValueKey('recipe-add-choice-button')));
    await tester.pumpAndSettle();
    for (final category in ownRecipeCategoryChoices) {
      await tester.ensureVisible(_chip(category));
      await tester.pumpAndSettle();
      expect(tester.getRect(_chip(category)).right, lessThanOrEqualTo(320));
      expect(tester.getSize(_chip(category)).height, greaterThanOrEqualTo(44));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgetsRobust('eine Kategorie zu wählen zählt für den Verwerfen-Schutz', (
    tester,
  ) async {
    await _openCreate(tester);
    await _tap(tester, _chip('Vegan'));
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('discard-changes-dialog')),
      findsOneWidget,
    );
  });

  testWidgetsRobust('beim Bearbeiten: Auswahl vorbelegt, Marker bleiben, '
      'abgewählte gehen', (tester) async {
    final saved = <FitnessRecipe>[];
    await pumpLocalized(
      tester,
      RecipeDetailScreen(
        recipe: _imported,
        onAddMeal: (_, _) {},
        onEdit: (recipe) async {
          saved.add(recipe);
          return RecipeSaveResult.detached(recipe, SyncDelivery.delivered);
        },
      ),
      safeArea: false,
    );
    await _tap(tester, find.byKey(const ValueKey('recipe-detail-edit')));
    expect(_selected(tester, 'Vegan'), isTrue);
    await _tap(tester, _chip('Vegan'));
    await _tap(tester, _chip('Hauptgericht'));
    await _tap(tester, find.byKey(const ValueKey('recipe-create-save')));

    expect(saved.single.categories, [
      'Eigene',
      '${recipeIngredientsBasisPrefix}per_serving',
      'Hauptgericht',
    ]);
    expect(saved.single.ingredientsBasis, RecipeIngredientsBasis.perServing);
  });
}
