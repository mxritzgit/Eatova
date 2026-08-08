// SONDE fuer Schalter 4 aus docs/REVIEW-2026-08-08.md (G2):
// `.toLocal()` an drei Stellen loeschen
//   * lib/src/models/logged_meal.dart:58   (effectiveLocalDay)
//   * lib/src/services/meal_totals.dart:23 (mealsForFoodDate)
//   * lib/src/services/trend_service.dart:123 (aggregateDailyTotals)
//
// DIESE DATEI HEISST BEWUSST NICHT `*_test.dart`.
//
// `flutter test` sammelt nur `*_test.dart` ein; diese Sonde wird
// ausschliesslich von `wire_local_day_tz_test.dart` gestartet — und zwar in
// einem KINDPROZESS MIT GESETZTER ZEITZONE (`TZ`). Der Grund ist der Kern des
// Problems:
//
//   Auf einer UTC-Maschine ist `.toLocal()` die IDENTITAET. Es gibt dort
//   keinen Eingabewert, fuer den ein Ergebnis MIT und ein Ergebnis OHNE
//   `.toLocal()` verschieden waeren — die drei Aufrufe muenden alle in
//   `localDayKey`, das nur Jahr/Monat/Tag liest. Ein Test, der in-process
//   laeuft, kann die Loeschung auf der CI (UTC) prinzipiell nicht sehen.
//
// Deshalb: Zeitzone im Kindprozess erzwingen, dort einen Zeitpunkt waehlen,
// dessen UTC-Kalendertag sich vom lokalen unterscheidet, und pruefen, welchen
// der beiden Tage die Produktion liefert. Die Sonde weigert sich zu laufen,
// wenn der Offset 0 ist — sonst waere sie eine gruene Nullaussage.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/local_day.dart';
import 'package:eatova/src/services/meal_totals.dart';
import 'package:eatova/src/services/trend_service.dart';

/// Marker, den der Treiber in stdout sucht: erst er belegt, dass die Sonde
/// wirklich in einer Zone ungleich UTC gelaufen ist.
const String zonenMarker = 'SONDE-ZONE-OK';

const MealAnalysisResult _result = MealAnalysisResult(
  mealName: 'Spaetes Abendessen',
  caloriesKcal: 600,
  estimatedGrams: 400,
  kcalPer100G: 150,
  protein: '40 g',
  carbs: '50 g',
  fat: '20 g',
  confidence: 'Hoch',
  portionNotes: '',
);

/// Sucht einen UTC-Zeitpunkt, dessen LOKALER Kalendertag ein anderer ist.
/// Existiert genau dann, wenn der Zonen-Offset nicht 0 ist.
DateTime _zeitpunktMitAbweichendemTag() {
  for (var stunde = 0; stunde < 24; stunde++) {
    for (final minute in <int>[15, 45]) {
      final utc = DateTime.utc(2026, 6, 15, stunde, minute);
      if (localDayKey(utc) != localDayKey(utc.toLocal())) return utc;
    }
  }
  throw StateError(
    'Kein Zeitpunkt gefunden, dessen lokaler Kalendertag vom UTC-Tag '
    'abweicht — die Sonde laeuft offenbar in UTC und kann nichts belegen.',
  );
}

void main() {
  final offset = DateTime.now().timeZoneOffset;

  test('die Sonde laeuft in einer Zone ungleich UTC', () {
    expect(
      offset,
      isNot(Duration.zero),
      reason:
          'Ohne Zonen-Offset ist .toLocal() die Identitaet und diese Sonde '
          'kann die Loeschung nicht sehen. Der Treiber muss TZ setzen '
          '(gesetzt: TZ=${Platform.environment['TZ'] ?? '<nicht gesetzt>'}).',
    );
    // Wird vom Treiber in stdout gesucht.
    // ignore: avoid_print
    print('$zonenMarker offset=$offset tz=${Platform.environment['TZ']}');
  });

  group('23:45 Ortszeit buckt in den lokalen Tag, nicht in den UTC-Tag', () {
    // Der Zeitpunkt kommt VOM SERVER: `logged_at` ist timestamptz und wird als
    // UTC-Instanz geparst. Genau an dieser Kante entscheidet sich der Tag.
    late DateTime utcInstant;
    late String lokalerTag;
    late String utcTag;

    setUp(() {
      utcInstant = _zeitpunktMitAbweichendemTag();
      lokalerTag = localDayKey(utcInstant.toLocal());
      utcTag = localDayKey(utcInstant);
      // Sicherheitsnetz: die beiden MUESSEN verschieden sein, sonst prueft
      // unten nichts.
      expect(lokalerTag, isNot(utcTag));
    });

    test('logged_meal.dart: effectiveLocalDay nimmt die lokale Wanduhr', () {
      final meal = LoggedMeal(
        id: 'm1',
        result: _result,
        loggedAt: utcInstant, // wie aus meals_sync ohne vorherige Umrechnung
      );

      expect(
        meal.effectiveLocalDay,
        lokalerTag,
        reason:
            'Der Tages-Schluessel, der nach local_day geschrieben wird, muss '
            'der lokale Kalendertag sein.',
      );
      expect(
        meal.effectiveLocalDay,
        isNot(utcTag),
        reason:
            'Ohne .toLocal() traegt die Mahlzeit den UTC-Kalendertag — eine '
            '23:45-Mahlzeit bucht damit auf den Folgetag (oder den Vortag, je '
            'nach Vorzeichen des Offsets).',
      );
    });

    test('meal_totals.dart: mealsForFoodDate normalisiert das Abfragedatum',
        () {
      final meal = LoggedMeal(
        id: 'm2',
        result: _result,
        loggedAt: utcInstant.toLocal(),
        localDay: lokalerTag,
      );

      final treffer = mealsForFoodDate(<LoggedMeal>[meal], utcInstant);
      expect(
        treffer.map((m) => m.id),
        contains('m2'),
        reason:
            'Ein Datum in UTC-Notation beschreibt denselben Tag wie seine '
            'lokale Wanduhr. Ohne .toLocal() vergleicht das Bucketing den '
            'persistierten lokalen Schluessel gegen einen UTC-Schluessel und '
            'findet die Mahlzeit nicht mehr.',
      );
    });

    test('trend_service.dart: aggregateDailyTotals faellt lokal zurueck', () {
      // Alt-Zeile ohne local_day — genau der Fallback-Pfad aus Zeile 123.
      final totals = aggregateDailyTotals(<Map<String, dynamic>>[
        <String, dynamic>{
          'local_day': null,
          'logged_at': utcInstant.toIso8601String(),
          'calories_kcal': 600,
          'protein_g': 40,
          'carbs_g': 50,
          'fat_g': 20,
        },
      ]);

      expect(totals, hasLength(1));
      expect(
        localDayKey(totals.single.day),
        lokalerTag,
        reason:
            'Die Trend-Kurve muss denselben Tag benutzen wie das Tagebuch.',
      );
      expect(localDayKey(totals.single.day), isNot(utcTag));
      expect(totals.single.kcal, 600);
    });

    test('alle drei Stellen liefern DENSELBEN Tag', () {
      // Die eigentliche Aussage von DATA-6: Tagebuch, Bucketing und Trend
      // duerfen fuer einen Zeitpunkt nie in verschiedene Tage laufen.
      final meal = LoggedMeal(id: 'm3', result: _result, loggedAt: utcInstant);
      final totals = aggregateDailyTotals(<Map<String, dynamic>>[
        <String, dynamic>{
          'local_day': null,
          'logged_at': utcInstant.toIso8601String(),
          'calories_kcal': 600,
        },
      ]);
      final gefunden = mealsForFoodDate(<LoggedMeal>[
        LoggedMeal(
          id: 'm3',
          result: _result,
          loggedAt: utcInstant.toLocal(),
          localDay: meal.effectiveLocalDay,
        ),
      ], utcInstant);

      expect(meal.effectiveLocalDay, localDayKey(totals.single.day));
      expect(gefunden, hasLength(1));
    });
  });
}
