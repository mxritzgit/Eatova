import 'dart:async';
import 'dart:developer' as dev;

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'day_math.dart';
import 'local_day.dart';

/// Daily aggregates (kcal + macros) for the trends view, read straight from
/// public.logged_meals and independent of the HomeStore boot window.
///
/// Projects only the denormalised numeric columns; the JSONB payload's macro
/// fields are display strings like "25 g".
class TrendService {
  TrendService(this._client, this._userId, {TrendTotalsCache? cache})
    : _cache = cache ?? TrendTotalsCache.instance;

  final SupabaseClient _client;
  final String _userId;

  /// Session cache in front of the window query; defaults to the process-wide
  /// instance because the loader builds a fresh service on every open.
  final TrendTotalsCache _cache;

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
  ///
  /// Served from [TrendTotalsCache] when a fresh entry for this user and this
  /// calendar day exists — opening the view twice in a session is then free.
  Future<List<TrendDayTotals>> loadDailyTotals() {
    // Attached here, not in the constructor: a service is built per open, and
    // attaching is idempotent, so the singleton keeps exactly one listener.
    _cache.attachAuthEvents(
      _client.auth.onAuthStateChange.map((state) => state.event),
    );
    return _cache.read(userId: _userId, load: _fetchDailyTotals);
  }

  Future<List<TrendDayTotals>> _fetchDailyTotals() async {
    try {
      // B5: absolute time on purpose. The cutoff is a generous bound on the
      // `logged_at` instant, so a DST-shifted edge changes nothing; day
      // boundaries appear client-side in aggregateDailyTotals.
      //
      // P1-06: `clock.now()`, like MealsSync — the cache measures the day
      // rollover against the same injectable clock, and a `withClock` test
      // that moves the day must move the cutoff with it.
      final cutoffIso = clock
          .now()
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

/// Session cache in front of [TrendService.loadDailyTotals].
///
/// The 90-day window is one PostgREST round trip over up to
/// [TrendService.trendMaxRows] rows, and it used to run on EVERY open of the
/// trends view. One entry is kept per session, keyed by user AND local
/// calendar day.
///
/// A stale trend chart is a correctness bug the user believes, so the entry is
/// dropped on everything that can make it wrong:
///  * the local calendar day rolls over — the 90-day window slides (the key
///    holds [localDayKey], measured against the injectable `clock`),
///  * a different user asks (account switch — the key holds the user id),
///  * any auth event except a token refresh: sign-out, sign-in, user deleted
///    ([attachAuthEvents]),
///  * [invalidate], the hook for a write (meal/weight logged, edited,
///    deleted),
///  * [ttl] expiry.
///
/// [invalidate] is called by `HomeStore` on every logged-meal write the server
/// will see (add, edit, result rescale, delete and both undos —
/// `_invalidateTrendWindow`). [ttl] is the backstop for anything that reaches
/// the rows another way, which is why it is [defaultTtl] and not an hour.
/// Only logged_meals matters here: [_projection] reads kcal and macros, so
/// weight and step writes never move this window.
class TrendTotalsCache {
  TrendTotalsCache({this.ttl = defaultTtl});

  /// Process-wide instance the Supabase loader uses. Construction is pure
  /// allocation: no `Supabase.instance`, no I/O (same contract as
  /// `SearchCredentialsStore.instance`).
  static TrendTotalsCache get instance => _instance ??= TrendTotalsCache();
  static TrendTotalsCache? _instance;

  /// Deliberately short. It covers the realistic loop — open trends, switch
  /// range, go back, open again — while keeping the window in which a meal
  /// logged in between could still show a stale chart down to minutes.
  static const Duration defaultTtl = Duration(minutes: 2);

  /// Maximum age of an entry before it is refetched.
  final Duration ttl;

  List<TrendDayTotals>? _totals;
  String? _userId;
  String? _dayKey;
  DateTime? _storedAt;

  /// Single flight: two opens in the same frame share one request.
  Future<List<TrendDayTotals>>? _inFlight;
  String? _inFlightKey;

  /// Counts invalidations, so a request started BEFORE a sign-out or a write
  /// cannot store its stale result afterwards (pattern from
  /// `SearchCredentialsStore`).
  int _generation = 0;

  /// The singleton lives as long as the process, so this is cancelled only in
  /// [dispose] (tests) — not in the function that opened it.
  // ignore: cancel_subscriptions
  StreamSubscription<AuthChangeEvent>? _authSub;

  /// True while a usable entry is held. Tests and diagnostics only.
  @visibleForTesting
  bool get debugHasEntry => _totals != null;

  /// Returns the cached window or runs [load] and stores its result. Errors
  /// are never cached — the screen keeps its retry state and the next open
  /// really refetches.
  ///
  /// A hit hands out the SAME list every caller before it got, so callers must
  /// treat it as read-only (TrendsScreen only reads it).
  Future<List<TrendDayTotals>> read({
    required String userId,
    required Future<List<TrendDayTotals>> Function() load,
  }) {
    final now = clock.now();
    final dayKey = localDayKey(now);
    final key = '$userId|$dayKey';
    final cached = _totals;
    final storedAt = _storedAt;
    if (cached != null && storedAt != null && '$_userId|$_dayKey' == key) {
      final age = now.difference(storedAt);
      // A clock jumped BACKWARDS yields a negative age; treat that as a miss
      // rather than as "fresh forever".
      if (!age.isNegative && age < ttl) return Future.value(cached);
    }
    final running = _inFlight;
    if (running != null && _inFlightKey == key) return running;

    final generation = _generation;
    late final Future<List<TrendDayTotals>> request;
    request = load()
        .then((totals) {
          // Dropped meanwhile (sign-out, write, day rollover): deliver the
          // result to this caller, but do not resurrect the entry.
          if (_generation == generation) {
            _totals = totals;
            _userId = userId;
            // The day the QUERY window was cut for, and the moment it was
            // cut: a rollover mid-request must expire the entry, not extend
            // it.
            _dayKey = dayKey;
            _storedAt = now;
          }
          return totals;
        })
        .whenComplete(() {
          if (identical(_inFlight, request)) {
            _inFlight = null;
            _inFlightKey = null;
          }
        });
    _inFlight = request;
    _inFlightKey = key;
    return request;
  }

  /// Drops the entry and disowns a request in flight. Idempotent.
  void invalidate() {
    _generation++;
    _totals = null;
    _userId = null;
    _dayKey = null;
    _storedAt = null;
    _inFlight = null;
    _inFlightKey = null;
  }

  /// Subscribes ONCE to the auth events; later calls are no-ops.
  void attachAuthEvents(Stream<AuthChangeEvent> events) {
    if (_authSub != null) return;
    _authSub = events.listen(
      (event) {
        // A token refresh runs roughly hourly and changes no row; everything
        // else (sign-out, sign-in, account switch, user deleted) can.
        if (event == AuthChangeEvent.tokenRefreshed) return;
        invalidate();
      },
      // Sentry FLUTTER-8: an auth-stream listener without onError takes the
      // zone down. An erroring stream is also a reason to distrust the entry.
      onError: (Object e, StackTrace stack) {
        invalidate();
        dev.log(
          'TrendTotalsCache: auth stream error',
          error: e,
          stackTrace: stack,
          name: 'trend_service',
        );
      },
    );
  }

  /// Releases the auth subscription and the entry. Tests only — the singleton
  /// lives as long as the process.
  @visibleForTesting
  Future<void> dispose() async {
    final sub = _authSub;
    _authSub = null;
    invalidate();
    await sub?.cancel();
  }
}

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

/// Tracked days inside `goal(day) * (1 +/- tolerance)`, bounds inclusive,
/// where `goal(day) = goalKcal + burnedKcalFor(day)` — the same "goal plus
/// step bonus" the Today tab steers by (model B, F7-05). Without
/// [burnedKcalFor] the corridor sits on the base goal. Gap days count as
/// neither; a goal <= 0 has no corridor -> 0 hits.
({int hit, int tracked}) goalHitsOf(
  Iterable<TrendDayTotals?> window, {
  required int goalKcal,
  double tolerance = trendGoalTolerance,
  int Function(DateTime day)? burnedKcalFor,
}) {
  var hit = 0;
  var tracked = 0;
  for (final day in window) {
    if (day == null) continue;
    tracked++;
    final goal = goalKcal + (burnedKcalFor?.call(day.day) ?? 0);
    if (goal <= 0) continue;
    final lo = goal * (1 - tolerance);
    final hi = goal * (1 + tolerance);
    if (day.kcal >= lo && day.kcal <= hi) hit++;
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
