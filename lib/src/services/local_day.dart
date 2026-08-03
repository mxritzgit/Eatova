/// DATA-6: Kanonischer lokaler Tages-Schluessel.
///
/// Mahlzeiten wurden frueher per `DateUtils.isSameDay(.toLocal())` getaggt,
/// Koffein dagegen ueber ein UTC-Halboffenes Fenster aus der *naiven* lokalen
/// Mitternacht. Beide koennen ueber eine DST- oder Zeitzonen-Aenderung hinweg
/// auseinanderlaufen: ein Eintrag um 23:45 Ortszeit landet dann in
/// unterschiedlichen „Tagen". Diese Datei zentralisiert die *eine* Wahrheit:
/// der lokale Kalendertag (Jahr-Monat-Tag der lokalen Wanduhr), unabhaengig
/// von der Zone, in der er spaeter betrachtet wird.
///
/// Das Format (`YYYY-MM-DD`) ist byte-genau das, was serverseitig in
/// `logged_meals.local_day` steht — die Spalte `local_day date` in Postgres
/// parst exakt diesen String.
library;

/// Liefert den naiven lokalen Kalendertag von [dateTime] als `YYYY-MM-DD`.
///
/// „Naiv lokal" heisst: es zaehlen Jahr/Monat/Tag der lokalen Wanduhr von
/// [dateTime]. Ist [dateTime] ein UTC-Wert, wird er NICHT in die lokale Zone
/// umgerechnet — der Aufrufer ist dafuer verantwortlich, vorher `.toLocal()`
/// aufzurufen, wenn er den lokalen Tag will (genau so wie das alte
/// Meals-Bucketing). Damit bleibt der Helper rein und ohne versteckte
/// Zonen-Magie.
String localDayKey(DateTime dateTime) {
  final y = dateTime.year.toString().padLeft(4, '0');
  final m = dateTime.month.toString().padLeft(2, '0');
  final d = dateTime.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}
