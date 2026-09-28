/// Day-level nutrition numbers shared by the redesigned tabs: the Today hero,
/// the Food slot cards, the Coach start card and the recipe pick.
///
/// Pure and widget-free; `HomeStore` binds its state to these in
/// `home_store_derivations.dart`.
library;

import 'daily_calorie_balance.dart';
import 'logged_meal.dart';
import 'macro_progress.dart';
import 'user_profile.dart';

/// One local day as the tabs show it: budget, eaten, activity credit and the
/// macros still open.
///
/// Budget = goal + activity credit, the rule of the Today hero and the coach
/// context ([DailyCalorieBalance]). Macros left use the profile goals only;
/// the activity credit is energy, not protein.
final class DayNutritionSummary {
  DayNutritionSummary({
    required UserProfile profile,
    required int burnedKcal,
    required this.consumed,
  }) : balance = DailyCalorieBalance(
         goalKcal: profile.dailyKcalGoal,
         consumedKcal: consumed.kcal,
         burnedKcal: burnedKcal,
       ),
       proteinGoalG = profile.proteinGoalG,
       carbsGoalG = profile.carbsGoalG,
       fatGoalG = profile.fatGoalG;

  final DailyCalorieBalance balance;

  /// Summed kcal and macros of the day's logged meals.
  final MacroProgress consumed;

  final int proteinGoalG;
  final int carbsGoalG;
  final int fatGoalG;

  int get goalKcal => balance.goalKcal;
  int get burnedKcal => balance.burnedKcal;
  int get consumedKcal => balance.consumedKcal;
  int get budgetKcal => balance.budgetKcal;

  /// Budget minus eaten; negative means over budget.
  int get remainingKcal => balance.remainingKcal;

  /// Eaten share of the budget, 0..1 (the calorie arc and "58% eaten").
  double get eatenFraction => balance.progress;

  /// Grams still open, rounded and never below 0 (same rule as the Today
  /// coach teaser).
  int get proteinLeftG => _left(proteinGoalG, consumed.proteinG);
  int get carbsLeftG => _left(carbsGoalG, consumed.carbsG);
  int get fatLeftG => _left(fatGoalG, consumed.fatG);

  /// The suggested band for an empty [slot] on this day's budget; see
  /// [suggestedKcalRangeForSlot].
  KcalRange suggestedKcalRange(MealSlot slot) =>
      suggestedKcalRangeForSlot(slot, budgetKcal);

  static int _left(int goalG, double eatenG) =>
      (goalG - eatenG).round().clamp(0, 99999);
}

/// Inclusive kcal band, both ends multiples of 50.
typedef KcalRange = ({int minKcal, int maxKcal});

/// Share of the day's budget suggested per slot, as (low, high) fractions.
///
/// Breakfast 20–25 %, lunch and dinner 25–33 %, snacks 7.5–15 %: a common
/// four-meal split, chosen so that the design's sample budget of 2,123 kcal
/// yields its exact bands (400–550, 550–700, 550–700, 150–300).
const Map<MealSlot, (double, double)> slotBudgetShares = {
  MealSlot.breakfast: (0.20, 0.25),
  MealSlot.lunch: (0.25, 0.33),
  MealSlot.dinner: (0.25, 0.33),
  MealSlot.snack: (0.075, 0.15),
};

/// "Suggested 550–700 kcal" for an empty [slot]: [slotBudgetShares] of
/// [budgetKcal] (goal + activity credit), each end rounded to the nearest
/// 50 kcal.
///
/// A static daily guide: it ignores what is already eaten. Whether a concrete
/// meal still fits the day is the recipe pick's job (`RecipePick.fits`).
/// Floors keep the band readable for tiny budgets: min >= 50, max >= min + 50.
KcalRange suggestedKcalRangeForSlot(MealSlot slot, int budgetKcal) {
  final (low, high) = slotBudgetShares[slot]!;
  final budget = budgetKcal < 0 ? 0 : budgetKcal;
  int round50(double kcal) => (kcal / 50).round() * 50;
  final minKcal = _atLeast(round50(budget * low), 50);
  final maxKcal = _atLeast(round50(budget * high), minKcal + 50);
  return (minKcal: minKcal, maxKcal: maxKcal);
}

int _atLeast(int value, int floor) => value < floor ? floor : value;

/// Main meals in day order; snacks are never a "next meal".
const List<MealSlot> mainMealSlots = <MealSlot>[
  MealSlot.breakfast,
  MealSlot.lunch,
  MealSlot.dinner,
];

/// The next main meal still open today, or null.
///
/// Rule: the current slot comes from the app's time-of-day heuristic
/// ([mealSlotForHour]: breakfast < 11:00, lunch < 15:00, dinner < 21:00,
/// snack after). From that slot on, the first main slot without any entry in
/// [todaysMeals] wins. Earlier, skipped slots are never suggested (at 13:00 an
/// empty breakfast is history, not the next meal), and from 21:00 there is no
/// next main meal. A meal counts for its [LoggedMeal.slot], so a forced slot
/// is respected.
///
/// [todaysMeals] must be the meals of [now]'s local day.
MealSlot? nextOpenMainMealSlot({
  required DateTime now,
  required Iterable<LoggedMeal> todaysMeals,
}) {
  final current = mealSlotForHour(now.toLocal().hour);
  final start = mainMealSlots.indexOf(current);
  if (start < 0) return null;
  final filled = <MealSlot>{for (final meal in todaysMeals) meal.slot};
  for (final slot in mainMealSlots.skip(start)) {
    if (!filled.contains(slot)) return slot;
  }
  return null;
}
