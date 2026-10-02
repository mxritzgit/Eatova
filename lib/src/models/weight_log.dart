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

  /// A day further than this share from the trend reseeds it: a correction or
  /// a typo, not water. Normal daily swings stay well below 5 %.
  static const double trendReseedShare = 0.05;

  /// The smoothed current weight that goals, forecast and BMI use
  /// (docs/WEIGHT-TREND.md); null without weigh-ins.
  ///
  /// A time-aware exponentially weighted moving average over the mean of each
  /// local calendar day: a day `Δ` days after the previous one moves the trend
  /// by `1 − (1 − trendAlphaPerDay)^Δ`, so sparse weigh-ins count for more.
  double? get trendKg {
    if (entries.isEmpty) return null;
    final sorted = [...entries]
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    final days = <(DateTime, double)>[];
    DateTime? day;
    var sum = 0.0;
    var count = 0;
    for (final entry in sorted) {
      final local = entry.timestamp.toLocal();
      // UTC midnight of the local date: day gaps stay whole across DST.
      final date = DateTime.utc(local.year, local.month, local.day);
      if (date != day) {
        if (day != null) days.add((day, sum / count));
        day = date;
        sum = 0;
        count = 0;
      }
      sum += entry.weightKg;
      count++;
    }
    days.add((day!, sum / count));

    var (previous, trend) = days.first;
    for (final (date, kg) in days.skip(1)) {
      if ((kg - trend).abs() > trend * trendReseedShare) {
        trend = kg;
      } else {
        final gap = date.difference(previous).inDays;
        trend += (1 - math.pow(1 - trendAlphaPerDay, gap)) * (kg - trend);
      }
      previous = date;
    }
    return trend;
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
