/// Text and format helpers of the "Heute" tab, widget-free so they run in
/// plain Dart tests.
///
/// [greetingForHour] and [kcalThousands] are the shared implementations.
/// [todayDateLabel] still duplicates `foodDateSelectedLabel`, which is
/// `@visibleForTesting` and thus uncallable from production code; both read
/// the same ARB keys, so the values cannot drift.
library;

import 'package:clock/clock.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

import '../../l10n/l10n.dart';
import '../../models/logged_meal.dart';
import '../../services/day_math.dart';
import '../../services/kcal_format.dart';

/// Time-of-day greeting. The only implementation: `_CoachHero` calls it with
/// `DateTime.now().hour` instead of carrying its own thresholds.
String greetingForHour(int hour, AppLocalizations l10n) {
  if (hour < 5) return l10n.todayGreetingNight;
  if (hour < 11) return l10n.todayGreetingMorning;
  if (hour < 17) return l10n.todayGreetingDay;
  return l10n.todayGreetingEvening;
}

/// The greeting for "now". Reads [clock.now()] so tests can pin the clock.
String todayGreeting(AppLocalizations l10n, [DateTime? now]) =>
    greetingForHour((now ?? clock.now()).hour, l10n);

/// One-time init of the `intl` date symbols. `initializeDateFormatting()`
/// loads a bundled table synchronously, so its future is already resolved;
/// the bool guard only stops every rebuild from rebuilding that table.
bool _dateSymbolsReady = false;
void _ensureDateSymbols() {
  if (_dateSymbolsReady) return;
  initializeDateFormatting();
  _dateSymbolsReady = true;
}

/// The eyebrow above the greeting, e.g. "SONNTAG, 9. AUGUST", ordered per
/// locale by `intl`'s `MMMMEEEEd`. `toUpperCase()` is safe: German month and
/// weekday names carry no "ß", where Dart's mapping would invent a truth.
String todayEyebrow(DateTime date, AppLocalizations l10n) {
  _ensureDateSymbols();
  return DateFormat.MMMMEEEEd(l10n.localeName).format(date).toUpperCase();
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

/// Subtitle of a slot row: the logged meal names, otherwise the empty text.
String mealSlotSubtitle(List<LoggedMeal> meals, AppLocalizations l10n) {
  if (meals.isEmpty) return l10n.todayMealSlotEmpty;
  return meals.map((m) => m.result.mealName).join(' · ');
}

/// The coach banner teaser, built from the remaining macros: a banner that
/// says the same thing daily stops being read.
///
/// [isToday] gates any claim about the open day — on an archive day both day
/// statements would be wrong and the coach always reasons about TODAY.
String coachTeaser({
  required bool dayIsEmpty,
  required int remainingProteinG,
  required AppLocalizations l10n,
  bool isToday = true,
}) {
  if (!isToday) {
    return l10n.todayCoachTeaserNeutral;
  }
  if (dayIsEmpty) {
    return l10n.todayCoachTeaserEmptyDay;
  }
  if (remainingProteinG > 0) {
    return l10n.todayCoachTeaserProteinOpen(remainingProteinG);
  }
  return l10n.todayCoachTeaserProteinDone;
}

/// Initial for the profile badge, mirroring `HomeStore.profileInitial`. The
/// 'S' fallback is language-neutral and stays out of the ARB.
String todayInitial(String name) {
  final parts = name.trim().split(RegExp(r'\s+'));
  if (parts.isEmpty || parts.first.isEmpty) return 'S';
  return parts.first.substring(0, 1).toUpperCase();
}
