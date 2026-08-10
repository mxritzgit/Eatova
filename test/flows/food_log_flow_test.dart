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

    // Eintrag ist im Verlauf …
    expect(find.byKey(const ValueKey('food-history-entry-0')), findsOneWidget);
    // … und im Tagestotal. Das steht seit dem 2026-08-10 im Heute-Tab, nicht
    // mehr in einer Karte des Food-Tabs (s. expectTagestotalAufHeute).
    await expectTagestotalAufHeute(tester, '252');
    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await tester.pumpAndSettle();

    // Den Bestaetigungs-Toast ablaufen lassen. Seit dem Design-Refactor reicht
    // das Tagebuch bis an den Seitenfuss, und der Toast liegt genau dort ueber
    // der untersten Zeile — der Wisch traefe sonst die Snackbar.
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();

    // Von rechts nach links swipen -> Lösch-Aktion erscheint -> antippen.
    //
    // ensureVisible ist ebenfalls neu noetig: die Eintraege liegen jetzt in
    // der Slot-Karte ihres Slots, und welcher das ist, entscheidet die
    // Uhrzeit-Heuristik. Ab der dritten Karte sitzt die Zeile im scrollbaren
    // Bereich unter dem Falz — ohne ensureVisible haenge der Test an der
    // CI-Uhrzeit.
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

    // Eintrag ist sofort weg und die Tagessumme aktualisiert direkt auf 0.
    expect(find.byKey(const ValueKey('food-history-entry-0')), findsNothing);
    await expectTagestotalAufHeute(tester, '0');
  });

  testWidgetsRobust('Food calendar keeps past days separate from today', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      EatovaApp(productService: FakeProductLookupService()),
    );

    // Vor allem anderen: heute ist leer. Das Tagestotal steht seit dem
    // 2026-08-10 im Heute-Tab — der demselben gewaehlten Tag folgt wie der
    // Food-Tab, deshalb taugt er auch als Orakel fuer einen Archivtag.
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

    // AddMealSheet schliessen, sonst absorbiert die Modal-Barrier den
    // naechsten Tap.
    await tester.tap(find.byKey(const ValueKey('add-meal-sheet-close')));
    await tester.pumpAndSettle();

    // Der ARCHIVTAG traegt die 252 …
    await expectTagestotalAufHeute(tester, '252');

    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await tester.pumpAndSettle();

    // Seit der absteigenden 30-Tage-Leiste ist Heute der ERSTE Chip
    // (chip-0); der Index ist der Tages-Offset. Test-Intention unveraendert:
    // zurueck zu Heute switchen.
    await tester.tap(find.byKey(const ValueKey('food-date-chip-0')));
    await tester.pumpAndSettle();
    expect(find.text('Heute'), findsWidgets);
    // … und heute bleibt davon unberuehrt. Genau das ist die Aussage.
    await expectTagestotalAufHeute(tester, '0');
  });
}
