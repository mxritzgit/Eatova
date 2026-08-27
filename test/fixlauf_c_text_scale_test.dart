// Fix run for review 2026-08-27, F3-05: the add-meal sheet, its slot
// selector and the manual-entry sheet used fixed heights (46/46/56) that
// left no room for large system text. Now `minHeight`, the slot segments
// scale with the text like the edit sheet's day picker. Overflows are the
// subject here, so `renderMatrix` asserts on them instead of swallowing them.
//
// The scale loop (1.3 / 2.0) plus the separate 1.0 case are one matrix now:
// 1.0 / 1.3 / 2.0 in BOTH brightnesses, since the light theme draws different
// border widths and thus different inner heights.

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
import 'package:eatova/src/widgets/kcal/manual_meal_sheet.dart';
import 'package:eatova/src/widgets/kcal/slot_selector.dart';

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

/// The three scales the sheet has to hold: normal, the 1.25 grid breakpoint's
/// neighbour, and the WCAG 1.4.4 cap.
const List<double> _skalen = <double>[1.0, 1.3, 2.0];

Future<void> _pumpAddSheet(WidgetTester tester, RenderCase c) async {
  pinPhoneViewport(tester);
  await c.pump(
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
          pinned: true,
        ),
      ],
      existingMeals: [
        LoggedMeal(
          id: 'm-1',
          result: _apfel,
          loggedAt: DateTime.now(),
          forcedSlot: MealSlot.snack,
        ),
      ],
      onAdd: (_, __) => 'id-1',
      onUpdateMeal: (_, __) {},
      onRemoveFavorite: (_) {},
      onRemoveMeal: (_) {},
    ),
    safeArea: false,
    settle: true,
  );
}

/// Opens the manual-entry sheet as a modal route. The text scale sits above
/// the navigator (see harness), so the route scales along.
Future<void> _openManualSheet(WidgetTester tester, RenderCase c) async {
  pinPhoneViewport(tester);
  await c.pump(
    tester,
    Builder(
      builder: (context) => Center(
        child: TextButton(
          onPressed: () => showManualMealSheet(context),
          child: const Text('open'),
        ),
      ),
    ),
    safeArea: false,
    settle: true,
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('manual-meal-save')), findsOneWidget);
}

void main() {
  renderMatrix(
    'Das Add-Sheet traegt seine Kapseln bei jeder Systemschrift',
    (tester, c) async {
      await _pumpAddSheet(tester, c);

      // Search capsule: at least the design height, taller when needed.
      final capsule =
          tester.getSize(find.byKey(const ValueKey('kcal-product-search-card')));
      expect(capsule.height, greaterThanOrEqualTo(46 + 8));
      final input =
          tester.getRect(find.byKey(const ValueKey('kcal-product-search-input')));
      final card =
          tester.getRect(find.byKey(const ValueKey('kcal-product-search-card')));
      expect(input.top, greaterThanOrEqualTo(card.top - 0.5));
      expect(input.bottom, lessThanOrEqualTo(card.bottom + 0.5));

      // Manual-entry row grows with its label instead of clipping it.
      final row = find.byKey(const ValueKey('manual-entry-button'));
      final label = find.descendant(of: row, matching: find.byType(Text));
      expect(
        tester.getSize(row).height,
        greaterThanOrEqualTo(tester.getSize(label).height),
      );
    },
    textScales: _skalen,
  );

  renderMatrix(
    'Der Slot-Waehler skaliert seine Segmente mit der Systemschrift',
    (tester, c) async {
      await _pumpAddSheet(tester, c);

      // 56 at normal size, growing with the text up to the 80 px cap. This
      // covers the old "bei Normalschrift exakt 56 hoch" case at 1.0x.
      final expected = (56 * c.textScale).clamp(56.0, 80.0);
      final segment = find.byKey(const ValueKey('slot-select-snack'));
      expect(tester.getSize(segment).height,
          moreOrLessEquals(expected, epsilon: 0.5));
      expect(find.byType(SlotSelector), findsOneWidget);

      // The label stays inside its segment.
      final text = find.descendant(of: segment, matching: find.byType(Text));
      expect(
        tester.getRect(text).bottom,
        lessThanOrEqualTo(tester.getRect(segment).bottom + 0.5),
      );
    },
    textScales: _skalen,
  );

  renderMatrix(
    'Das Manuell-Sheet rendert bei jeder Systemschrift overflow-frei',
    (tester, c) async {
      await _openManualSheet(tester, c);
      expect(tester.takeException(), isNull);
    },
    textScales: _skalen,
  );
}
