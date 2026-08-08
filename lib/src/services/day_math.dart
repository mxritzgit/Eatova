/// B5: Kalenderarithmetik auf lokalen Tagen — DST-fest.
///
/// `Duration` ist Absolutzeit, kein Kalender. Am Montag 30.03.2026 in
/// Europe/Berlin (Fruehjahrsumstellung war Sonntag 29.03., ein 23-Stunden-Tag)
/// liefert `DateTime(2026, 3, 30).subtract(const Duration(days: 1))` den
/// `2026-03-28 23:00`: die Datumsleiste verschluckt den Sonntag, der Chip
/// „Gestern" traegt den 28.03., und jede von dort geloggte Mahlzeit bekommt
/// serverseitig den falschen `local_day`. Spiegelbildlich verrechnet sich
/// `.difference(...).inDays` auf zwei lokalen Mitternachten:
///
/// ```text
/// Fruehjahr, Folgetag:      23h -> inDays = 0   // muesste 1 sein
/// Fruehjahr, 2-Tage-Luecke: 47h -> inDays = 1   // muesste 2 sein
/// Herbst,    Folgetag:      25h -> inDays = 1   // zufaellig richtig
/// ```
///
/// Dieses Utility zentralisiert die beiden korrekten Muster, die im Projekt
/// bislang nur verstreut angewendet werden (`trend_service.dart`,
/// `meals_sync.dart`, `streak_reminder_planner.dart`):
///
///  * **Verschieben** ueber den Tages-Overflow des `DateTime`-Konstruktors.
///    `DateTime(2026, 3, 29 + 1)` ist echte Kalenderarithmetik und ergibt den
///    30.03. um Mitternacht — unabhaengig davon, wie viele Stunden der 29.
///    tatsaechlich hatte.
///  * **Differenzen** ueber `(Jahr, Monat, Tag)`-Tripel, die als UTC-Instants
///    verrechnet werden. UTC kennt keine Sommerzeit, also ist die Differenz
///    dort exakt die Zahl der Kalendertage.
///
/// Die Datei ist bewusst abhaengigkeitsfrei (kein `flutter/material.dart`),
/// damit sie in reinen Dart-Tests ohne Widget-Binding laeuft.
///
/// Verwandt: `local_day.dart` formatiert denselben Kalendertag als
/// `YYYY-MM-DD`-Schluessel fuer `logged_meals.local_day`. Das ist die
/// Serialisierungs-Seite; hier steht die Rechen-Seite.
library;

/// Verschiebt [day] um [n] Kalendertage — vorwaerts bei positivem, rueckwaerts
/// bei negativem [n].
///
/// Die Verschiebung laeuft ueber den Tages-Overflow des Konstruktors, nicht
/// ueber `Duration`: `DateTime(2026, 3, 30 - 1)` ist der 29.03. um Mitternacht,
/// waehrend `subtract(const Duration(days: 1))` in Europe/Berlin auf dem
/// `2026-03-28 23:00` landen wuerde. Monats-, Jahres- und Schaltjahrgrenzen
/// normalisiert der Konstruktor mit (`DateTime(2026, 1, 31 + 1)` ist der
/// 01.02.).
///
/// Die Wanduhrzeit von [day] bleibt erhalten — 20:00 bleibt 20:00, auch ueber
/// eine Umstellung hinweg. Das ist die Semantik, die Terminplanung braucht
/// (Streak-Reminder). Wer eine Tagesgrenze will, gibt eine Mitternacht hinein
/// oder ruft vorher [startOfDay].
///
/// Ein UTC-`day` bleibt UTC, ein lokaler bleibt lokal.
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

/// Kalendertage zwischen [a] und [b], gerechnet als `a - b`.
///
/// Vorzeichen und Argumentreihenfolge sind absichtlich identisch zu
/// `a.difference(b).inDays` — der Ausdruck, den diese Funktion ersetzt. Damit
/// ist die Umstellung der Aufrufer eine reine Textersetzung:
///
/// ```dart
/// // vorher (bricht ueber die Fruehjahrsumstellung):
/// final offset = today.difference(date).inDays;
/// // nachher:
/// final offset = daysBetween(today, date);
/// ```
///
/// `daysBetween(heute, gestern) == 1`, `daysBetween(heute, morgen) == -1`,
/// `daysBetween(tag, tag) == 0`.
///
/// Die Uhrzeit beider Argumente wird verworfen: es zaehlt allein der
/// Kalendertag der jeweiligen Wanduhr. Gerechnet wird ueber UTC-Instants der
/// `(Jahr, Monat, Tag)`-Tripel, weil UTC keine Sommerzeit kennt und die
/// Stundendifferenz dort immer ein exaktes Vielfaches von 24 ist.
int daysBetween(DateTime a, DateTime b) {
  final ua = DateTime.utc(a.year, a.month, a.day);
  final ub = DateTime.utc(b.year, b.month, b.day);
  return ua.difference(ub).inDays;
}

/// Der Beginn des Kalendertages von [dateTime] in derselben Zone.
///
/// Entspricht Flutters `DateUtils.dateOnly`; existiert hier nur, damit dieses
/// Utility ohne Flutter-Abhaengigkeit auskommt. Aufrufer, die `DateUtils`
/// ohnehin importieren, muessen nicht wechseln — beide liefern denselben Wert.
///
/// In den seltenen Zonen, die um Mitternacht umstellen (dort existiert 00:00
/// an einzelnen Tagen nicht), normalisiert der Konstruktor auf den ersten
/// existierenden Moment des Tages. Die Funktion bleibt idempotent:
/// `startOfDay(startOfDay(x)) == startOfDay(x)`.
DateTime startOfDay(DateTime dateTime) {
  if (dateTime.isUtc) {
    return DateTime.utc(dateTime.year, dateTime.month, dateTime.day);
  }
  return DateTime(dateTime.year, dateTime.month, dateTime.day);
}

/// Die Datumsleiste: [pastDays] zurueckliegende Tage plus [today] selbst,
/// **aufsteigend** sortiert (aeltester zuerst), also `pastDays + 1` Eintraege.
///
/// Jeder Eintrag ist der Beginn eines Kalendertages in der lokalen Zone, und
/// die Liste ist ueber jede DST-Kante hinweg lueckenlos und doppelfrei — genau
/// das, was `List.generate(..., (i) => today.subtract(Duration(days: n - i)))`
/// nach einer Fruehjahrsumstellung nicht mehr leistet.
///
/// [today] darf eine beliebige Uhrzeit tragen; sie wird verworfen.
/// Ein negatives [pastDays] liefert eine leere Liste (statt zu werfen — eine
/// verkonfigurierte Leiste soll nicht die Ansicht abstuerzen lassen).
List<DateTime> dayStrip({required DateTime today, required int pastDays}) {
  if (pastDays < 0) return const <DateTime>[];
  final anchor = startOfDay(today);
  return List<DateTime>.generate(
    pastDays + 1,
    (index) => addDays(anchor, index - pastDays),
    growable: false,
  );
}

/// Dieselbe Leiste **absteigend**: [count] Kalendertage, die auf [today]
/// enden, heute zuerst.
///
/// Ersetzt `[for (var i = 0; i < count; i++) today.subtract(Duration(days: i))]`.
/// Ein [count] von 0 oder weniger liefert eine leere Liste.
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
