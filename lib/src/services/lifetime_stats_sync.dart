import 'dart:developer' as dev;

import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/lifetime_stats.dart';

/// Liest und schreibt LifetimeStats gegen public.lifetime_stats. Genau eine
/// Zeile pro User (primary key user_id). Die Zeile wird beim User-Anlegen
/// per Bootstrap-Trigger erzeugt.
///
/// Schreibpfad seit Audit 2026-06-04: KEIN absolutes read-modify-write-Upsert
/// mehr (das verlor bei parallelen Geraeten/Tabs Increments via last-write-
/// wins). Stattdessen serverseitig-atomare RPCs:
///   * increment_lifetime_stats(p_water,p_steps,p_meals,p_weight_logs,
///     p_workouts,p_request_id) — addiert die uebergebenen Deltas atomar
///     (col = col + p_x) und gibt die frische Zeile zurueck. p_request_id ist
///     optional und macht den Aufruf idempotent (s. [increment]).
///   * record_tracking_day(p_day) — fuehrt die Logging-Streak persistent
///     fort (liest last_workout_date aus der DB statt aus In-Memory).
///     Gibt die frische Zeile zurueck.
/// Siehe Migrationen 20260604120000_lifetime_increment_rpcs.sql +
/// 20260804120000_tracking_streak.sql. Seit
/// 20260811120000_lifetime_stats_integrity.sql sind direkte Client-Writes auf
/// die Tabelle auch serverseitig entzogen (Grants + Policies weg); nur das
/// SELECT in [load] liest weiterhin direkt. record_tracking_day verlangt
/// seitdem einen Quell-Beweis (logged_meals.local_day = p_day) und lehnt
/// Zukunfts-Tage ab — beide Fehler sind P0001 und laufen im Fehlerfall ueber
/// den bestehenden Outbox-Retry-Pfad.
class LifetimeStatsSync {
  LifetimeStatsSync(this._client, this._userId);

  final SupabaseClient _client;
  final String _userId;

  Future<LifetimeStats?> load() async {
    try {
      final row = await _client
          .from('lifetime_stats')
          .select(
              'workouts_completed, meals_logged, water_total_ml, steps_recorded, weight_logs, current_streak, longest_streak, last_workout_date, session_start')
          .eq('user_id', _userId)
          .maybeSingle();
      if (row == null) {
        dev.log('LifetimeStatsSync.load: no row for current user',
            name: 'lifetime_stats_sync');
        return null;
      }
      return LifetimeStats.fromRow(row);
    } catch (e, stack) {
      dev.log('LifetimeStatsSync.load failed',
          error: e, stackTrace: stack, name: 'lifetime_stats_sync');
      rethrow;
    }
  }

  /// Zaehlt die uebergebenen Deltas serverseitig-atomar hoch und liefert die
  /// frische public.lifetime_stats-Zeile zurueck. Nur die gesetzten Felder
  /// (water/steps/meals/weightLogs) werden addiert; die uebrigen RPC-Parameter
  /// defaulten serverseitig auf 0. Die Streak laeuft bewusst NICHT hier —
  /// dafuer ist [recordTrackingDay] zustaendig (idempotent pro Tag).
  ///
  /// Negative oder 0-Deltas sind erlaubt (Server clampt mit greatest(x,0));
  /// ein leeres bzw. komplett-0 Delta ist ein No-op-Call, der einfach die
  /// aktuelle Zeile zurueckliefert.
  ///
  /// [requestId] ist der Idempotenz-Schluessel des Delta-Buendels (Migration
  /// 20260814120000_audit_rls_guard.sql, `p_request_id`): der Server haelt
  /// verbrauchte Ids 30 Tage fest und ADDIERT bei einer Wiederholung NICHT
  /// erneut, sondern liefert nur die aktuelle Zeile. Das ist der einzige Schutz
  /// gegen den Abbruch NACH dem Commit — ohne Id zaehlt jeder Retry ein zweites
  /// Mal. Der Aufrufer muss deshalb dieselbe Id wiederverwenden, solange dasselbe
  /// Buendel offen ist (home_store_sync.dart, `_flushStatsDelta`). `null` faellt
  /// serverseitig auf das alte, rein additive Verhalten zurueck.
  ///
  /// UEBERGANGSPFAD (Audit 2026-08-14, B1): antwortet der Server, dass er diese
  /// Ueberladung nicht kennt ([_ueberladungFehlt]), wird der Aufruf GENAU EINMAL
  /// ohne `p_request_id` wiederholt — s. dort.
  Future<LifetimeStats> increment({
    int water = 0,
    int steps = 0,
    int meals = 0,
    int weightLogs = 0,
    String? requestId,
  }) async {
    try {
      return await _rpcIncrement(water, steps, meals, weightLogs, requestId);
    } catch (e, stack) {
      // Rollout-Entkopplung (Audit 2026-08-14, B1): die Migration
      // 20260814120000_audit_rls_guard.sql ist abwaerts-, aber NICHT
      // vorwaertskompatibel. Laeuft dieser Build gegen eine Datenbank, die sie
      // noch nicht hat, findet PostgREST keine passende Ueberladung und
      // antwortet PGRST202/404 — und weil der Aufrufer (`_flushStatsDelta`)
      // jeden Fehler nur zurueck in die Queue legt, froeren Lebenszeit-Zaehler
      // und Streak dauerhaft ein, ohne dass irgendetwas rot wird. Deshalb hier
      // EIN Wiederholungsversuch ohne den Schluessel: er trifft die alte,
      // rein additive Signatur und kostet nur die Idempotenz — und die gibt es
      // auf einer nicht migrierten Datenbank ohnehin nicht.
      //
      // Der Pfad ist bewusst eng: nur bei fehlender Ueberladung, nur wenn
      // ueberhaupt eine Id mitging, und der Wiederholungsversuch uebergibt
      // `null` an denselben direkten RPC-Aufruf — er kann also weder bei einem
      // anderen Fehler greifen noch sich selbst erneut ausloesen.
      //
      // ENTFAELLT, sobald die Migration ueberall live ist: dann kann diese
      // ganze catch-Verzweigung ersatzlos weg, und `increment` ist wieder ein
      // einziger RPC-Aufruf mit rethrow.
      if (requestId != null && _ueberladungFehlt(e)) {
        dev.log(
            'LifetimeStatsSync.increment: increment_lifetime_stats ohne '
            'p_request_id-Ueberladung — einmalige Wiederholung ohne '
            'Idempotenz-Schluessel (Migration noch nicht angewendet)',
            error: e,
            name: 'lifetime_stats_sync');
        try {
          return await _rpcIncrement(water, steps, meals, weightLogs, null);
        } catch (e2, stack2) {
          dev.log(
              'LifetimeStatsSync.increment failed (Wiederholung ohne '
              'p_request_id)',
              error: e2,
              stackTrace: stack2,
              name: 'lifetime_stats_sync');
          rethrow;
        }
      }
      dev.log('LifetimeStatsSync.increment failed',
          error: e, stackTrace: stack, name: 'lifetime_stats_sync');
      rethrow;
    }
  }

  /// Der nackte RPC-Aufruf — ohne Logging, ohne Wiederholungslogik. Existiert,
  /// damit der Uebergangspfad in [increment] denselben Aufruf ein zweites Mal
  /// abschicken kann, ohne dabei erneut durch [increment] zu laufen (und damit
  /// ohne jede Schleifengefahr).
  Future<LifetimeStats> _rpcIncrement(
    int water,
    int steps,
    int meals,
    int weightLogs,
    String? requestId,
  ) async {
    final row = await _client.rpc(
      'increment_lifetime_stats',
      params: <String, dynamic>{
        'p_water': water,
        'p_steps': steps,
        'p_meals': meals,
        'p_weight_logs': weightLogs,
        if (requestId != null) 'p_request_id': requestId,
      },
    ).select().single();
    return LifetimeStats.fromRow(row);
  }

  /// Sagt der Server „diese Funktion/Signatur kenne ich nicht"?
  ///
  /// PostgREST meldet eine nicht aufloesbare Ueberladung als `PGRST202` mit
  /// HTTP 404. Die Kennung ist wie ueberall sonst (s.
  /// sync_error_messages.dart) NUR der Code: eine [PostgrestException] traegt
  /// kein statusCode-Feld, und `fromJson` schreibt den HTTP-Status nur dann
  /// nach `code`, wenn der Antwort-Body selbst keinen traegt (Proxy/Gateway).
  /// Deshalb beide Formen — der rohe `'404'` kostet hoechstens einen zweiten,
  /// ebenso erfolglosen Versuch.
  static bool _ueberladungFehlt(Object e) =>
      e is PostgrestException && (e.code == 'PGRST202' || e.code == '404');

  /// Verbucht einen getrackten Tag (>= 1 geloggte Mahlzeit) serverseitig:
  /// schreibt die Logging-Streak (current/longest/last_workout_date)
  /// persistent fort. Idempotent pro Tag; Tage VOR dem letzten gezaehlten
  /// Tag sind serverseitig ein No-op (Food-Kalender-Nachtraege). Gibt die
  /// frische Zeile zurueck — die Streak-Felder sind jetzt Server-Wahrheit.
  Future<LifetimeStats> recordTrackingDay(DateTime day) async {
    try {
      final row = await _client.rpc(
        'record_tracking_day',
        params: <String, dynamic>{'p_day': _dateOnly(day)},
      ).select().single();
      return LifetimeStats.fromRow(row);
    } catch (e, stack) {
      dev.log('LifetimeStatsSync.recordTrackingDay failed',
          error: e, stackTrace: stack, name: 'lifetime_stats_sync');
      rethrow;
    }
  }

  static String _dateOnly(DateTime d) {
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '$y-$m-$day';
  }
}
