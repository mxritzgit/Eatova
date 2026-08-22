import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/eatova_app.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/widgets/kcal/slot_selector.dart';

// With the floating log button gone, the meal rows are the ONLY way to add an
// entry — and the shell used to drop the slot on the way
// (`onOpenMealSlot: (_) => setTab(food)`). These tests pin the end-to-end
// path: tapping a slot opens the add sheet for that slot.

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

    // ALWAYS scroll into view first: how far down the rows sit depends on the
    // platform's font metrics, so on CI the tap missed silently.
    final mittag = find.byKey(const ValueKey('today-meal-row-lunch'));
    await tester.ensureVisible(mittag);
    await tester.pumpAndSettle();
    await tester.tap(mittag);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('screen-kcal-tracker')), findsOneWidget);
    expect(find.byKey(const ValueKey('add-meal-slot-select')), findsOneWidget);
    // The key sits on the padding, the selector below it.
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

    // Dinner sits below the fold on an 852 px screen; without ensureVisible
    // the tap misses.
    final abend = find.byKey(const ValueKey('today-meal-row-dinner'));
    await tester.ensureVisible(abend);
    await tester.pumpAndSettle();
    await tester.tap(abend);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('add-meal-slot-select')), findsOneWidget);

    // Back and forth: the request must not queue up and open a ghost sheet on
    // the next tab visit.
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
