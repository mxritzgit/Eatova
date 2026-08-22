import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/services/day_math.dart';
import 'package:eatova/src/services/trend_service.dart';

// B5 in the trend path: the dense trend window and the metrics slice derived
// from it must contain every calendar day exactly once across a DST switch.
//
// On a 23-hour DST day `today.subtract(Duration(days: n))` lands at 23:00 of
// the day before, which shares a localDayKey with it — so one day would drop
// out of the window and another appear twice.
//
// Zone independence (CI runs on UTC): only properties that hold in EVERY zone
// are asserted — (year, month, day) triples and a property test against a UTC
// oracle, where `add(Duration(days: n))` IS the calendar shift.

/// Shorthand for calendar assertions: only (year, month, day) count.
({int y, int m, int d}) ymd(DateTime value) =>
    (y: value.year, m: value.month, d: value.day);

TrendDayTotals _day(DateTime day, int kcal) =>
    TrendDayTotals(day: day, kcal: kcal, proteinG: 0, carbsG: 0, fatG: 0);

void main() {
  group('denseTrendWindow ueber die Fruehjahrsumstellung 2026-03-29', () {
    test('enthaelt den 29.03. genau einmal und den 28.03. nicht doppelt', () {
      // Evidence of the failure pattern, observable only in a zone with a DST
      // switch on 2026-03-29.
      final naiv = DateTime(2026, 3, 30).subtract(const Duration(days: 1));
      if (naiv.day != 29) {
        expect(ymd(naiv), (y: 2026, m: 3, d: 28));
        expect(naiv.hour, 23);
      }

      // One total per day from the 24th to the 30th, kcal = day * 100.
      final totals = [
        for (var d = 24; d <= 30; d++) _day(DateTime(2026, 3, d), d * 100),
      ];
      final window = denseTrendWindow(
        totals,
        today: DateTime(2026, 3, 30, 9, 15),
        days: 7,
      );

      expect(window, hasLength(7));
      // Oldest first, without gaps or duplicates.
      expect(window.map((t) => t?.kcal).toList(), [
        2400,
        2500,
        2600,
        2700,
        2800,
        2900, // the day Duration arithmetic swallows
        3000,
      ]);
    });

    test('auch mit dem 29.03. selbst als heute', () {
      final totals = [
        for (var d = 26; d <= 29; d++) _day(DateTime(2026, 3, d), d * 100),
      ];
      final window = denseTrendWindow(
        totals,
        today: DateTime(2026, 3, 29, 14),
        days: 4,
      );
      expect(window.map((t) => t?.kcal).toList(), [2600, 2700, 2800, 2900]);
    });

    test(
      'Herbstumstellung 2026-10-25 (25-Stunden-Tag) ebenfalls lueckenlos',
      () {
        final totals = [
          for (var d = 22; d <= 27; d++) _day(DateTime(2026, 10, d), d * 100),
        ];
        final window = denseTrendWindow(
          totals,
          today: DateTime(2026, 10, 27, 22),
          days: 6,
        );
        expect(window.map((t) => t?.kcal).toList(), [
          2200,
          2300,
          2400,
          2500,
          2600,
          2700,
        ]);
      },
    );

    test('days <= 0 liefert ein leeres Fenster statt zu werfen', () {
      final totals = [_day(DateTime(2026, 3, 30), 2000)];
      expect(
        denseTrendWindow(totals, today: DateTime(2026, 3, 30), days: 0),
        isEmpty,
      );
      expect(
        denseTrendWindow(totals, today: DateTime(2026, 3, 30), days: -1),
        isEmpty,
      );
    });
  });

  group('completedDaysOf ueber die Umstellung', () {
    test('am 30.03. bleibt der 29.03. der juengste abgeschlossene Tag', () {
      final totals = [
        for (var d = 27; d <= 30; d++) _day(DateTime(2026, 3, d), d * 100),
      ];
      final completed = completedDaysOf(
        denseTrendWindow(totals, today: DateTime(2026, 3, 30, 7), days: 4),
      );
      expect(completed.map((t) => t?.kcal).toList(), [2700, 2800, 2900]);
    });
  });

  group('Eigenschaften gegen ein UTC-Orakel (zonenunabhaengig)', () {
    test('denseTrendWindow trifft an jedem Tag 2026 die Kalender-Position', () {
      const days = 7;
      var cursor = DateTime.utc(2026, 1, 1);
      final ende = DateTime.utc(2026, 12, 31);
      var geprueft = 0;
      while (!cursor.isAfter(ende)) {
        final heute = DateTime(cursor.year, cursor.month, cursor.day);
        // The expected days come from UTC, where Duration arithmetic is
        // exactly the calendar shift regardless of the test's zone.
        final totals = <TrendDayTotals>[];
        for (var k = 0; k < days; k++) {
          final orakel = cursor.subtract(Duration(days: k));
          totals.add(
            _day(DateTime(orakel.year, orakel.month, orakel.day), 1000 + k),
          );
        }
        final window = denseTrendWindow(totals, today: heute, days: days);
        for (var k = 0; k < days; k++) {
          expect(
            window[days - 1 - k]?.kcal,
            1000 + k,
            reason:
                'Fenster um ${cursor.year}-${cursor.month}-${cursor.day}: '
                'Position ${days - 1 - k} traegt nicht den Tag vor $k Tagen',
          );
        }
        geprueft++;
        cursor = cursor.add(const Duration(days: 1));
      }
      expect(geprueft, 365);
    });

    test('der erste Fenstertag entspricht addDays(heute, -(days - 1))', () {
      // Exactly the calculation trends_screen.dart uses for the axis label and
      // the painter's weekday abbreviations.
      for (final days in [7, 30, 90]) {
        for (final anker in [
          DateTime(2026, 3, 30),
          DateTime(2026, 3, 29),
          DateTime(2026, 10, 26),
          DateTime(2027, 1, 1),
        ]) {
          final erster = addDays(startOfDay(anker), -(days - 1));
          expect(daysBetween(anker, erster), days - 1);
          expect(ymd(addDays(erster, days - 1)), ymd(anker));
        }
      }
    });
  });
}
