import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';

// The meal slot heuristic: hour boundaries, the instance slot (time of day or
// a forced slot) and currentMealSlot(), which reads `clock` so it can be
// pinned across midnight.

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
  test('mealSlotForHour: Grenzen 11/15/21 inklusiv/exklusiv', () {
    expect(mealSlotForHour(0), MealSlot.breakfast);
    expect(mealSlotForHour(10), MealSlot.breakfast);
    expect(mealSlotForHour(11), MealSlot.lunch); // boundary
    expect(mealSlotForHour(14), MealSlot.lunch);
    expect(mealSlotForHour(15), MealSlot.dinner); // boundary
    expect(mealSlotForHour(20), MealSlot.dinner);
    expect(mealSlotForHour(21), MealSlot.snack); // boundary
    expect(mealSlotForHour(23), MealSlot.snack);
  });

  test('LoggedMeal.slot folgt loggedAt, forcedSlot ueberschreibt die Uhrzeit',
      () {
    LoggedMeal at(int hour, [MealSlot? forced]) => LoggedMeal(
          id: 'x',
          result: _result(),
          loggedAt: DateTime(2026, 6, 2, hour, 30),
          forcedSlot: forced,
        );
    expect(at(8).slot, MealSlot.breakfast);
    expect(at(12).slot, MealSlot.lunch);
    expect(at(18).slot, MealSlot.dinner);
    expect(at(22).slot, MealSlot.snack);
    expect(at(23, MealSlot.breakfast).slot, MealSlot.breakfast);
  });

  test('currentMealSlot liest clock: 23:58 Snack, 00:01 Fruehstueck', () {
    withClock(Clock.fixed(DateTime(2026, 6, 2, 23, 58)), () {
      expect(currentMealSlot(), MealSlot.snack);
    });
    withClock(Clock.fixed(DateTime(2026, 6, 3, 0, 1)), () {
      expect(currentMealSlot(), MealSlot.breakfast);
    });
  });
}
