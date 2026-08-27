// Day switching in the food diary: a meal booked onto an ARCHIVE day via the
// date strip lands on that day only — diary, slot total and day total follow
// the selection, today stays untouched, and both days keep their own sum once
// a second meal is logged on today.
//
// A fixed clock (`withClock`) is the whole point: the strip's chip index IS
// the day offset and the persisted `local_day` key is derived from the wall
// clock, so without a pinned "now" the test would drift across midnight.
// The shell is composed here because EatovaApp builds its sync from
// `Supabase.instance` and would run without a server. Runs in English.

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/logged_meal.dart';

import '../fixlauf_a_helpers.dart';
import 'flow_test_helpers.dart';

/// Pinned "now": a plain midday, far from any midnight or DST edge.
final DateTime _jetzt = DateTime(2026, 8, 20, 12, 30);
final DateTime _heute = DateTime(2026, 8, 20);
final DateTime _gestern = DateTime(2026, 8, 19);

/// Selects a day via the date strip; the chip index IS the day offset.
Future<void> _pickDay(WidgetTester tester, int offset) async {
  await tester.tap(find.byKey(ValueKey('food-date-chip-$offset')));
  await settleFrames(tester);
}

String _selectedDayLabel(WidgetTester tester) => tester
    .widget<Text>(find.byKey(const ValueKey('food-date-selected-label')))
    .data!;

/// Switches to the Heute tab, checks the eaten tile and comes back to Food.
/// The Heute tab follows the same `selectedFoodDate`, archive days included.
Future<void> _expectDayTotal(WidgetTester tester, String kcal) async {
  await tester.tap(find.byKey(const ValueKey('nav-Heute')));
  await settleFrames(tester);
  expect(
    find.descendant(
      of: find.byKey(const ValueKey('today-stat-eaten')),
      matching: find.text(kcal),
    ),
    findsOneWidget,
    reason: 'der Heute-Hero nennt nicht $kcal gegessene kcal',
  );
  await tester.tap(find.byKey(const ValueKey('nav-Food')));
  await settleFrames(tester);
}

void main() {
  testWidgetsRobust(
      'Archivtag buchen, zurück auf heute: beide Tagessummen bleiben getrennt',
      (WidgetTester tester) async {
    await withClock(Clock.fixed(_jetzt), () async {
      final server = FixlaufServer()
        ..profileRow = serverProfileRow(completedProfile);
      final store = await pumpSignedIn(tester, server);

      await tester.tap(find.byKey(const ValueKey('nav-Food')));
      await settleFrames(tester);
      // Through the ARB bundle, not hard-coded: the suite runs in English, so
      // a renamed label must fail here rather than pass on a stale sentence.
      expect(_selectedDayLabel(tester), enL10n.todayDateToday);

      // ---- 1. Book onto yesterday ------------------------------------------
      await _pickDay(tester, 1);
      expect(_selectedDayLabel(tester), enL10n.todayDateYesterday);
      expect(store.selectedFoodDate, _gestern);

      await logSalami(tester, 'dinner');

      expect(find.byKey(const ValueKey('food-history-entry-0')), findsOneWidget,
          reason: 'das Tagebuch des Zieltags zeigt die Mahlzeit nicht');
      expect(find.text('252 kcal · 1 entry'), findsOneWidget,
          reason: 'die Slot-Summe der Abendkarte fehlt');
      expect(store.loggedMeals.single.slot, MealSlot.dinner);
      // The entry carries yesterday's wall clock, not today's.
      expect(DateUtils.dateOnly(store.loggedMeals.single.loggedAt), _gestern);

      await _expectDayTotal(tester, '252');

      // ---- 2. Back to today: untouched ---------------------------------
      await _pickDay(tester, 0);
      expect(_selectedDayLabel(tester), enL10n.todayDateToday);
      expect(find.byKey(const ValueKey('food-history-entry-0')), findsNothing,
          reason: 'die Buchung von gestern ist auf heute durchgeschlagen');
      expect(find.text('252 kcal · 1 entry'), findsNothing);
      await _expectDayTotal(tester, '0');

      // ---- 3. A second meal on today -----------------------------------
      await logSalami(tester, 'breakfast');
      expect(find.byKey(const ValueKey('food-history-entry-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('food-history-entry-1')), findsNothing,
          reason: 'der Tag von gestern lief in das heutige Tagebuch mit');
      await _expectDayTotal(tester, '252');

      // ---- 4. Both day totals hold -------------------------------------
      expect(store.consumedKcalForFoodDate(_heute), 252);
      expect(store.consumedKcalForFoodDate(_gestern), 252);
      expect(store.loggedMeals.length, 2);

      // Back on yesterday the diary still shows exactly its own entry.
      await _pickDay(tester, 1);
      expect(_selectedDayLabel(tester), enL10n.todayDateYesterday);
      expect(find.byKey(const ValueKey('food-history-entry-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('food-history-entry-1')), findsNothing);
      await _expectDayTotal(tester, '252');

      // ---- 5. The server rows carry the two distinct local days --------
      expect(server.mealRows.length, 2);
      expect(
        server.mealRows.values.map((row) => row['local_day']).toSet(),
        <String>{'2026-08-19', '2026-08-20'},
        reason: 'DATA-6: local_day trennt die Tage serverseitig nicht',
      );
    });
  });
}
