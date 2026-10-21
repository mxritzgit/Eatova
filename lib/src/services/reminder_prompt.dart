import '../models/lifetime_stats.dart';
import '../models/logged_meal.dart';
import 'day_math.dart';
import 'local_day.dart';

/// From this local hour the first day with an entry counts as an evening
/// worth a reminder offer.
const int reminderOfferEveningHour = 17;

/// Whether Today may offer the reminder (C4; review 2026-10-22: from day one).
///
/// The offer comes on the evening of the first day with an entry, and on any
/// later day. Waiting for a second day missed exactly the people who log once
/// and never come back. Before the evening the first day is still running,
/// and the offer would land in the middle of the first meal.
///
/// The streak counters and the last tracked day cover history beyond the
/// loaded meal window (`MealsSync.loggedMealsWindowDays`). It stays an
/// explicit opt-in: this only decides when the card shows.
bool reminderOfferDue(
  Iterable<LoggedMeal> meals,
  LifetimeStats stats,
  DateTime now,
) {
  if (stats.longestStreak >= 2 || stats.currentStreak >= 2) return true;
  final today = startOfDay(now);
  final last = stats.lastTrackedDate;
  if (last != null && startOfDay(last).isBefore(today)) return true;
  final todayKey = localDayKey(now);
  var loggedToday = last != null && startOfDay(last) == today;
  for (final meal in meals) {
    // Entries cannot be dated ahead, so another day is an earlier one.
    if (meal.effectiveLocalDay != todayKey) return true;
    loggedToday = true;
  }
  return loggedToday && now.hour >= reminderOfferEveningHour;
}
