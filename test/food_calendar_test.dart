import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/screens/meal_analysis_screen.dart';

import 'support/harness.dart';

// Calendar access to older days in the food tab: a calendar button next to
// the date chips whose selection runs through the same onDateSelected path as
// the chips. Plus the loading state for on-demand days, where dayLoading
// replaces the history with a spinner.
//
// No `renderMatrix` here: nothing in this file is duplicated per brightness,
// locale or text scale — it is one dark-mode flow per state. Viewport pinning
// and overflow tolerance come from the harness's `testWidgetsRobust`.

/// Food tab harness in the same shell as EatovaHomePage.
Future<void> _pumpFoodTab(
  WidgetTester tester, {
  ValueChanged<DateTime>? onDateSelected,
  bool dayLoading = false,
}) async {
  await pumpLocalized(
    tester,
    MealAnalysisScreen(
      dailyConsumedKcal: 0,
      onDateSelected: onDateSelected,
      dayLoading: dayLoading,
    ),
    padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
  );
  // With dayLoading the spinner never stops, so pumpAndSettle would never
  // settle: pump a bounded amount instead.
  if (dayLoading) {
    await tester.pump(const Duration(milliseconds: 100));
  } else {
    await tester.pumpAndSettle();
  }
}

void main() {
  testWidgetsRobust(
      'Kalender-Knopf oeffnet deutschen DatePicker; Auswahl laeuft durch den '
      'Chip-Callback (onDateSelected)', (WidgetTester tester) async {
    DateTime? selected;
    await _pumpFoodTab(tester, onDateSelected: (d) => selected = d);

    expect(find.byKey(const ValueKey('food-date-calendar')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('food-date-calendar')));
    await tester.pumpAndSettle();

    // German dialog (de delegates), custom help text.
    expect(find.byType(DatePickerDialog), findsOneWidget);
    expect(find.text('Tag wählen'), findsOneWidget);
    expect(find.text('Abbrechen'), findsOneWidget);

    // Page to the PREVIOUS month and pick the 15th: it exists in every month,
    // is always in the past (lastDate = today never bites) and never collides
    // with the today special case.
    await tester.tap(find.byIcon(Icons.chevron_left));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
      of: find.byType(DatePickerDialog),
      matching: find.text('15'),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    final today = DateUtils.dateOnly(DateTime.now());
    expect(selected, DateTime(today.year, today.month - 1, 15));
    expect(find.byType(DatePickerDialog), findsNothing);
  });

  testWidgetsRobust('dayLoading zeigt den Spinner statt der Verlaufskarte',
      (WidgetTester tester) async {
    await _pumpFoodTab(tester, dayLoading: true);

    expect(find.byKey(const ValueKey('food-day-loading')), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    // History slots are absent while loading.
    expect(find.text('Tag wird geladen…'), findsOneWidget);
  });

  testWidgetsRobust('Ohne dayLoading rendert der Verlauf wie bisher',
      (WidgetTester tester) async {
    await _pumpFoodTab(tester);

    expect(find.byKey(const ValueKey('food-day-loading')), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
