/// Text- und Formathelfer des Tabs „Heute" (Design-Refactor 2026-08-09).
///
/// Bewusst Flutter-frei von Widgets: so laufen sie in reinen Dart-Tests ohne
/// Widget-Binding, und die Screen-Tests koennen sich auf Layout konzentrieren.
/// Seit der i18n-Migration (Paket 1, 2026-08-10) brauchen die textgebenden
/// Funktionen ein [AppLocalizations] — reines `package:flutter/widgets.dart`
/// fuer den Typ, kein Widget-Baum noetig.
///
/// Drei Funktionen hier waren urspruenglich KOPIEN ohne erreichbares
/// Original (privat/`part`/`@visibleForTesting` in einer fremden Datei).
/// Zwei davon sind inzwischen konsolidiert, eine ist es strukturell noch
/// nicht (aber ohne Drift-Risiko mehr):
///
///   * [greetingForHour] ist seit der Coach-Migration (Paket 4,
///     2026-08-10) die GETEILTE Implementierung, kein Spiegel mehr:
///     `_CoachHero._timeGreeting` (coach_hero.dart, privat und in einem
///     `part`) ruft diese Funktion jetzt direkt mit `DateTime.now().hour`
///     auf, statt eigene Schwellen/Texte zu tragen. Heute und Coach laufen
///     also durch denselben Code — eine Drift ist damit strukturell
///     ausgeschlossen, nicht nur getestet. Der Test hier bleibt trotzdem
///     der Wert-Nachweis fuer die vier ARB-Texte (`todayGreeting*`).
///   * [kcalThousands] delegiert seit der Food-Migration (Paket 2,
///     2026-08-10) an `services/kcal_format.dart:formatThousands` — der
///     gemeinsamen Heimat der drei vormals zeichengleichen Kopien (Food-
///     Karte, Heute-Texte, die inzwischen entfernte alte
///     Kalorienuebersicht). Ebenfalls kein Spiegel mehr, kein Drift-Risiko.
///   * [todayDateLabel] ist WEITERHIN eine eigene Implementierung, kein
///     Aufruf: das Original `foodDateSelectedLabel`
///     (meal_analysis_screen.dart, `@visibleForTesting`) laesst sich aus
///     Produktivcode nicht rufen (`invalid_use_of_visible_for_testing_member`).
///     Seit der Food-Migration (Paket 2) lesen aber BEIDE Implementierungen
///     dieselben ARB-Keys (`todayDateToday`/`todayDateYesterday`/
///     `todayDateDaysAgo`) statt je eigener deutscher Literale — die WERTE
///     koennen deshalb nicht mehr auseinanderlaufen, auch wenn der Code
///     strukturell dupliziert bleibt. Analog dazu [todayEyebrow]: dessen
///     Pendant in Food, `foodHeaderDateLabel` (meal_analysis_screen.dart),
///     trug frueher eine eigene hartkodierte Wochentags-/Monatsliste und
///     ist seit Paket 2 ebenfalls auf `intl`s Skeleton `MMMMEEEEd`
///     umgestellt — beide lesen jetzt dieselben CLDR-Daten statt eigener
///     Tabellen. `todayEyebrow` stand nie in dieser Kopien-Liste, weil es
///     von Anfang an die massgebliche Implementierung war (kein Original
///     anderswo, das haette auseinanderlaufen koennen).
///
/// Jede verbliebene Doppelung haengt an einem eigenen Test, damit eine
/// Aenderung an nur einer Seite auffiele. Die sauberste Loesung fuer
/// [todayDateLabel]/`foodDateSelectedLabel` waere eine gemeinsame Heimat
/// unter `lib/src/services/` (wie inzwischen bei `kcalThousands`) — offen,
/// s. Paket-4-Bericht.
library;

import 'package:clock/clock.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

import '../../l10n/l10n.dart';
import '../../models/logged_meal.dart';
import '../../services/day_math.dart';
import '../../services/kcal_format.dart';

/// Tageszeit-Begruessung. Seit der Coach-Migration (Paket 4, 2026-08-10)
/// die einzige Implementierung: `_CoachHero` (coach_hero.dart) ruft sie
/// direkt mit `DateTime.now().hour` auf, statt eigene Schwellen/Texte zu
/// tragen (s. Datei-Kommentar oben).
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
