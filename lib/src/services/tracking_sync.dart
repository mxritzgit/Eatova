import 'dart:developer' as dev;

import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/weight_log.dart';

/// Sync fuer die Gewichts-Zeitreihe (weight_log). Frueher lagen hier auch
/// Koffein- und Schlaf-Sync; beide sind mit dem Heute-Tab entfernt worden
/// (Rework spaeter). Jede Methode ist atomar gegen ihre Tabelle.
class TrackingSync {
  TrackingSync(this._client, this._userId);

  final SupabaseClient _client;
  final String _userId;

  Future<WeightLog> loadWeightLog() async {
    try {
      final rows = await _client
          .from('weight_log')
          .select('recorded_at, weight_kg')
          .eq('user_id', _userId)
          .order('recorded_at', ascending: true);
      final entries = rows.map<WeightLogEntry>((row) {
        return WeightLogEntry(
          timestamp:
              DateTime.parse(row['recorded_at'] as String).toLocal(),
          weightKg: (row['weight_kg'] as num).toDouble(),
        );
      }).toList();
      return WeightLog(entries: entries);
    } catch (e, stack) {
      dev.log('TrackingSync.loadWeightLog failed',
          error: e, stackTrace: stack, name: 'tracking_sync');
      rethrow;
    }
  }

  Future<void> insertWeight(double weightKg, DateTime timestamp) async {
    try {
      await _client.from('weight_log').insert({
        'user_id': _userId,
        'recorded_at': timestamp.toUtc().toIso8601String(),
        'weight_kg': weightKg,
      });
    } catch (e, stack) {
      dev.log('TrackingSync.insertWeight failed',
          error: e, stackTrace: stack, name: 'tracking_sync');
      rethrow;
    }
  }
}
