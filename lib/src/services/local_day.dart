/// DATA-6: canonical local day key — the local wall clock's year-month-day,
/// so entries near midnight cannot land in different days across a DST or
/// timezone change. `YYYY-MM-DD` is what `logged_meals.local_day` stores.
library;

/// The naive local calendar day of [dateTime] as `YYYY-MM-DD`. A UTC value is
/// NOT converted; callers must `.toLocal()` first.
String localDayKey(DateTime dateTime) {
  final y = dateTime.year.toString().padLeft(4, '0');
  final m = dateTime.month.toString().padLeft(2, '0');
  final d = dateTime.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}

/// The local calendar day a `YYYY-MM-DD` key (or a date column, which
/// PostgREST returns in that shape) names, as local midnight; null for
/// anything else.
DateTime? parseLocalDayKey(Object? raw) {
  if (raw is! String) return null;
  final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(raw);
  if (match == null) return null;
  final (y, m, day) = (
    int.parse(match.group(1)!),
    int.parse(match.group(2)!),
    int.parse(match.group(3)!),
  );
  final date = DateTime(y, m, day);
  // Rejects 2026-02-30 and similar, which DateTime would roll over.
  if (date.year != y || date.month != m || date.day != day) return null;
  return date;
}
