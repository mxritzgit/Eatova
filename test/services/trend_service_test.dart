import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/services/meals_sync.dart';
import 'package:eatova/src/services/trend_service.dart';

// Pure Trend-Logik: Tagessummen-Aggregation, dichtes Zeitfenster mit
// Luecken-Tagen, Durchschnitts- und Ziel-Treffer-Berechnung. Alles ohne
// Supabase — genau die Funktionen, die der TrendsScreen konsumiert.

TrendDayTotals _day(
  DateTime day, {
  int kcal = 0,
  double p = 0,
  double c = 0,
  double f = 0,
}) => TrendDayTotals(day: day, kcal: kcal, proteinG: p, carbsG: c, fatG: f);

void main() {
  group('aggregateDailyTotals', () {
    test('summiert mehrere Zeilen desselben local_day zu einer Tagessumme', () {
      final totals = aggregateDailyTotals([
        {
          'local_day': '2026-08-05',
          'logged_at': '2026-08-05T08:00:00Z',
          'calories_kcal': 600,
          'protein_g': 30,
          'carbs_g': 70,
          'fat_g': 20,
        },
        {
          'local_day': '2026-08-05',
          'logged_at': '2026-08-05T19:30:00Z',
          'calories_kcal': 900,
          'protein_g': 45.5,
          'carbs_g': 80,
          'fat_g': 25,
        },
      ]);

      expect(totals, hasLength(1));
      expect(totals.single.day, DateTime(2026, 8, 5));
      expect(totals.single.kcal, 1500);
      expect(totals.single.proteinG, closeTo(75.5, 0.001));
      expect(totals.single.carbsG, closeTo(150, 0.001));
      expect(totals.single.fatG, closeTo(45, 0.001));
    });

    test('faellt ohne local_day auf den lokalen logged_at-Tag zurueck und '
        'ueberspringt Zeilen ohne jedes Datum', () {
      final totals = aggregateDailyTotals([
        // Aeltere Zeile ohne local_day: lokaler ISO-String (ohne Z) ->
        // zeitzonen-unabhaengig derselbe Kalendertag.
        {
          'local_day': null,
          'logged_at': '2026-08-04T12:00:00',
          'calories_kcal': 500,
        },
        // Defensiv: ganz ohne Datum -> Zeile wird verworfen, kein Crash.
        {'local_day': null, 'logged_at': null, 'calories_kcal': 999},
      ]);

      expect(totals, hasLength(1));
      expect(totals.single.day, DateTime(2026, 8, 4));
      expect(totals.single.kcal, 500);
    });

    test('behandelt null-Makros als 0 und sortiert Tage aufsteigend', () {
      final totals = aggregateDailyTotals([
        {
          'local_day': '2026-08-05',
          'calories_kcal': 800,
          'protein_g': null,
          'carbs_g': null,
          'fat_g': null,
        },
        {
          'local_day': '2026-08-03',
          'calories_kcal': 1200,
          'protein_g': 60,
          'carbs_g': 100,
          'fat_g': 30,
        },
      ]);

      expect(totals.map((t) => t.day).toList(), [
        DateTime(2026, 8, 3),
        DateTime(2026, 8, 5),
      ]);
      expect(totals.last.kcal, 800);
      expect(totals.last.proteinG, 0);
      expect(totals.last.carbsG, 0);
      expect(totals.last.fatG, 0);
    });
  });

  group('denseTrendWindow', () {
    test('fuellt Luecken-Tage mit null und schneidet aeltere Tage ab', () {
      final today = DateTime(2026, 8, 6);
      final window = denseTrendWindow(
        [
          _day(DateTime(2026, 8, 6), kcal: 2200),
          _day(DateTime(2026, 8, 4), kcal: 1800),
          // Ausserhalb des 7-Tage-Fensters -> muss verschwinden.
          _day(DateTime(2026, 7, 1), kcal: 999),
        ],
        today: today,
        days: 7,
      );

      expect(window, hasLength(7));
      // Aeltester zuerst: Index 0 = 31.07., Index 6 = heute.
      expect(window[0], isNull);
      expect(window[4]?.kcal, 1800); // 04.08.
      expect(window[5], isNull); // 05.08. ohne Logs -> Luecke
      expect(window[6]?.kcal, 2200); // 06.08.
      expect(window.whereType<TrendDayTotals>(), hasLength(2));
    });

    test('funktioniert ueber Monatsgrenzen hinweg', () {
      final window = denseTrendWindow(
        [_day(DateTime(2026, 7, 31), kcal: 1500)],
        today: DateTime(2026, 8, 2),
        days: 7,
      );
      // 31.07. liegt 2 Tage vor dem 02.08. -> Index days-1-2 = 4.
      expect(window[4]?.kcal, 1500);
    });
  });

  group('completedDaysOf — B6: der laufende Tag zaehlt nicht mit', () {
    test('schneidet genau den letzten Eintrag (= heute) ab', () {
      final window = denseTrendWindow(
        [
          _day(DateTime(2026, 8, 5), kcal: 2200),
          _day(DateTime(2026, 8, 6), kcal: 2100),
          _day(DateTime(2026, 8, 7), kcal: 350),
        ],
        today: DateTime(2026, 8, 7, 8, 30),
        days: 3,
      );

      expect(window, hasLength(3));
      expect(window.last?.kcal, 350); // heute ist im Fenster
      final completed = completedDaysOf(window);
      expect(completed, hasLength(2));
      expect(completed.map((d) => d?.kcal).toList(), [2200, 2100]);
    });

    test(
      'Review-Szenario: das 350-kcal-Fruehstueck verwaessert nichts mehr',
      () {
        // Ziel 2200 kcal, 01.-06.08. je exakt 2200 geloggt. Am 07.08. um 08:30
        // loggt der Nutzer ein 350-kcal-Fruehstueck und oeffnet Trends.
        final totals = [
          for (var d = 1; d <= 6; d++) _day(DateTime(2026, 8, d), kcal: 2200),
          _day(DateTime(2026, 8, 7), kcal: 350),
        ];
        final window = denseTrendWindow(
          totals,
          today: DateTime(2026, 8, 7, 8, 30),
          days: 7,
        );

        // Der dokumentierte Fehler, als Beleg: heute mitgerechnet ergibt
        // (6 x 2200 + 350) / 7 = 1935,71 und 6 von 7 Tagen.
        expect(averageKcalOf(window), closeTo(1935.714, 0.001));
        expect(goalHitsOf(window, goalKcal: 2200).tracked, 7);

        // Ohne den laufenden Tag stimmen alle drei Kennzahlen wieder.
        final completed = completedDaysOf(window);
        expect(averageKcalOf(completed), closeTo(2200, 0.001));
        final hits = goalHitsOf(completed, goalKcal: 2200);
        expect(hits.hit, 6);
        expect(hits.tracked, 6);
      },
    );

    test('Ø Makros werden ebenfalls nicht mehr vom Teiltag verduennt', () {
      final totals = [
        for (var d = 1; d <= 6; d++)
          _day(DateTime(2026, 8, d), kcal: 2200, p: 120, c: 200, f: 60),
        _day(DateTime(2026, 8, 7), kcal: 350, p: 10, c: 40, f: 8),
      ];
      final completed = completedDaysOf(
        denseTrendWindow(totals, today: DateTime(2026, 8, 7, 8, 30), days: 7),
      );
      final macros = averageMacrosOf(completed);
      expect(macros, isNotNull);
      expect(macros!.proteinG, closeTo(120, 0.001));
      expect(macros.carbsG, closeTo(200, 0.001));
      expect(macros.fatG, closeTo(60, 0.001));
    });

    test(
      'nur heute geloggt: leere Kennzahlen statt NaN oder Division durch 0',
      () {
        final window = denseTrendWindow(
          [_day(DateTime(2026, 8, 7), kcal: 350)],
          today: DateTime(2026, 8, 7, 8, 30),
          days: 7,
        );
        // Das Chart zeigt den laufenden Tag weiterhin.
        expect(trackedDaysOf(window), 1);

        final completed = completedDaysOf(window);
        expect(averageKcalOf(completed), isNull);
        expect(averageMacrosOf(completed), isNull);
        final hits = goalHitsOf(completed, goalKcal: 2200);
        expect(hits.hit, 0);
        expect(hits.tracked, 0);
        // Keine Quote bilden — 0/0 waere NaN. Der Aufrufer muss auf tracked == 0
        // pruefen; hier wird nur belegt, dass der Nenner sauber 0 ist.
        expect(trackedDaysOf(completed), 0);
      },
    );

    test('leeres Fenster bleibt leer (kein RangeError)', () {
      expect(completedDaysOf(const <TrendDayTotals?>[]), isEmpty);
      expect(completedDaysOf(<TrendDayTotals?>[null]), isEmpty);
    });
  });

  group('trackedDaysOf', () {
    test('zaehlt nur Tage mit Eintraegen, Luecken zaehlen nicht', () {
      expect(
        trackedDaysOf(<TrendDayTotals?>[
          _day(DateTime(2026, 8, 1), kcal: 1200),
          null,
          _day(DateTime(2026, 8, 3), kcal: 0), // 0 kcal ist ein getrackter Tag
        ]),
        2,
      );
      expect(trackedDaysOf(const <TrendDayTotals?>[]), 0);
    });
  });

  group('averageKcalOf', () {
    test('mittelt nur getrackte Tage — Luecken ziehen nicht auf 0', () {
      final window = <TrendDayTotals?>[
        _day(DateTime(2026, 8, 1), kcal: 2000),
        null,
        null,
        _day(DateTime(2026, 8, 4), kcal: 1000),
      ];
      expect(averageKcalOf(window), closeTo(1500, 0.001));
    });

    test('liefert null ohne getrackte Tage', () {
      expect(averageKcalOf(<TrendDayTotals?>[null, null]), isNull);
    });
  });

  group('goalHitsOf', () {
    test('zaehlt Tage im ±10%-Korridor, Grenzen inklusive', () {
      final window = <TrendDayTotals?>[
        _day(DateTime(2026, 8, 1), kcal: 1980), // exakt untere Grenze -> Hit
        _day(DateTime(2026, 8, 2), kcal: 2420), // exakt obere Grenze -> Hit
        _day(DateTime(2026, 8, 3), kcal: 1979), // knapp drunter -> Miss
        _day(DateTime(2026, 8, 4), kcal: 2421), // knapp drueber -> Miss
        null, // Luecken-Tag: weder Hit noch getrackt
      ];
      final hits = goalHitsOf(window, goalKcal: 2200);
      expect(hits.hit, 2);
      expect(hits.tracked, 4);
    });

    test('Ziel <= 0 hat keinen Korridor -> 0 Treffer, aber getrackte Tage', () {
      final hits = goalHitsOf([
        _day(DateTime(2026, 8, 1), kcal: 0),
      ], goalKcal: 0);
      expect(hits.hit, 0);
      expect(hits.tracked, 1);
    });
  });

  group('averageMacrosOf', () {
    test('mittelt P/C/F ueber getrackte Tage', () {
      final macros = averageMacrosOf(<TrendDayTotals?>[
        _day(DateTime(2026, 8, 1), p: 120, c: 200, f: 60),
        null,
        _day(DateTime(2026, 8, 3), p: 80, c: 100, f: 40),
      ]);
      expect(macros, isNotNull);
      expect(macros!.proteinG, closeTo(100, 0.001));
      expect(macros.carbsG, closeTo(150, 0.001));
      expect(macros.fatG, closeTo(50, 0.001));
    });

    test('liefert null ohne getrackte Tage', () {
      expect(averageMacrosOf(<TrendDayTotals?>[null]), isNull);
    });
  });

  group('TrendService Query-Grenzen', () {
    test('90-Tage-Fenster mit deterministischem Zeilen-Deckel', () {
      // Eigener Datenpfad, bewusst groesser als das 35-Tage-Boot-Fenster
      // des Tagebuchs — und wie dort mit explizitem Limit gegen stilles
      // PostgREST-Kappen (~27 Logs/Tag Reserve im Fenster).
      expect(TrendService.trendWindowDays, 90);
      expect(
        TrendService.trendWindowDays,
        greaterThan(MealsSync.loggedMealsWindowDays),
      );
      expect(TrendService.trendMaxRows, 2500);
      expect(
        TrendService.trendMaxRows / TrendService.trendWindowDays,
        greaterThanOrEqualTo(20),
      );
    });
  });
}
