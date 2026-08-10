// Produktsuche-Flows (aus test/widget_test.dart aufgeteilt): Textsuche mit
// Treffer-Auswahl, Live-Vorschlaege beim Tippen und die Retry-Logik bei
// transienten Fehlern bzw. voruebergehend leeren Ergebnissen.

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

  testWidgetsRobust('Kcal live product search retries temporary empty results', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      EatovaApp(productService: EmptyThenSuccessProductLookupService()),
    );

    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('food-search')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('kcal-product-search-input')),
      'Wagner Salami',
    );
    await tester.pump(const Duration(milliseconds: 1100));
    await tester.pump(const Duration(milliseconds: 20));

    expect(
      find.text('Keine passenden Produkte gefunden. Versuche Marke + Produktname.'),
      findsNothing,
    );

    await tester.pump(const Duration(milliseconds: 3600));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('kcal-product-suggestion-0')), findsOneWidget);
    expect(find.textContaining('Dr. Oetker'), findsWidgets);
    expect(
      find.text('Keine passenden Produkte gefunden. Versuche Marke + Produktname.'),
      findsNothing,
    );
  });
}
