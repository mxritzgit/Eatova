import 'package:clock/clock.dart';

import '../services/local_day.dart';
import 'meal_analysis_result.dart';

enum MealSlot { breakfast, lunch, dinner, snack }

extension MealSlotLabel on MealSlot {
  /// German plain-text name, INDEPENDENT of the app language.
  ///
  /// Only for non-UI text sent to the AI model (coach context). For
  /// user-visible text always use `MealSlotStyle.label(l10n)`
  /// (theme/meal_slot_style.dart), which reads the ARB.
  String get germanLabel => switch (this) {
        MealSlot.breakfast => 'Frühstück',
        MealSlot.lunch => 'Mittagessen',
        MealSlot.dinner => 'Abendessen',
        MealSlot.snack => 'Snacks',
      };
}

/// Pure time-of-day heuristic: maps an hour (0-23) to a [MealSlot].
/// Top-level and pure so the 11/15/21 boundaries are testable without a
/// LoggedMeal instance or a wall clock.
MealSlot mealSlotForHour(int hour) {
  if (hour < 11) return MealSlot.breakfast;
  if (hour < 15) return MealSlot.lunch;
  if (hour < 21) return MealSlot.dinner;
  return MealSlot.snack;
}

/// Slot for "now" from the local zone clock. Reads [clock.now()] so tests can
/// pin midnight/DST boundaries via withClock; runtime behaviour is unchanged.
MealSlot currentMealSlot() => mealSlotForHour(clock.now().hour);

class LoggedMeal {
  const LoggedMeal({
    required this.id,
    required this.result,
    required this.loggedAt,
    this.forcedSlot,
    this.localDay,
  });

  final String id;
  final MealAnalysisResult result;
  final DateTime loggedAt;
  final MealSlot? forcedSlot;

  /// DATA-6: canonical local day key (`YYYY-MM-DD`), mirroring
  /// `logged_meals.local_day`. Optional: older rows leave it null and bucketing
  /// falls back to `isSameDay(.toLocal())`.
  final String? localDay;

  /// Local day key: the persisted [localDay] if present, else derived from
  /// [loggedAt]. Always non-null so bucketing has a stable key.
  String get effectiveLocalDay => localDay ?? localDayKey(loggedAt.toLocal());

  MealSlot get slot {
    if (forcedSlot != null) {
      return forcedSlot!;
    }
    return mealSlotForHour(loggedAt.hour);
  }

  LoggedMeal copyWith({
    MealAnalysisResult? result,
    DateTime? loggedAt,
    MealSlot? forcedSlot,
    String? localDay,
  }) {
    return LoggedMeal(
      id: id,
      result: result ?? this.result,
      loggedAt: loggedAt ?? this.loggedAt,
      forcedSlot: forcedSlot ?? this.forcedSlot,
      localDay: localDay ?? this.localDay,
    );
  }
}
