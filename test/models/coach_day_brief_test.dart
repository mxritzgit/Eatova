import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/coach_day_brief.dart';
import 'package:eatova/src/models/day_nutrition.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/macro_progress.dart';
import 'package:eatova/src/models/user_profile.dart';

// The Coach start card ("From today's log", dark redesign). Design scenario:
// goal 2,050 + 73 activity = 2,123 budget, 1,221 eaten -> 902 kcal left,
// protein 111 of 162 g -> 51 g left, dinner still open.

const _profile = UserProfile(dailyKcalGoal: 2050, proteinGoalG: 162);

DayNutritionSummary _day({required int kcal, double proteinG = 0}) =>
    DayNutritionSummary(
      profile: _profile,
      burnedKcal: 73,
      consumed: MacroProgress(
        proteinG: proteinG,
        carbsG: 0,
        fatG: 0,
        kcal: kcal,
      ),
    );

CoachDayBrief _brief({
  required int kcal,
  double proteinG = 0,
  bool logged = true,
  MealSlot? next = MealSlot.dinner,
}) => coachDayBrief(
  summary: _day(kcal: kcal, proteinG: proteinG),
  loggedToday: logged,
  nextMainSlot: next,
);

void main() {
  test('reproduces the design scenario', () {
    final brief = _brief(kcal: 1221, proteinG: 111);
    expect(brief.state, CoachDayState.underBudget);
    expect(brief.budgetKcal, 2123);
    expect(brief.remainingKcal, 902);
    expect(brief.proteinLeftG, 51);
    expect(brief.mealSlot, MealSlot.dinner);
    expect(brief.proteinGapClosable, isTrue);
    expect(brief.primaryAction, CoachDayAction.suggestMeal);
    expect(brief.secondaryAction, CoachDayAction.planTomorrow);
  });

  test('reads the numbers of the shared day summary, not its own', () {
    final summary = _day(kcal: 1221, proteinG: 111);
    final brief = coachDayBrief(
      summary: summary,
      loggedToday: true,
      nextMainSlot: MealSlot.dinner,
    );
    expect(brief.remainingKcal, summary.remainingKcal);
    expect(brief.budgetKcal, summary.budgetKcal);
    expect(brief.proteinLeftG, summary.proteinLeftG);
    expect(brief.proteinGoalG, summary.proteinGoalG);
  });

  group('state', () {
    test('an empty diary is "nothing logged", not "everything left"', () {
      final brief = _brief(kcal: 0, logged: false, next: MealSlot.breakfast);
      expect(brief.state, CoachDayState.nothingLogged);
      expect(brief.primaryAction, CoachDayAction.suggestMeal);
      expect(brief.mealSlot, MealSlot.breakfast);
      expect(brief.secondaryAction, CoachDayAction.planDay);
      expect(brief.proteinGapClosable, isFalse);
    });

    test('a logged 0 kcal entry counts as logged', () {
      expect(_brief(kcal: 0).state, CoachDayState.underBudget);
    });

    test('an empty diary late at night plans tomorrow instead of the day', () {
      final brief = _brief(kcal: 0, logged: false, next: null);
      expect(brief.state, CoachDayState.nothingLogged);
      expect(brief.mealSlot, MealSlot.snack);
      expect(brief.secondaryAction, CoachDayAction.planTomorrow);
    });

    test('exactly on budget', () {
      final brief = _brief(kcal: 2123, proteinG: 150);
      expect(brief.state, CoachDayState.atBudget);
      expect(brief.overKcal, 0);
      expect(brief.primaryAction, CoachDayAction.planTomorrow);
      expect(brief.secondaryAction, isNull);
    });

    test('over budget offers no meal, only tomorrow', () {
      final brief = _brief(kcal: 2323, proteinG: 130);
      expect(brief.state, CoachDayState.overBudget);
      expect(brief.remainingKcal, -200);
      expect(brief.overKcal, 200);
      expect(brief.proteinLeftG, 32);
      expect(brief.primaryAction, CoachDayAction.planTomorrow);
      expect(brief.secondaryAction, isNull);
      expect(brief.proteinGapClosable, isFalse);
    });

    test('one kcal left is still under budget', () {
      expect(_brief(kcal: 2122).state, CoachDayState.underBudget);
    });
  });

  group('the protein hint', () {
    test('is off once the protein goal is met', () {
      expect(_brief(kcal: 1500, proteinG: 170).proteinGapClosable, isFalse);
    });

    test('is off when the gap is more than one meal', () {
      // 61 g open, plenty of kcal: one meal is not expected to close it.
      expect(_brief(kcal: 500, proteinG: 101).proteinGapClosable, isFalse);
      expect(_brief(kcal: 500, proteinG: 102).proteinGapClosable, isTrue);
    });

    test('is off when the protein would not fit the kcal left', () {
      // 51 g = 204 kcal of protein; 60 % of 340 kcal is exactly 204.
      expect(_brief(kcal: 1783, proteinG: 111).proteinGapClosable, isTrue);
      expect(_brief(kcal: 1784, proteinG: 111).proteinGapClosable, isFalse);
    });

    test('is off without a main meal ahead (snacks only)', () {
      expect(
        _brief(kcal: 1221, proteinG: 111, next: null).proteinGapClosable,
        isFalse,
      );
    });
  });
}
