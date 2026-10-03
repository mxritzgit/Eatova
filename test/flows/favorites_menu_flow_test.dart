// Favorites menu flows (feature 2026-08-27): the add sheet's "All (N)" button
// opens the favorites sheet. Adding there logs into the slot chosen in the
// add sheet, unpinning there flows back into the favorites row and the store,
// and the local search narrows the list.

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/main.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';

import 'flow_test_helpers.dart';
import '../support/meal_slot_picker.dart';

MealAnalysisResult _meal(
  String name, {
  required String brand,
  required String barcode,
  required int kcal,
}) {
  return MealAnalysisResult(
    mealName: name,
    caloriesKcal: kcal,
    estimatedGrams: 100,
    kcalPer100G: kcal.toDouble(),
    protein: '-',
    carbs: '-',
    fat: '-',
    confidence: 'Datenbank',
    portionNotes: '',
    barcode: barcode,
    brand: brand,
  );
}

// Pinned in this order with fixed timestamps (oldest first), so the sheet and
// lists them newest first: Haferdrink, Skyr, Brot, Bananen.
final MealAnalysisResult _bananen =
    _meal('Bananen', brand: 'Chiquita', barcode: '4000000000001', kcal: 90);
final MealAnalysisResult _brot =
    _meal('Vollkornbrot', brand: 'Harry', barcode: '4000000000002', kcal: 210);
final MealAnalysisResult _skyr =
    _meal('Skyr Natur', brand: 'Arla', barcode: '4000000000003', kcal: 230);
final MealAnalysisResult _haferdrink =
    _meal('Haferdrink', brand: 'Alpro', barcode: '4000000000004', kcal: 120);
final List<MealAnalysisResult> _pinnedOldestFirst = [
  _bananen,
  _brot,
  _skyr,
  _haferdrink,
];

// Auto-recents: logged, never pinned. Explicit snack slot so they cannot land
// in lunch by the clock heuristic and blur the slot assertion below.
final MealAnalysisResult _apfel =
    _meal('Apfel', brand: 'Hofladen', barcode: '4000000000005', kcal: 52);
final MealAnalysisResult _reiswaffeln =
    _meal('Reiswaffeln', brand: 'Continental', barcode: '4000000000006', kcal: 35);

/// Boots the app on the food tab with 4 pinned favorites and 2 recents in the
/// real store, then opens the add sheet the way the food tab does.
Future<HomeStore> _bootWithFavorites(WidgetTester tester) async {
  // Pin the device locale: the assertions below match German ARB strings.
  tester.platformDispatcher.localesTestValue = const [Locale('de', 'DE')];
  addTearDown(tester.platformDispatcher.clearLocalesTestValue);
  await tester.pumpWidget(
    EatovaApp(productService: FakeProductLookupService()),
  );

  final store = storeOf(tester);
  for (var i = 0; i < _pinnedOldestFirst.length; i++) {
    // `addedAt` is the recency key of the sheet; a fixed clock per pin keeps
    // the order independent of how fast the loop runs.
    withClock(
      Clock.fixed(DateTime(2026, 8, 20, 8 + i)),
      () => store.toggleFavorite(_pinnedOldestFirst[i]),
    );
  }
  store.addResultToDailyTotal(_apfel, slot: MealSlot.snack);
  store.addResultToDailyTotal(_reiswaffeln, slot: MealSlot.snack);
  await tester.pumpAndSettle();
  expect(store.favorites.where((f) => f.pinned).length, 4);
  expect(store.favorites.where((f) => !f.pinned).length, 2);

  await tester.tap(find.byKey(const ValueKey('nav-Food')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('food-search')));
  await tester.pumpAndSettle();
  return store;
}

/// Opens the favorites sheet via the "All (N)" button of the add sheet.
Future<void> _openFavoritesMenu(WidgetTester tester) async {
  final allButton = find.byKey(const ValueKey('add-meal-favorites-all'));
  await tester.ensureVisible(allButton);
  await tester.pumpAndSettle();
  await tester.tap(allButton);
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('favorites-sheet')), findsOneWidget);
}

/// Use the visible close action; a tall collection can fill the modal cap.
Future<void> _dismissFavoritesMenu(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('favorites-sheet-close')));
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('favorites-sheet')), findsNothing);
}

/// Text inside the favorites sheet only, not the add sheet behind it.
Finder _menuText(String text) => find.descendant(
      of: find.byKey(const ValueKey('favorites-sheet')),
      matching: find.text(text),
    );

void main() {
  testWidgetsRobust('Favorites menu logs a favorite into the chosen slot', (
    WidgetTester tester,
  ) async {
    final store = await _bootWithFavorites(tester);
    final loggedBefore = store.loggedMeals.length;

    // Since 2026-10-03: no inline favorites, one row with the count.
    final zeile = find.byKey(const ValueKey('add-meal-favorites-all'));
    expect(find.byKey(const ValueKey('favorite-pinned-0')), findsNothing);
    expect(
      find.descendant(of: zeile, matching: find.text('4 gespeichert')),
      findsOneWidget,
    );

    // Slot is chosen in the add sheet, not in the favorites sheet.
    await chooseMealSlot(tester, 'slot-select-lunch');
    await tester.pumpAndSettle();

    await _openFavoritesMenu(tester);

    // The sheet lists ALL pinned, newest first, and no recents.
    expect(find.text('Favoriten (4)'), findsOneWidget);
    for (var i = 0; i < 4; i++) {
      expect(find.byKey(ValueKey('favorites-sheet-item-$i')), findsOneWidget);
    }
    expect(find.byKey(const ValueKey('favorites-sheet-item-4')), findsNothing);
    expect(_menuText('Haferdrink'), findsOneWidget);
    expect(_menuText('Bananen'), findsOneWidget);
    expect(_menuText('Apfel'), findsNothing);
    expect(_menuText('Reiswaffeln'), findsNothing);

    // Expand row 0 and add it.
    await tester.tap(find.byKey(const ValueKey('favorites-sheet-item-0')));
    await tester.pumpAndSettle();
    final addButton = find.byKey(const ValueKey('favorites-sheet-add-0'));
    await tester.ensureVisible(addButton);
    await tester.pumpAndSettle();
    await tester.tap(addButton);
    await tester.pumpAndSettle();
    expect(find.text('120 kcal zu Mittagessen hinzugefügt.'), findsOneWidget);

    // The store carries the meal in the chosen slot.
    expect(store.loggedMeals.length, loggedBefore + 1);
    final logged = store.loggedMeals.first;
    expect(logged.result.mealName, 'Haferdrink');
    expect(logged.slot, MealSlot.lunch);
    expect(logged.forcedSlot, MealSlot.lunch);
    expect(store.isFavorite(_haferdrink), isTrue);

    // Back in the add sheet the favorites row is unchanged.
    await _dismissFavoritesMenu(tester);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('add-meal-favorites-all')),
        matching: find.text('4 gespeichert'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('add-meal-sheet-close')));
    await tester.pumpAndSettle();
  });

  testWidgetsRobust('Unpin in the favorites menu updates the favorites row', (
    WidgetTester tester,
  ) async {
    final store = await _bootWithFavorites(tester);
    await _openFavoritesMenu(tester);

    // Heart on row 0 (Haferdrink): the row leaves the sheet, the count drops.
    await tester.tap(find.byKey(const ValueKey('favorites-sheet-fav-0')));
    await tester.pumpAndSettle();
    expect(find.text('Favorit entfernt'), findsOneWidget);
    expect(find.text('Favoriten (3)'), findsOneWidget);
    expect(find.byKey(const ValueKey('favorites-sheet-item-3')), findsNothing);
    expect(_menuText('Haferdrink'), findsNothing);
    expect(_menuText('Skyr Natur'), findsOneWidget);

    // The store took the unpin, not just the sheet's local mirror.
    expect(store.isFavorite(_haferdrink), isFalse);
    expect(store.isFavorite(_skyr), isTrue);
    expect(store.favorites.where((f) => f.pinned).length, 3);

    // The row counts one less.
    await _dismissFavoritesMenu(tester);
    final zeile = find.byKey(const ValueKey('add-meal-favorites-all'));
    expect(find.byKey(const ValueKey('favorite-pinned-0')), findsNothing);
    expect(
      find.descendant(of: zeile, matching: find.text('3 gespeichert')),
      findsOneWidget,
    );
    expect(find.text('4 gespeichert'), findsNothing);

    // Reopened from the store, the add sheet shows the same picture.
    await tester.tap(find.byKey(const ValueKey('add-meal-sheet-close')));
    await tester.pumpAndSettle();
    // Let the unpin snackbar expire so it cannot catch the next tap.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('food-search')));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('add-meal-favorites-all')),
        matching: find.text('3 gespeichert'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('add-meal-sheet-close')));
    await tester.pumpAndSettle();
  });

  testWidgetsRobust('Search inside the favorites menu narrows the list', (
    WidgetTester tester,
  ) async {
    await _bootWithFavorites(tester);
    await _openFavoritesMenu(tester);
    final search = find.byKey(const ValueKey('favorites-sheet-search'));
    expect(search, findsOneWidget);

    // Name match: only Haferdrink stays.
    await tester.enterText(search, 'hafer');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('favorites-sheet-item-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('favorites-sheet-item-1')), findsNothing);
    expect(_menuText('Haferdrink'), findsOneWidget);
    expect(_menuText('Skyr Natur'), findsNothing);
    expect(find.byKey(const ValueKey('favorites-sheet-no-match')), findsNothing);

    // Brand match works the same way.
    await tester.enterText(search, 'alpro');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('favorites-sheet-item-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('favorites-sheet-item-1')), findsNothing);
    expect(_menuText('Haferdrink'), findsOneWidget);

    // Nonsense query: the no-match hint replaces the list.
    await tester.enterText(search, 'xyzzy');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('favorites-sheet-no-match')), findsOneWidget);
    expect(find.byKey(const ValueKey('favorites-sheet-item-0')), findsNothing);
    expect(find.text('Favoriten (4)'), findsOneWidget);

    // Clearing the query brings all four back.
    await tester.tap(find.byKey(const ValueKey('favorites-sheet-search-clear')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('favorites-sheet-no-match')), findsNothing);
    expect(find.byKey(const ValueKey('favorites-sheet-item-3')), findsOneWidget);

    await _dismissFavoritesMenu(tester);
    await tester.tap(find.byKey(const ValueKey('add-meal-sheet-close')));
    await tester.pumpAndSettle();
  });

  // Lively list (2026-10-03): "Frequent" counts the store's logged meals,
  // while "Recent" follows the last use.
  testWidgetsRobust('Favorites menu sorts by how often a favorite was logged', (
    WidgetTester tester,
  ) async {
    final store = await _bootWithFavorites(tester);
    for (var i = 0; i < 3; i++) {
      await store.addResultToDailyTotal(_bananen, slot: MealSlot.snack);
    }
    await store.addResultToDailyTotal(_brot, slot: MealSlot.snack);
    await tester.pumpAndSettle();

    await _openFavoritesMenu(tester);
    String row(int i) => tester
        .widgetList<Text>(
          find.descendant(
            of: find.byKey(ValueKey('favorites-sheet-item-$i')),
            matching: find.byType(Text),
          ),
        )
        .firstWhere((text) => text.data != null)
        .data!;
    expect([for (var i = 0; i < 4; i++) row(i)], [
      'Vollkornbrot',
      'Bananen',
      'Haferdrink',
      'Skyr Natur',
    ]);

    await tester.tap(find.byKey(const ValueKey('favorites-sheet-sort-frequent')));
    await tester.pumpAndSettle();
    expect([for (var i = 0; i < 4; i++) row(i)], [
      'Bananen',
      'Vollkornbrot',
      'Haferdrink',
      'Skyr Natur',
    ]);
    await _dismissFavoritesMenu(tester);
  });
}
