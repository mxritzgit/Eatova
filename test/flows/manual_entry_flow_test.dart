// Manueller Eintrag (Spec 2026-08-13), Einstieg 1: das vierte Header-Icon im
// Add-Meal-Sheet oeffnet das Formular; das Ergebnis loggt ueber denselben
// Pfad wie eine Such-/Favoriten-Zeile in den gewaehlten Slot.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/main.dart';

import 'flow_test_helpers.dart';

void main() {
  testWidgetsRobust('Header-Icon: manueller Eintrag landet im Tagestotal', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      EatovaApp(productService: FakeProductLookupService()),
    );

    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await tester.pumpAndSettle();

    // Slot-Tap oeffnet das Add-Sheet im normalen Modus (Header-Icons an).
    // ensureVisible: der Snack-Slot ist der vierte und liegt unter dem Falz
    // (Muster food_diary_screen_test.dart „Der Plus-Knopf...").
    final addSnack = find.byKey(const ValueKey('food-slot-add-snack'));
    await tester.ensureVisible(addSnack);
    await tester.tap(addSnack);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('manual-entry-button')));
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

    // Erfolgs-Snack aus _handleAdd (265 × 1,25 = 331 kcal).
    expect(find.textContaining('331'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('add-meal-sheet-close')));
    await tester.pumpAndSettle();
    await expectTagestotalAufHeute(tester, '331');
  });

  testWidgetsRobust('Such-Modus zeigt das Header-Icon NICHT', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      EatovaApp(productService: FakeProductLookupService()),
    );

    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('food-search')));
    await tester.pumpAndSettle();

    // Der Kopf bleibt im Such-Modus schlank (wie Kamera/Galerie/Barcode).
    expect(find.byKey(const ValueKey('manual-entry-button')), findsNothing);
  });

  testWidgetsRobust('Leersuche bietet den manuellen Eintrag mit Vorbelegung an',
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
    // Debounce (1000 ms) + 2 Leer-Retries (je 600 ms) abwarten.
    await tester.pump(const Duration(milliseconds: 1100));
    await tester.pump(const Duration(milliseconds: 1300));
    await tester.pumpAndSettle();

    final cta = find.byKey(const ValueKey('manual-entry-cta'));
    expect(cta, findsOneWidget,
        reason: 'endgueltig nichts gefunden -> direkter Weg ins Formular');

    await tester.tap(cta);
    await tester.pumpAndSettle();
    final nameFeld = tester.widget<TextField>(
      find.byKey(const ValueKey('manual-meal-name')),
    );
    expect(nameFeld.controller?.text, 'Bauernmozzarella',
        reason: 'der erfolglose Suchbegriff ist der wahrscheinlichste Name');
  });

  testWidgetsRobust('Netz-Fehler zeigt KEINEN manuellen CTA', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      EatovaApp(productService: AlwaysFailingProductLookupService()),
    );

    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('food-search')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('kcal-product-search-input')),
      'Bauernmozzarella',
    );
    await tester.pump(const Duration(milliseconds: 1100));
    await tester.pump(const Duration(milliseconds: 1300));
    await tester.pumpAndSettle();

    // Fehler heisst „Suche kaputt", nicht „gibt es nicht" — kein CTA.
    expect(find.byKey(const ValueKey('manual-entry-cta')), findsNothing);
  });
}
