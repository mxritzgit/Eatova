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

  /// Bounded Load fuer die Gewichts-Zeitreihe: 365 Messpunkte decken ein Jahr
  /// taegliches Wiegen — grosszuegig fuer den Verlaufs-Chart, der die Liste
  /// komplett zeichnet (WeightLog.add trimmt lokal ohnehin auf 30 Eintraege).
  /// Serverseitig desc + Limit, damit bei mehr Historie die AELTESTEN
  /// Messpunkte wegfallen, nie die aktuellen.
  static const int weightLogLimit = 365;

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
        // Zurueck in die aufsteigende Reihenfolge, die WeightLog erwartet
        // (latest == entries.last, Chart zeichnet links->rechts). Expliziter
        // Sort statt reversed: robust, egal wie der Server sortiert hat.
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
      return WeightLog(entries: entries);
    } catch (e, stack) {
      dev.log('TrackingSync.loadWeightLog failed',
          error: e, stackTrace: stack, name: 'tracking_sync');
      rethrow;
    }
  }

  /// Schreibt einen Gewichts-Messpunkt. Mit [id] (Client-UUID) laeuft der
  /// Write als Upsert auf den Primary Key — ein Outbox-Retry nach unklarem
  /// Netzwerk-Timeout schreibt dann dieselbe Zeile erneut statt ein Duplikat
  /// anzulegen (gleiche Idempotenz-Mechanik wie MealsSync.insertLoggedMeal;
  /// die weight_log-id-Spalte hat einen DB-Default, akzeptiert aber Client-
  /// Werte). Ohne [id] bleibt der alte insert-Pfad (Server vergibt die id).
  Future<void> insertWeight(
    double weightKg,
    DateTime timestamp, {
    String? id,
  }) async {
    try {
      final row = <String, dynamic>{
        'user_id': _userId,
        'recorded_at': timestamp.toUtc().toIso8601String(),
        'weight_kg': weightKg,
      };
      if (id == null) {
        await _client.from('weight_log').insert(row);
      } else {
        await _client.from('weight_log').upsert(
          <String, dynamic>{'id': id, ...row},
          onConflict: 'id',
          ignoreDuplicates: false,
        );
      }
    } catch (e, stack) {
      dev.log('TrackingSync.insertWeight failed',
          error: e, stackTrace: stack, name: 'tracking_sync');
      rethrow;
    }
  }
}
