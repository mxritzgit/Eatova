import 'package:intl/intl.dart';

/// Kalorien mit dem Tausendertrenner der aktiven Sprache: unter `de`
/// `2200` -> `2.200`, `-1234` -> `-1.234`; unter `en` `2200` -> `2,200`
/// (i18n-design.md §5, „Formate").
///
/// Seit der i18n-Migration (Paket 2, 2026-08-10) ueber `package:intl`s
/// `NumberFormat.decimalPattern` statt einer handgeschriebenen Ziffernschleife
/// — die CLDR-Daten kennen den Gruppierungs-/Dezimaltrenner jeder Sprache.
/// Verifiziert byte-identisch zur alten Handschleife fuer alle Bestandswerte
/// (0, 999, 1000, 2200, 12345, 1234567, -1234, -42) unter `de`.
///
/// Diese Funktion hatte nach dem Design-Refactor 2026-08-09 drei
/// zeichengleiche Kopien (Food-Karte, Heute-Texte, die alte
/// Kalorienuebersicht). Zwei Flaechen, die dieselbe Zahl verschieden
/// formatieren, sind ein Fehler, den niemand meldet — deshalb eine Heimat.
///
/// [localeName] ist die AKTIVE App-Sprache (`AppLocalizations.localeName`),
/// nicht der Geraete-Default — Aufrufer reichen sie durch, kein eigenes
/// Locale-Lookup hier.
String formatThousands(int n, String localeName) =>
    NumberFormat.decimalPattern(localeName).format(n);
