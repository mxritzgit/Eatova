import 'dart:developer' as dev;

import 'package:supabase_flutter/supabase_flutter.dart';

import 'day_math.dart';
import 'local_day.dart';

/// Daily aggregates (kcal + macros) for the trends view, read straight from
/// public.logged_meals and independent of the HomeStore boot window.
///
/// Projects only the denormalised numeric columns; the JSONB payload's macro
/// fields are display strings like "25 g".
class TrendService {
  TrendService(this._client, this._userId);

  final SupabaseClient _client;
  final String _userId;

  /// Trend window in days. Filtered on logged_at, not local_day: very old
  /// rows may carry local_day=null and would silently disappear.
  static const int trendWindowDays = 90;

  /// Defensive row cap: PostgREST truncates SILENTLY under db-max-rows, so an
  /// explicit limit makes the ceiling deterministic (order desc drops oldest).
  static const int trendMaxRows = 2500;

  static const String _projection =
      'local_day, logged_at, calories_kcal, protein_g, carbs_g, fat_g';

  /// Aggregates the window to daily totals client-side (ascending). Errors
  /// are logged and rethrown; the UI shows a retry state.
  Future<List<TrendDayTotals>> loadDailyTotals() async {
    try {
      // B5: absolute time on purpose. The cutoff is a generous bound on the
      // `logged_at` instant, so a DST-shifted edge changes nothing; day
      // boundaries appear client-side in aggregateDailyTotals.
      final cutoffIso = DateTime.now()
          .toUtc()
          .subtract(const Duration(days: trendWindowDays))
          .toIso8601String();
      final rows = await _client
          .from('logged_meals')
          .select(_projection)
          .eq('user_id', _userId)
          .gte('logged_at', cutoffIso)
          .order('logged_at', ascending: false)
          .limit(trendMaxRows);
      // Aggregation is order-independent; the desc sort only serves the limit.
      return aggregateDailyTotals(rows);
    } catch (e, stack) {
      dev.log(
        'TrendService.loadDailyTotals failed',
        error: e,
        stackTrace: stack,
        name: 'trend_service',
      );
      rethrow;
    }
  }
}

/// Trend loader injected into TrendsScreen; tests pass fakes.
typedef TrendTotalsLoader = Future<List<TrendDayTotals>> Function();

/// One daily total (local calendar day) for the trends view.
class TrendDayTotals {
  const TrendDayTotals({
    required this.day,
    required this.kcal,
    required this.proteinG,
    required this.carbsG,
    required this.fatG,
  });

  /// Local calendar day (date-only, no time).
  final DateTime day;
  final int kcal;
  final double proteinG;
  final double carbsG;
  final double fatG;
}

/// A day "hits" the kcal goal within +/-10 % of it (bounds inclusive).
const double trendGoalTolerance = 0.10;

/// Pure aggregation: PostgREST rows -> daily totals, ascending. Day key is
/// `local_day` (DATA-6), falling back to `logged_at`; null macros count as 0.
List<TrendDayTotals> aggregateDailyTotals(Iterable<Map<String, dynamic>> rows) {
  final byDay = <String, ({int kcal, double p, double c, double f})>{};
  for (final row in rows) {
    String? key = row['local_day']?.toString();
    if (key == null) {
      final loggedAtRaw = row['logged_at']?.toString();
      final loggedAt = loggedAtRaw == null
          ? null
          : DateTime.tryParse(loggedAtRaw);
      // Defensive: skip a row without any date.
      if (loggedAt == null) {
        continue;
      }
      key = localDayKey(loggedAt.toLocal());
    }
    final prev = byDay[key] ?? (kcal: 0, p: 0.0, c: 0.0, f: 0.0);
    byDay[key] = (
      kcal: prev.kcal + ((row['calories_kcal'] as num?)?.toInt() ?? 0),
      p: prev.p + ((row['protein_g'] as num?)?.toDouble() ?? 0),
      c: prev.c + ((row['carbs_g'] as num?)?.toDouble() ?? 0),
      f: prev.f + ((row['fat_g'] as num?)?.toDouble() ?? 0),
    );
  }
  final totals = <TrendDayTotals>[];
  for (final entry in byDay.entries) {
    final day = DateTime.tryParse(entry.key);
    if (day == null) continue; // defensive: broken day key
    totals.add(
      TrendDayTotals(
        // startOfDay, not DateTime(y, m, d): same value, but the same calendar
        // normalisation day_math.dart provides everywhere else (B5).
        day: startOfDay(day),
        kcal: entry.value.kcal,
        proteinG: entry.value.p,
        carbsG: entry.value.c,
        fatG: entry.value.f,
      ),
    );
  }
  totals.sort((a, b) => a.day.compareTo(b.day));
  return totals;
}

/// Dense window of the last [days] calendar days, oldest first: the total per
/// day or `null` for a gap. The last entry is [today], a property
/// [completedDaysOf] relies on; [days] <= 0 yields an empty window.
List<TrendDayTotals?> denseTrendWindow(
  List<TrendDayTotals> totals, {
  required DateTime today,
  required int days,
}) {
  final byKey = <String, TrendDayTotals>{
    for (final t in totals) localDayKey(t.day): t,
  };
  // B5: dayStrip counts calendar days; a Duration subtraction would slip to
  // 23:00 across a DST edge and drop a whole day out of the chart.
  return [
    for (final day in dayStrip(today: today, pastDays: days - 1))
      byKey[localDayKey(day)],
  ];
}

/// B6: the metrics slice of a [denseTrendWindow] — every day EXCEPT the
/// running one, which the averages would treat as complete and let a single
/// breakfast drag down. A day viewed at 23:50 therefore does not count either;
/// a clock heuristic would be arbitrary and untestable.
///
/// The CHART still gets the full window. A window holding only today becomes
/// empty, so callers must render an empty state instead of computing 0/0.
List<TrendDayTotals?> completedDaysOf(List<TrendDayTotals?> window) {
  if (window.isEmpty) return const <TrendDayTotals?>[];
  return window.sublist(0, window.length - 1);
}

/// Days with at least one entry. A 0-kcal day counts as tracked.
int trackedDaysOf(Iterable<TrendDayTotals?> window) {
  var tracked = 0;
  for (final day in window) {
    if (day != null) tracked++;
  }
  return tracked;
}

/// Average kcal over the TRACKED days; gap days are not 0. `null` if none.
double? averageKcalOf(Iterable<TrendDayTotals?> window) {
  var sum = 0;
  var tracked = 0;
  for (final day in window) {
    if (day == null) continue;
    sum += day.kcal;
    tracked++;
  }
  return tracked == 0 ? null : sum / tracked;
}

/// Tracked days inside `goalKcal * (1 +/- tolerance)`, bounds inclusive. Gap
/// days count as neither; a goal <= 0 has no corridor -> 0 hits.
({int hit, int tracked}) goalHitsOf(
  Iterable<TrendDayTotals?> window, {
  required int goalKcal,
  double tolerance = trendGoalTolerance,
}) {
  var hit = 0;
  var tracked = 0;
  final lo = goalKcal * (1 - tolerance);
  final hi = goalKcal * (1 + tolerance);
  for (final day in window) {
    if (day == null) continue;
    tracked++;
    if (goalKcal > 0 && day.kcal >= lo && day.kcal <= hi) hit++;
  }
  return (hit: hit, tracked: tracked);
}

/// Average macros (P/C/F in grams) over the tracked days. `null` if none.
({double proteinG, double carbsG, double fatG})? averageMacrosOf(
  Iterable<TrendDayTotals?> window,
) {
  var p = 0.0;
  var c = 0.0;
  var f = 0.0;
  var tracked = 0;
  for (final day in window) {
    if (day == null) continue;
    p += day.proteinG;
    c += day.carbsG;
    f += day.fatG;
    tracked++;
  }
  if (tracked == 0) return null;
  return (proteinG: p / tracked, carbsG: c / tracked, fatG: f / tracked);
}
