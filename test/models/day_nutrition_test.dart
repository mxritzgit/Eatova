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
        summary.suggestedKcalRange(MealSlot.snack, emptySlots: MealSlot.values),
        suggestedKcalRangeForSlot(
          MealSlot.snack,
          budgetKcal: 2050,
          remainingKcal: 2050,
          emptySlots: MealSlot.values,
        ),
      );
    });

    test('the band uses budget and remainder, activity credit included', () {
      MacroProgress eaten() =>
          const MacroProgress(proteinG: 111, carbsG: 144, fatG: 20, kcal: 1221);
      const empty = [MealSlot.dinner, MealSlot.snack];
      final withCredit = DayNutritionSummary(
        profile: _profile,
        burnedKcal: 73,
        consumed: eaten(),
      );
      expect(
        withCredit.suggestedKcalRange(MealSlot.dinner, emptySlots: empty),
        (minKcal: 550, maxKcal: 600),
      );
      // Without the 73 kcal credit only 829 are left: max floors to 550
      // and min steps down to 500.
      final noCredit = DayNutritionSummary(
        profile: _profile,
        burnedKcal: 0,
        consumed: eaten(),
      );
      expect(noCredit.suggestedKcalRange(MealSlot.dinner, emptySlots: empty), (
        minKcal: 500,
        maxKcal: 550,
      ));
    });
  });

  group('suggestedKcalRangeForSlot', () {
    KcalRange? band(
      MealSlot slot, {
      required int budget,
      required int remaining,
      Iterable<MealSlot> empty = MealSlot.values,
    }) => suggestedKcalRangeForSlot(
      slot,
      budgetKcal: budget,
      remainingKcal: remaining,
      emptySlots: empty,
    );

    test('nothing eaten, all empty: close to the static split (2,123)', () {
      // The design draws the static 400-550 / 550-700 / 550-700 / 150-300;
      // sharing the budget over all four slots trims the upper ends.
      for (final (slot, expected) in [
        (MealSlot.breakfast, (minKcal: 400, maxKcal: 500)),
        (MealSlot.lunch, (minKcal: 550, maxKcal: 650)),
        (MealSlot.dinner, (minKcal: 550, maxKcal: 650)),
        (MealSlot.snack, (minKcal: 150, maxKcal: 250)),
      ]) {
        expect(
          band(slot, budget: 2123, remaining: 2123),
          expected,
          reason: '$slot',
        );
      }
    });

    test('design scenario: 902 left for dinner (and snack)', () {
      // The design day: only dinner open, so the 33 % cap binds.
      expect(
        band(
          MealSlot.dinner,
          budget: 2123,
          remaining: 902,
          empty: const [MealSlot.dinner],
        ),
        (minKcal: 550, maxKcal: 700),
      );
      const empty = [MealSlot.dinner, MealSlot.snack];
      // F(dinner) = 902 x 0.29 / 0.4025 = 649.9 -> 600; min 550.
      expect(
        band(MealSlot.dinner, budget: 2123, remaining: 902, empty: empty),
        (minKcal: 550, maxKcal: 600),
      );
      // F(snack) = 902 x 0.1125 / 0.4025 = 252.1 -> 250; min 150.
      expect(band(MealSlot.snack, budget: 2123, remaining: 902, empty: empty), (
        minKcal: 150,
        maxKcal: 250,
      ));
    });

    test('a big lunch leaves dinner a narrow band, not 550-700', () {
      // 1,800 of 2,100 eaten by noon, dinner and snack still open.
      const empty = [MealSlot.dinner, MealSlot.snack];
      // F(dinner) = 300 x 0.29 / 0.4025 = 216 -> 200; min steps to 150.
      expect(
        band(MealSlot.dinner, budget: 2100, remaining: 300, empty: empty),
        (minKcal: 150, maxKcal: 200),
      );
      // F(snack) = 83.9 -> below 100: no band.
      expect(
        band(MealSlot.snack, budget: 2100, remaining: 300, empty: empty),
        isNull,
      );
    });

    test('the last open slot takes the rest, capped by high x budget', () {
      const onlyDinner = [MealSlot.dinner];
      // 1,200 left, but dinner is capped at 33 % of 2,123 = 700.
      expect(
        band(MealSlot.dinner, budget: 2123, remaining: 1200, empty: onlyDinner),
        (minKcal: 550, maxKcal: 700),
      );
      // 420 left: the whole rest, floored to 400; min steps down to 350.
      expect(
        band(MealSlot.dinner, budget: 2123, remaining: 420, empty: onlyDinner),
        (minKcal: 350, maxKcal: 400),
      );
      // The asked slot always counts as empty, even when left out.
      expect(
        band(MealSlot.dinner, budget: 2123, remaining: 420, empty: const []),
        (minKcal: 350, maxKcal: 400),
      );
    });

    test('nothing or too little left: no band', () {
      for (final remaining in [0, -1, -250]) {
        for (final slot in MealSlot.values) {
          expect(
            band(slot, budget: 2123, remaining: remaining),
            isNull,
            reason: '$slot @ $remaining',
          );
        }
      }
      // Dinner alone with 149 left floors to 100: still a band ...
      expect(
        band(MealSlot.dinner, budget: 2123, remaining: 149, empty: const []),
        (minKcal: 50, maxKcal: 100),
      );
      // ... with 99 left it would be 50: none.
      expect(
        band(MealSlot.dinner, budget: 2123, remaining: 99, empty: const []),
        isNull,
      );
      // All four open with 400 left: breakfast's share is 98 -> none.
      expect(band(MealSlot.breakfast, budget: 2123, remaining: 400), isNull);
      expect(band(MealSlot.lunch, budget: 2123, remaining: 400), (
        minKcal: 50,
        maxKcal: 100,
      ));
    });

    test('negative or zero budget: no band', () {
      expect(band(MealSlot.dinner, budget: -40, remaining: 300), isNull);
      expect(band(MealSlot.dinner, budget: 0, remaining: 300), isNull);
    });

    test('floors: min >= 50 and max - min >= 50 on the 50 kcal grid', () {
      // Tiny budget: the cap of 33 % of 400 = 132 floors to 100.
      expect(
        band(
          MealSlot.dinner,
          budget: 400,
          remaining: 400,
          empty: const [MealSlot.dinner],
        ),
        (minKcal: 50, maxKcal: 100),
      );
      // A tight max pulls min below low x budget (300 of 1,200 stays).
      expect(band(MealSlot.lunch, budget: 1200, remaining: 1200), (
        minKcal: 300,
        maxKcal: 350,
      ));
    });

    test('property: on a grid, maxima never add up to more than is left', () {
      final subsets = <List<MealSlot>>[
        for (var mask = 1; mask < 16; mask++)
          [
            for (final slot in MealSlot.values)
              if (mask & (1 << slot.index) != 0) slot,
          ],
      ];
      final failures = <String>[];
      var bands = 0;
      for (var budget = -100; budget <= 4200; budget += 175) {
        for (var remaining = -300; remaining <= 4500; remaining += 37) {
          for (final empty in subsets) {
            var sumMax = 0;
            for (final slot in empty) {
              final range = band(
                slot,
                budget: budget,
                remaining: remaining,
                empty: empty,
              );
              if (range == null) continue;
              bands++;
              final (low, high) = slotBudgetShares[slot]!;
              final (:minKcal, :maxKcal) = range;
              final ok =
                  minKcal % 50 == 0 &&
                  maxKcal % 50 == 0 &&
                  minKcal >= 50 &&
                  maxKcal >= 100 &&
                  maxKcal - minKcal >= 50 &&
                  maxKcal <= high * budget &&
                  minKcal <= low * budget + 25;
              if (!ok) failures.add('$slot b=$budget r=$remaining $range');
              sumMax += maxKcal;
            }
            if (sumMax > (remaining < 0 ? 0 : remaining)) {
              failures.add('sum $sumMax > r=$remaining b=$budget e=$empty');
            }
          }
        }
      }
      expect(failures, isEmpty);
      expect(bands, greaterThan(1000));
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
