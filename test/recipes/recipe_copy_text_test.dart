// Review 2026-10-19, "Teilen und Support": a recipe (ingredients and steps)
// can be copied as clean plain text, with a confirmation toast. No share
// package.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/screens/recipes/recipes_screen.dart';

import '../support/harness.dart';

FitnessRecipe _de(String slug) =>
    recipeCatalogDe.firstWhere((r) => r.slug == slug);

FitnessRecipe _own({
  String ingredients = '',
  String preparation = '',
  List<RecipeIngredient> structured = const [],
}) => FitnessRecipe(
  slug: 'user_bowl',
  title: 'Meine Bowl',
  description: '',
  portion: '1 Schüssel',
  ingredients: ingredients,
  preparation: preparation,
  professionalHint: '',
  imageAsset: '',
  caloriesKcal: 520,
  proteinG: 31,
  carbsG: 60,
  fatG: 14,
  estimatedGrams: 400,
  categories: const ['Eigene'],
  userCreated: true,
  structuredIngredients: structured,
);

void main() {
  test('ein Katalogrezept: Titel, Werte, Portion, Zutaten, Zubereitung', () {
    final lachs = _de('lachs_mit_sukartoffel_and_spargel');
    expect(
      recipeAsPlainText(lachs, deL10n),
      'Lachs mit Süßkartoffel & Spargel\n'
      '640 kcal · 43 g Protein\n'
      'Portion: 1 großer Fitness-Teller / 1 Hauptmahlzeit\n'
      '\n'
      'Zutaten\n'
      '${lachs.ingredients}\n'
      '\n'
      'Zubereitung\n'
      '${lachs.preparation}',
    );
    final en = recipeCatalogEn.firstWhere((r) => r.slug == lachs.slug);
    expect(recipeAsPlainText(en, enL10n).split('\n').take(3), [
      'Salmon with Sweet Potato & Asparagus',
      '640 kcal · 43 g protein',
      'Portion: 1 large fitness plate / 1 main meal',
    ]);
  });

  test('leere Abschnitte eines eigenen Rezepts fehlen statt Platzhalter', () {
    final text = recipeAsPlainText(_own(), deL10n);
    expect(text, 'Meine Bowl\n520 kcal · 31 g Protein\nPortion: 1 Schüssel');
    expect(text, isNot(contains(deL10n.recipesNoPreparationYet)));
  });

  test('gewogene Zutaten stehen mit Gramm da', () {
    final text = recipeAsPlainText(
      _own(
        structured: [
          RecipeIngredient(
            name: 'Reis',
            grams: 75,
            per100g: const RecipeNutrition(
              caloriesKcal: 350,
              proteinG: 7,
              carbsG: 77,
              fatG: 1,
            ),
          ),
        ],
        ingredients: 'Salz',
        preparation: 'Kochen.',
      ),
      deL10n,
    );
    expect(text, contains('\nZutaten\n75 g Reis\nSalz\n'));
    expect(text, endsWith('\nZubereitung\nKochen.'));
  });

  testWidgets('„Als Text kopieren" in den Rezeptdetails legt den Text in die '
      'Zwischenablage und bestätigt', (tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final lachs = _de('lachs_mit_sukartoffel_and_spargel');
    await pumpLocalized(
      tester,
      RecipeDetailScreen(recipe: lachs, onAddMeal: (_, _) {}),
    );
    final copy = find.byKey(const ValueKey('recipe-detail-copy'));
    await tester.ensureVisible(copy);
    await tester.pumpAndSettle();
    await tester.tap(copy);
    await tester.pumpAndSettle();
    expect(copied, [recipeAsPlainText(lachs, deL10n)]);
    expect(find.text('Rezept kopiert.'), findsOneWidget);
  });
}
