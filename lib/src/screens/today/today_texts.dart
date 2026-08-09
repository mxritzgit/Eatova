/// Text- und Formathelfer des Tabs „Heute" (Design-Refactor 2026-08-09).
///
/// Bewusst Flutter-frei: so laufen sie in reinen Dart-Tests ohne Widget-
/// Binding, und die Screen-Tests koennen sich auf Layout konzentrieren.
///
/// Drei Funktionen hier sind KOPIEN, keine Aufrufe — das Original ist jeweils
/// nicht erreichbar:
///   * [greetingForHour] spiegelt `_CoachHero._timeGreeting`
///     (coach_hero.dart:13-19, privat und in einem `part`),
///   * [kcalThousands] spiegelt `_formatThousands`
///     (calories_overview_card.dart:1061-1071, privat),
///   * [todayDateLabel] spiegelt `foodDateSelectedLabel`
///     (meal_analysis_screen.dart:623-628, `@visibleForTesting` — ein Aufruf
///     aus Produktivcode waere `invalid_use_of_visible_for_testing_member`).
/// Jede Kopie haengt an einem eigenen Test, damit eine Drift auffaellt. Die
/// saubere Loesung waere eine gemeinsame Heimat unter `lib/src/services/`;
/// das sind fremde Dateien und steht im Bericht.
library;

import 'package:clock/clock.dart';

import '../../models/logged_meal.dart';
import '../../services/day_math.dart';
import '../../services/kcal_format.dart';

/// Tageszeit-Begruessung. Schwellen wortgleich aus coach_hero.dart:13-19.
String greetingForHour(int hour) {
  if (hour < 5) return 'Gute Nacht';
  if (hour < 11) return 'Guten Morgen';
  if (hour < 17) return 'Hallo';
  return 'Guten Abend';
}

/// Die Begruessung fuer „jetzt". Liest [clock.now()], damit Tests die Uhr
/// festnageln koennen — zur Laufzeit identisch zu `DateTime.now()`.
String todayGreeting([DateTime? now]) =>
    greetingForHour((now ?? clock.now()).hour);

// Eigene Tabellen statt `intl`: das Paket ist keine Abhaengigkeit dieses
// Projekts, und pubspec.yaml ist fuer dieses Paket tabu. Die Werte stehen
// direkt in Versalien, weil die Eyebrow-Schrift sie nicht selbst umstellt und
// `toUpperCase()` bei „ß" eine zweite Wahrheit erfinden wuerde.
const List<String> _wochentage = <String>[
  'MONTAG',
  'DIENSTAG',
  'MITTWOCH',
  'DONNERSTAG',
  'FREITAG',
  'SAMSTAG',
  'SONNTAG',
];

const List<String> _monate = <String>[
  'JANUAR',
  'FEBRUAR',
  'MÄRZ',
  'APRIL',
  'MAI',
  'JUNI',
  'JULI',
  'AUGUST',
  'SEPTEMBER',
  'OKTOBER',
  'NOVEMBER',
  'DEZEMBER',
];

/// Die Eyebrow ueber der Begruessung: „SONNTAG, 9. AUGUST".
String todayEyebrow(DateTime date) =>
    '${_wochentage[date.weekday - 1]}, ${date.day}. ${_monate[date.month - 1]}';

/// kcal mit deutschem Tausenderpunkt.
///
/// Delegiert an die gemeinsame Heimat unter `services/` — die drei
/// zeichengleichen Kopien waren genau die Sorte Doppelung, bei der eine
/// spaetere Aenderung nur eine Flaeche erreicht.
String kcalThousands(int n) => formatThousands(n);

/// Benennt den gewaehlten Tag: „Heute" / „Gestern" / „Vor N Tagen".
/// Zeichengleich zu `foodDateSelectedLabel`, damit beide Tabs denselben Tag
/// gleich benennen. Rechnet ueber [daysBetween] — nie ueber `Duration` (B5).
String todayDateLabel(DateTime today, DateTime selected) {
  final offset = daysBetween(today, selected);
  if (offset == 0) return 'Heute';
  if (offset == 1) return 'Gestern';
  return 'Vor $offset Tagen';
}

/// Untertitel einer Slot-Zeile: die Namen der geloggten Mahlzeiten, sonst der
/// wortgleiche Leertext aus calories_overview_card.dart:796.
String mealSlotSubtitle(List<LoggedMeal> meals) {
  if (meals.isEmpty) return 'Noch nichts geloggt';
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
  bool isToday = true,
}) {
  if (!isToday) {
    return 'Frag den Coach nach Ideen für deine Ziele.';
  }
  if (dayIsEmpty) {
    return 'Logge deine erste Mahlzeit — ich baue deinen Tag darum herum.';
  }
  if (remainingProteinG > 0) {
    return 'Dir fehlen noch $remainingProteinG g Protein. '
        'Soll ich dir etwas vorschlagen?';
  }
  return 'Dein Protein-Ziel steht. Soll ich auf den Rest des Tages schauen?';
}

/// Initiale fuer das Profil-Badge. Gespiegelt zu `HomeStore.profileInitial`
/// (home_store.dart:138-142) inklusive des „S"-Fallbacks — der Screen bekommt
/// die Initiale normalerweise fertig durchgereicht und braucht diesen Zweig
/// nur, wenn `profileInitial` null ist.
String todayInitial(String name) {
  final parts = name.trim().split(RegExp(r'\s+'));
  if (parts.isEmpty || parts.first.isEmpty) return 'S';
  return parts.first.substring(0, 1).toUpperCase();
}
