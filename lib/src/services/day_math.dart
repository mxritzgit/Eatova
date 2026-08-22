/// B5: DST-safe calendar arithmetic on local days.
///
/// `Duration` is absolute time, not a calendar: across a 23-hour spring day
/// `subtract(Duration(days: 1))` lands at 23:00 of the day before, and
/// `.difference(...).inDays` on two local midnights is off by one.
///
/// The two correct patterns live here:
///  * **shifting** via the day overflow of the `DateTime` constructor, which
///    is real calendar arithmetic;
///  * **differences** over `(year, month, day)` triples computed as UTC
///    instants, where a day is always exactly 24 hours.
///
/// Dependency-free on purpose (no `flutter/material.dart`) so it runs in pure
/// Dart tests. Related: `local_day.dart` is the serialization side.
library;

/// Shifts [day] by [n] calendar days via the constructor's day overflow, not
/// `Duration`. The constructor also normalises month, year and leap-year
/// boundaries.
///
/// The wall-clock time of [day] is preserved — 20:00 stays 20:00 across a DST
/// change, which is what scheduling needs. Pass a midnight (or [startOfDay])
/// for a day boundary. UTC stays UTC, local stays local.
DateTime addDays(DateTime day, int n) {
  if (day.isUtc) {
    return DateTime.utc(
      day.year,
      day.month,
      day.day + n,
      day.hour,
      day.minute,
      day.second,
      day.millisecond,
      day.microsecond,
    );
  }
  return DateTime(
    day.year,
    day.month,
    day.day + n,
    day.hour,
    day.minute,
    day.second,
    day.millisecond,
    day.microsecond,
  );
}

/// Calendar days between [a] and [b], computed as `a - b`.
///
/// Sign and argument order match `a.difference(b).inDays`, the expression
/// this replaces, so migrating callers is a text substitution. Yesterday
/// gives 1, tomorrow -1, the same day 0.
///
/// Times of day are discarded; only the calendar day counts. Computed over
/// UTC instants of the `(year, month, day)` triples, where a day is always
/// 24 hours.
int daysBetween(DateTime a, DateTime b) {
  final ua = DateTime.utc(a.year, a.month, a.day);
  final ub = DateTime.utc(b.year, b.month, b.day);
  return ua.difference(ub).inDays;
}

/// Start of [dateTime]'s calendar day in the same zone.
///
/// Same result as Flutter's `DateUtils.dateOnly`; exists so this utility
/// needs no Flutter dependency. In zones that switch at midnight the
/// constructor normalises to the first existing moment of the day, and the
/// function stays idempotent.
DateTime startOfDay(DateTime dateTime) {
  if (dateTime.isUtc) {
    return DateTime.utc(dateTime.year, dateTime.month, dateTime.day);
  }
  return DateTime(dateTime.year, dateTime.month, dateTime.day);
}

/// The date strip: [pastDays] past days plus [today], **ascending**, so
/// `pastDays + 1` entries.
///
/// Every entry is the start of a local calendar day, and the list is gapless
/// and duplicate-free across any DST edge. The time of [today] is discarded;
/// a negative [pastDays] returns an empty list instead of throwing.
List<DateTime> dayStrip({required DateTime today, required int pastDays}) {
  if (pastDays < 0) return const <DateTime>[];
  final anchor = startOfDay(today);
  return List<DateTime>.generate(
    pastDays + 1,
    (index) => addDays(anchor, index - pastDays),
    growable: false,
  );
}

/// The same strip **descending**: [count] calendar days ending on [today],
/// today first. A [count] of 0 or less returns an empty list.
List<DateTime> recentDaysDescending({
  required DateTime today,
  required int count,
}) {
  if (count <= 0) return const <DateTime>[];
  final anchor = startOfDay(today);
  return List<DateTime>.generate(
    count,
    (index) => addDays(anchor, -index),
    growable: false,
  );
}
