import 'dart:developer' as dev;

import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/lifetime_stats.dart';

/// Reads and writes LifetimeStats against public.lifetime_stats — exactly one
/// row per user (primary key user_id), created by a bootstrap trigger.
///
/// Writes go through server-side atomic RPCs, never read-modify-write upserts
/// (those lost increments across devices via last-write-wins):
///   * increment_lifetime_stats(...) — adds the given deltas atomically and
///     returns the fresh row. `p_request_id` makes the call idempotent
///     (see [increment]).
///   * record_tracking_day(p_day) — advances the logging streak from the DB.
/// Direct client writes to the table are revoked server-side; only the SELECT
/// in [load] reads directly. record_tracking_day requires a source proof
/// (logged_meals.local_day = p_day) and rejects future days; both raise P0001
/// and run through the existing outbox retry path.
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

  /// Increments the given deltas server-side-atomically and returns the fresh
  /// public.lifetime_stats row. Remaining RPC parameters default to 0
  /// server-side. The streak deliberately does NOT run here — that is
  /// [recordTrackingDay] (idempotent per day).
  ///
  /// Negative or 0 deltas are allowed (the server clamps with greatest(x,0));
  /// an all-zero delta is a no-op call returning the current row.
  ///
  /// [requestId] is the bundle's idempotency key (`p_request_id`): the server
  /// keeps spent ids for 30 days and does NOT add again on a repeat. It is the
  /// only protection against an abort AFTER the commit, so the caller must
  /// reuse the same id while the bundle is open. `null` falls back to the old,
  /// purely additive behaviour.
  ///
  /// TRANSITION PATH (Audit 2026-08-14, B1): if the server does not know this
  /// overload ([_ueberladungFehlt]), the call is repeated EXACTLY ONCE without
  /// `p_request_id`.
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
      // Rollout decoupling (Audit 2026-08-14, B1): against a database without
      // migration 20260814120000_audit_rls_guard.sql, PostgREST finds no
      // matching overload and answers PGRST202/404. Since the caller only
      // re-queues every error, counters and streak would freeze silently. So
      // ONE retry without the key: it hits the old additive signature and only
      // costs idempotency, which an unmigrated database has no way to offer.
      //
      // Deliberately narrow: only on a missing overload, only if an id was
      // passed, and the retry hands `null` to the same direct RPC call, so it
      // can neither fire on other errors nor re-trigger itself.
      //
      // Remove this whole branch once the migration is live everywhere.
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

  /// The bare RPC call, no logging, no retry logic. Exists so the transition
  /// path in [increment] can resend without looping back through [increment].
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

  /// Does the server say "I don't know this function/signature"?
  ///
  /// PostgREST reports an unresolvable overload as `PGRST202` with HTTP 404.
  /// The check uses the code only: [PostgrestException] has no statusCode
  /// field, and `fromJson` writes the HTTP status into `code` only when the
  /// body carries none (proxy/gateway). Hence both forms — the raw `'404'` at
  /// worst costs one more equally unsuccessful attempt.
  static bool _ueberladungFehlt(Object e) =>
      e is PostgrestException && (e.code == 'PGRST202' || e.code == '404');

  /// Books a tracked day (>= 1 logged meal) server-side, advancing the logging
  /// streak. Idempotent per day; days BEFORE the last counted one are a no-op.
  /// Returns the fresh row — the streak fields are server truth.
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
