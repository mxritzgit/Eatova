import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/local_day.dart';
import 'package:eatova/src/services/meal_totals.dart';

// DATA-6: Der eigentliche Bug, den diese Welle killt.
//
// Frueher buckete der Meals-Pfad per isSameDay(.toLocal()), waehrend der
// Koffein-Pfad ein UTC-Fenster aus naiver lokaler Mitternacht nahm. Ueber eine
// DST-/Zonen-Aenderung hinweg konnten dieselbe 23:45-Ortszeit fuer Mahlzeiten
// und Koffein in unterschiedlichen „Tagen" landen.
//
// Jetzt teilen sich beide denselben kanonischen Schluessel local_day (Client
// schreibt ihn aus der lokalen Wanduhr). Diese Tests zeigen: ein 23:45-Eintrag
// bleibt fuer BEIDE Tracks am selben Tag, unabhaengig davon, mit welchem
// Uhrzeit-Offset spaeter gefiltert wird.

MealAnalysisResult _result() => const MealAnalysisResult(
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

void main() {
  group('Meals bucketen 23:45 stabil ueber local_day', () {
    test('Eintrag um 23:45 buckete in seinen lokalen Tag, nicht den Folgetag',
        () {
      // Mahlzeit um 23:45 lokal am 4. Juni, mit persistiertem local_day.
      final at2345 = DateTime(2026, 6, 4, 23, 45);
      final meal = LoggedMeal(
        id: 'm1',
        result: _result(),
        loggedAt: at2345,
        localDay: localDayKey(at2345), // '2026-06-04'
      );

      // Abfrage des Tages mit einer ANDEREN Uhrzeit (00:30) — frueher haette ein
      // Zonen-/Offset-Wechsel die isSameDay-Zuordnung kippen koennen. Mit
      // local_day zaehlt nur der Kalendertag.
      final hits = mealsForFoodDate([meal], DateTime(2026, 6, 4, 0, 30));
      expect(hits.length, 1);

      // Der Folgetag darf den Eintrag NICHT einsammeln.
      final nextDay = mealsForFoodDate([meal], DateTime(2026, 6, 5, 12, 0));
      expect(nextDay, isEmpty);
    });

    test('Mahlzeit ohne localDay faellt auf isSameDay(.toLocal()) zurueck', () {
      // Altbestand / home_page-Konstruktion ohne das Feld -> alte Logik bleibt
      // byte-identisch (keine Pin-Bruecke).
      final meal = LoggedMeal(
        id: 'legacy',
        result: _result(),
        loggedAt: DateTime(2026, 6, 4, 23, 45),
        // localDay bewusst null.
      );
      expect(mealsForFoodDate([meal], DateTime(2026, 6, 4)).length, 1);
      expect(mealsForFoodDate([meal], DateTime(2026, 6, 5)), isEmpty);
    });
  });

  group('Meals und Koffein teilen denselben local_day fuer 23:45', () {
    test('effectiveLocalDay einer Mahlzeit == localDayKey desselben Zeitpunkts',
        () {
      final ts = DateTime(2026, 6, 4, 23, 45);

      // Meals-Seite: der Schluessel, den meals_sync auf local_day schreibt.
      final mealKey = LoggedMeal(
        id: 'm',
        result: _result(),
        loggedAt: ts,
      ).effectiveLocalDay;

      // Koffein-Seite: derselbe localDayKey, den tracking_sync.insertCaffeine
      // aus demselben lokalen Zeitstempel ableitet.
      final caffeineKey = localDayKey(ts);

      expect(mealKey, caffeineKey);
      expect(mealKey, '2026-06-04');
    });
  });
}
