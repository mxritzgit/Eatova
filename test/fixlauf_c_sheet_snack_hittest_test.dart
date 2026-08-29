// Fix run for review 2026-08-27, F3-02: toasts fired while a modal sheet is
// open (add success, delete undo, unpin) must be reachable — the root
// messenger renders them UNDER the sheet's scrim, where the undo button is
// visible but dead. `hitTestable()` is the proof: it hit-tests the toast's
// centre through the whole overlay stack.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/main.dart';
import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';

import 'flows/flow_test_helpers.dart';

HomeStore _storeOf(WidgetTester tester) =>
    (tester.state(find.byType(EatovaHomePage)) as HomePageDebugAccess)
        .debugStore;

const MealAnalysisResult _skyr = MealAnalysisResult(
  mealName: 'Skyr Natur',
  caloriesKcal: 230,
  estimatedGrams: 100,
  kcalPer100G: 230,
  protein: '-',
  carbs: '-',
  fat: '-',
  confidence: 'Datenbank',
  portionNotes: '',
  barcode: '4000000000003',
  brand: 'Arla',
);

/// Boots on the food tab (German strings) and opens the search add sheet.
Future<void> _bootSheet(WidgetTester tester) async {
  tester.platformDispatcher.localesTestValue = const [Locale('de', 'DE')];
  addTearDown(tester.platformDispatcher.clearLocalesTestValue);
  await tester.pumpWidget(
    EatovaApp(productService: FakeProductLookupService()),
  );
  await tester.tap(find.byKey(const ValueKey('nav-Food')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('food-search')));
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('add-meal-sheet')), findsOneWidget);
}

/// Searches the fake product and logs it into the snack slot.
Future<void> _logSalami(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('slot-select-snack')));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.byKey(const ValueKey('kcal-product-search-input')),
    'Dr Oetker Salami',
  );
  await tester.tap(find.byKey(const ValueKey('kcal-product-search-button')));
  await tester.pump();
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('kcal-product-suggestion-0')));
  await tester.pumpAndSettle();
  final add = find.byKey(const ValueKey('kcal-product-suggestion-add-0'));
  await tester.ensureVisible(add);
  await tester.tap(add);
  // No pumpAndSettle: it would run the toast's dwell time out.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

/// Lets the current toast expire (dwell + own dismiss timer).
Future<void> _toastAblaufen(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}

void main() {
  testWidgetsRobust('Erfolgs-Toast ist bei offenem Add-Sheet antippbar', (
    WidgetTester tester,
  ) async {
    await _bootSheet(tester);
    await _logSalami(tester);

    final toast = find.text('252 kcal zu Snacks hinzugefügt.');
    expect(toast, findsOneWidget);
    expect(
      toast.hitTestable(),
      findsOneWidget,
      reason: 'der Toast liegt unter dem Scrim des Sheets',
    );
  });

  testWidgetsRobust(
      'Löschen im Add-Sheet: der Rückgängig-Knopf des Store-Toasts ist '
      'antippbar', (WidgetTester tester) async {
    await _bootSheet(tester);
    await _logSalami(tester);
    await _toastAblaufen(tester);

    // The mirrored row carries the store id, so match the key by prefix.
    final entfernen = find.byWidgetPredicate((w) {
      final key = w.key;
      return w is IconButton &&
          key is ValueKey<String> &&
          key.value.startsWith('analyse-existing-remove-');
    });
    expect(entfernen, findsOneWidget);
    await tester.ensureVisible(entfernen);
    await tester.tap(entfernen);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Mahlzeit gelöscht').hitTestable(), findsOneWidget);
    final undo = find.text('Rückgängig');
    expect(undo, findsOneWidget);
    expect(
      undo.hitTestable(),
      findsOneWidget,
      reason: 'Rückgängig liegt unter dem Scrim und ist tot',
    );

    // And it actually works from there.
    await tester.tap(undo);
    await tester.pumpAndSettle();
    expect(_storeOf(tester).loggedMeals.length, 1);

    // P8-01/P8-08: the store alone is not the proof. The undo must reach the
    // OPEN sheet, or the user sees a dead "Rückgängig", books the meal again
    // and has it twice in the diary.
    expect(
      find.byKey(const ValueKey('analyse-existing-meals')),
      findsOneWidget,
      reason: 'die „Bereits hinzugefügt"-Karte kommt nicht zurück',
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('analyse-existing-total-kcal')),
        matching: find.text('252 kcal'),
        matchRoot: true,
      ),
      findsOneWidget,
      reason: 'die Slot-Summe bleibt nach dem Rückgängig zu niedrig',
    );
  });

  testWidgetsRobust(
      'Favorit löschen im Add-Sheet: Rückgängig stellt die Kachel wieder her',
      (WidgetTester tester) async {
    await _bootSheet(tester);
    await _logSalami(tester);
    await _toastAblaufen(tester);

    // Logging created an auto-recent in the store; the open sheet follows it.
    // Clearing the search term switches the zone back from hits to favorites.
    await tester.enterText(
      find.byKey(const ValueKey('kcal-product-search-input')),
      '',
    );
    await tester.pumpAndSettle();
    final kachel = find.byKey(const ValueKey('favorite-tile-0'));
    await tester.ensureVisible(kachel);
    expect(kachel, findsOneWidget);

    final x = find.descendant(of: kachel, matching: find.byTooltip('Entfernen'));
    await tester.tap(x);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('favorite-tile-0')), findsNothing);

    final undo = find.text('Rückgängig');
    expect(undo.hitTestable(), findsOneWidget);
    await tester.tap(undo);
    await tester.pumpAndSettle();

    expect(_storeOf(tester).favorites, hasLength(1));
    expect(
      find.byKey(const ValueKey('favorite-tile-0')),
      findsOneWidget,
      reason: 'P8-05: das Rückgängig erreicht die Favoritenliste des Sheets nicht',
    );
  });

  testWidgetsRobust('Entpinnen im Favoriten-Sheet: Toast ist antippbar', (
    WidgetTester tester,
  ) async {
    await _bootSheet(tester);
    _storeOf(tester).toggleFavorite(_skyr);
    await tester.pumpAndSettle();
    // The sheet holds a copy: reopen so the pin is visible.
    await tester.tap(find.byKey(const ValueKey('add-meal-sheet-close')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('food-search')));
    await tester.pumpAndSettle();

    final alle = find.byKey(const ValueKey('add-meal-favorites-all'));
    await tester.ensureVisible(alle);
    await tester.tap(alle);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('favorites-sheet')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('favorites-sheet-fav-0')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Favorit entfernt').hitTestable(), findsOneWidget);
  });
}
