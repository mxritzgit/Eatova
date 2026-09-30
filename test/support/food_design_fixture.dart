// The Food design scenario (dark redesign 2026-09-28, design/food): Monday
// 2026-09-28 at 18:30, breakfast 08:10, lunch 12:45, dinner empty, snacks
// 16:20 — 1,221 kcal, 111 g protein, 144 g carbs, 20 g fat against a
// 2,123 kcal budget (902 left). The day's recipe pick is the turkey steak
// (610 kcal) for dinner.

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/local_day.dart';

/// "Now" of the scenario: dinner is the next open main meal.
final DateTime foodDesignNow = DateTime(2026, 9, 28, 18, 30);

/// Goal = the design's budget; the test shell has no step source, so there
/// is no activity credit on top.
const UserProfile foodDesignProfile = UserProfile(
  dailyKcalGoal: 2123,
  proteinGoalG: 162,
  carbsGoalG: 222,
  fatGoalG: 57,
);

LoggedMeal _item(
  String id,
  MealSlot slot,
  DateTime at,
  String name,
  int grams,
  int kcal, {
  required int protein,
  required int carbs,
  required int fat,
}) => LoggedMeal(
  id: id,
  forcedSlot: slot,
  loggedAt: at,
  localDay: localDayKey(at),
  result: MealAnalysisResult(
    mealName: name,
    caloriesKcal: kcal,
    estimatedGrams: grams,
    kcalPer100G: kcal * 100 / grams,
    protein: '$protein g',
    carbs: '$carbs g',
    fat: '$fat g',
    confidence: 'database',
    portionNotes: '',
    sourceLabel: 'OpenFoodFacts',
  ),
);

/// The scenario's diary, in the store's newest-first order.
List<LoggedMeal> foodDesignMeals() {
  final breakfast = DateTime(2026, 9, 28, 8, 10);
  final lunch = DateTime(2026, 9, 28, 12, 45);
  final snacks = DateTime(2026, 9, 28, 16, 20);
  return <LoggedMeal>[
    _item(
      's2',
      MealSlot.snack,
      snacks,
      'Whey shake',
      30,
      118,
      protein: 24,
      carbs: 4,
      fat: 2,
    ),
    _item(
      's1',
      MealSlot.snack,
      snacks,
      'Banana',
      118,
      105,
      protein: 1,
      carbs: 27,
      fat: 0,
    ),
    _item(
      'l4',
      MealSlot.lunch,
      lunch,
      'Olive oil',
      10,
      88,
      protein: 0,
      carbs: 0,
      fat: 10,
    ),
    _item(
      'l3',
      MealSlot.lunch,
      lunch,
      'Broccoli',
      150,
      51,
      protein: 4,
      carbs: 6,
      fat: 1,
    ),
    _item(
      'l2',
      MealSlot.lunch,
      lunch,
      'Basmati rice, cooked',
      200,
      260,
      protein: 5,
      carbs: 56,
      fat: 1,
    ),
    _item(
      'l1',
      MealSlot.lunch,
      lunch,
      'Chicken breast',
      180,
      198,
      protein: 42,
      carbs: 0,
      fat: 2,
    ),
    _item(
      'b3',
      MealSlot.breakfast,
      breakfast,
      'Blueberries',
      100,
      57,
      protein: 1,
      carbs: 12,
      fat: 0,
    ),
    _item(
      'b2',
      MealSlot.breakfast,
      breakfast,
      'Oat flakes',
      50,
      186,
      protein: 7,
      carbs: 29,
      fat: 3,
    ),
    _item(
      'b1',
      MealSlot.breakfast,
      breakfast,
      'Skyr, natural',
      250,
      158,
      protein: 27,
      carbs: 10,
      fat: 1,
    ),
  ];
}
