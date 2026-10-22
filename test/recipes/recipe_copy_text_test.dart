// Review 2026-10-19, "Teilen und Support": a recipe (ingredients and steps)
// goes out as clean plain text, through the share sheet since 2026-10-22;
// where that cannot open, onto the clipboard with a confirmation toast.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_plus/share_plus.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/screens/recipes/recipes_screen.dart';
import 'package:eatova/src/services/text_share.dart';

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

  test('gewogene Zutaten stehen mit Gramm da, für geplante Portionen '
      'umgerechnet', () {
    final recipe = _own(
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
    );
    final text = recipeAsPlainText(recipe, deL10n);
    expect(text, contains('\nZutaten\n75 g Reis\nSalz\n'));
    expect(text, endsWith('\nZubereitung\nKochen.'));
    // Shared from a meal planned for two: what the detail shows.
    expect(
      recipeAsPlainText(recipe, deL10n, servings: 2),
      contains(
        '\nZutaten\n${deL10n.recipeIngredientsForServings('2')}\n'
        '150 g Reis\nSalz\n',
      ),
    );
  });

  testWidgets('„Teilen" in den Rezeptdetails öffnet das Teilen-Menü mit dem '
      'Text, sonst geht er in die Zwischenablage', (tester) async {
    final shared = <ShareParams>[];
    final platformSheet = shareSheet;
    addTearDown(() => shareSheet = platformSheet);
    shareSheet = (params) async {
      shared.add(params);
      return const ShareResult('', ShareResultStatus.dismissed);
    };
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
    final share = find.byKey(const ValueKey('recipe-detail-share'));
    await tester.ensureVisible(share);
    await tester.pumpAndSettle();
    await tester.tap(share);
    await tester.pumpAndSettle();
    final text = recipeAsPlainText(lachs, deL10n);
    expect(shared.single.text, text);
    expect(shared.single.subject, lachs.title);
    // The iPad popover points at the button.
    expect(shared.single.sharePositionOrigin, tester.getRect(share));
    // A dismissed sheet is no failure: nothing is copied behind it.
    expect(copied, isEmpty);
    expect(find.text('Rezept kopiert.'), findsNothing);

    // No share sheet on this device: the clipboard, with a toast.
    shareSheet = (params) async =>
        throw PlatformException(code: 'unavailable');
    await tester.tap(share);
    await tester.pumpAndSettle();
    expect(copied, [text]);
    expect(find.text('Rezept kopiert.'), findsOneWidget);
  });
}
