/// The Coach start card ("From today's log"): where today stands against the
/// budget, and which prepared questions fit that situation.
///
/// Pure and widget-free. The numbers come from [DayNutritionSummary] (budget =
/// goal + activity credit, the same rule as the Today hero and the coach
/// context); the texts live in the ARB files.
library;

import 'day_nutrition.dart';
import 'logged_meal.dart';

/// Where today stands against its budget.
enum CoachDayState {
  /// Nothing is logged for today yet.
  nothingLogged,

  /// Some of the budget is still open.
  underBudget,

  /// The budget is used up exactly.
  atBudget,

  /// More was eaten than the budget allows.
  overBudget,
}

/// A prepared question the card offers as a pill.
enum CoachDayAction {
  /// "Suggest a dinner": a meal for [CoachDayBrief.mealSlot].
  suggestMeal,

  /// "Plan my day": nothing is logged and a main meal is still ahead.
  planDay,

  /// "Plan tomorrow".
  planTomorrow,
}

/// Today's numbers as the Coach start card reads them.
final class CoachDayBrief {
  const CoachDayBrief({
    required this.state,
    required this.budgetKcal,
    required this.remainingKcal,
    required this.proteinGoalG,
    required this.proteinLeftG,
    required this.mealSlot,
    required this.mainMealAhead,
  });

  /// Most protein one meal is expected to close. Above it the card does not
  /// claim that a single meal closes the gap.
  static const int maxProteinPerMealG = 60;

  /// Highest share (in percent) of a lean meal's energy that comes from
  /// protein. Above it the protein still open would not fit into the kcal
  /// still open.
  static const int maxProteinEnergyPercent = 60;

  final CoachDayState state;

  /// Goal plus activity credit.
  final int budgetKcal;

  /// Budget minus eaten; negative means over budget.
  final int remainingKcal;

  final int proteinGoalG;

  /// Protein still open in grams, never below 0.
  final int proteinLeftG;

  /// The slot "Suggest a …" asks for: today's next open main meal, or snacks
  /// when no main meal is ahead.
  final MealSlot mealSlot;

  /// Whether a main meal is still open today ([nextOpenMainMealSlot]).
  final bool mainMealAhead;

  /// kcal over the budget, 0 when not over.
  int get overKcal => remainingKcal < 0 ? -remainingKcal : 0;

  /// Whether one lean main meal can close the protein gap without going over:
  /// at most [maxProteinPerMealG] g open, and their energy (4 kcal/g) at most
  /// [maxProteinEnergyPercent] % of the kcal still open.
  bool get proteinGapClosable =>
      state == CoachDayState.underBudget &&
      mainMealAhead &&
      proteinLeftG > 0 &&
      proteinLeftG <= maxProteinPerMealG &&
      proteinLeftG * 4 * 100 <= remainingKcal * maxProteinEnergyPercent;

  /// The accent pill. Over or at the budget a meal suggestion would push the
  /// day further over, so the card looks ahead instead.
  CoachDayAction get primaryAction => switch (state) {
    CoachDayState.atBudget ||
    CoachDayState.overBudget => CoachDayAction.planTomorrow,
    _ => CoachDayAction.suggestMeal,
  };

  /// The secondary pill, or null when the primary one already plans ahead.
  CoachDayAction? get secondaryAction => switch (state) {
    CoachDayState.nothingLogged =>
      mainMealAhead ? CoachDayAction.planDay : CoachDayAction.planTomorrow,
    CoachDayState.underBudget => CoachDayAction.planTomorrow,
    CoachDayState.atBudget || CoachDayState.overBudget => null,
  };
}

/// Reads [summary] for the Coach start card.
///
/// [loggedToday] is whether today's diary has any entry (a 0 kcal entry
/// counts); [nextMainSlot] is today's next open main meal, or null from
/// 21:00 on or once every main meal is logged.
CoachDayBrief coachDayBrief({
  required DayNutritionSummary summary,
  required bool loggedToday,
  required MealSlot? nextMainSlot,
}) {
  final remaining = summary.remainingKcal;
  final state = !loggedToday
      ? CoachDayState.nothingLogged
      : remaining > 0
      ? CoachDayState.underBudget
      : remaining == 0
      ? CoachDayState.atBudget
      : CoachDayState.overBudget;
  return CoachDayBrief(
    state: state,
    budgetKcal: summary.budgetKcal,
    remainingKcal: remaining,
    proteinGoalG: summary.proteinGoalG,
    proteinLeftG: summary.proteinLeftG,
    mealSlot: nextMainSlot ?? MealSlot.snack,
    mainMealAhead: nextMainSlot != null,
  );
}
