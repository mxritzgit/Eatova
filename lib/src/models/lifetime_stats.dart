import '../services/day_math.dart';

/// Cumulative lifetime counters of a user (1:1 public.lifetime_stats).
///
/// The streak is a LOGGING streak: every calendar day with at least one logged
/// meal counts. The DB columns keep their historic workout names.
class LifetimeStats {
  LifetimeStats({
    this.workoutsCompleted = 0,
    this.mealsLogged = 0,
    this.waterTotalMl = 0,
    this.stepsRecorded = 0,
    this.weightLogs = 0,
    this.currentStreak = 0,
    this.longestStreak = 0,
    this.lastTrackedDate,
    DateTime? sessionStart,
  }) : sessionStart = sessionStart ?? DateTime.now();

  /// DEPRECATED (C7) — frozen legacy counter with no writer; permanently 0 for
  /// new accounts. The field stays because `workouts_completed` is a not-null
  /// column, part of the explicit select, an increment_lifetime_stats RPC
  /// parameter and lives in existing LocalCache JSON. Not `@Deprecated`: that
  /// would flood analyze at every read site for no gain.
  final int workoutsCompleted;

  final int mealsLogged;

  /// DEPRECATED (C7) — like [workoutsCompleted]: `addWater()` is gone, the
  /// column `water_total_ml` stays.
  final int waterTotalMl;

  /// DEPRECATED (C7) — like [workoutsCompleted]: `addSteps()` is gone, the
  /// column `steps_recorded` stays. Live step count is `HomeStore.dailySteps`
  /// from HealthKit.
  final int stepsRecorded;

  final int weightLogs;

  /// Current logging streak in consecutive days.
  final int currentStreak;

  /// Highest streak ever reached (never decreases).
  final int longestStreak;

  /// Date-only of the last counted logging day, or null.
  /// Persisted in the historically named column last_workout_date.
  final DateTime? lastTrackedDate;

  final DateTime sessionStart;

  /// C7: the frozen legacy counters ([workoutsCompleted], [waterTotalMl],
  /// [stepsRecorded]) are deliberately not settable here and only passed
  /// through; the constructor still takes them so [fromRow] and the LocalCache
  /// can reconstruct existing values.
  LifetimeStats copyWith({
    int? mealsLogged,
    int? weightLogs,
    int? currentStreak,
    int? longestStreak,
    DateTime? lastTrackedDate,
  }) {
    return LifetimeStats(
      workoutsCompleted: workoutsCompleted,
      mealsLogged: mealsLogged ?? this.mealsLogged,
      waterTotalMl: waterTotalMl,
      stepsRecorded: stepsRecorded,
      weightLogs: weightLogs ?? this.weightLogs,
      currentStreak: currentStreak ?? this.currentStreak,
      longestStreak: longestStreak ?? this.longestStreak,
      lastTrackedDate: lastTrackedDate ?? this.lastTrackedDate,
      sessionStart: sessionStart,
    );
  }

  LifetimeStats incrementMeals() =>
      copyWith(mealsLogged: mealsLogged + 1);

  LifetimeStats incrementWeightLogs() =>
      copyWith(weightLogs: weightLogs + 1);

  /// Records a tracked day (>= 1 logged meal) and continues the streak.
  ///
  /// Yesterday -> +1; same day -> idempotent; [day] before lastTrackedDate ->
  /// no-op (back-dated entries must neither reset nor extend the streak);
  /// otherwise reset to 1. longestStreak = max(longestStreak, new streak).
  LifetimeStats recordTrackedDay(DateTime day) {
    final today = DateTime(day.year, day.month, day.day);
    int nextStreak;
    if (lastTrackedDate == null) {
      nextStreak = 1;
    } else {
      final last = DateTime(
        lastTrackedDate!.year,
        lastTrackedDate!.month,
        lastTrackedDate!.day,
      );
      // B5: calendar days, not `.difference().inDays` — the latter measures
      // absolute time and reports 0 instead of 1 across the DST short day.
      final diffDays = daysBetween(today, last);
      if (diffDays < 0) {
        // Back-dated entry: streak untouched.
        return this;
      }
      if (diffDays == 0) {
        // Already counted today: idempotent, streak holds.
        nextStreak = currentStreak < 1 ? 1 : currentStreak;
      } else if (diffDays == 1) {
        nextStreak = currentStreak + 1;
      } else {
        // Gap (or future date): streak broken, restart at 1.
        nextStreak = 1;
      }
    }
    final nextLongest = nextStreak > longestStreak ? nextStreak : longestStreak;
    return copyWith(
      currentStreak: nextStreak,
      longestStreak: nextLongest,
      lastTrackedDate: today,
    );
  }

  /// Streak for DISPLAY: currentStreak while the chain is alive (last tracked
  /// day is today or yesterday relative to [now]), else 0. currentStreak itself
  /// stays put until the next log, so without this check a long-broken chain
  /// would keep showing its old value.
  int effectiveStreakOn(DateTime now) {
    final last = lastTrackedDate;
    if (last == null) return 0;
    final today = DateTime(now.year, now.month, now.day);
    final lastDay = DateTime(last.year, last.month, last.day);
    // B5: see recordTrackedDay — `.difference().inDays` returned 1 for 47
    // hours across DST, showing a broken chain as alive.
    final diffDays = daysBetween(today, lastDay);
    return diffDays <= 1 ? currentStreak : 0;
  }

  /// Builds LifetimeStats from a public.lifetime_stats row. Missing or
  /// mistyped columns fall back to defaults so an old schema does not crash.
  factory LifetimeStats.fromRow(Map<String, dynamic> row) {
    return LifetimeStats(
      workoutsCompleted: _toInt(row['workouts_completed']),
      mealsLogged: _toInt(row['meals_logged']),
      waterTotalMl: _toInt(row['water_total_ml']),
      stepsRecorded: _toInt(row['steps_recorded']),
      weightLogs: _toInt(row['weight_logs']),
      currentStreak: _toInt(row['current_streak']),
      longestStreak: _toInt(row['longest_streak']),
      lastTrackedDate: _toDate(row['last_workout_date']),
      sessionStart: _toDate(row['session_start']),
    );
  }

  /// Serializes to the public.lifetime_stats column format. There is no direct
  /// client write to the table any more (RPCs only), so this map is just a
  /// wire-format guard for tests. session_start is deliberately omitted: the
  /// first insert sets it via DB default and later saves must not overwrite it.
  Map<String, dynamic> toRow() {
    return <String, dynamic>{
      'workouts_completed': workoutsCompleted,
      'meals_logged': mealsLogged,
      'water_total_ml': waterTotalMl,
      'steps_recorded': stepsRecorded,
      'weight_logs': weightLogs,
      'current_streak': currentStreak,
      'longest_streak': longestStreak,
      'last_workout_date':
          lastTrackedDate == null ? null : _dateOnly(lastTrackedDate!),
    };
  }

  static int _toInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }

  static DateTime? _toDate(Object? value) {
    if (value is DateTime) return value;
    if (value is String && value.isNotEmpty) {
      return DateTime.tryParse(value);
    }
    return null;
  }

  static String _dateOnly(DateTime d) {
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '$y-$m-$day';
  }
}
