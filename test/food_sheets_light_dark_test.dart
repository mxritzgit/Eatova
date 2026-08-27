// DESIGN_REFACTOR §7.2 for the food sheets: at least one widget test per sheet
// pumps it under buildEatovaTheme(Brightness.light) AND (Brightness.dark).
//
// The existing sheet suites only pump dark, since they test flows. This covers
// the missing half via `renderMatrix`, which also adds the `en` column the old
// hand-written brightness loop never had: does every sheet render without
// exception and without RenderFlex overflow in every combination? Overflows
// are checked by the matrix itself, never swallowed.
//
// Camera and barcode sheets are deliberately absent: their surfaces sit on a
// live camera image and are dark in both modes, and their states depend on
// platform fakes that meal_camera_sheet_test already provides.

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
import 'package:eatova/src/theme/meal_slot_style.dart';
import 'package:eatova/src/widgets/kcal/add_meal_sheet.dart';
import 'package:eatova/src/widgets/kcal/edit_meal_sheet.dart';
import 'package:eatova/src/widgets/kcal/meal_analysis_sheet.dart';

import 'support/harness.dart';

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

const MealAnalysisResult _resultat = MealAnalysisResult(
  mealName: 'Linsensuppe',
  caloriesKcal: 420,
  estimatedGrams: 350,
  kcalPer100G: 120,
  protein: '24 g',
  carbs: '48 g',
  fat: '9 g',
  confidence: 'Hoch',
  portionNotes: 'Ein tiefer Teller.',
  sourceLabel: 'Foto-KI',
);

final FavoriteMeal _favorit = FavoriteMeal(
  id: 'name:linsensuppe',
  addedAt: DateTime(2026, 8, 1),
  result: _resultat,
);

const List<Locale> _beideSprachen = <Locale>[Locale('de'), Locale('en')];

/// Mounts [inhalt] bottom-aligned, the way a modal sheet sits on the screen.
Future<void> _pumpSheet(
  WidgetTester tester,
  RenderCase c,
  Widget inhalt,
) async {
  pinPhoneViewport(tester);
  await c.pump(
    tester,
    Align(alignment: Alignment.bottomCenter, child: inhalt),
    settle: true,
  );
}

void main() {
  renderMatrix(
    'Das Add-Sheet rendert sauber',
    (tester, c) async {
      await _pumpSheet(
        tester,
        c,
        AddMealSheet(
          slot: MealSlot.lunch,
          analyzer: _StummerAnalyzer(),
          productService: _StummerProduktdienst(),
          photoInput: _StummeFotoquelle(),
          favorites: <FavoriteMeal>[_favorit],
          existingMeals: <LoggedMeal>[
            LoggedMeal(
              id: 'm1',
              result: _resultat,
              loggedAt: DateTime.now(),
              forcedSlot: MealSlot.lunch,
            ),
          ],
          onAdd: (_, __) => 'id-1',
          onUpdateMeal: (_, __) {},
          onRemoveFavorite: (_) {},
        ),
      );

      expect(tester.takeException(), isNull);
      // Slot header and the already-added list show in every combination — the
      // card takes its surface from the tokens, not from a constant, and its
      // heading from the ARB, not from a German literal.
      expect(find.text(MealSlot.lunch.label(c.l10n)), findsWidgets);
      expect(
        find.byKey(const ValueKey('analyse-existing-meals')),
        findsOneWidget,
      );
    },
    locales: _beideSprachen,
  );

  renderMatrix(
    'Das Analyse-Sheet rendert sauber',
    (tester, c) async {
      await _pumpSheet(
        tester,
        c,
        MealAnalysisSheet(
          slot: MealSlot.dinner,
          resultFuture: Future<MealAnalysisResult>.value(_resultat),
          previewImage: null,
          onAdd: (_, __) => 'id-1',
          onUpdateMeal: (_, __) {},
          failureMessage: 'Analyse fehlgeschlagen.',
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('analyse-result-card')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('analyse-add-daily-button')),
        findsOneWidget,
      );
    },
    locales: _beideSprachen,
  );

  renderMatrix(
    'Das Bearbeiten-Sheet rendert sauber',
    (tester, c) async {
      await _pumpSheet(
        tester,
        c,
        EditMealSheet(
          meal: LoggedMeal(
            id: 'm1',
            result: _resultat,
            loggedAt: DateTime.now(),
            forcedSlot: MealSlot.dinner,
          ),
          // No real update needed: this test only renders, never saves.
          onUpdateMeal: (_, {result, slot, day}) => null,
          onRemoveMeal: (_) {},
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('edit-meal-sheet')), findsOneWidget);
      expect(find.text(c.l10n.foodEditMealTitle), findsOneWidget);
    },
    locales: _beideSprachen,
  );

  testWidgets('Auf Englisch traegt das Bearbeiten-Sheet den englischen Titel',
      (tester) async {
    // Counter-check to the matrices above: they read the same ARB the sheets
    // read, so a regress in app_en.arb would pass unnoticed. One hard anchor
    // per language proves the title really CHANGES with the language.
    pinPhoneViewport(tester);
    await pumpLocalized(
      tester,
      Align(
        alignment: Alignment.bottomCenter,
        child: EditMealSheet(
          meal: LoggedMeal(
            id: 'm1',
            result: _resultat,
            loggedAt: DateTime.now(),
            forcedSlot: MealSlot.dinner,
          ),
          onUpdateMeal: (_, {result, slot, day}) => null,
          onRemoveMeal: (_) {},
        ),
      ),
      locale: const Locale('en'),
      settle: true,
    );

    expect(find.text('Edit meal'), findsOneWidget);
    expect(find.text('Mahlzeit bearbeiten'), findsNothing);
  });
}
