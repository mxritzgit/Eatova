import '../models/lifetime_stats.dart';
import '../models/logged_meal.dart';

/// Whether the user has logged meals on at least two different days (C4).
///
/// Today offers the reminder only then: one log is curiosity, a second day
/// is the start of a habit the reminder can protect. The streak counters
/// cover history beyond the loaded meal window
/// (`MealsSync.loggedMealsWindowDays`); the window covers two days that were
/// never consecutive.
bool loggedOnTwoDays(Iterable<LoggedMeal> meals, LifetimeStats stats) {
  if (stats.longestStreak >= 2 || stats.currentStreak >= 2) return true;
  String? first;
  for (final meal in meals) {
    final day = meal.effectiveLocalDay;
    if (first == null) {
      first = day;
    } else if (day != first) {
      return true;
    }
  }
  return false;
}
