// Manueller Eintrag (Spec 2026-08-13), Einstieg 1: die beschriftete
// "Manuell eintragen"-Zeile unter der Slot-Wahl oeffnet das Formular
// (Nutzer-Feedback 2026-08-13: vorher ein viertes Header-Icon — quetschte
// den Slot-Titel zweizeilig und war als nackter Stift kaum auffindbar);
// das Ergebnis loggt ueber denselben Pfad wie eine Such-/Favoriten-Zeile.

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

    // Slot-Tap oeffnet das Add-Sheet im normalen Modus.
    // ensureVisible: der Snack-Slot ist der vierte und liegt unter dem Falz
    // (Muster food_diary_screen_test.dart „Der Plus-Knopf...").
    final addSnack = find.byKey(const ValueKey('food-slot-add-snack'));
    await tester.ensureVisible(addSnack);
    await tester.tap(addSnack);
    await tester.pumpAndSettle();

    // Der Header traegt nur noch Kamera/Galerie/Barcode + X — der manuelle
    // Eintrag ist die beschriftete Zeile im Inhalt.
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

    // Erfolgs-Snack aus _handleAdd (265 × 1,25 = 331 kcal).
    expect(find.textContaining('331'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('add-meal-sheet-close')));
    await tester.pumpAndSettle();
    await expectTagestotalAufHeute(tester, '331');
  });

  testWidgetsRobust('Manuell-Zeile: sichtbar bis die Suche aktiv wird', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      EatovaApp(productService: FakeProductLookupService()),
    );

    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('food-search')));
    await tester.pumpAndSettle();

    // Auch im Such-Modus steht die Zeile bereit, solange nicht gesucht wird —
    // sie liegt im Inhalt, nicht im (dort schlanken) Kopf.
    expect(find.byKey(const ValueKey('manual-entry-button')), findsOneWidget);

    // Ab aktiver Suche uebernimmt der Ergebnisbereich (inkl. Leersuche-CTA);
    // die stehende Zeile verschwindet, damit nicht zwei Eingaenge konkurrieren.
    await tester.enterText(
      find.byKey(const ValueKey('kcal-product-search-input')),
      'Dr Oetker',
    );
    await tester.pump(const Duration(milliseconds: 1100));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('manual-entry-button')), findsNothing);
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
      // Debounce (1000 ms) + 2 Leer-Retries (je 600 ms) abwarten.
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
