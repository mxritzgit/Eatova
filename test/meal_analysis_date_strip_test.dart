// W3-07 / B5: the food tab's day navigation counts calendar days.
//
// `Duration` is absolute time, not a calendar. Across a 23-hour DST day
// `DateTime(2026, 3, 30).subtract(const Duration(days: 1))` lands on
// `2026-03-28 23:00`, so "yesterday" carried the wrong day — logging meals
// under the wrong `local_day`. The day arithmetic itself is covered in
// `services/day_math_test.dart`; this file covers the food tab's labels and
// its previous-day button.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/screens/meal_analysis_screen.dart';
import 'package:eatova/src/services/day_math.dart';

import 'support/harness.dart';

final AppLocalizations _de = lookupAppLocalizations(const Locale('de'));

Future<void> _pumpFoodTab(
  WidgetTester tester, {
  ValueChanged<DateTime>? onDateSelected,
}) async {
  await pumpLocalized(
    tester,
    MealAnalysisScreen(
      dailyConsumedKcal: 0,
      onDateSelected: onDateSelected,
    ),
    padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
  );
  await tester.pumpAndSettle();
}

void main() {
  // 2026-03-30 is a Monday; the DST switch fell on Sunday 2026-03-29.
  final montagNachUmstellung = DateTime(2026, 3, 30);

  group('foodDateSelectedLabel — die Kopfzeile', () {
    test('zaehlt Kalendertage, nicht 24-Stunden-Bloecke', () {
      expect(
        foodDateSelectedLabel(
            montagNachUmstellung, DateTime(2026, 3, 30), _de),
        'Heute',
      );
      expect(
        foodDateSelectedLabel(
            montagNachUmstellung, DateTime(2026, 3, 29), _de),
        'Gestern',
      );
      // Old code: 119 hours -> inDays == 4 -> "4 days ago".
      expect(
        foodDateSelectedLabel(
            montagNachUmstellung, DateTime(2026, 3, 25), _de),
        'Vor 5 Tagen',
      );
    });
  });

  group('Die gerenderte Leiste', () {
    testWidgetsRobust(
      'zeigt den Tag einmal und navigiert einen Kalendertag zurueck',
      (tester) async {
        DateTime? gewaehlt;
        await _pumpFoodTab(tester, onDateSelected: (d) => gewaehlt = d);

        final heute = startOfDay(DateTime.now());
        expect(find.text(foodHeaderDateLabel(heute, _de)), findsOneWidget);
        final next = tester.widget<IconButton>(
          find.byKey(const ValueKey('food-date-next')),
        );
        expect(next.onPressed, isNull);
        await tester.tap(find.byKey(const ValueKey('food-date-previous')));
        await tester.pumpAndSettle();
        expect(gewaehlt, isNotNull);
        expect(daysBetween(heute, gewaehlt!), 1);
      },
    );
  });
}
