// The add sheet's "Describe" entry: visible next to the other methods, opens
// the describe sheet on the add sheet's slot, and an Add logs exactly once
// through the add sheet's path with its usual confirmation.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_request.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/meal_analyzer.dart';
import 'package:eatova/src/services/meal_photo_input.dart';
import 'package:eatova/src/services/open_food_facts_product_service.dart';
import 'package:eatova/src/theme/meal_slot_style.dart';
import 'package:eatova/src/widgets/kcal/add_meal_sheet.dart';
import 'package:eatova/src/widgets/kcal/meal_entry_methods.dart';
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

Future<DescribeHost> _openAddSheet(
  WidgetTester tester, {
  MealSlot slot = MealSlot.lunch,
}) async {
  final h = DescribeHost();
  phoneViewport(tester);
  await pumpLocalized(
    tester,
    Builder(
      builder: (context) => TextButton(
        onPressed: () => showAddMealSheet(
          context,
          slot: slot,
          analyzer: _NoAnalyzer(),
          productService: _NoProducts(),
          photoInput: _NoPhotos(),
          favorites: const [],
          onAdd: h.onAdd,
          onUpdateMeal: (_, _) {},
          onRemoveFavorite: (_) {},
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
  return h;
}

Future<void> _openDescribeEntry(WidgetTester tester) async {
  final entry = key('describe-entry-button');
  await tester.ensureVisible(entry);
  await tester.pumpAndSettle();
  await tester.tap(entry);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the entry sits in the method card and opens the sheet', (
    tester,
  ) async {
    await _openAddSheet(tester, slot: MealSlot.dinner);
    final entry = key('describe-entry-button');
    expect(
      find.descendant(of: find.byType(MealEntryMethods), matching: entry),
      findsOneWidget,
    );
    final l10n = tester.element(entry).l10n;
    expect(
      find.descendant(
        of: entry,
        matching: find.text(l10n.foodDescribeEntryTitle),
      ),
      findsOneWidget,
    );
    expect(tester.getSize(entry).height, greaterThanOrEqualTo(48));

    await _openDescribeEntry(tester);
    expect(key('meal-describe-sheet'), findsOneWidget);
    // The add sheet's slot carries over.
    expect(
      tester
          .widget<MealSlotPicker>(
            find.descendant(
              of: key('meal-describe-sheet'),
              matching: find.byType(MealSlotPicker),
            ),
          )
          .selected,
      MealSlot.dinner,
    );
  });

  testWidgets('Add logs once through the add sheet and confirms there', (
    tester,
  ) async {
    final h = await _openAddSheet(tester);
    await _openDescribeEntry(tester);
    await describe(tester, 'Nutella auf einer Scheibe Toast von Lidl');
    final l10n = l10nOf(tester);

    await tester.ensureVisible(key('meal-describe-add'));
    await tester.pumpAndSettle();
    await tester.tap(key('meal-describe-add'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(h.logged, hasLength(1));
    expect(h.logged.single.slot, MealSlot.lunch);
    expect(h.logged.single.result.caloriesKcal, 146);
    expect(key('meal-describe-sheet'), findsNothing);
    expect(key('add-meal-sheet'), findsOneWidget);
    expect(
      find.text(l10n.commonKcalAddedToSlot(146, MealSlot.lunch.label(l10n))),
      findsOneWidget,
    );
    // The add sheet mirrors the new row under "already added".
    await tester.pumpAndSettle();
    expect(find.text('Nutella-Toast'), findsWidgets);
    expect(h.logged, hasLength(1));
  });
}
