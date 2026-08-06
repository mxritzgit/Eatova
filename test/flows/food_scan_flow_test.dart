// KI-Scan-Flows (aus test/widget_test.dart aufgeteilt): Foto-Analyse mit
// Einzelposten, Re-Portionierung inkl. Makro-Skalierung und das
// Favoriten-Herz auf der Ergebniskarte.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/main.dart';

import 'flow_test_helpers.dart';

void main() {
  testWidgetsRobust('Food tab supports deterministic itemized photo results and daily kcal adding', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      EatovaApp(
        mealAnalyzer: FakeMealAnalyzer(),
        mealCameraLauncher: FakeMealCameraLauncher(),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('analyse-daily-kcal-total')), findsOneWidget);
    expect(find.text('0 kcal'), findsOneWidget);

    // KI-Scan öffnet die (gefakte) In-App-Kamera -> liefert das Foto -> das
    // Analyse-Sheet öffnet direkt (kein generisches Add-Sheet mehr).
    await tester.tap(find.byKey(const ValueKey('food-action-ai')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('analyse-result-card')), findsOneWidget);
    expect(find.text('Kartoffeln'), findsOneWidget);
    expect(find.text('Steak'), findsOneWidget);
    expect(find.text('Brokkoli'), findsOneWidget);
    expect(find.byKey(const ValueKey('analyse-item-breakdown')), findsOneWidget);
    expect(find.text('855 kcal'), findsWidgets);

    await tester.ensureVisible(find.byKey(const ValueKey('analyse-add-daily-button')));
    await tester.tap(find.byKey(const ValueKey('analyse-add-daily-button')));
    await tester.pumpAndSettle();
    expect(find.text('Zu heute hinzugefügt'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('analyse-daily-kcal-card')),
        matching: find.text('855 kcal'),
      ),
      findsOneWidget,
    );

    await tester.ensureVisible(find.byKey(const ValueKey('analyse-adjust-button')));
    await tester.tap(find.byKey(const ValueKey('analyse-adjust-button')));
    await tester.pumpAndSettle();
    expect(find.text('Bestandteile anpassen'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('analyse-item-weight-input-0')),
      '150',
    );
    await tester.pumpAndSettle();
    expect(find.text('550 g ≈ 815 kcal'), findsOneWidget);

    await tester.ensureVisible(
      find.byKey(const ValueKey('analyse-save-weight-button')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('analyse-save-weight-button')));
    await tester.pumpAndSettle();
    expect(find.text('815 kcal'), findsWidgets);
    // Exakter Match auf das persistente "angepasst"-Label der Ergebniskarte
    // (meal_widgets), bewusst NICHT textContaining: die Bestätigungs-Snackbar
    // ("… angepasst. Tageswert aktualisiert.") enthält denselben Teilstring und
    // rendert mit dem neuen no-stacking-Toast sofort -> textContaining wäre
    // mehrdeutig. Das exakte Label ist timing-unabhängig.
    expect(find.text('550 g über Einzelposten angepasst'), findsOneWidget);
    expect(find.text('Zu heute hinzugefügt'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('analyse-daily-kcal-card')),
        matching: find.text('815 kcal'),
      ),
      findsOneWidget,
    );
  });

  // PROD-3: Re-Portionierung einer bereits geloggten Mahlzeit skaliert kcal UND
  // Makros (frueher froren Protein/KH/Fett ein und der kcal-Delta traf zudem die
  // FALSCHE — erste — Mahlzeit des Tages). 300 g / 30 g Protein -> 400 g muss
  // Protein auf ~40 g hochskalieren (Makro-Balken zeigt 40/130g).
  testWidgetsRobust('Re-portioning a logged meal scales macros, not just kcal', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      EatovaApp(
        mealAnalyzer: MacroMealAnalyzer(),
        mealCameraLauncher: FakeMealCameraLauncher(),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await tester.pumpAndSettle();

    // Vor dem Loggen: Protein 0/130g.
    expect(find.text('0/130g'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('food-action-ai')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('analyse-result-card')), findsOneWidget);

    // Hinzufuegen -> 30 g Protein im Tageswert.
    await tester.ensureVisible(find.byKey(const ValueKey('analyse-add-daily-button')));
    await tester.tap(find.byKey(const ValueKey('analyse-add-daily-button')));
    await tester.pumpAndSettle();
    expect(find.text('Zu heute hinzugefügt'), findsOneWidget);

    // Re-Portionierung: 300 g -> 400 g (Einzelposten-Sheet, ein synthetischer
    // Posten fuer die nicht-itemisierte Mahlzeit).
    await tester.ensureVisible(find.byKey(const ValueKey('analyse-adjust-button')));
    await tester.tap(find.byKey(const ValueKey('analyse-adjust-button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('analyse-item-weight-input-0')),
      '400',
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('analyse-save-weight-button')),
    );
    await tester.tap(find.byKey(const ValueKey('analyse-save-weight-button')));
    await tester.pumpAndSettle();

    // Der Makro-Balken der Food-Seite liegt hinter den Sheets im Widget-Tree
    // und ist daher direkt findbar. Protein skaliert von 30 auf ~40 g
    // (400/300 * 30 = 40). Vorher fror der Bug das Protein bei 30 ein, waehrend
    // nur die kcal stiegen — UND traf zudem die falsche Mahlzeit.
    expect(find.text('40/130g'), findsOneWidget);
    expect(find.text('30/130g'), findsNothing);
  });

  // PROD-4: Das Favoriten-Herz rendert im Analyse-Ergebnis und das Antippen
  // heftet die Mahlzeit an (eigene „Favoriten"-Sektion im Add-Sheet).
  testWidgetsRobust('Meal result shows a favorite heart that pins the meal', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      EatovaApp(
        mealAnalyzer: MacroMealAnalyzer(),
        mealCameraLauncher: FakeMealCameraLauncher(),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('food-action-ai')));
    await tester.pumpAndSettle();

    // Das Herz rendert (onToggleFavorite ist verdrahtet).
    expect(find.byKey(const ValueKey('analyse-favorite-button')), findsOneWidget);
    expect(find.byIcon(Icons.favorite_outline_rounded), findsOneWidget);

    // Anheften -> Herz wird gefuellt.
    await tester.tap(find.byKey(const ValueKey('analyse-favorite-button')));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.favorite_rounded), findsWidgets);

    // Loggen, dann beide Sheets schliessen und erneut oeffnen: der angeheftete
    // Favorit steht in der eigenen „Favoriten"-Sektion (nicht „Letzte
    // Mahlzeiten").
    await tester.ensureVisible(find.byKey(const ValueKey('analyse-add-daily-button')));
    await tester.tap(find.byKey(const ValueKey('analyse-add-daily-button')));
    await tester.pumpAndSettle();
    // Nur das Analyse-Sheet ist offen (KI-Scan öffnet kein Add-Sheet mehr),
    // danach über die Suche das Add-Sheet zum Prüfen der Favoriten öffnen.
    await tester.tap(find.byKey(const ValueKey('analyse-sheet-close')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('food-search')));
    await tester.pumpAndSettle();
    expect(find.text('FAVORITEN'), findsOneWidget);
    expect(find.byKey(const ValueKey('favorite-pinned-0')), findsOneWidget);
  });
}
