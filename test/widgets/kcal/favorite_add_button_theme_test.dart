// Fix run for review 2026-08-27, F8-10 (Food part): the suggestion tile's add
// button overrode the theme with `FilledButton.styleFrom(backgroundColor:
// forest …)` — `forest` is itself a dark surface, so in dark mode the button
// all but vanished. It now inherits the app-wide filledButtonTheme.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

import 'package:eatova/src/models/favorite_meal.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_request.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/meal_analyzer.dart';
import 'package:eatova/src/services/meal_photo_input.dart';
import 'package:eatova/src/services/open_food_facts_product_service.dart';
import 'package:eatova/src/widgets/kcal/add_meal_sheet.dart';

import '../../support/harness.dart';

class _StummerAnalyzer implements MealAnalyzer {
  @override
  Future<MealAnalysisResult> analyze(MealAnalysisRequest request) async =>
      throw UnimplementedError();
}

class _StummerProduktdienst implements ProductLookupService {
  @override
  Future<MealAnalysisResult> lookupBarcode(String barcode) async =>
      throw UnimplementedError();

  @override
  Future<List<ProductSearchResult>> searchProducts(String query) async =>
      const <ProductSearchResult>[];
}

class _StummeFotoquelle implements MealPhotoInput {
  @override
  Future<MealPhotoSelection?> pick(ImageSource source) async => null;
}

const MealAnalysisResult _apfel = MealAnalysisResult(
  mealName: 'Apfel',
  caloriesKcal: 52,
  estimatedGrams: 100,
  kcalPer100G: 52,
  protein: '0 g',
  carbs: '14 g',
  fat: '0 g',
  confidence: 'Datenbank',
  portionNotes: '',
);

void _telefon(WidgetTester tester) {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// A button is "unstyled" when it neither overrides its fill nor its ink.
void _expectThemed(WidgetTester tester, Finder button) {
  final style = tester.widget<FilledButton>(button).style;
  expect(style?.backgroundColor, isNull, reason: 'eigene Füllung');
  expect(style?.foregroundColor, isNull, reason: 'eigene Textfarbe');
}

void main() {
  testWidgets('Hinzufügen-Knopf der Vorschlagskachel nimmt das Theme',
      (tester) async {
    _telefon(tester);
    await pumpLocalized(
      tester,
      AddMealSheet(
        slot: MealSlot.snack,
        analyzer: _StummerAnalyzer(),
        productService: _StummerProduktdienst(),
        photoInput: _StummeFotoquelle(),
        favorites: [
          FavoriteMeal(
            id: FavoriteMeal.idFor(_apfel),
            result: _apfel,
            addedAt: DateTime(2026, 8, 20),
            pinned: false,
          ),
        ],
        onAdd: (_, __) => 'id-1',
        onUpdateMeal: (_, __) {},
        onRemoveFavorite: (_) {},
      ),
      // Motion on: the favorites list sits in an AnimatedSize, and a zero
      // duration makes it re-dirty itself during layout.
      reducedMotion: false,
    );
    await tester.pumpAndSettle();
    // The inline slot control and the entry card push the tile below
    // the 800x600 test view.
    await tester.ensureVisible(find.byKey(const ValueKey('favorite-tile-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('favorite-tile-0')));
    await tester.pumpAndSettle();

    _expectThemed(tester, find.byKey(const ValueKey('favorite-tile-add-0')));
  });

  // The edit and manual sheets' save buttons are PrimaryActionButtons since
  // the 2026-10-03 redesign: their fill comes from the tokens by
  // construction (widgets/design/ suites), so a type check here proved
  // nothing more.
}
