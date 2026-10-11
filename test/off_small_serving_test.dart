// Open Food Facts products with a serving of a few grams: the search row must
// show the label's density, and a portion that rounds to 0 kcal at a known
// density is a measurement the add guard lets through.

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/favorite_meal.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_request.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/meal_analyzer.dart';
import 'package:eatova/src/services/meal_photo_input.dart';
import 'package:eatova/src/services/open_food_facts_product_service.dart';
import 'package:eatova/src/widgets/kcal/add_meal_sheet.dart';
import 'package:eatova/src/widgets/kcal/meal_suggestion_item.dart';

import 'support/harness.dart';

class _StummerAnalyzer implements MealAnalyzer {
  @override
  Future<MealAnalysisResult> analyze(MealAnalysisRequest request) async =>
      throw UnimplementedError();
}

class _StummeFotoquelle implements MealPhotoInput {
  @override
  Future<MealPhotoSelection?> pick(ImageSource source) async => null;
}

class _Katalog implements ProductLookupService {
  _Katalog(this.treffer);

  final List<ProductSearchResult> treffer;

  @override
  Future<MealAnalysisResult> lookupBarcode(String barcode) async =>
      throw UnimplementedError();

  @override
  Future<List<ProductSearchResult>> searchProducts(String query) async =>
      treffer;
}

ProductSearchResult _produkt(String name, num portion, num kcalPer100G) =>
    ProductSearchResult.fromOpenFoodFacts(<String, dynamic>{
      'code': '4000000000017',
      'product_name': name,
      'serving_quantity': portion,
      'nutriments': <String, dynamic>{'energy-kcal_100g': kcalPer100G},
    });

void main() {
  testWidgets('Suchzeile: Kaugummi zeigt 153 kcal pro 100 g, nicht 200', (
    tester,
  ) async {
    await pumpLocalized(
      tester,
      MealSuggestionItem(
        result: _produkt('Kaugummi', 1.4, 153).result,
        productPresentation: true,
        expanded: false,
        onTap: () {},
        onAdd: (_) {},
      ),
      settle: true,
    );
    expect(find.text('153 kcal'), findsOneWidget);
    expect(find.text('200 kcal'), findsNothing);
  });

  testWidgets('Teebeutel mit bekannter Dichte wird in der Standardportion '
      'geloggt', (tester) async {
    await withClock(Clock.fixed(DateTime(2026, 10, 11, 9)), () async {
      tester.view.physicalSize = const Size(1179, 2556);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final geloggt = <MealAnalysisResult>[];
      final c = await pumpLocalizedContext(
        tester,
        AddMealSheet(
          slot: MealSlot.snack,
          analyzer: _StummerAnalyzer(),
          productService: _Katalog([_produkt('Kräutertee', 2, 1)]),
          photoInput: _StummeFotoquelle(),
          favorites: const <FavoriteMeal>[],
          onAdd: (result, _) {
            geloggt.add(result);
            return 'id-1';
          },
          onUpdateMeal: (_, _) {},
          onRemoveFavorite: (_) {},
        ),
        reducedMotion: false,
        safeArea: false,
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('kcal-product-search-input')),
        'Kräutertee',
      );
      await tester.pump(const Duration(milliseconds: 1100));
      await tester.pumpAndSettle();
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('kcal-product-suggestion-0')),
          matching: find.text('Kräutertee'),
        ),
      );
      await tester.pumpAndSettle();
      final add = find.byKey(const ValueKey('kcal-product-suggestion-add-0'));
      await tester.ensureVisible(add);
      await tester.tap(add);
      await tester.pump();

      expect(
        find.text(c.l10n.foodSuggestionWithoutCaloriesMessage),
        findsNothing,
      );
      expect(geloggt, hasLength(1));
      expect(geloggt.single.estimatedGrams, 2);
      expect(geloggt.single.caloriesKcal, 0);
      await tester.pumpAndSettle();
    });
  });
}
