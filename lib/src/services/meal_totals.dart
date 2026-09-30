import 'package:flutter/material.dart' show DateUtils;

import '../models/logged_meal.dart';
import '../models/macro_progress.dart';
import 'local_day.dart';

/// Pure aggregation helpers for the daily nutrition values, extracted from the
/// home state so the kcal/macro math is unit-testable without UI.

/// All meals logged for [date] — day-accurate, the time is ignored.
///
/// DATA-6: meals with a persisted [LoggedMeal.localDay] are bucketed by that
/// canonical local day key, so a 23:45 entry stays on the same day even if the
/// view later runs under a different zone/DST offset. Rows without localDay
/// fall back to the old `isSameDay(.toLocal())` logic.
List<LoggedMeal> mealsForFoodDate(List<LoggedMeal> meals, DateTime date) {
  final dayKey = localDayKey(date.toLocal());
  final day = DateUtils.dateOnly(date);
  return meals.where((meal) {
    final persisted = meal.localDay;
    if (persisted != null) {
      return persisted == dayKey;
    }
    return DateUtils.isSameDay(meal.loggedAt, day);
  }).toList(growable: false);
}

/// Total calories eaten on [date].
int consumedKcalForFoodDate(List<LoggedMeal> meals, DateTime date) {
  return mealsForFoodDate(meals, date)
      .fold<int>(0, (sum, meal) => sum + meal.result.caloriesKcal);
}

/// Macro progress (protein/carbs/fat/kcal) on [date], summed over the meals.
MacroProgress macroProgressForFoodDate(List<LoggedMeal> meals, DateTime date) {
  return mealsForFoodDate(meals, date).fold<MacroProgress>(
    MacroProgress.empty,
    (progress, meal) => progress.add(meal.result),
  );
}

/// Daily total of ONE meal slot: summed macros/kcal plus the number of
/// entries. [MacroProgress] has no count, but the coach context needs it to
/// tell "one large dinner" from "many entries".
typedef SlotTotals = ({MacroProgress macros, int entries});

/// Macro progress per [MealSlot] on [date] — the slot breakdown of
/// [macroProgressForFoodDate] for the coach context.
///
/// Contains ONLY slots with at least one meal on [date], in
/// [MealSlot.values] order regardless of log order. Empty slots are absent
/// rather than [MacroProgress.empty], so callers filter nothing and "empty"
/// stays distinguishable from "0 kcal logged". The slot comes from
/// [LoggedMeal.slot]; the day filter is [mealsForFoodDate].
Map<MealSlot, SlotTotals> slotTotalsForFoodDate(
  List<LoggedMeal> meals,
  DateTime date,
) {
  final bySlot = <MealSlot, SlotTotals>{};
  for (final meal in mealsForFoodDate(meals, date)) {
    final previous =
        bySlot[meal.slot] ?? (macros: MacroProgress.empty, entries: 0);
    bySlot[meal.slot] = (
      macros: previous.macros.add(meal.result),
      entries: previous.entries + 1,
    );
  }
  // Canonical slot order instead of insertion order: the map is rendered
  // linearly into the context and should read as the course of a day.
  return {
    for (final slot in MealSlot.values)
      if (bySlot.containsKey(slot)) slot: bySlot[slot]!,
  };
}

/// One diary slot of a day, for the Food card header ("08:10 · 3 items") and
/// the Today slot rows.
final class MealSlotSummary {
  const MealSlotSummary({
    required this.slot,
    required this.meals,
    required this.macros,
  });

  final MealSlot slot;

  /// The slot's meals on that day, oldest first (id breaks equal times).
  final List<LoggedMeal> meals;

  /// Summed kcal and macros of [meals].
  final MacroProgress macros;

  int get entryCount => meals.length;
  bool get isEmpty => meals.isEmpty;
  int get kcal => macros.kcal;

  /// Local time of the earliest entry; null for an empty slot.
  DateTime? get firstLoggedAt =>
      meals.isEmpty ? null : meals.first.loggedAt.toLocal();
}

/// All four slots of [date] in [MealSlot.values] order, empty ones included,
/// so a diary can render them in one pass. Day filter: [mealsForFoodDate];
/// slot: [LoggedMeal.slot].
List<MealSlotSummary> mealSlotSummariesForFoodDate(
  List<LoggedMeal> meals,
  DateTime date,
) {
  final bySlot = <MealSlot, List<LoggedMeal>>{};
  for (final meal in mealsForFoodDate(meals, date)) {
    bySlot.putIfAbsent(meal.slot, () => <LoggedMeal>[]).add(meal);
  }
  final summaries = <MealSlotSummary>[];
  for (final slot in MealSlot.values) {
    final inSlot = (bySlot[slot] ?? <LoggedMeal>[])
      ..sort((a, b) {
        final byTime = a.loggedAt.compareTo(b.loggedAt);
        return byTime != 0 ? byTime : a.id.compareTo(b.id);
      });
    summaries.add(
      MealSlotSummary(
        slot: slot,
        meals: List.unmodifiable(inSlot),
        macros: inSlot.fold<MacroProgress>(
          MacroProgress.empty,
          (sum, meal) => sum.add(meal.result),
        ),
      ),
    );
  }
  return List.unmodifiable(summaries);
}
