import 'dart:developer' as dev;

import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/weight_log.dart';

/// Loads the weight time series (weight_log). Weigh-ins are written as durable
/// sync operations (`SyncOperationSync`).
class TrackingSync {
  TrackingSync(this._client, this._userId);

  final SupabaseClient _client;
  final String _userId;

  /// Bounded load: 365 points cover a year of daily weigh-ins. Server-side desc
  /// + limit so extra history drops the OLDEST points, never the current ones.
  /// Same number as the local ring buffer ([WeightLog.maxEntries]) on purpose
  /// (F7-03): a different local cap moved the baseline on every weigh-in.
  static const int weightLogLimit = WeightLog.maxEntries;

  Future<WeightLog> loadWeightLog() async {
    try {
      final rows = await _client
          .from('weight_log')
          .select('recorded_at, weight_kg')
          .eq('user_id', _userId)
          .order('recorded_at', ascending: false)
          .limit(weightLogLimit);
      final entries = rows.map<WeightLogEntry>((row) {
        return WeightLogEntry(
          timestamp:
              DateTime.parse(row['recorded_at'] as String).toLocal(),
          weightKg: (row['weight_kg'] as num).toDouble(),
        );
      }).toList()
        // Back to the ascending order WeightLog expects (latest ==
        // entries.last). Explicit sort instead of reversed: robust regardless
        // of the server's ordering.
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
      return WeightLog(entries: entries);
    } catch (e, stack) {
      dev.log('TrackingSync.loadWeightLog failed',
          error: e, stackTrace: stack, name: 'tracking_sync');
      rethrow;
    }
  }
}
