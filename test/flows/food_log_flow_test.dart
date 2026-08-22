// Food logging flows: slot picking in the add sheet, swipe-to-delete in the
// history and day separation in the food calendar.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/main.dart';

import 'flow_test_helpers.dart';

void main() {
  testWidgetsRobust('Food add lets the user pick the meal slot, not the clock', (
    WidgetTester tester,
  ) async {
    // Pin the device locale: without an override EatovaApp resolves via
    // resolveEatovaLocale (device -> de/en), and the assertions below match
    // German ARB strings verbatim.
    tester.platformDispatcher.localesTestValue = const [Locale('de', 'DE')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    await tester.pumpWidget(
      EatovaApp(productService: FakeProductLookupService()),
    );

    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('food-search')));
    await tester.pumpAndSettle();

    // The add sheet offers a slot selector with all four slots.
    expect(find.byKey(const ValueKey('add-meal-slot-select')), findsOneWidget);
    expect(find.byKey(const ValueKey('slot-select-breakfast')), findsOneWidget);
    expect(find.byKey(const ValueKey('slot-select-lunch')), findsOneWidget);
    expect(find.byKey(const ValueKey('slot-select-dinner')), findsOneWidget);
    expect(find.byKey(const ValueKey('slot-select-snack')), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('kcal-product-search-input')),
      'Dr Oetker Salami',
    );
    await tester.tap(find.byKey(const ValueKey('kcal-product-search-button')));
    await tester.pump();
    await tester.pumpAndSettle();

    // 1) Pick the snack slot -> the entry lands there.
    await tester.tap(find.byKey(const ValueKey('slot-select-snack')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('kcal-product-suggestion-0')));
    await tester.pumpAndSettle();
    final addSnack = find.byKey(const ValueKey('kcal-product-suggestion-add-0'));
    await tester.ensureVisible(addSnack);
    await tester.tap(addSnack);
    await tester.pumpAndSettle();
    expect(find.text('252 kcal zu Snacks hinzugefügt.'), findsOneWidget);

    // Let the first snackbar expire so the next one is not queued behind it.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    // 2) Pick breakfast in the same sheet. Two different slots prove the
    // selector decides, not the clock heuristic (which yields one slot).
    await tester.tap(find.byKey(const ValueKey('slot-select-breakfast')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('kcal-product-suggestion-0')));
    await tester.pumpAndSettle();
    final addBreakfast =
        find.byKey(const ValueKey('kcal-product-suggestion-add-0'));
    await tester.ensureVisible(addBreakfast);
    await tester.tap(addBreakfast);
    await tester.pumpAndSettle();
    expect(find.text('252 kcal zu Frühstück hinzugefügt.'), findsOneWidget);
  });

  testWidgetsRobust('Food history row can be swiped to delete and updates live', (
    WidgetTester tester,
  ) async {
    // Pin the device locale: without an override EatovaApp resolves via
    // resolveEatovaLocale (device -> de/en), and the assertions below match
    // German ARB strings verbatim.
    tester.platformDispatcher.localesTestValue = const [Locale('de', 'DE')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    await tester.pumpWidget(
      EatovaApp(productService: FakeProductLookupService()),
    );

    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await tester.pumpAndSettle();

    // Add an entry via search.
    await tester.tap(find.byKey(const ValueKey('food-search')));
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
    final addButton =
        find.byKey(const ValueKey('kcal-product-suggestion-add-0'));
    await tester.ensureVisible(addButton);
    await tester.tap(addButton);
    await tester.pumpAndSettle();

    // Close the sheet to reach the history card.
    await tester.tap(find.byKey(const ValueKey('add-meal-sheet-close')));
    await tester.pumpAndSettle();

    // Entry is in the history …
    expect(find.byKey(const ValueKey('food-history-entry-0')), findsOneWidget);
    // … and in the day total, which lives in the Heute tab (see
    // expectTagestotalAufHeute), not in a food-tab card.
    await expectTagestotalAufHeute(tester, '252');
    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await tester.pumpAndSettle();

    // Let the confirmation toast expire: it covers the bottom diary row, so
    // the swipe would hit the snackbar instead.
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();

    // Swipe right to left -> delete action appears -> tap it. ensureVisible is
    // required because the clock heuristic decides the slot card, and from the
    // third card on the row sits below the fold.
    await tester.ensureVisible(
      find.byKey(const ValueKey('food-history-entry-0')),
    );
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const ValueKey('food-history-entry-0')),
      const Offset(-300, 0),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('food-history-delete-0')), findsOneWidget);
    await tester.ensureVisible(
      find.byKey(const ValueKey('food-history-delete-0')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('food-history-delete-0')));
    await tester.pumpAndSettle();

    // Entry is gone at once and the day total drops to 0.
    expect(find.byKey(const ValueKey('food-history-entry-0')), findsNothing);
    await expectTagestotalAufHeute(tester, '0');
  });

  testWidgetsRobust('Food calendar keeps past days separate from today', (
    WidgetTester tester,
  ) async {
    // Pin the device locale: without an override EatovaApp resolves via
    // resolveEatovaLocale (device -> de/en), and the assertions below match
    // German ARB strings verbatim.
    tester.platformDispatcher.localesTestValue = const [Locale('de', 'DE')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    await tester.pumpWidget(
      EatovaApp(productService: FakeProductLookupService()),
    );

    // Today starts empty. The day total lives in the Heute tab, which follows
    // the same selected day as the food tab, so it also works for an
    // archived day.
    await expectTagestotalAufHeute(tester, '0');

    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('food-date-chip-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('food-date-chip-2')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('food-date-chip-2')));
    await tester.pumpAndSettle();
    expect(find.text('Vor 2 Tagen'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('food-search')));
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
    final pastAddButton =
        find.byKey(const ValueKey('kcal-product-suggestion-add-0'));
    await tester.ensureVisible(pastAddButton);
    await tester.tap(pastAddButton);
    await tester.pumpAndSettle();

    // Close AddMealSheet, else the modal barrier eats the next tap.
    await tester.tap(find.byKey(const ValueKey('add-meal-sheet-close')));
    await tester.pumpAndSettle();

    // The archived day carries the 252 …
    await expectTagestotalAufHeute(tester, '252');

    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await tester.pumpAndSettle();

    // In the descending 30-day strip today is chip-0; the index is the day
    // offset. Switch back to today.
    await tester.tap(find.byKey(const ValueKey('food-date-chip-0')));
    await tester.pumpAndSettle();
    expect(find.text('Heute'), findsWidgets);
    // … and today stays untouched.
    await expectTagestotalAufHeute(tester, '0');
  });
}
