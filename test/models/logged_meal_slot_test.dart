import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';

// TEST-4: make the slot heuristic flake-free. currentMealSlot() reads
// clock.now(), so withClock can pin the time across midnight and a DST switch.

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
      expect(mealSlotForHour(11), MealSlot.lunch); // boundary
      expect(mealSlotForHour(14), MealSlot.lunch);
      expect(mealSlotForHour(15), MealSlot.dinner); // boundary
      expect(mealSlotForHour(20), MealSlot.dinner);
      expect(mealSlotForHour(21), MealSlot.snack); // boundary
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
        loggedAt: DateTime(2026, 6, 2, 23, 0), // would be snack
        forcedSlot: MealSlot.breakfast,
      );
      expect(m.slot, MealSlot.breakfast);
    });
  });

  group('currentMealSlot (clock.now-getrieben)', () {
    test('default (ohne withClock) liest echte Zeit ohne Crash', () {
      // No pin -> default clock == DateTime.now(); slot is one of the four.
      expect(MealSlot.values, contains(currentMealSlot()));
    });

    test('um 23:58 -> Snack, 2 Minuten spaeter (00:01 naechster Tag) -> Fruehstueck', () {
      // The midnight flake the old DateTime.now() variant made
      // unreproducible, pinned here.
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
      // The wall clock jumps 01:59 -> 03:00. Both sides are breakfast
      // (< 11), so the slot must neither flip nor flake at the switch.
      withClock(Clock.fixed(DateTime(2025, 3, 30, 1, 59)), () {
        expect(currentMealSlot(), MealSlot.breakfast);
      });
      withClock(Clock.fixed(DateTime(2025, 3, 30, 3, 0)), () {
        expect(currentMealSlot(), MealSlot.breakfast);
      });
      // Across the same DST hour into lunch: 10:30 vs 11:30 must separate
      // breakfast from lunch cleanly.
      withClock(Clock.fixed(DateTime(2025, 3, 30, 10, 30)), () {
        expect(currentMealSlot(), MealSlot.breakfast);
      });
      withClock(Clock.fixed(DateTime(2025, 3, 30, 11, 30)), () {
        expect(currentMealSlot(), MealSlot.lunch);
      });
    });
  });
}
