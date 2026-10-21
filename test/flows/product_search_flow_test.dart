// Product search through the real app: live suggestions while typing wait
// through transient failures. Search, add and the day total run in
// food_log_flow_test.dart; that an EMPTY result triggers no retry is pinned in
// add_meal_search_throttle_test.dart.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/main.dart';
import 'package:eatova/src/l10n/l10n.dart';

import 'flow_test_helpers.dart';

void main() {
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
}
