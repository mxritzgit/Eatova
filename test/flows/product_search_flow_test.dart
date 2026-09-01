// Product search flows: text search with result selection, live suggestions
// while typing, retry on transient failures, and the counter-check that an
// EMPTY result triggers no retry.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/main.dart';
import 'package:eatova/src/l10n/l10n.dart';

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

    // Close the sheet and check the today tab: the daily total lives there
    // since the calorie card left the food tab.
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
    final dienst = FlakyProductLookupService();
    await tester.pumpWidget(EatovaApp(productService: dienst));

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

    // Through the ARB bundle, and in the language the flow actually runs in.
    // This used to name a hard-coded GERMAN sentence that no longer exists in
    // either bundle — in an English app it could never be found, so both
    // `findsNothing` lines passed by construction.
    expect(find.text(enL10n.foodSearchUnreachableHint), findsNothing,
        reason: 'waehrend die Wiederholungen laufen, darf kein Fehler stehen');

    await tester.pump(const Duration(milliseconds: 3600));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('kcal-product-suggestion-0')), findsOneWidget);
    expect(find.textContaining('Dr. Oetker'), findsWidgets);
    expect(find.text(enL10n.foodSearchUnreachableHint), findsNothing);
    // Two failures had to be survived, not skipped: without this the same
    // green would follow from a service that never failed.
    expect(dienst.searchAttempts, 3,
        reason: 'die dritte Anfrage ist die erste erfolgreiche');
  });

  // Empty is an ANSWER, not an error. One attempt fans out across mirror +
  // OFF-de + OFF-world in the service layer, so three attempts would mean
  // nine requests for a "does not exist". The service is asked exactly ONCE;
  // retries stay reserved for real failures (see the flaky test above).
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
    // Debounce (1000 ms) plus the room two retries (600 ms each) would need —
    // exactly the room that must now stay unused.
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
    // The flow harness starts the app without a forced language and lands on
    // ENGLISH, so the hint is checked in its en wording.
    expect(
      find.text('No matching products found. Try a brand plus product name.'),
      findsOneWidget,
    );
  });
}
