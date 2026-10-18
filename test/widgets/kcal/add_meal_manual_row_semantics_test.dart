// Review 2026-10-11 (FOOD-3): in search mode the add sheet shows its own
// manual-entry row instead of the entry-method card. That row was an InkWell
// without the button role a screen reader announces; the method card's row
// with the same key has it.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_request.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/meal_analyzer.dart';
import 'package:eatova/src/services/meal_photo_input.dart';
import 'package:eatova/src/services/open_food_facts_product_service.dart';
import 'package:eatova/src/widgets/kcal/add_meal_sheet.dart';

import '../../support/harness.dart';

class _NoAnalyzer implements MealAnalyzer {
  @override
  Future<MealAnalysisResult> analyze(MealAnalysisRequest request) async =>
      throw UnimplementedError();
}

class _NoPhotos implements MealPhotoInput {
  @override
  Future<MealPhotoSelection?> pick(ImageSource source) async => null;
}

class _NoProducts implements ProductLookupService {
  @override
  Future<MealAnalysisResult> lookupBarcode(String barcode) async =>
      throw UnimplementedError();

  @override
  Future<List<ProductSearchResult>> searchProducts(String query) async =>
      const <ProductSearchResult>[];
}

void main() {
  for (final searchMode in [false, true]) {
    testWidgets(
      'Manuell-Zeile ist ein Button für den Screenreader '
      '(searchMode: $searchMode)',
      (tester) async {
        final semantics = tester.ensureSemantics();
        pinPhoneViewport(tester);
        await pumpLocalizedContext(
          tester,
          AddMealSheet(
            slot: MealSlot.snack,
            searchMode: searchMode,
            analyzer: _NoAnalyzer(),
            productService: _NoProducts(),
            photoInput: _NoPhotos(),
            favorites: const [],
            onAdd: (_, __) => 'id',
            onUpdateMeal: (_, __) {},
            onRemoveFavorite: (_) {},
          ),
          reducedMotion: false,
          safeArea: false,
          settle: true,
        );

        final row = tester.getSemantics(
          find.byKey(const ValueKey('manual-entry-button')),
        );
        expect(
          row,
          matchesSemantics(
            isButton: true,
            hasTapAction: true,
            isFocusable: true,
            hasFocusAction: true,
            label: 'Manuell eintragen\nVom Etikett oder nur die Gesamtwerte',
            textDirection: TextDirection.ltr,
          ),
        );
        semantics.dispose();
      },
    );
  }
}
