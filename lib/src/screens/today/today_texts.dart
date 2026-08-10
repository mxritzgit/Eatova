/// Text- und Formathelfer des Tabs „Heute" (Design-Refactor 2026-08-09).
///
/// Bewusst Flutter-frei von Widgets: so laufen sie in reinen Dart-Tests ohne
/// Widget-Binding, und die Screen-Tests koennen sich auf Layout konzentrieren.
/// Seit der i18n-Migration (Paket 1, 2026-08-10) brauchen die textgebenden
/// Funktionen ein [AppLocalizations] — reines `package:flutter/widgets.dart`
/// fuer den Typ, kein Widget-Baum noetig.
///
/// Drei Funktionen hier sind KOPIEN, keine Aufrufe — das Original ist jeweils
/// nicht erreichbar:
///   * [greetingForHour] spiegelt `_CoachHero._timeGreeting`
///     (coach_hero.dart:13-19, privat und in einem `part`). ACHTUNG
///     DRIFT-RISIKO seit der i18n-Migration: DIESE Kopie liest ihre Texte
///     jetzt aus der ARB (`todayGreeting*`), das Original in coach_hero.dart
///     traegt bis zur Coach-Migration (Paket 4) weiterhin die hartkodierten
///     deutschen Strings. Die Schwellen (<5/<11/<17) bleiben identisch, nur
///     die Textquelle ist auseinandergelaufen — der Drift-Test hier prueft
///     nur noch die deutschen WERTE, nicht mehr die Kopie-Identitaet.
///   * [kcalThousands] spiegelt `_formatThousands`
///     (calories_overview_card.dart:1061-1071, privat).
///   * [todayDateLabel] spiegelt `foodDateSelectedLabel`
///     (meal_analysis_screen.dart:623-628, `@visibleForTesting` — ein Aufruf
///     aus Produktivcode waere `invalid_use_of_visible_for_testing_member`).
///     Dasselbe Drift-Risiko wie bei [greetingForHour]: das Original bleibt
///     bis zur Food-Migration (Paket 2) hartkodiert deutsch.
/// Jede Kopie haengt an einem eigenen Test, damit eine Drift auffaellt. Die
/// saubere Loesung waere eine gemeinsame Heimat unter `lib/src/services/`;
/// das sind fremde Dateien und steht im Bericht.
library;

import 'package:clock/clock.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

import '../../l10n/l10n.dart';
import '../../models/logged_meal.dart';
import '../../services/day_math.dart';
import '../../services/kcal_format.dart';

/// Tageszeit-Begruessung. Schwellen wortgleich aus coach_hero.dart:13-19,
/// die Texte kommen seit der i18n-Migration aus der ARB.
String greetingForHour(int hour, AppLocalizations l10n) {
  if (hour < 5) return l10n.todayGreetingNight;
  if (hour < 11) return l10n.todayGreetingMorning;
  if (hour < 17) return l10n.todayGreetingDay;
  return l10n.todayGreetingEvening;
}

/// Die Begruessung fuer „jetzt". Liest [clock.now()], damit Tests die Uhr
/// festnageln koennen — zur Laufzeit identisch zu `DateTime.now()`.
String todayGreeting(AppLocalizations l10n, [DateTime? now]) =>
    greetingForHour((now ?? clock.now()).hour, l10n);

/// Einmalige Initialisierung der `intl`-Datumssymbole (Wochentags-/
/// Monatsnamen aller Locales). `initializeDateFormatting()` laedt dabei
/// **synchron** eine gebuendelte Tabelle (kein Netzwerk-/Asset-Zugriff, s.
/// `date_symbol_data_local.dart`) — das zurueckgegebene Future ist bereits
/// aufgeloest, wenn der Aufruf zurueckkehrt. Der Bool-Wächter verhindert nur,
/// dass jeder Rebuild diese (recht grosse) Tabelle erneut aufbaut.
bool _dateSymbolsReady = false;
void _ensureDateSymbols() {
  if (_dateSymbolsReady) return;
  initializeDateFormatting();
  _dateSymbolsReady = true;
}

/// Die Eyebrow ueber der Begruessung: „SONNTAG, 9. AUGUST".
///
/// Ersetzt die frueheren hartkodierten `_wochentage`/`_monate`-Tabellen durch
/// `intl`s Skeleton `MMMMEEEEd` — die CLDR-Daten ordnen Wochentag/Tag/Monat
/// bereits locale-richtig an (`de`: „EEEE, d. MMMM" -> „Sonntag, 9. August",
/// `en`: „EEEE, MMMM d" -> „Sunday, August 9"), `toUpperCase()` liefert unter
/// `de` byte-gleich die alten Versalien-Werte („MÄRZ" bleibt „MÄRZ" — die
/// deutschen Monats-/Wochentagsnamen enthalten kein „ß", bei dem Darts
/// einfache `toUpperCase()`-Abbildung eine zweite Wahrheit erfaende).
String todayEyebrow(DateTime date, AppLocalizations l10n) {
  _ensureDateSymbols();
  return DateFormat.MMMMEEEEd(l10n.localeName).format(date).toUpperCase();
}

/// kcal mit dem Tausendertrenner der aktiven Sprache.
///
/// Delegiert an die gemeinsame Heimat unter `services/` — die drei
/// zeichengleichen Kopien waren genau die Sorte Doppelung, bei der eine
/// spaetere Aenderung nur eine Flaeche erreicht.
///
/// Seit der i18n-Migration Paket 2 (2026-08-10) locale-bewusst:
/// `formatThousands` liest jetzt `l10n.localeName` statt fest `de` zu
/// rechnen. Unter `de` byte-identisch zum Bestand.
String kcalThousands(int n, AppLocalizations l10n) =>
    formatThousands(n, l10n.localeName);

/// Benennt den gewaehlten Tag: „Heute" / „Gestern" / „Vor N Tagen".
/// Zeichengleich zu `foodDateSelectedLabel`, damit beide Tabs denselben Tag
/// gleich benennen. Rechnet ueber [daysBetween] — nie ueber `Duration` (B5).
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

/// Untertitel einer Slot-Zeile: die Namen der geloggten Mahlzeiten, sonst der
/// wortgleiche Leertext aus calories_overview_card.dart:796.
String mealSlotSubtitle(List<LoggedMeal> meals, AppLocalizations l10n) {
  if (meals.isEmpty) return l10n.todayMealSlotEmpty;
  return meals.map((m) => m.result.mealName).join(' · ');
}

/// Der Teaser im Coach-Banner. Bewusst aus den Restmakros gebaut statt
/// generisch: ein Banner, das jeden Tag dasselbe sagt, wird nicht mehr gelesen.
///
/// [isToday] steuert, ob der Teaser ueberhaupt etwas ueber den aufgeschlagenen
/// Tag behaupten darf. Auf einem Archivtag waeren beide Tagesaussagen falsch:
/// „logge deine erste Mahlzeit" fordert zum Nachtragen in die Vergangenheit
/// auf, und ein Vorschlag gegen offenes Protein kommt fuer einen abgelaufenen
/// Tag zu spaet. Der Coach selbst rechnet ohnehin mit HEUTE
/// (`HomeStore.coachContext`), deshalb bleibt die Zeile dort bewusst
/// tagesneutral und verspricht nichts, was der Coach nicht einloesen kann.
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

/// Initiale fuer das Profil-Badge. Gespiegelt zu `HomeStore.profileInitial`
/// (home_store.dart:138-142) inklusive des „S"-Fallbacks — der Screen bekommt
/// die Initiale normalerweise fertig durchgereicht und braucht diesen Zweig
/// nur, wenn `profileInitial` null ist.
///
/// Der Fallback-Buchstabe „S" ist sprachneutral (kein Wort, keine Ableitung
/// aus dem Namen) und bleibt deshalb ausserhalb der ARB — s. Bericht.
String todayInitial(String name) {
  final parts = name.trim().split(RegExp(r'\s+'));
  if (parts.isEmpty || parts.first.isEmpty) return 'S';
  return parts.first.substring(0, 1).toUpperCase();
}
