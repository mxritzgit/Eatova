import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/day_nutrition.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/macro_progress.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/user_profile.dart';

// Shared day numbers of the dark redesign (Task 7). The design scenario:
// goal 2,050 + 73 activity = 2,123 budget, 1,221 eaten -> 902 left, 58 %
// eaten, protein 111 of 162 g -> 51 g left.

const _profile = UserProfile(
  dailyKcalGoal: 2050,
  proteinGoalG: 162,
  carbsGoalG: 222,
  fatGoalG: 57,
);

LoggedMeal _meal(String id, DateTime at, {MealSlot? slot}) => LoggedMeal(
  id: id,
  loggedAt: at,
  forcedSlot: slot,
  result: const MealAnalysisResult(
    mealName: 'M',
    caloriesKcal: 300,
    estimatedGrams: 200,
    kcalPer100G: 150,
    protein: '20 g',
    carbs: '30 g',
    fat: '10 g',
    confidence: 'Hoch',
    portionNotes: '',
  ),
);

void main() {
  group('DayNutritionSummary', () {
    test('reproduces the design scenario', () {
      final summary = DayNutritionSummary(
        profile: _profile,
        burnedKcal: 73,
        consumed: const MacroProgress(
          proteinG: 111,
          carbsG: 144,
          fatG: 20,
          kcal: 1221,
        ),
      );
      expect(summary.goalKcal, 2050);
      expect(summary.burnedKcal, 73);
      expect(summary.budgetKcal, 2123);
      expect(summary.consumedKcal, 1221);
      expect(summary.remainingKcal, 902);
      expect((summary.eatenFraction * 100).round(), 58);
      expect(summary.proteinLeftG, 51);
      expect(summary.carbsLeftG, 78);
      expect(summary.fatLeftG, 37);
    });

    test('over budget: negative remainder, macros left never below 0', () {
      final summary = DayNutritionSummary(
        profile: _profile,
        burnedKcal: 0,
        consumed: const MacroProgress(
          proteinG: 200.4,
          carbsG: 222,
          fatG: 56.6,
          kcal: 2300,
        ),
      );
      expect(summary.remainingKcal, -250);
      expect(summary.eatenFraction, 1.0);
      expect(summary.proteinLeftG, 0);
      expect(summary.carbsLeftG, 0);
      // 0.4 g open rounds to 0, not to a negative number.
      expect(summary.fatLeftG, 0);
    });

    test('empty day: everything still open', () {
      final summary = DayNutritionSummary(
        profile: _profile,
        burnedKcal: 0,
        consumed: MacroProgress.empty,
      );
      expect(summary.remainingKcal, 2050);
      expect(summary.eatenFraction, 0);
      expect(summary.proteinLeftG, 162);
      expect(
        summary.suggestedKcalRange(MealSlot.snack),
        suggestedKcalRangeForSlot(MealSlot.snack, 2050),
      );
    });
  });

  group('suggestedKcalRangeForSlot', () {
    test('design budget 2,123 kcal gives the design bands', () {
      expect(suggestedKcalRangeForSlot(MealSlot.breakfast, 2123), (
        minKcal: 400,
        maxKcal: 550,
      ));
      expect(suggestedKcalRangeForSlot(MealSlot.lunch, 2123), (
        minKcal: 550,
        maxKcal: 700,
      ));
      expect(suggestedKcalRangeForSlot(MealSlot.dinner, 2123), (
        minKcal: 550,
        maxKcal: 700,
      ));
      expect(suggestedKcalRangeForSlot(MealSlot.snack, 2123), (
        minKcal: 150,
        maxKcal: 300,
      ));
    });

    test('scales with the budget and stays on the 50 kcal grid', () {
      for (final budget in [1200, 1500, 1834, 2500, 3200, 4100]) {
        for (final slot in MealSlot.values) {
          final range = suggestedKcalRangeForSlot(slot, budget);
          expect(range.minKcal % 50, 0, reason: '$slot @ $budget');
          expect(range.maxKcal % 50, 0, reason: '$slot @ $budget');
          expect(range.maxKcal, greaterThan(range.minKcal));
        }
      }
      expect(suggestedKcalRangeForSlot(MealSlot.lunch, 1200), (
        minKcal: 300,
        maxKcal: 400,
      ));
    });

    test('tiny or negative budgets keep a readable band', () {
      expect(suggestedKcalRangeForSlot(MealSlot.snack, 100), (
        minKcal: 50,
        maxKcal: 100,
      ));
      expect(suggestedKcalRangeForSlot(MealSlot.dinner, -40), (
        minKcal: 50,
        maxKcal: 100,
      ));
    });
  });

  group('nextOpenMainMealSlot', () {
    DateTime at(int hour, [int minute = 0]) =>
        DateTime(2026, 9, 28, hour, minute);

    test('follows the app slot boundaries 11/15/21', () {
      expect(
        nextOpenMainMealSlot(now: at(10, 59), todaysMeals: const []),
        MealSlot.breakfast,
      );
      expect(
        nextOpenMainMealSlot(now: at(11), todaysMeals: const []),
        MealSlot.lunch,
      );
      expect(
        nextOpenMainMealSlot(now: at(20, 59), todaysMeals: const []),
        MealSlot.dinner,
      );
      expect(nextOpenMainMealSlot(now: at(21), todaysMeals: const []), isNull);
      expect(
        nextOpenMainMealSlot(now: at(0, 30), todaysMeals: const []),
        MealSlot.breakfast,
      );
    });

    test('skips filled slots, never goes back to a skipped one', () {
      final lunch = _meal('l', at(12, 45));
      // 12:00 with lunch logged: dinner is next; the empty breakfast is past.
      expect(
        nextOpenMainMealSlot(now: at(12), todaysMeals: [lunch]),
        MealSlot.dinner,
      );
      final breakfast = _meal('b', at(8, 10));
      expect(
        nextOpenMainMealSlot(now: at(9), todaysMeals: [breakfast]),
        MealSlot.lunch,
      );
      final dinner = _meal('d', at(18));
      expect(
        nextOpenMainMealSlot(now: at(19), todaysMeals: [lunch, dinner]),
        isNull,
      );
    });

    test('a forced slot counts for its slot, not its clock time', () {
      // Logged at 16:20 but filed under dinner by the user.
      final forced = _meal('f', at(16, 20), slot: MealSlot.dinner);
      expect(nextOpenMainMealSlot(now: at(17), todaysMeals: [forced]), isNull);
      // A snack does not close any main meal.
      final snack = _meal('s', at(16, 20), slot: MealSlot.snack);
      expect(
        nextOpenMainMealSlot(now: at(17), todaysMeals: [snack]),
        MealSlot.dinner,
      );
    });
  });
}
