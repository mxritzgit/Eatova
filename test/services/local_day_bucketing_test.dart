import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/local_day.dart';
import 'package:eatova/src/services/meal_totals.dart';

// DATA-6: meals used to bucket via isSameDay(.toLocal()) while caffeine took
// a UTC window from naive local midnight, so across a DST or zone change the
// same 23:45 local time could land on different "days".
//
// Both now share the canonical local_day key, written from the local wall
// clock. These tests show a 23:45 entry stays on the same day for both
// tracks, whatever time offset is used to filter later.

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
      // Meal at 23:45 local on June 4, with a persisted local_day.
      final at2345 = DateTime(2026, 6, 4, 23, 45);
      final meal = LoggedMeal(
        id: 'm1',
        result: _result(),
        loggedAt: at2345,
        localDay: localDayKey(at2345), // '2026-06-04'
      );

      // Query the day at a different time of day; with local_day only the
      // calendar day counts.
      final hits = mealsForFoodDate([meal], DateTime(2026, 6, 4, 0, 30));
      expect(hits.length, 1);

      // The next day must not pick the entry up.
      final nextDay = mealsForFoodDate([meal], DateTime(2026, 6, 5, 12, 0));
      expect(nextDay, isEmpty);
    });

    test('weicht der gespeicherte Tag vom Zeitstempel ab, gewinnt der '
        'gespeicherte', () {
      // The case DATA-6 exists for: logged at 23:45 in Berlin, then the phone
      // moves a zone (or DST shifts) and the SAME instant now reads as 00:30
      // of the next day. local_day was written from the wall clock at logging
      // time and must not move with it — otherwise the entry silently jumps
      // to another day.
      //
      // As long as `localDay` and `loggedAt` agree, the persisted key and the
      // isSameDay fallback are indistinguishable; only a disagreement shows
      // which of the two the code really reads.
      final meal = LoggedMeal(
        id: 'verschoben',
        result: _result(),
        loggedAt: DateTime(2026, 6, 5, 0, 30),
        localDay: '2026-06-04',
      );

      expect(meal.effectiveLocalDay, '2026-06-04');
      expect(mealsForFoodDate([meal], DateTime(2026, 6, 4, 18)).single.id,
          'verschoben');
      expect(mealsForFoodDate([meal], DateTime(2026, 6, 5, 18)), isEmpty,
          reason: 'der Zeitstempel darf den gespeicherten Tag nicht ueberstimmen');
    });

    test('Mahlzeit ohne localDay faellt auf isSameDay(.toLocal()) zurueck', () {
      // Legacy rows without the field keep the old logic byte-identical.
      final meal = LoggedMeal(
        id: 'legacy',
        result: _result(),
        loggedAt: DateTime(2026, 6, 4, 23, 45),
        // localDay deliberately null.
      );
      expect(mealsForFoodDate([meal], DateTime(2026, 6, 4)).length, 1);
      expect(mealsForFoodDate([meal], DateTime(2026, 6, 5)), isEmpty);
    });
  });

  group('Meals und Koffein teilen denselben local_day fuer 23:45', () {
    test('effectiveLocalDay einer Mahlzeit == localDayKey desselben Zeitpunkts',
        () {
      final ts = DateTime(2026, 6, 4, 23, 45);

      // Meals side: the key meals_sync writes to local_day.
      final mealKey = LoggedMeal(
        id: 'm',
        result: _result(),
        loggedAt: ts,
      ).effectiveLocalDay;

      // Caffeine side: the same localDayKey derived from the same timestamp.
      final caffeineKey = localDayKey(ts);

      expect(mealKey, caffeineKey);
      expect(mealKey, '2026-06-04');
    });
  });
}
