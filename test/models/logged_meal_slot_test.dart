import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';

// TEST-4: Slot-Heuristik flake-frei machen. currentMealSlot() liest clock.now()
// statt der nackten Wanduhr, daher koennen wir die Zeit per withClock fest
// ueber Mitternacht und ueber eine DST-Umstellung pinnen. Die reine Funktion
// mealSlotForHour deckt die Stundengrenzen direkt ab, die Instanz-Heuristik
// (LoggedMeal.slot) bleibt dabei byte-genau identisch.

MealAnalysisResult _result() => const MealAnalysisResult(
      mealName: 'Test',
      caloriesKcal: 100,
      estimatedGrams: 100,
      kcalPer100G: 100,
      protein: '5 g',
      carbs: '5 g',
      fat: '5 g',
      confidence: 'Hoch',
      portionNotes: '',
    );

void main() {
  group('mealSlotForHour (reine Stundengrenzen)', () {
    test('Grenzen 11/15/21 inklusiv/exklusiv', () {
      expect(mealSlotForHour(0), MealSlot.breakfast);
      expect(mealSlotForHour(10), MealSlot.breakfast);
      expect(mealSlotForHour(11), MealSlot.lunch); // Grenze
      expect(mealSlotForHour(14), MealSlot.lunch);
      expect(mealSlotForHour(15), MealSlot.dinner); // Grenze
      expect(mealSlotForHour(20), MealSlot.dinner);
      expect(mealSlotForHour(21), MealSlot.snack); // Grenze
      expect(mealSlotForHour(23), MealSlot.snack);
    });
  });

  group('LoggedMeal.slot (Instanz-Heuristik unveraendert)', () {
    LoggedMeal at(int hour) => LoggedMeal(
          id: 'x',
          result: _result(),
          loggedAt: DateTime(2026, 6, 2, hour, 30),
        );

    test('Uhrzeit aus loggedAt steuert den Slot', () {
      expect(at(8).slot, MealSlot.breakfast);
      expect(at(12).slot, MealSlot.lunch);
      expect(at(18).slot, MealSlot.dinner);
      expect(at(22).slot, MealSlot.snack);
    });

    test('forcedSlot ueberschreibt die Uhrzeit', () {
      final m = LoggedMeal(
        id: 'x',
        result: _result(),
        loggedAt: DateTime(2026, 6, 2, 23, 0), // waere snack
        forcedSlot: MealSlot.breakfast,
      );
      expect(m.slot, MealSlot.breakfast);
    });
  });

  group('currentMealSlot (clock.now-getrieben)', () {
    test('default (ohne withClock) liest echte Zeit ohne Crash', () {
      // Kein Pin -> Default-Clock == DateTime.now(); Slot ist einer der vier.
      expect(MealSlot.values, contains(currentMealSlot()));
    });

    test('um 23:58 -> Snack, 2 Minuten spaeter (00:01 naechster Tag) -> Fruehstueck', () {
      // Genau der Mitternachts-Flake, den die alte DateTime.now()-Variante
      // unreproduzierbar machte: hier hart festgenagelt.
      withClock(Clock.fixed(DateTime(2026, 6, 2, 23, 58)), () {
        expect(currentMealSlot(), MealSlot.snack);
      });
      withClock(Clock.fixed(DateTime(2026, 6, 3, 0, 1)), () {
        expect(currentMealSlot(), MealSlot.breakfast);
      });
    });

    test('jede Stunde eines fixierten Tages liefert deterministisch denselben Slot', () {
      for (var h = 0; h < 24; h++) {
        withClock(Clock.fixed(DateTime(2026, 6, 2, h, 30)), () {
          expect(currentMealSlot(), mealSlotForHour(h));
        });
      }
    });

    test('DST-Sprung (DE 30.03.2025: 02:00 -> 03:00) bleibt deterministisch', () {
      // Lokale Wanduhr springt von 01:59 auf 03:00. Beide Seiten sind
      // Fruehstueck (< 11 Uhr) — der Slot darf an der Umstellung nicht kippen
      // und nicht flaken.
      withClock(Clock.fixed(DateTime(2025, 3, 30, 1, 59)), () {
        expect(currentMealSlot(), MealSlot.breakfast);
      });
      withClock(Clock.fixed(DateTime(2025, 3, 30, 3, 0)), () {
        expect(currentMealSlot(), MealSlot.breakfast);
      });
      // Und ueber dieselbe DST-Stunde hinweg in den Mittag: 10:30 vs 11:30
      // muessen sauber Fruehstueck -> Mittag trennen.
      withClock(Clock.fixed(DateTime(2025, 3, 30, 10, 30)), () {
        expect(currentMealSlot(), MealSlot.breakfast);
      });
      withClock(Clock.fixed(DateTime(2025, 3, 30, 11, 30)), () {
        expect(currentMealSlot(), MealSlot.lunch);
      });
    });
  });
}
