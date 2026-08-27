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

  WeightLog add(double kg) {
    if (kg <= 0) return this;
    final entry = WeightLogEntry(timestamp: clock.now(), weightKg: kg);
    final trimmed = [...entries, entry];
    if (trimmed.length > maxEntries) {
      trimmed.removeRange(0, trimmed.length - maxEntries);
    }
    return WeightLog(entries: trimmed);
  }

  WeightLog clear() => const WeightLog();
}
