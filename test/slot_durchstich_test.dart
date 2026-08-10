import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/eatova_app.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/widgets/kcal/slot_selector.dart';

// Nutzer-Feedback 2026-08-10: Der schwebende „Essen loggen"-Knopf auf „Heute"
// ist entfallen. Damit sind die Mahlzeiten-Zeilen der EINZIGE Weg zum
// Nachtragen — und sie mussten bis dahin ihre Aussage unterwegs abgeben: die
// Schale warf den Slot weg (`onOpenMealSlot: (_) => setTab(food)`), der Nutzer
// landete im Food-Tab und musste „Mittagessen" ein zweites Mal waehlen.
//
// Diese Tests halten den Durchstich fest: Wer auf „Mittagessen" tippt, landet
// im Hinzufuegen-Fenster fuer Mittagessen.

void main() {
  Future<void> bootHeute(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const EatovaApp());
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-today')), findsOneWidget);
  }

  testWidgets('Tap auf eine Mahlzeit oeffnet das Hinzufuegen-Fenster fuer '
      'GENAU diesen Slot', (tester) async {
    await bootHeute(tester);

    // IMMER erst heranscrollen: Die Mahlzeiten-Zeilen liegen am unteren Rand,
    // und wie weit genau haengt an der Schriftmetrik der Plattform. Lokal
    // (Windows) war „Mittagessen" gerade noch tippbar, auf dem CI-Runner
    // (Linux) sass es bei y=801 von 852 — der Tipp ging dort ins Leere und der
    // Test behauptete danach etwas Falsches.
    final mittag = find.byKey(const ValueKey('today-meal-row-lunch'));
    await tester.ensureVisible(mittag);
    await tester.pumpAndSettle();
    await tester.tap(mittag);
    await tester.pumpAndSettle();

    // Der Wechsel auf den Food-Tab ist passiert ...
    expect(find.byKey(const ValueKey('screen-kcal-tracker')), findsOneWidget);
    // ... und das Sheet steht offen, mit Mittagessen vorgewaehlt.
    expect(find.byKey(const ValueKey('add-meal-slot-select')), findsOneWidget);
    // Der Key sitzt am Padding, der Waehler liegt darunter.
    final waehler = tester.widget<SlotSelector>(
      find.descendant(
        of: find.byKey(const ValueKey('add-meal-slot-select')),
        matching: find.byType(SlotSelector),
      ),
    );
    expect(waehler.selected, MealSlot.lunch);
  });

  testWidgets('ein zweiter Tap auf denselben Slot oeffnet kein zweites Fenster',
      (tester) async {
    await bootHeute(tester);

    // Abendessen liegt auf einem 852-px-Schirm unter der Falz — ohne
    // ensureVisible tippt der Test ins Leere und behauptet danach etwas
    // Falsches.
    final abend = find.byKey(const ValueKey('today-meal-row-dinner'));
    await tester.ensureVisible(abend);
    await tester.pumpAndSettle();
    await tester.tap(abend);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('add-meal-slot-select')), findsOneWidget);

    // Zurueck auf „Heute" und erneut tippen — die Anfrage darf sich nicht
    // aufstauen und beim naechsten Tab-Besuch ein Geister-Sheet oeffnen.
    await tester.tap(find.byKey(const ValueKey('add-meal-sheet-close')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('nav-Heute')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('add-meal-slot-select')), findsNothing,
        reason: 'ein blosser Tab-Wechsel darf kein Sheet oeffnen');
  });

  testWidgets('ein normaler Tab-Wechsel oeffnet nichts', (tester) async {
    await bootHeute(tester);

    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('screen-kcal-tracker')), findsOneWidget);
    expect(find.byKey(const ValueKey('add-meal-slot-select')), findsNothing);
  });
}
