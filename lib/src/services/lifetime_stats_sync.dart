import 'dart:developer' as dev;

import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/lifetime_stats.dart';

/// Reads LifetimeStats from public.lifetime_stats: exactly one row per user
/// (primary key user_id), created by a bootstrap trigger. Counter and streak
/// writes are durable outbox operations applied by `apply_sync_operation`;
/// direct client writes to the table are revoked server-side.
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
}
