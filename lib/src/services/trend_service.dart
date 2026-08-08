import 'dart:developer' as dev;

import 'package:supabase_flutter/supabase_flutter.dart';

import 'day_math.dart';
import 'local_day.dart';

/// Laedt Tagesaggregate (kcal + Makros) fuer die Trend-Ansicht direkt aus
/// public.logged_meals — bewusst UNABHAENGIG vom 35-Tage-Boot-Fenster des
/// HomeStore (MealsSync.loggedMealsWindowDays): Trends brauchen ~90 Tage,
/// das Tagebuch nur ~5.
///
/// Projektion: NUR die denormalisierten Spalten (local_day, logged_at,
/// calories_kcal, protein_g, carbs_g, fat_g). Der JSONB-Payload bleibt
/// komplett drauessen — seine Makro-Felder (`payload->>'protein'` usw.) sind
/// Anzeige-Strings wie "25 g", waehrend die numerischen Spalten seit der
/// Ur-Migration (20260516160000_app_data_schema.sql) existieren und von jedem
/// Insert-/Update-Pfad in meals_sync.dart mitgeschrieben werden.
class TrendService {
  TrendService(this._client, this._userId);

  final SupabaseClient _client;
  final String _userId;

  /// Trend-Fenster in Tagen (laengster Zeitraum der UI: 90-Tage-Ansicht).
  /// Gefiltert wird wie in MealsSync auf logged_at statt local_day, weil
  /// sehr alte Zeilen local_day=null tragen koennen und bei einem
  /// local_day-Filter kommentarlos fehlen wuerden.
  static const int trendWindowDays = 90;

  /// Defensiver Zeilen-Deckel (~27 Logs/Tag im 90-Tage-Fenster): PostgREST
  /// kappt bei gesetztem db-max-rows STILL — mit explizitem Limit ist die
  /// Obergrenze deterministisch, und dank order desc verschwinden hoechstens
  /// die AELTESTEN Zeilen des Fensters (Muster aus MealsSync.loggedMealsMaxRows).
  static const int trendMaxRows = 2500;

  static const String _projection =
      'local_day, logged_at, calories_kcal, protein_g, carbs_g, fat_g';

  /// Laedt das 90-Tage-Fenster und aggregiert clientseitig zu Tagessummen
  /// (aufsteigend sortiert). Fehler werden geloggt und rethrown — die UI
  /// faengt sie und zeigt einen Retry-Zustand.
  Future<List<TrendDayTotals>> loadDailyTotals() async {
    try {
      // B5: Hier steht bewusst Absolutzeit, KEINE Kalenderarithmetik. Der
      // Cutoff ist eine grosszuegige Server-Grenze auf `logged_at` (einem
      // Instant), kein Kalendertag — 90x24h ist genau die gemeinte Semantik,
      // und ein um eine DST-Stunde verschobener Rand aendert nichts am
      // Ergebnis, weil das Fenster ohnehin weiter reicht als jede UI-Ansicht
      // (laengster Zeitraum: 90 Tage). Tagesgrenzen entstehen erst
      // clientseitig in aggregateDailyTotals/denseTrendWindow.
      final cutoffIso = DateTime.now()
          .toUtc()
          .subtract(const Duration(days: trendWindowDays))
          .toIso8601String();
      final rows = await _client
          .from('logged_meals')
          .select(_projection)
          .eq('user_id', _userId)
          .gte('logged_at', cutoffIso)
          .order('logged_at', ascending: false)
          .limit(trendMaxRows);
      // Aggregation ist reihenfolge-unabhaengig — dass die Query desc sortiert
      // (fuer das Limit), spielt fuer die Tagessummen keine Rolle.
      return aggregateDailyTotals(rows);
    } catch (e, stack) {
      dev.log(
        'TrendService.loadDailyTotals failed',
        error: e,
        stackTrace: stack,
        name: 'trend_service',
      );
      rethrow;
    }
  }
}

/// Signatur des Trend-Laders, wie ihn der TrendsScreen injiziert bekommt —
/// Produktions-Pfad ist [TrendService.loadDailyTotals], Tests reichen Fakes.
typedef TrendTotalsLoader = Future<List<TrendDayTotals>> Function();

/// Eine Tagessumme (lokaler Kalendertag) fuer die Trend-Ansicht.
class TrendDayTotals {
  const TrendDayTotals({
    required this.day,
    required this.kcal,
    required this.proteinG,
    required this.carbsG,
    required this.fatG,
  });

  /// Lokaler Kalendertag (date-only, keine Uhrzeit).
  final DateTime day;
  final int kcal;
  final double proteinG;
  final double carbsG;
  final double fatG;
}

/// Toleranz des Zielkorridors: ein Tag "trifft" das Kalorienziel, wenn seine
/// Summe innerhalb von +/-10 % des Tagesziels liegt (inklusive Grenzen).
const double trendGoalTolerance = 0.10;

/// Pure Aggregation: PostgREST-Zeilen -> Tagessummen, aufsteigend sortiert.
///
/// Tages-Schluessel ist `local_day` (kanonisch, DATA-6); Zeilen ohne
/// local_day (sehr alte Eintraege) fallen auf den lokalen Kalendertag von
/// `logged_at` zurueck — dieselbe Fallback-Logik wie das Meals-Bucketing.
/// Null-Makros (aeltere Zeilen / unparsebare Angaben) zaehlen als 0.
List<TrendDayTotals> aggregateDailyTotals(Iterable<Map<String, dynamic>> rows) {
  final byDay = <String, ({int kcal, double p, double c, double f})>{};
  for (final row in rows) {
    String? key = row['local_day']?.toString();
    if (key == null) {
      final loggedAtRaw = row['logged_at']?.toString();
      final loggedAt = loggedAtRaw == null
          ? null
          : DateTime.tryParse(loggedAtRaw);
      // Defensiv: Zeile ohne jedes Datum ueberspringen.
      if (loggedAt == null) {
        continue;
      }
      key = localDayKey(loggedAt.toLocal());
    }
    final prev = byDay[key] ?? (kcal: 0, p: 0.0, c: 0.0, f: 0.0);
    byDay[key] = (
      kcal: prev.kcal + ((row['calories_kcal'] as num?)?.toInt() ?? 0),
      p: prev.p + ((row['protein_g'] as num?)?.toDouble() ?? 0),
      c: prev.c + ((row['carbs_g'] as num?)?.toDouble() ?? 0),
      f: prev.f + ((row['fat_g'] as num?)?.toDouble() ?? 0),
    );
  }
  final totals = <TrendDayTotals>[];
  for (final entry in byDay.entries) {
    final day = DateTime.tryParse(entry.key);
    if (day == null) continue; // defensiv: kaputter Tages-Schluessel
    totals.add(
      TrendDayTotals(
        // startOfDay statt DateTime(y, m, d): identischer Wert, aber es ist
        // dieselbe Kalender-Normalisierung, die day_math.dart ueberall sonst
        // im Projekt liefert (B5).
        day: startOfDay(day),
        kcal: entry.value.kcal,
        proteinG: entry.value.p,
        carbsG: entry.value.c,
        fatG: entry.value.f,
      ),
    );
  }
  totals.sort((a, b) => a.day.compareTo(b.day));
  return totals;
}

/// Dichtes Fenster der letzten [days] Kalendertage (aeltester zuerst, letzter
/// Eintrag = [today]): pro Tag entweder die Tagessumme oder `null` fuer
/// Luecken-Tage ohne Logs. Tage ausserhalb des Fensters werden verworfen.
///
/// Dass der LETZTE Eintrag [today] ist, ist eine zugesicherte Eigenschaft —
/// [completedDaysOf] verlaesst sich darauf.
///
/// Ein [days] von 0 oder weniger liefert ein leeres Fenster (statt zu werfen).
List<TrendDayTotals?> denseTrendWindow(
  List<TrendDayTotals> totals, {
  required DateTime today,
  required int days,
}) {
  final byKey = <String, TrendDayTotals>{
    for (final t in totals) localDayKey(t.day): t,
  };
  // B5: dayStrip rechnet in Kalendertagen (Day-Overflow im Konstruktor). Eine
  // Duration-Subtraktion wuerde ueber eine DST-Kante hinweg auf 23:00 des
  // Vortags rutschen und Tage doppeln/ueberspringen — nach der
  // Fruehjahrsumstellung faellt sonst ein ganzer Tag aus dem Chart.
  return [
    for (final day in dayStrip(today: today, pastDays: days - 1))
      byKey[localDayKey(day)],
  ];
}

/// B6: Der Kennzahlen-Ausschnitt eines [denseTrendWindow] — alle Tage AUSSER
/// dem laufenden (dem letzten Eintrag).
///
/// Warum: `averageKcalOf`/`goalHitsOf`/`averageMacrosOf` behandeln jeden Tag
/// mit mindestens einem Eintrag als vollstaendig. Der laufende Tag ist das per
/// Definition nicht. Wer morgens um 08:30 ein 350-kcal-Fruehstueck loggt und
/// direkt auf Trends tippt, saehe sonst bei sechs perfekten Vortagen a 2200
/// kcal einen Schnitt von (6 x 2200 + 350) / 7 = 1936 kcal „pro getracktem
/// Tag" und eine Trefferquote von 6 von 7 Tagen — der Fehler ist am groessten
/// genau dann, wenn der Nutzer am ehesten hinschaut.
///
/// **Der Preis:** Wer abends um 23:50 schaut, hat einen praktisch
/// vollstaendigen Tag, der trotzdem nicht mitzaehlt. Das ist bewusst so: eine
/// Uhrzeit-Heuristik („ab 20 Uhr zaehlt heute mit") waere willkuerlich, waere
/// vom Essrhythmus des Nutzers abhaengig und liesse sich nicht sinnvoll
/// testen. „Abgeschlossen heisst: der Tag ist vorbei" ist die einzige Regel,
/// die ohne Annahmen ueber den Nutzer auskommt.
///
/// Das CHART bekommt weiterhin das volle [denseTrendWindow] — die Kurve soll
/// den laufenden Tag zeigen, nur die Kennzahlen-Kacheln rechnen ohne ihn. Die
/// Kacheln muessen das beschriften (`trends_screen.dart`).
///
/// Ein leeres Fenster bleibt leer; ein Fenster mit nur einem Tag (heute) wird
/// leer — der Aufrufer bekommt dann `null` aus den Durchschnitten und
/// `tracked == 0` aus [goalHitsOf] und muss daraus einen Leerzustand bauen,
/// statt 0/0 zu rechnen.
List<TrendDayTotals?> completedDaysOf(List<TrendDayTotals?> window) {
  if (window.isEmpty) return const <TrendDayTotals?>[];
  return window.sublist(0, window.length - 1);
}

/// Anzahl der Tage mit mindestens einem Eintrag (Luecken zaehlen nicht).
/// Ein Tag mit 0 kcal ist getrackt — „nicht getrackt" ist kein 0-kcal-Tag.
int trackedDaysOf(Iterable<TrendDayTotals?> window) {
  var tracked = 0;
  for (final day in window) {
    if (day != null) tracked++;
  }
  return tracked;
}

/// Durchschnitts-kcal ueber die GETRACKTEN Tage des Fensters (Luecken-Tage
/// zaehlen nicht als 0 — ein nicht getrackter Tag ist kein 0-kcal-Tag).
/// `null`, wenn kein Tag Daten hat.
double? averageKcalOf(Iterable<TrendDayTotals?> window) {
  var sum = 0;
  var tracked = 0;
  for (final day in window) {
    if (day == null) continue;
    sum += day.kcal;
    tracked++;
  }
  return tracked == 0 ? null : sum / tracked;
}

/// Ziel-Treffer: wie viele getrackte Tage liegen im Korridor
/// `goalKcal * (1 +/- tolerance)` (Grenzen inklusive)? Luecken-Tage zaehlen
/// weder als Treffer noch als getrackt. Ein Ziel <= 0 hat keinen sinnvollen
/// Korridor -> 0 Treffer.
({int hit, int tracked}) goalHitsOf(
  Iterable<TrendDayTotals?> window, {
  required int goalKcal,
  double tolerance = trendGoalTolerance,
}) {
  var hit = 0;
  var tracked = 0;
  final lo = goalKcal * (1 - tolerance);
  final hi = goalKcal * (1 + tolerance);
  for (final day in window) {
    if (day == null) continue;
    tracked++;
    if (goalKcal > 0 && day.kcal >= lo && day.kcal <= hi) hit++;
  }
  return (hit: hit, tracked: tracked);
}

/// Durchschnitts-Makros (P/C/F in Gramm) ueber die getrackten Tage.
/// `null`, wenn kein Tag Daten hat.
({double proteinG, double carbsG, double fatG})? averageMacrosOf(
  Iterable<TrendDayTotals?> window,
) {
  var p = 0.0;
  var c = 0.0;
  var f = 0.0;
  var tracked = 0;
  for (final day in window) {
    if (day == null) continue;
    p += day.proteinG;
    c += day.carbsG;
    f += day.fatG;
    tracked++;
  }
  if (tracked == 0) return null;
  return (proteinG: p / tracked, carbsG: c / tracked, fatG: f / tracked);
}
