// W3-07 / B5: the food tab's date strip skipped a day.
//
// `Duration` is absolute time, not a calendar. Across a 23-hour DST day
// `DateTime(2026, 3, 30).subtract(const Duration(days: 1))` lands on
// `2026-03-28 23:00`, so 2026-03-29 was unreachable and the "yesterday" chip
// carried the wrong day — logging meals under the wrong `local_day`.
//
// Zone independence: `flutter test` runs in the machine's local zone (UTC in
// CI), where the bug does not exist. These tests therefore only assert
// properties that hold in EVERY zone: calendar (y, m, d) assertions, a
// property test against a UTC oracle, and gap-freeness via `daysBetween`. The
// one DST-dependent assertion is conditional, so it can never fail falsely.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/screens/meal_analysis_screen.dart';
import 'package:eatova/src/services/day_math.dart';
import 'package:eatova/src/theme/app_theme.dart';

final AppLocalizations _de = lookupAppLocalizations(const Locale('de'));

/// Shorthand for calendar assertions: only (year, month, day) count.
({int y, int m, int d}) ymd(DateTime value) =>
    (y: value.year, m: value.month, d: value.day);

void testWidgetsRobust(String description, WidgetTesterCallback callback) {
  testWidgets(description, (tester) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final prior = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception.toString().contains('overflowed')) return;
      prior?.call(details);
    };
    addTearDown(() => FlutterError.onError = prior);

    await callback(tester);
  });
}

Future<void> _pumpFoodTab(
  WidgetTester tester, {
  ValueChanged<DateTime>? onDateSelected,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildEatovaTheme(Brightness.dark),
      // MealAnalysisScreen reads context.l10n; without delegates/locale
      // AppLocalizations.of() throws.
      locale: const Locale('de'),
      supportedLocales: const [Locale('de'), Locale('en')],
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
            child: MealAnalysisScreen(
              dailyConsumedKcal: 0,
              onDateSelected: onDateSelected,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  // 2026-03-30 is a Monday; the DST switch fell on Sunday 2026-03-29.
  final montagNachUmstellung = DateTime(2026, 3, 30);

  group('foodDateStripDays — die Leiste verschluckt keinen Tag', () {
    test('bedingter Beleg: die Duration-Subtraktion verliert den 29.03.', () {
      final naiv = DateTime(2026, 3, 30).subtract(const Duration(days: 1));
      if (naiv.day != 29) {
        // Only on a machine with a DST switch on 2026-03-29.
        expect(
          ymd(naiv),
          (y: 2026, m: 3, d: 28),
          reason: 'Duration-Subtraktion landet auf dem Vorvortag',
        );
        expect(naiv.hour, 23);
      }
    });

    test('fuenf Chips ueber die Umstellung: 26., 27., 28., 29., 30.', () {
      final tage = foodDateStripDays(today: montagNachUmstellung, pastDays: 4);
      expect(tage, hasLength(5));
      expect(tage.map(ymd).toList(), [
        (y: 2026, m: 3, d: 26),
        (y: 2026, m: 3, d: 27),
        (y: 2026, m: 3, d: 28),
        (y: 2026, m: 3, d: 29), // the day the old code swallowed
        (y: 2026, m: 3, d: 30),
      ]);
    });

    test('jeder Eintrag ist eine lokale Mitternacht, keiner ein 23:00', () {
      for (final tag in foodDateStripDays(
        today: montagNachUmstellung,
        pastDays: 4,
      )) {
        // Idempotence instead of `hour == 0`: in zones that switch at
        // midnight, 00:00 does not exist on some days.
        expect(startOfDay(tag), tag);
        expect(tag.isUtc, isFalse);
      }
    });

    test('die Leiste ist doppelt- und luckenfrei und endet auf heute', () {
      final tage = foodDateStripDays(today: montagNachUmstellung, pastDays: 4);
      expect(ymd(tage.last), ymd(montagNachUmstellung));
      for (var i = 1; i < tage.length; i++) {
        expect(
          daysBetween(tage[i], tage[i - 1]),
          1,
          reason: 'Luecke oder Dopplung zwischen Index ${i - 1} und $i',
        );
      }
    });

    test('auch ueber die Herbstumstellung (25.10.2026) lueckenlos', () {
      final tage = foodDateStripDays(today: DateTime(2026, 10, 27), pastDays: 4);
      expect(tage.map(ymd).toList(), [
        (y: 2026, m: 10, d: 23),
        (y: 2026, m: 10, d: 24),
        (y: 2026, m: 10, d: 25),
        (y: 2026, m: 10, d: 26),
        (y: 2026, m: 10, d: 27),
      ]);
    });

    test('trifft ueber 2025..2028 hinweg immer das UTC-Orakel', () {
      // UTC has no DST, so there add(Duration(days: n)) IS the calendar
      // shift. The strip must hit the same (y, m, d) in any zone.
      var geprueft = 0;
      var cursor = DateTime.utc(2025, 1, 1);
      final ende = DateTime.utc(2028, 12, 31);
      while (!cursor.isAfter(ende)) {
        final anker = DateTime(cursor.year, cursor.month, cursor.day);
        final tage = foodDateStripDays(today: anker, pastDays: 4);
        expect(tage, hasLength(5));
        for (var i = 0; i < tage.length; i++) {
          final orakel = cursor.add(Duration(days: i - 4));
          expect(
            ymd(tage[i]),
            ymd(orakel),
            reason: 'Leiste um $anker weicht bei Index $i vom Kalender ab',
          );
        }
        geprueft++;
        cursor = cursor.add(const Duration(days: 1));
      }
      expect(geprueft, greaterThan(1400));
    });
  });

  group('foodDateChipLabel — Heute/Gestern/Wochentag', () {
    test('der Vortag heisst „Gestern", auch ueber die Umstellung', () {
      expect(
        foodDateChipLabel(montagNachUmstellung, DateTime(2026, 3, 30), _de),
        'Heute',
      );
      // Old code: 23 hours -> inDays == 0 -> wrongly "today".
      expect(
        foodDateChipLabel(montagNachUmstellung, DateTime(2026, 3, 29), _de),
        'Gestern',
      );
      // Old code: 47 hours -> inDays == 1 -> wrongly "yesterday".
      expect(
        foodDateChipLabel(montagNachUmstellung, DateTime(2026, 3, 28), _de),
        'Sa',
      );
      expect(
        foodDateChipLabel(montagNachUmstellung, DateTime(2026, 3, 27), _de),
        'Fr',
      );
    });

    test('ausserhalb der Umstellung unveraendert', () {
      final dienstag = DateTime(2026, 6, 9);
      expect(foodDateChipLabel(dienstag, DateTime(2026, 6, 9), _de), 'Heute');
      expect(
          foodDateChipLabel(dienstag, DateTime(2026, 6, 8), _de), 'Gestern');
      expect(foodDateChipLabel(dienstag, DateTime(2026, 6, 7), _de), 'So');
    });

    test('unter en englische Kuerzel ohne Punkt', () {
      final en = lookupAppLocalizations(const Locale('en'));
      expect(
        foodDateChipLabel(montagNachUmstellung, DateTime(2026, 3, 28), en),
        'Sat',
      );
    });
  });

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
      'zeigt genau die Tage, die dayStrip liefert, und traegt sie beim Tap weiter',
      (tester) async {
        DateTime? gewaehlt;
        await _pumpFoodTab(tester, onDateSelected: (d) => gewaehlt = d);

        final heute = startOfDay(DateTime.now());
        // The 30-day strip runs descending (today first), so the chip index IS
        // the day offset. Only the first five are checked — the test viewport
        // does not build more of a horizontal ListView.
        for (var i = 0; i < 5; i++) {
          final tag = heute.subtract(Duration(days: i));
          expect(
            find.descendant(
              of: find.byKey(ValueKey('food-date-chip-$i')),
              matching: find.text('${tag.day}.${tag.month}.'),
            ),
            findsOneWidget,
            reason: 'Chip $i zeigt nicht ${ymd(tag)}',
          );
        }

        // The chip after today is yesterday, and a tap yields a day exactly
        // one calendar day back.
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('food-date-chip-1')),
            matching: find.text('Gestern'),
          ),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('food-date-chip-1')));
        await tester.pumpAndSettle();
        expect(gewaehlt, isNotNull);
        expect(daysBetween(heute, gewaehlt!), 1);
      },
    );
  });
}
