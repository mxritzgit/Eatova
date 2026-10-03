import 'dart:math' as math;

import 'package:clock/clock.dart';

import 'model_limits.dart';

class WeightLogEntry {
  const WeightLogEntry({required this.timestamp, required this.weightKg});

  final DateTime timestamp;
  final double weightKg;
}

/// Weight history, ascending (oldest first, [latest] == `entries.last`).
///
/// ONE cap for local ring buffer and server load ([maxEntries], F7-03): the
/// loader used to fetch 365 points while [add] trimmed to 30, so the first
/// weigh-in after boot silently moved [baseline] 335 entries forward and the
/// delta pill, progress bar and caption jumped — and jumped back on the next
/// boot.
class WeightLog {
  const WeightLog({this.entries = const <WeightLogEntry>[]});

  /// Normalizes a merged or restored history to the same order and bound as
  /// the server loader. Equal timestamps retain their input order.
  factory WeightLog.capped(Iterable<WeightLogEntry> entries) {
    final indexed = entries.toList().indexed.toList()
      ..sort((a, b) {
        final byTime = a.$2.timestamp.compareTo(b.$2.timestamp);
        return byTime != 0 ? byTime : a.$1.compareTo(b.$1);
      });
    final start = indexed.length > maxEntries ? indexed.length - maxEntries : 0;
    return WeightLog(
      entries: [for (final (_, entry) in indexed.skip(start)) entry],
    );
  }

  /// Upper bound of the history, local AND server-side
  /// (`TrackingSync.weightLogLimit`): a year of daily weigh-ins. When the cap
  /// is hit the OLDEST point drops on both sides, so [baseline] stays stable
  /// across a weigh-in.
  static const int maxEntries = 365;

  /// Clamps a weigh-in to the `weight_log` table bounds (20..400 kg, two
  /// decimals) — the last barrier before cache, HealthKit and server (F7-02).
  /// Non-finite or non-positive input yields null: nothing to log.
  static double? sanitizeKg(double kg) {
    if (!kg.isFinite || kg <= 0) return null;
    return clampWeightLogKg(kg);
  }

  final List<WeightLogEntry> entries;

  WeightLogEntry? get latest => entries.isEmpty ? null : entries.last;

  /// Explicit reference point for delta and goal progress: the oldest entry
  /// in the history, i.e. the first weigh-in after onboarding (or the oldest
  /// still inside [maxEntries]). The profile has no "goal changed at"
  /// timestamp, so "oldest since the last goal change" cannot be expressed
  /// yet — callers fall back to the onboarding weight when this is null.
  WeightLogEntry? get baseline => entries.isEmpty ? null : entries.first;

  /// Change since [baseline]; null below two entries.
  double? get trendDelta {
    if (entries.length < 2) return null;
    return entries.last.weightKg - entries.first.weightKg;
  }

  /// Daily smoothing of [trendKg]: a weigh-in moves the trend by 10 % of its
  /// distance, the classic weight-trend value.
  static const double trendAlphaPerDay = 0.1;

  /// A day further than this share from the trend is an outlier (a typo, a
  /// correction, a long break), not water: normal daily swings stay well
  /// below 5 %. It counts only once the next weigh-in day confirms it.
  static const double trendOutlierShare = 0.05;

  /// Weigh-ins older than this no longer speak for the current weight: the
  /// plan then falls back to the profile weight ([planWeightKg]).
  static const Duration trendMaxAge = Duration(days: 28);

  /// The smoothed current weight (docs/WEIGHT-TREND.md); null without
  /// weigh-ins. Use [planWeightKg] for goals and forecast.
  ///
  /// A time-aware exponentially weighted moving average over the LAST
  /// weigh-in of each local calendar day (a later entry corrects an earlier
  /// one; there is no delete): a day `Δ` days after the last counted one
  /// moves the trend by `1 − (1 − trendAlphaPerDay)^Δ`.
  ///
  /// An outlier day ([trendOutlierShare]) is held back. If the next day lies
  /// within the share of it, the jump is real and the trend moves to that
  /// day; otherwise the outlier is dropped. An outlier on the last day does
  /// not move the trend yet. A day more than [trendMaxAge] after the last
  /// counted one starts afresh: after a break, the new weight is no outlier.
  double? get trendKg => _trend()?.kg;

  /// The trend the plan may use at [now]: [trendKg] when its last COUNTED
  /// day is at most [trendMaxAge] old (a held outlier does not refresh it)
  /// and the rounded value fits the profile's weight range; otherwise null,
  /// and the profile weight stays in charge.
  double? planWeightKg(DateTime now) {
    final trend = _trend();
    if (trend == null) return null;
    final local = now.toLocal();
    final today = DateTime.utc(local.year, local.month, local.day);
    if (today.difference(trend.counted).inDays > trendMaxAge.inDays) {
      return null;
    }
    final kg = trend.kg.round();
    if (kg < ProfileLimits.weightKgMin || kg > ProfileLimits.weightKgMax) {
      return null;
    }
    return trend.kg;
  }

  /// The trend and its last counted day (UTC midnight of the local date).
  ({double kg, DateTime counted})? _trend() {
    if (entries.isEmpty) return null;
    final sorted = [...entries]
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    final days = <(DateTime, double)>[];
    for (final entry in sorted) {
      final local = entry.timestamp.toLocal();
      // UTC midnight of the local date: day gaps stay whole across DST.
      final date = DateTime.utc(local.year, local.month, local.day);
      if (days.isNotEmpty && days.last.$1 == date) days.removeLast();
      days.add((date, entry.weightKg));
    }

    bool far(double kg, double from) =>
        (kg - from).abs() > from * trendOutlierShare;

    var (counted, trend) = days.first;
    double? held;
    for (final (date, kg) in days.skip(1)) {
      final gap = date.difference(counted).inDays;
      if (gap > trendMaxAge.inDays) {
        // After a break the old trend says nothing: start afresh.
        trend = kg;
        counted = date;
        held = null;
        continue;
      }
      final outlier = held;
      if (outlier != null) {
        held = null;
        if (!far(kg, outlier)) {
          // Two days agree on the jump: adopt it.
          trend = kg;
          counted = date;
          continue;
        }
      }
      if (far(kg, trend)) {
        held = kg;
        continue;
      }
      trend += (1 - math.pow(1 - trendAlphaPerDay, gap)) * (kg - trend);
      counted = date;
    }
    return (kg: trend, counted: counted);
  }

  WeightLog add(double kg) =>
      addEntry(WeightLogEntry(timestamp: clock.now(), weightKg: kg));

  /// Adds one point without assuming the device clock advanced since the last
  /// weigh-in. The oldest timestamp falls when the history reaches its cap.
  WeightLog addEntry(WeightLogEntry entry) {
    if (!entry.weightKg.isFinite || entry.weightKg <= 0) return this;
    return WeightLog.capped([...entries, entry]);
  }
}
