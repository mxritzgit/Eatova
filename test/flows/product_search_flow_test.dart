// Produktsuche-Flows (aus test/widget_test.dart aufgeteilt): Textsuche mit
// Treffer-Auswahl, Live-Vorschlaege beim Tippen und die Retry-Logik bei
// transienten Fehlern — sowie die Gegenprobe, dass ein LEERES Ergebnis
// keinen Retry mehr ausloest (Komplettreview 2026-08-19).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/main.dart';

import 'flow_test_helpers.dart';

void main() {
  testWidgetsRobust('Food tab searches OpenFoodFacts products and adds selected item', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      EatovaApp(productService: FakeProductLookupService()),
    );

    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('food-search')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('kcal-product-search-input')),
      'Dr Oetker Salami',
    );
    await tester.tap(find.byKey(const ValueKey('kcal-product-search-button')));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.textContaining('Dr. Oetker'), findsWidgets);
    expect(find.byKey(const ValueKey('kcal-product-suggestion-0')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('kcal-product-suggestion-0')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Die Ofenfrische Salami'), findsWidgets);
    expect(find.text('252 kcal'), findsWidgets);

    final addButton =
        find.byKey(const ValueKey('kcal-product-suggestion-add-0'));
    await tester.ensureVisible(addButton);
    await tester.tap(addButton);
    await tester.pumpAndSettle();

    // Das Sheet schliessen und im Heute-Tab nachsehen: dort steht das
    // Tagestotal, seit die Kalorien-Karte aus dem Food-Tab entfernt ist.
    await tester.tap(find.byKey(const ValueKey('add-meal-sheet-close')));
    await tester.pumpAndSettle();
    await expectTagestotalAufHeute(tester, '252');
  });

  testWidgetsRobust('Kcal product search shows suggestions while typing', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      EatovaApp(productService: FakeProductLookupService()),
    );

    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('food-search')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('kcal-product-search-input')),
      'Dr Oetker',
    );
    await tester.pump(const Duration(milliseconds: 1100));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('kcal-product-suggestion-0')), findsOneWidget);
    expect(find.textContaining('Dr. Oetker'), findsWidgets);
  });

  testWidgetsRobust('Kcal live product search waits through transient failures', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      EatovaApp(productService: FlakyProductLookupService()),
    );

    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('food-search')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('kcal-product-search-input')),
      'Dr Oetker',
    );
    await tester.pump(const Duration(milliseconds: 1100));
    await tester.pump(const Duration(milliseconds: 20));

    expect(find.text('OpenFoodFacts-Suche gerade nicht erreichbar.'), findsNothing);

    await tester.pump(const Duration(milliseconds: 3600));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('kcal-product-suggestion-0')), findsOneWidget);
    expect(find.textContaining('Dr. Oetker'), findsWidgets);
    expect(find.text('OpenFoodFacts-Suche gerade nicht erreichbar.'), findsNothing);
  });

  // Komplettreview 2026-08-19: leer ist eine ANTWORT, kein Fehler.
  //
  // Bis dahin lief ein leeres (aber fehlerfreies) Ergebnis durch dieselbe
  // Retry-Schleife wie ein Netzfehler — in der Annahme, der Mirror sei nur
  // kalt. Bezahlt hat das jede erfolglose Suche: ein Versuch faechert sich in
  // der Dienstschicht ueber Mirror + OFF-de + OFF-world auf, drei Versuche
  // machen daraus neun Anfragen fuer ein "gibt es nicht". Der Dienst wird
  // seitdem genau EINMAL gefragt; Retries bleiben echten Fehlern vorbehalten
  // (siehe den Flaky-Test darueber).
  testWidgetsRobust('Kcal live product search takes an empty result as final', (
    WidgetTester tester,
  ) async {
    final dienst = EmptyThenSuccessProductLookupService();
    await tester.pumpWidget(EatovaApp(productService: dienst));

    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('food-search')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('kcal-product-search-input')),
      'Wagner Salami',
    );
    // Debounce (1000 ms) plus der Raum, den zwei Retries (je 600 ms) brauchen
    // wuerden — genau der Raum, der jetzt ungenutzt bleiben muss.
    await tester.pump(const Duration(milliseconds: 1100));
    await tester.pump(const Duration(milliseconds: 1300));
    await tester.pumpAndSettle();

    expect(
      dienst.searchAttempts,
      1,
      reason: 'eine erfolglose Suche darf die Dienstkette nicht dreimal '
          'anfassen',
    );
    expect(find.byKey(const ValueKey('kcal-product-suggestion-0')), findsNothing);
    // Der Flow-Harness startet die App ohne erzwungene Sprache und landet
    // deshalb auf ENGLISCH — der Hinweis wird hier in seiner en-Fassung
    // geprueft (die beiden findsNothing-Zusicherungen weiter oben sind gegen
    // diese Falle immun, ein findsOneWidget waere es nicht).
    expect(
      find.text('No matching products found. Try a brand plus product name.'),
      findsOneWidget,
    );
  });
}
