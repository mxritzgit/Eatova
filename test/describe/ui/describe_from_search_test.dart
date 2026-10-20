// An empty product search offers "Describe" (2026-10-19): home cooking has
// no barcode, so the search text opens the describe sheet as its
// description, on the add sheet's slot and day. Nothing is sent until the
// user submits; the manual form stays as the second way.

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
import 'package:eatova/src/widgets/kcal/meal_slot_picker.dart';

import '../../support/harness.dart';
import 'describe_harness.dart';

class _NoPhotos implements MealPhotoInput {
  @override
  Future<MealPhotoSelection?> pick(ImageSource source) async => null;
}

class _NoAnalyzer implements MealAnalyzer {
  @override
  Future<MealAnalysisResult> analyze(MealAnalysisRequest request) =>
      throw StateError('no photo in these tests');
}

class _NoProducts implements ProductLookupService {
  @override
  Future<MealAnalysisResult> lookupBarcode(String barcode) =>
      throw StateError('no barcode in these tests');

  @override
  Future<List<ProductSearchResult>> searchProducts(String query) async =>
      const <ProductSearchResult>[];
}

final Finder _searchInput = key('kcal-product-search-input');

Future<DescribeHost> _searchNothing(
  WidgetTester tester, {
  required String query,
  DateTime? foodDate,
}) async {
  final h = DescribeHost();
  phoneViewport(tester);
  await pumpLocalized(
    tester,
    Builder(
      builder: (context) => TextButton(
        onPressed: () => showAddMealSheet(
          context,
          slot: MealSlot.dinner,
          searchMode: true,
          analyzer: _NoAnalyzer(),
          productService: _NoProducts(),
          photoInput: _NoPhotos(),
          favorites: const [],
          onAdd: h.onAdd,
          onUpdateMeal: (_, _) {},
          onRemoveFavorite: (_) {},
          foodDate: foodDate,
          describer: h.describer,
          describeMatcher: h.matcher,
          speechInput: h.speech,
          screenAwake: h.awake,
          dictationLanguageStore: h.languages,
        ),
        child: const Text('open'),
      ),
    ),
    safeArea: false,
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  await tester.enterText(_searchInput, query);
  await tester.tap(key('kcal-product-search-button'));
  await tester.pumpAndSettle();
  return h;
}

void main() {
  testWidgets('nichts gefunden: Beschreiben oeffnet das Blatt mit dem '
      'Suchtext, Slot und Tag', (tester) async {
    final day = DateTime(2026, 10, 18);
    final h = await _searchNothing(
      tester,
      query: 'Omas Linseneintopf',
      foodDate: day,
    );
    final cta = key('search-describe-cta');
    expect(cta, findsOneWidget);
    expect(key('manual-entry-cta'), findsOneWidget);
    expect(
      find.descendant(of: cta, matching: find.text('Beschreiben')),
      findsOneWidget,
    );

    await tester.ensureVisible(cta);
    await tester.pumpAndSettle();
    await tester.tap(cta);
    await tester.pumpAndSettle();

    final sheet = key('meal-describe-sheet');
    expect(sheet, findsOneWidget);
    expect(
      tester.widget<TextField>(describeInput).controller!.text,
      'Omas Linseneintopf',
    );
    expect(
      tester
          .widget<MealSlotPicker>(
            find.descendant(of: sheet, matching: find.byType(MealSlotPicker)),
          )
          .selected,
      MealSlot.dinner,
    );
    final dayLabel = MaterialLocalizations.of(
      tester.element(sheet),
    ).formatMediumDate(day);
    expect(
      find.descendant(of: sheet, matching: find.text(dayLabel)),
      findsOneWidget,
    );
    // Prefilled is not sent: the AI call waits for the user's submit.
    expect(h.describer.calls, isEmpty);

    // Untouched, the text is still in the search field: closing asks nothing.
    await tester.tap(key('meal-describe-close'));
    await tester.pumpAndSettle();
    expect(sheet, findsNothing);
    expect(key('add-meal-sheet'), findsOneWidget);
  });

  testWidgets('abgeschickt geht genau der Suchtext an die Beschreibung', (
    tester,
  ) async {
    final h = await _searchNothing(tester, query: 'Nutella-Toast');
    await tester.ensureVisible(key('search-describe-cta'));
    await tester.pumpAndSettle();
    await tester.tap(key('search-describe-cta'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(describeSubmit);
    await tester.pumpAndSettle();
    await tester.tap(describeSubmit);
    await tester.pumpAndSettle();

    expect(h.describer.calls.single.text, 'Nutella-Toast');
  });
}
