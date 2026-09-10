import 'dart:async';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/recipe_ingredient.dart';
import 'package:eatova/src/services/open_food_facts_product_service.dart';
import 'package:eatova/src/widgets/recipes/recipe_ingredient_editor.dart';
import 'package:eatova/src/widgets/recipes/recipe_portion_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

class _Products implements ProductLookupService {
  Future<List<ProductSearchResult>> Function(String) response = (_) async => [];
  @override
  Future<List<ProductSearchResult>> searchProducts(String query) =>
      response(query);
  @override
  Future<MealAnalysisResult> lookupBarcode(String barcode) =>
      throw UnimplementedError();
}

ProductSearchResult _product() => ProductSearchResult.fromOpenFoodFacts({
  'code': '123',
  'product_name': 'Oats',
  'nutriments': {
    'energy-kcal_100g': 350,
    'proteins_100g': 12.345,
    'fat_100g': 0,
  },
});

Future<void> _enter(WidgetTester tester, int field, String value) async {
  final finder = find.byKey(ValueKey('ingredient-field-$field'));
  await tester.ensureVisible(finder);
  await tester.enterText(finder, value);
  await tester.pump();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  for (final locale in ['de', 'en']) {
    for (final brightness in Brightness.values) {
      testWidgets(
        'manual ingredient and decimal portions at 320px 2x $locale $brightness',
        (tester) async {
          tester.view.physicalSize = const Size(320, 760);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final t = locale == 'de' ? deL10n : enL10n;
          var ingredients = <RecipeIngredient>[];
          double? servings = 1;
          await pumpLocalized(
            tester,
            StatefulBuilder(
              builder: (context, setState) => SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      RecipeIngredientEditor(
                        ingredients: ingredients,
                        productService: _Products(),
                        onChanged: (value) => setState(() {
                          ingredients = value;
                        }),
                      ),
                      RecipePortionSelector(
                        onChanged: (value) {
                          servings = value;
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
            locale: Locale(locale),
            brightness: brightness,
            textScale: 2,
          );
          await _tap(tester, find.byKey(const ValueKey('ingredient-add')));
          await _tap(tester, find.byKey(const ValueKey('ingredient-manual')));
          await _enter(tester, 0, 'Oats');
          await _enter(tester, 1, '123,5');
          await _enter(tester, 2, '350');
          await _enter(tester, 3, '12.345');
          await _enter(tester, 5, '0');
          await _tap(tester, find.text(t.ingredientSave));
          expect(ingredients.single.grams, 123.5);
          expect(ingredients.single.per100g.proteinG, 12.345);
          expect(ingredients.single.per100g.carbsG, isNull);
          expect(ingredients.single.per100g.fatG, 0);
          expect(find.text(t.ingredientIncomplete), findsOneWidget);
          await tester.ensureVisible(
            find.byKey(const ValueKey('recipe-portion-field')),
          );
          await tester.enterText(
            find.byKey(const ValueKey('recipe-portion-field')),
            '0,5',
          );
          await tester.pump();
          expect(servings, 0.5);
          await tester.enterText(
            find.byKey(const ValueKey('recipe-portion-field')),
            '0',
          );
          await tester.pump();
          expect(servings, isNull);
          expect(find.text(t.recipeCalcServingsError), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'product search preserves original precision and supports safe editing',
    (tester) async {
      final products = _Products()..response = (_) async => [_product()];
      var ingredients = <RecipeIngredient>[];
      await pumpLocalized(
        tester,
        StatefulBuilder(
          builder: (context, setState) => RecipeIngredientEditor(
            ingredients: ingredients,
            productService: products,
            onChanged: (value) => setState(() {
              ingredients = value;
            }),
          ),
        ),
        locale: const Locale('en'),
      );
      await _tap(tester, find.byKey(const ValueKey('ingredient-add')));
      await tester.enterText(
        find.byKey(const ValueKey('ingredient-query')),
        'oats',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      await _tap(tester, find.byKey(const ValueKey('ingredient-result-0')));
      await _enter(tester, 1, '40');
      await _tap(tester, find.text(enL10n.ingredientSave));
      expect(ingredients.single.source, IngredientSource.openFoodFacts);
      expect(ingredients.single.productCode, '123');
      expect(ingredients.single.per100g.proteinG, 12.345);
      await _tap(tester, find.byKey(const ValueKey('ingredient-edit-0')));
      await _enter(tester, 2, '9000');
      await _tap(tester, find.text(enL10n.ingredientSave));
      expect(ingredients.single.per100g.caloriesKcal, 350);
      await _enter(tester, 2, '333');
      await _tap(tester, find.text(enL10n.ingredientSave));
      expect(ingredients.single.source, IngredientSource.manual);
      expect(ingredients.single.productCode, isNull);
      expect(ingredients.single.per100g.caloriesKcal, 333);
      await _tap(tester, find.byKey(const ValueKey('ingredient-remove-0')));
      expect(ingredients, isEmpty);
    },
  );

  testWidgets(
    'stale search, empty search and provider errors stay recoverable',
    (tester) async {
      final pending = Completer<List<ProductSearchResult>>();
      final products = _Products()..response = (_) => pending.future;
      await pumpLocalized(
        tester,
        RecipeIngredientEditor(
          ingredients: const [],
          onChanged: (_) {},
          productService: products,
        ),
        locale: const Locale('en'),
      );
      await _tap(tester, find.byKey(const ValueKey('ingredient-add')));
      await tester.enterText(
        find.byKey(const ValueKey('ingredient-query')),
        'oats',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('ingredient-query')),
        'rice',
      );
      pending.complete([_product()]);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('ingredient-result-0')), findsNothing);
      products.response = (_) async => [];
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(find.text(enL10n.ingredientNoResults), findsOneWidget);
      products.response = (_) async =>
          throw const FormatException('private upstream data');
      await _tap(tester, find.byKey(const ValueKey('ingredient-search-submit')));
      expect(find.text(enL10n.ingredientSearchError), findsOneWidget);
      expect(find.textContaining('private upstream'), findsNothing);
      await _tap(tester, find.byKey(const ValueKey('ingredient-manual')));
      await _enter(tester, 0, 'Rice');
      await _tap(tester, find.text(enL10n.commonCancel));
      expect(find.byKey(const ValueKey('ingredient-add')), findsOneWidget);
    },
  );
}
