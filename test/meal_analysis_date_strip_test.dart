// W3-07 / B5: Die Datumsleiste des Food-Tabs ueberspringt einen Tag.
//
// `Duration` ist Absolutzeit, kein Kalender. Am Montag 30.03.2026 in
// Europe/Berlin (Fruehjahrsumstellung war Sonntag 29.03., ein 23-Stunden-Tag)
// liefert `DateTime(2026, 3, 30).subtract(const Duration(days: 1))` den
// `2026-03-28 23:00`. Die Leiste rendert dann
//
//   Mi 25.3. | Do 26.3. | Fr 27.3. | Gestern 28.3. | Heute 30.3.
//
// Sonntag der 29.3. ist nicht erreichbar, und der Chip „Gestern" traegt den
// 28.3.: ein Tap darauf ruft `setFoodDate(2026-03-28)`, der Nutzer sieht die
// Kalorien des falschen Tages, und jede von dort geloggte Mahlzeit bekommt
// `local_day = 2026-03-28`.
//
// ZONEN-UNABHAENGIGKEIT (Technik aus test/services/day_math_test.dart):
// `flutter test` laeuft in der lokalen Zone der Maschine — hier Europe/Berlin,
// in der CI UTC. In UTC EXISTIERT dieser Fehler nicht, ein Test kann dort also
// gar nicht rot werden. Deshalb pruefen die Tests hier ausschliesslich
// Eigenschaften, die in JEDER Zone gelten muessen:
//
//   1. Kalender-Assertions auf (Jahr, Monat, Tag).
//   2. Ein Property-Test gegen ein UTC-Orakel: UTC kennt keine Sommerzeit,
//      dort IST `add(Duration(days: n))` die Kalenderverschiebung.
//   3. Rundreise-/Lueckenfreiheit ueber `daysBetween`.
//
// Die eine Assertion, die vom DST-Verhalten der Maschine abhaengt, ist als
// bedingter Beleg formuliert: sie nagelt den Fehler NUR fest, wenn die
// Maschine ihn ueberhaupt hat, und kann nirgends falsch rot werden.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/screens/meal_analysis_screen.dart';
import 'package:eatova/src/services/day_math.dart';
import 'package:eatova/src/theme/app_theme.dart';

final AppLocalizations _de = lookupAppLocalizations(const Locale('de'));

/// Kurzform fuer Kalender-Assertions: nur (Jahr, Monat, Tag) zaehlen.
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
      // MealAnalysisScreen liest seit der i18n-Migration context.l10n —
      // ohne Delegates/locale wirft AppLocalizations.of() (Muster
      // test/home_page_tabs_test.dart).
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
  // Der 30.03.2026 ist ein Montag; die Umstellung lag auf Sonntag, dem 29.03.
  final montagNachUmstellung = DateTime(2026, 3, 30);

  group('foodDateStripDays — die Leiste verschluckt keinen Tag', () {
    test('bedingter Beleg: die Duration-Subtraktion verliert den 29.03.', () {
      final naiv = DateTime(2026, 3, 30).subtract(const Duration(days: 1));
      if (naiv.day != 29) {
        // Nur auf einer Maschine MIT Fruehjahrsumstellung am 29.03.2026.
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
        (y: 2026, m: 3, d: 29), // der Tag, den der Altcode verschluckte
        (y: 2026, m: 3, d: 30),
      ]);
    });

    test('jeder Eintrag ist eine lokale Mitternacht, keiner ein 23:00', () {
      for (final tag in foodDateStripDays(
        today: montagNachUmstellung,
        pastDays: 4,
      )) {
        // Idempotenz statt `hour == 0`: in Zonen, die um Mitternacht
        // umstellen, existiert 00:00 an einzelnen Tagen nicht.
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
      // UTC kennt keine Sommerzeit: dort IST add(Duration(days: n)) die
      // Kalenderverschiebung. Genau dieses (y, m, d) muss die Leiste lokal
      // ebenfalls treffen — in jeder Zone, an jedem Tag.
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
      // Altcode: 23 Stunden -> inDays == 0 -> faelschlich „Heute".
      expect(
        foodDateChipLabel(montagNachUmstellung, DateTime(2026, 3, 29), _de),
        'Gestern',
      );
      // Altcode: 47 Stunden -> inDays == 1 -> faelschlich „Gestern".
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
      // Altcode: 119 Stunden -> inDays == 4 -> „Vor 4 Tagen".
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
        // Seit der scrollbaren 30-Tage-Leiste laeuft der Streifen ABSTEIGEND
        // (Heute zuerst, wie der Tages-Picker im Edit-Sheet): der Chip-Index
        // IST der Tages-Offset (chip-0 = Heute, chip-1 = Gestern, ...).
        // Geprueft werden die ersten fuenf — mehr baut der Test-Viewport
        // einer horizontalen ListView ohnehin nicht auf.
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

        // Der Chip nach „Heute" ist „Gestern" — und liefert beim Tap einen
        // Tag, der genau EINEN Kalendertag zurueckliegt.
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
