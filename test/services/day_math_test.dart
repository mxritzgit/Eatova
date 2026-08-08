import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/services/day_math.dart';

// B5: Sommerzeit-Umstellung ueberspringt einen Tag.
//
// `Duration`-Arithmetik ist Absolutzeit, keine Kalenderarithmetik. Am
// 30.03.2026 in Europe/Berlin (Fruehjahrsumstellung am Sonntag 29.03., ein
// 23-Stunden-Tag) liefert `DateTime(2026, 3, 30).subtract(Duration(days: 1))`
// den `2026-03-28 23:00` — der Sonntag verschwindet aus der Datumsleiste und
// der Chip „Gestern" traegt das falsche Datum.
//
// Zeitzonen-Unabhaengigkeit der Tests: `flutter test` laeuft in der lokalen
// Zone der Maschine (hier Europe/Berlin, in der CI moeglicherweise UTC). Ein
// Test, der nur in Berlin rot wird, ist wertlos. Deshalb pruefen die Tests
// hier ausschliesslich Eigenschaften, die in JEDER Zone gelten muessen:
//
//   1. Kalender-Assertions auf (Jahr, Monat, Tag) — zonenunabhaengig wahr.
//   2. Ein Property-Test gegen ein UTC-Orakel: UTC kennt keine Sommerzeit,
//      dort IST `add(Duration(days: n))` exakt die Kalenderverschiebung.
//      Was `addDays` lokal liefert, muss dasselbe (y, m, d) tragen.
//   3. Rundreise-Eigenschaften: `daysBetween(addDays(d, n), d) == n`.
//
// Die eine Stelle, die vom DST-Verhalten der Maschine abhaengt, ist bewusst
// als Beleg-Assertion formuliert, die den Fehler NUR dann festnagelt, wenn
// die Maschine ihn ueberhaupt hat — sie kann nirgends falsch rot werden.

/// Kurzform fuer Kalender-Assertions: nur (Jahr, Monat, Tag) zaehlen.
({int y, int m, int d}) ymd(DateTime value) =>
    (y: value.year, m: value.month, d: value.day);

void main() {
  group('addDays — Kalenderverschiebung statt Duration', () {
    test(
      'Fruehjahrsumstellung: der Vortag des 30.03.2026 ist der 29.03., nicht der 28.',
      () {
        // Der dokumentierte Fehler, als Beleg. Auf einer Maschine in einer
        // Zone MIT Fruehjahrsumstellung am 29.03.2026 (z. B. Europe/Berlin)
        // rutscht die Duration-Subtraktion auf den 28.03. um 23:00. Auf einer
        // UTC-Maschine passiert das nicht — dann ist hier nichts zu belegen.
        final naiv = DateTime(2026, 3, 30).subtract(const Duration(days: 1));
        if (naiv.day != 29) {
          expect(
            ymd(naiv),
            (y: 2026, m: 3, d: 28),
            reason: 'Duration-Subtraktion verliert hier den 29.03.',
          );
          expect(naiv.hour, 23);
        }

        // Das gilt in JEDER Zone.
        expect(ymd(addDays(DateTime(2026, 3, 30), -1)), (y: 2026, m: 3, d: 29));
        expect(ymd(addDays(DateTime(2026, 3, 29), 1)), (y: 2026, m: 3, d: 30));
        expect(ymd(addDays(DateTime(2026, 3, 28), 2)), (y: 2026, m: 3, d: 30));
      },
    );

    test('Herbstumstellung (25-Stunden-Tag) verschiebt ebenfalls sauber', () {
      // Europe/Berlin: Rueckstellung am Sonntag 25.10.2026.
      expect(ymd(addDays(DateTime(2026, 10, 26), -1)), (y: 2026, m: 10, d: 25));
      expect(ymd(addDays(DateTime(2026, 10, 25), 1)), (y: 2026, m: 10, d: 26));
      expect(ymd(addDays(DateTime(2026, 10, 24), 3)), (y: 2026, m: 10, d: 27));
    });

    test('n == 0 laesst den Tag unveraendert', () {
      expect(ymd(addDays(DateTime(2026, 3, 29), 0)), (y: 2026, m: 3, d: 29));
    });

    test('Monatsgrenzen laufen ueber den Konstruktor-Overflow', () {
      expect(ymd(addDays(DateTime(2026, 3, 1), -1)), (y: 2026, m: 2, d: 28));
      expect(ymd(addDays(DateTime(2026, 1, 31), 1)), (y: 2026, m: 2, d: 1));
      expect(ymd(addDays(DateTime(2026, 4, 30), 1)), (y: 2026, m: 5, d: 1));
      expect(ymd(addDays(DateTime(2026, 5, 1), -1)), (y: 2026, m: 4, d: 30));
    });

    test('Jahresgrenzen laufen ueber', () {
      expect(ymd(addDays(DateTime(2025, 12, 31), 1)), (y: 2026, m: 1, d: 1));
      expect(ymd(addDays(DateTime(2026, 1, 1), -1)), (y: 2025, m: 12, d: 31));
      // 2025 hat 365 Tage — 366 Tage zurueck landet einen Tag frueher.
      expect(ymd(addDays(DateTime(2026, 1, 1), -365)), (y: 2025, m: 1, d: 1));
      expect(ymd(addDays(DateTime(2026, 1, 1), -366)), (y: 2024, m: 12, d: 31));
    });

    test('Schaltjahr: der 29.02. existiert 2024 und fehlt 2026', () {
      expect(ymd(addDays(DateTime(2024, 2, 28), 1)), (y: 2024, m: 2, d: 29));
      expect(ymd(addDays(DateTime(2024, 3, 1), -1)), (y: 2024, m: 2, d: 29));
      expect(ymd(addDays(DateTime(2024, 2, 29), 1)), (y: 2024, m: 3, d: 1));
      // 2026 ist kein Schaltjahr — der Vortag des 01.03. ist der 28.02.
      expect(ymd(addDays(DateTime(2026, 3, 1), -1)), (y: 2026, m: 2, d: 28));
      // 2100 ist trotz Teilbarkeit durch 4 KEIN Schaltjahr.
      expect(ymd(addDays(DateTime(2100, 3, 1), -1)), (y: 2100, m: 2, d: 28));
    });

    test('erhaelt die Wanduhrzeit (fuer Terminplanung wie Streak-Reminder)', () {
      final shifted = addDays(DateTime(2026, 3, 28, 20, 15, 30, 400), 2);
      expect(ymd(shifted), (y: 2026, m: 3, d: 30));
      expect(shifted.hour, 20);
      expect(shifted.minute, 15);
      expect(shifted.second, 30);
      expect(shifted.millisecond, 400);
    });

    test('bleibt in der lokalen Zone (kein stiller UTC-Wechsel)', () {
      expect(addDays(DateTime(2026, 3, 30), -1).isUtc, isFalse);
    });
  });

  group('daysBetween — Tagesdifferenz ohne DST-Drift', () {
    test('Fruehjahr: der Folgetag ist 1 Tag entfernt, nicht 0', () {
      // Gemessener Fehler des Altcodes in Europe/Berlin:
      //   23h -> inDays == 0, 47h -> inDays == 1.
      expect(daysBetween(DateTime(2026, 3, 30), DateTime(2026, 3, 29)), 1);
      expect(daysBetween(DateTime(2026, 3, 30), DateTime(2026, 3, 28)), 2);
      expect(daysBetween(DateTime(2026, 3, 31), DateTime(2026, 3, 28)), 3);
    });

    test('Herbst: der 25-Stunden-Tag zaehlt ebenfalls als 1', () {
      expect(daysBetween(DateTime(2026, 10, 26), DateTime(2026, 10, 25)), 1);
      expect(daysBetween(DateTime(2026, 10, 27), DateTime(2026, 10, 24)), 3);
    });

    test('derselbe Tag ergibt 0, unabhaengig von der Uhrzeit', () {
      expect(daysBetween(DateTime(2026, 3, 29), DateTime(2026, 3, 29)), 0);
      expect(
        daysBetween(
          DateTime(2026, 3, 30, 23, 59, 59),
          DateTime(2026, 3, 30, 0, 0, 1),
        ),
        0,
      );
    });

    test('Uhrzeit kippt die Differenz nicht (Minuten um Mitternacht)', () {
      expect(
        daysBetween(DateTime(2026, 3, 30, 0, 5), DateTime(2026, 3, 29, 23, 55)),
        1,
      );
      expect(
        daysBetween(DateTime(2026, 3, 29, 23, 55), DateTime(2026, 3, 30, 0, 5)),
        -1,
      );
    });

    test('Zukunft ergibt negative Werte (Vorzeichen wie bei difference)', () {
      expect(daysBetween(DateTime(2026, 3, 28), DateTime(2026, 3, 30)), -2);
    });

    test('Monats-, Jahres- und Schaltjahrgrenzen', () {
      expect(daysBetween(DateTime(2026, 3, 1), DateTime(2026, 2, 28)), 1);
      expect(daysBetween(DateTime(2026, 1, 1), DateTime(2025, 12, 31)), 1);
      expect(daysBetween(DateTime(2024, 3, 1), DateTime(2024, 2, 28)), 2);
      expect(daysBetween(DateTime(2025, 1, 1), DateTime(2024, 1, 1)), 366);
      expect(daysBetween(DateTime(2026, 1, 1), DateTime(2025, 1, 1)), 365);
    });

    test('funktioniert auch mit UTC-Argumenten (reine Kalenderrechnung)', () {
      expect(
        daysBetween(DateTime.utc(2026, 3, 30), DateTime.utc(2026, 3, 29)),
        1,
      );
    });
  });

  group('startOfDay — Normalisierung auf die lokale Mitternacht', () {
    test('schneidet die Uhrzeit ab und ist idempotent', () {
      final normalisiert = startOfDay(DateTime(2026, 3, 29, 17, 42, 13, 9));
      expect(ymd(normalisiert), (y: 2026, m: 3, d: 29));
      expect(startOfDay(normalisiert), normalisiert);
      expect(normalisiert.isUtc, isFalse);
    });

    test('gleicher Kalendertag => identischer Wert', () {
      expect(
        startOfDay(DateTime(2026, 3, 29, 0, 0, 1)),
        startOfDay(DateTime(2026, 3, 29, 23, 59, 59)),
      );
    });
  });

  group('dayStrip — die Datumsleiste (aufsteigend, luckenlos)', () {
    test('liefert pastDays + 1 Eintraege, aufsteigend, endend auf heute', () {
      final tage = dayStrip(today: DateTime(2026, 6, 10, 14, 30), pastDays: 4);
      expect(tage.length, 5);
      expect(tage.map(ymd).toList(), [
        (y: 2026, m: 6, d: 6),
        (y: 2026, m: 6, d: 7),
        (y: 2026, m: 6, d: 8),
        (y: 2026, m: 6, d: 9),
        (y: 2026, m: 6, d: 10),
      ]);
    });

    test('jeder Eintrag ist eine lokale Mitternacht', () {
      for (final tag in dayStrip(today: DateTime(2026, 3, 30, 9), pastDays: 6)) {
        // Idempotenz statt `hour == 0`: in Zonen, die um Mitternacht
        // umstellen, existiert 00:00 an manchen Tagen nicht.
        expect(startOfDay(tag), tag);
        expect(tag.isUtc, isFalse);
      }
    });

    test(
      'ueber die Fruehjahrsumstellung: jeder Kalendertag genau einmal, keine Luecke',
      () {
        final tage = dayStrip(today: DateTime(2026, 3, 30), pastDays: 5);
        expect(tage.map(ymd).toList(), [
          (y: 2026, m: 3, d: 25),
          (y: 2026, m: 3, d: 26),
          (y: 2026, m: 3, d: 27),
          (y: 2026, m: 3, d: 28),
          (y: 2026, m: 3, d: 29), // der Tag, den der Altcode verschluckt
          (y: 2026, m: 3, d: 30),
        ]);
      },
    );

    test('35-Tage-Fenster ueber die Umstellung ist doppelt- und luckenfrei', () {
      final tage = dayStrip(today: DateTime(2026, 4, 20), pastDays: 34);
      expect(tage.length, 35);
      expect(tage.map((t) => '${t.year}-${t.month}-${t.day}').toSet().length, 35);
      for (var i = 1; i < tage.length; i++) {
        expect(
          daysBetween(tage[i], tage[i - 1]),
          1,
          reason: 'Luecke oder Dopplung zwischen Index ${i - 1} und $i',
        );
      }
    });

    test('auch ueber die Herbstumstellung luckenlos', () {
      final tage = dayStrip(today: DateTime(2026, 10, 27), pastDays: 6);
      expect(tage.map(ymd).toList(), [
        (y: 2026, m: 10, d: 21),
        (y: 2026, m: 10, d: 22),
        (y: 2026, m: 10, d: 23),
        (y: 2026, m: 10, d: 24),
        (y: 2026, m: 10, d: 25),
        (y: 2026, m: 10, d: 26),
        (y: 2026, m: 10, d: 27),
      ]);
    });

    test('pastDays == 0 liefert genau heute, negative Werte eine leere Liste', () {
      expect(
        dayStrip(today: DateTime(2026, 3, 30, 8), pastDays: 0).map(ymd).toList(),
        [(y: 2026, m: 3, d: 30)],
      );
      expect(dayStrip(today: DateTime(2026, 3, 30), pastDays: -1), isEmpty);
    });
  });

  group('recentDaysDescending — Leiste mit heute zuerst', () {
    test('liefert count Eintraege, absteigend, beginnend bei heute', () {
      final tage = recentDaysDescending(
        today: DateTime(2026, 3, 30, 21),
        count: 4,
      );
      expect(tage.map(ymd).toList(), [
        (y: 2026, m: 3, d: 30),
        (y: 2026, m: 3, d: 29),
        (y: 2026, m: 3, d: 28),
        (y: 2026, m: 3, d: 27),
      ]);
    });

    test('ist die Umkehrung von dayStrip', () {
      final absteigend = recentDaysDescending(
        today: DateTime(2026, 3, 30),
        count: 35,
      );
      final aufsteigend = dayStrip(today: DateTime(2026, 3, 30), pastDays: 34);
      expect(absteigend, aufsteigend.reversed.toList());
    });

    test('count <= 0 liefert eine leere Liste', () {
      expect(recentDaysDescending(today: DateTime(2026, 3, 30), count: 0), isEmpty);
      expect(recentDaysDescending(today: DateTime(2026, 3, 30), count: -3), isEmpty);
    });
  });

  group('Eigenschaften (zonenunabhaengig, gegen ein UTC-Orakel)', () {
    // UTC kennt keine Sommerzeit: dort ist `add(Duration(days: n))` per
    // Definition die Kalenderverschiebung. Genau dieses (y, m, d) muss
    // `addDays` lokal ebenfalls treffen — in jeder Zone, an jedem Tag.
    const offsets = [-400, -366, -35, -34, -31, -30, -7, -2, -1, 0, 1, 2, 7, 30, 35, 365];

    test('addDays trifft ueber 2024..2032 hinweg immer das UTC-Orakel', () {
      var geprueft = 0;
      var cursor = DateTime.utc(2024, 1, 1);
      final ende = DateTime.utc(2032, 12, 31);
      while (!cursor.isAfter(ende)) {
        for (final n in offsets) {
          final orakel = cursor.add(Duration(days: n));
          final lokal = addDays(
            DateTime(cursor.year, cursor.month, cursor.day),
            n,
          );
          expect(
            ymd(lokal),
            ymd(orakel),
            reason:
                'addDays(${cursor.year}-${cursor.month}-${cursor.day}, $n) '
                'weicht vom Kalender ab',
          );
          geprueft++;
        }
        cursor = cursor.add(const Duration(days: 1));
      }
      // Sicherheitsnetz: die Schleife muss wirklich gelaufen sein.
      expect(geprueft, greaterThan(50000));
    });

    test('daysBetween(addDays(d, n), d) == n fuer alle d und n', () {
      var cursor = DateTime.utc(2024, 1, 1);
      final ende = DateTime.utc(2032, 12, 31);
      while (!cursor.isAfter(ende)) {
        final tag = DateTime(cursor.year, cursor.month, cursor.day);
        for (final n in offsets) {
          expect(
            daysBetween(addDays(tag, n), tag),
            n,
            reason: 'Rundreise gebrochen bei $tag + $n',
          );
          expect(
            ymd(addDays(addDays(tag, n), -n)),
            ymd(tag),
            reason: 'Hin und zurueck landet nicht wieder auf $tag',
          );
        }
        cursor = cursor.add(const Duration(days: 1));
      }
    });

    test('dayStrip ist fuer jeden Anker luckenlos und endet auf dem Anker', () {
      var cursor = DateTime.utc(2025, 1, 1);
      final ende = DateTime.utc(2028, 12, 31);
      while (!cursor.isAfter(ende)) {
        final anker = DateTime(cursor.year, cursor.month, cursor.day);
        final tage = dayStrip(today: anker, pastDays: 6);
        expect(tage.length, 7);
        expect(ymd(tage.last), ymd(anker));
        for (var i = 1; i < tage.length; i++) {
          expect(
            daysBetween(tage[i], tage[i - 1]),
            1,
            reason: 'Luecke in der Leiste um $anker',
          );
        }
        cursor = cursor.add(const Duration(days: 1));
      }
    });
  });
}
