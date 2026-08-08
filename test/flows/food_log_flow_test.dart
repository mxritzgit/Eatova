// Food-Logging-Flows (aus test/widget_test.dart aufgeteilt): Slot-Auswahl im
// Add-Sheet, Swipe-to-delete im Verlauf und die Tages-Trennung des
// Food-Kalenders.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/main.dart';

import 'flow_test_helpers.dart';

void main() {
  testWidgetsRobust('Food add lets the user pick the meal slot, not the clock', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      EatovaApp(productService: FakeProductLookupService()),
    );

    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('food-search')));
    await tester.pumpAndSettle();

    // Der Slot-Selector ist im Add-Sheet vorhanden, alle vier Slots wählbar.
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

    // 1) Slot "Snack" wählen -> Eintrag landet in Snacks.
    await tester.tap(find.byKey(const ValueKey('slot-select-snack')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('kcal-product-suggestion-0')));
    await tester.pumpAndSettle();
    final addSnack = find.byKey(const ValueKey('kcal-product-suggestion-add-0'));
    await tester.ensureVisible(addSnack);
    await tester.tap(addSnack);
    await tester.pumpAndSettle();
    expect(find.text('252 kcal zu Snacks hinzugefügt.'), findsOneWidget);

    // Erste Snackbar auslaufen lassen, damit die nächste nicht in der Queue
    // wartet (sonst verdeckt sie die zweite Bestätigung).
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    // 2) Im selben Sheet "Frühstück" wählen -> nächster Eintrag landet dort.
    // Zwei verschiedene Slots beweisen: der Selector steuert den Slot, nicht
    // die Uhrzeit-Heuristik (deren Default ist immer nur EIN Slot).
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
    await tester.pumpWidget(
      EatovaApp(productService: FakeProductLookupService()),
    );

    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await tester.pumpAndSettle();

    // Einen Eintrag über die Suche hinzufügen.
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

    // Sheet schließen, um an die Verlauf-Karte zu kommen.
    await tester.tap(find.byKey(const ValueKey('add-meal-sheet-close')));
    await tester.pumpAndSettle();

    // Eintrag ist im Verlauf, Tages-kcal zeigt ihn.
    expect(find.byKey(const ValueKey('food-history-entry-0')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('analyse-daily-kcal-card')),
        matching: find.text('252 kcal'),
      ),
      findsOneWidget,
    );

    // Von rechts nach links swipen -> Lösch-Aktion erscheint -> antippen.
    await tester.drag(
      find.byKey(const ValueKey('food-history-entry-0')),
      const Offset(-300, 0),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('food-history-delete-0')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('food-history-delete-0')));
    await tester.pumpAndSettle();

    // Eintrag ist sofort weg und die Tagessumme aktualisiert direkt auf 0.
    expect(find.byKey(const ValueKey('food-history-entry-0')), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('analyse-daily-kcal-card')),
        matching: find.text('0 kcal'),
      ),
      findsOneWidget,
    );
  });

  testWidgetsRobust('Food calendar keeps past days separate from today', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      EatovaApp(productService: FakeProductLookupService()),
    );

    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('food-date-chip-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('food-date-chip-2')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('analyse-daily-kcal-card')),
        matching: find.text('0 kcal'),
      ),
      findsOneWidget,
    );

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

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('analyse-daily-kcal-card')),
        matching: find.text('252 kcal'),
      ),
      findsOneWidget,
    );

    // AddMealSheet schliessen, sonst absorbiert die Modal-Barrier den
    // naechsten Chip-Tap.
    await tester.tap(find.byKey(const ValueKey('add-meal-sheet-close')));
    await tester.pumpAndSettle();

    // Seit der absteigenden 30-Tage-Leiste ist Heute der ERSTE Chip
    // (chip-0); der Index ist der Tages-Offset. Test-Intention unveraendert:
    // zurueck zu Heute switchen.
    await tester.tap(find.byKey(const ValueKey('food-date-chip-0')));
    await tester.pumpAndSettle();
    expect(find.text('Heute'), findsWidgets);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('analyse-daily-kcal-card')),
        matching: find.text('0 kcal'),
      ),
      findsOneWidget,
    );
  });
}
