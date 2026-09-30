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

  /// The suggested band for the empty [slot] on this day, given the day's
  /// [emptySlots]; null when too little is left. See
  /// [suggestedKcalRangeForSlot].
  KcalRange? suggestedKcalRange(
    MealSlot slot, {
    required Iterable<MealSlot> emptySlots,
  }) => suggestedKcalRangeForSlot(
    slot,
    budgetKcal: budgetKcal,
    remainingKcal: remainingKcal,
    emptySlots: emptySlots,
  );

  static int _left(int goalG, double eatenG) =>
      (goalG - eatenG).round().clamp(0, 99999);
}

/// Inclusive kcal band, both ends multiples of 50.
typedef KcalRange = ({int minKcal, int maxKcal});

/// Share of the day's budget suggested per slot, as (low, high) fractions.
///
/// Breakfast 20–25 %, lunch and dinner 25–33 %, snacks 7.5–15 %: a common
/// four-meal split. [suggestedKcalRangeForSlot] caps it by what is left.
const Map<MealSlot, (double, double)> slotBudgetShares = {
  MealSlot.breakfast: (0.20, 0.25),
  MealSlot.lunch: (0.25, 0.33),
  MealSlot.dinner: (0.25, 0.33),
  MealSlot.snack: (0.075, 0.15),
};

/// "Suggested 550–600 kcal" for the empty [slot], adapted to what is left.
///
/// Rule, with B = [budgetKcal] (goal + activity credit, floored at 0),
/// R = [remainingKcal] (budget minus eaten), E = [emptySlots] plus [slot]
/// and mid = (low + high) / 2 of [slotBudgetShares]:
/// - fair share F = R × mid(slot) / Σ mid(E): what is left, split over the
///   still-empty slots by their share midpoints;
/// - max = min(high × B, F), floored to a multiple of 50, so the maxima of
///   all empty slots never add up to more than R;
/// - max < 100 → null (no band; nothing meaningful is left);
/// - min = min(low × B rounded to 50, max − 50), at least 50.
///
/// With nothing eaten and every slot empty, F sits just under high × B, so
/// the band stays close to the static split: the design's sample budget of
/// 2,123 kcal gives 400–500, 550–650, 550–650 and 150–250 (the design draws
/// the static 400–550, 550–700, 550–700, 150–300). Its scenario (1,221 eaten,
/// 902 left) keeps dinner at 550–700 while dinner is the only empty slot (the
/// cap of 33 % binds); with dinner and snack empty they get 550–600 and
/// 150–250.
///
/// Whether a concrete meal still fits the day is the recipe pick's job
/// (`RecipePick.fits`).
KcalRange? suggestedKcalRangeForSlot(
  MealSlot slot, {
  required int budgetKcal,
  required int remainingKcal,
  required Iterable<MealSlot> emptySlots,
}) {
  final budget = budgetKcal < 0 ? 0 : budgetKcal;
  if (budget == 0 || remainingKcal <= 0) return null;
  // Integer per-mille shares keep the floors exact.
  final (lowMille, highMille) = _sharesMille(slot);
  var midSum = 0;
  for (final s in {...emptySlots, slot}) {
    final (low, high) = _sharesMille(s);
    midSum += low + high;
  }
  final fairShare = remainingKcal * (lowMille + highMille) ~/ midSum;
  final cap = budget * highMille ~/ 1000;
  final maxKcal = _floor50(fairShare < cap ? fairShare : cap);
  if (maxKcal < 100) return null;
  final lowKcal = (budget * lowMille + 25000) ~/ 50000 * 50;
  final minKcal = lowKcal < maxKcal - 50 ? lowKcal : maxKcal - 50;
  return (minKcal: minKcal < 50 ? 50 : minKcal, maxKcal: maxKcal);
}

(int, int) _sharesMille(MealSlot slot) {
  final (low, high) = slotBudgetShares[slot]!;
  return ((low * 1000).round(), (high * 1000).round());
}

int _floor50(int kcal) => kcal ~/ 50 * 50;

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
