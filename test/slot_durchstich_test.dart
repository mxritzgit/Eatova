import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/eatova_app.dart';

// The meal rows' add buttons (the dark redesign's round "+" per slot) open the
// add sheet through the shell. That each slot's "+" opens the sheet for THAT
// slot and the shown day is pinned in flows/today_wiring_flow_test.dart; this
// file pins, on the full app, that the request is consumed once and does not
// come back as a ghost sheet on a later tab visit.

void main() {
  testWidgets('nach dem Schliessen oeffnet ein Tab-Wechsel kein Geister-Fenster',
      (tester) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const EatovaApp());
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-today')), findsOneWidget);

    // Dinner sits below the fold on an 852 px screen; without ensureVisible
    // the tap misses.
    final abend = find.byKey(const ValueKey('today-meal-add-dinner'));
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

    expect(find.byKey(const ValueKey('screen-kcal-tracker')), findsOneWidget);
    expect(find.byKey(const ValueKey('add-meal-slot-select')), findsNothing,
        reason: 'ein blosser Tab-Wechsel darf kein Sheet oeffnen');
  });
}
