// Manual entry (spec 2026-08-13) through the real app: the labelled row below
// the slot choice opens the form and logs into the day total, and a search
// that finds nothing offers the form with the query as the name. When the
// row gives way to the results and the error state's retry live in
// add_meal_sheet_keystroke_rebuild_test.dart and
// add_meal_search_throttle_test.dart.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/main.dart';

import 'flow_test_helpers.dart';

void main() {
  testWidgetsRobust('Manuell-Zeile: manueller Eintrag landet im Tagestotal', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      EatovaApp(productService: FakeProductLookupService()),
    );

    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await tester.pumpAndSettle();

    // ensureVisible: the snack slot sits below the fold.
    final addSnack = find.byKey(const ValueKey('food-slot-add-snack'));
    await tester.ensureVisible(addSnack);
    await tester.tap(addSnack);
    await tester.pumpAndSettle();

    final manualRow = find.byKey(const ValueKey('manual-entry-button'));
    await tester.ensureVisible(manualRow);
    await tester.tap(manualRow);
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('manual-meal-name')),
      'Bauern-Mozzarella',
    );
    await tester.enterText(
      find.byKey(const ValueKey('manual-meal-kcal100')),
      '265',
    );
    await tester.enterText(
      find.byKey(const ValueKey('manual-meal-grams')),
      '125',
    );
    await tester.pump();

    final save = find.byKey(const ValueKey('manual-meal-save'));
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();

    // 265 × 1.25 = 331 kcal.
    expect(find.textContaining('331'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('add-meal-sheet-close')));
    await tester.pumpAndSettle();
    await expectTagestotalAufHeute(tester, '331');
  });

  testWidgetsRobust(
    'Leersuche bietet den manuellen Eintrag mit Vorbelegung an',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        EatovaApp(productService: NeverFindsProductLookupService()),
      );

      await tester.tap(find.byKey(const ValueKey('nav-Food')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('food-search')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('kcal-product-search-input')),
        'Bauernmozzarella',
      );
      // Debounce (1000 ms) + 2 empty retries (600 ms each).
      await tester.pump(const Duration(milliseconds: 1100));
      await tester.pump(const Duration(milliseconds: 1300));
      await tester.pumpAndSettle();

      final cta = find.byKey(const ValueKey('manual-entry-cta'));
      expect(
        cta,
        findsOneWidget,
        reason: 'endgueltig nichts gefunden -> direkter Weg ins Formular',
      );

      await tester.tap(cta);
      await tester.pumpAndSettle();
      final nameFeld = tester.widget<TextField>(
        find.byKey(const ValueKey('manual-meal-name')),
      );
      expect(
        nameFeld.controller?.text,
        'Bauernmozzarella',
        reason: 'der erfolglose Suchbegriff ist der wahrscheinlichste Name',
      );
    },
  );
}
