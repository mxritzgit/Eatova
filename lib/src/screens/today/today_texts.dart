/// Text and format helpers of the "Heute" tab, widget-free so they run in
/// plain Dart tests.
///
/// [greetingForHour] and [kcalThousands] are the shared implementations.
/// [todayDateLabel] still duplicates `foodDateSelectedLabel`, which is
/// `@visibleForTesting` and thus uncallable from production code; both read
/// the same ARB keys, so the values cannot drift.
library;

import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

import '../../l10n/l10n.dart';
import '../../models/logged_meal.dart';
import '../../services/day_math.dart';
import '../../services/kcal_format.dart';

/// Line height of the Today texts: CSS `normal` for Figtree and Bricolage
/// (both 1.2 em by their metrics), as in the design. The theme's body
/// default (1.45) would make every row of the redesign taller.
const double todayLineHeight = 1.2;

/// Time-of-day greeting. The only implementation: `_CoachHero` calls it with
/// `DateTime.now().hour` instead of carrying its own thresholds.
String greetingForHour(int hour, AppLocalizations l10n) {
  if (hour < 5) return l10n.todayGreetingNight;
  if (hour < 11) return l10n.todayGreetingMorning;
  if (hour < 17) return l10n.todayGreetingDay;
  return l10n.todayGreetingEvening;
}

/// One-time init of the `intl` date symbols. `initializeDateFormatting()`
/// loads a bundled table synchronously, so its future is already resolved;
/// the bool guard only stops every rebuild from rebuilding that table.
bool _dateSymbolsReady = false;
void _ensureDateSymbols() {
  if (_dateSymbolsReady) return;
  initializeDateFormatting();
  _dateSymbolsReady = true;
}

/// The header's date line: full weekday plus the short date, "Monday, Sep 28"
/// / "Montag, 28. Sept." (intl has no such skeleton, so two are joined). A
/// date outside [today]'s year carries its year.
String todayHeaderDate(DateTime date, DateTime today, AppLocalizations l10n) {
  _ensureDateSymbols();
  final locale = l10n.localeName;
  final day = date.year == today.year
      ? DateFormat.MMMd(locale).format(date)
      : DateFormat.yMMMd(locale).format(date);
  return '${DateFormat.EEEE(locale).format(date)}, $day';
}

/// Two-letter weekday for a day-strip cell: "Mo", "Tu" / "Mo", "Di" (the
/// CLDR abbreviation without its trailing dot, cut to two letters; weekday
/// abbreviations are plain BMP text, so a code-unit cut is safe).
String todayWeekdayShort(DateTime date, AppLocalizations l10n) {
  _ensureDateSymbols();
  final short = DateFormat.E(l10n.localeName).format(date).replaceAll('.', '');
  return short.length > 2 ? short.substring(0, 2) : short;
}

/// What a screen reader hears for a day-strip cell: the relative day and the
/// full date, "Yesterday, Sunday, September 27".
String todayDayCellLabel(
  DateTime today,
  DateTime date,
  AppLocalizations l10n,
) {
  _ensureDateSymbols();
  final full = DateFormat.MMMMEEEEd(l10n.localeName).format(date);
  return '${todayDateLabel(today, date, l10n)}, $full';
}

/// kcal with the active locale's thousands separator, via the shared
/// `services/kcal_format.dart`.
String kcalThousands(int n, AppLocalizations l10n) =>
    formatThousands(n, l10n.localeName);

/// Names the selected day: today / yesterday / N days ago. Kept identical to
/// `foodDateSelectedLabel`. Uses [daysBetween], never `Duration` (B5).
String todayDateLabel(
  DateTime today,
  DateTime selected,
  AppLocalizations l10n,
) {
  final offset = daysBetween(today, selected);
  if (offset == 0) return l10n.todayDateToday;
  if (offset == 1) return l10n.todayDateYesterday;
  return l10n.todayDateDaysAgo(offset);
}

/// Subtitle of a slot row: the logged meal names in log order, comma
/// separated as in the design ("Skyr, Oats, Blueberries"), otherwise the
/// empty text.
String mealSlotSubtitle(List<LoggedMeal> meals, AppLocalizations l10n) {
  if (meals.isEmpty) return l10n.todayMealSlotEmpty;
  return meals.map((m) => m.result.resolvedMealName(l10n)).join(', ');
}

/// Initial for the profile badge, mirroring `HomeStore.profileInitial`. The
/// 'S' fallback is language-neutral and stays out of the ARB.
String todayInitial(String name) {
  final parts = name.trim().split(RegExp(r'\s+'));
  if (parts.isEmpty || parts.first.isEmpty) return 'S';
  return parts.first.substring(0, 1).toUpperCase();
}
