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
