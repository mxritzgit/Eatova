import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/services/lifetime_stats_sync.dart';

// INT-1 / DATA-1: LifetimeStatsSync schreibt seit dem Audit 2026-06-04 NICHT
// mehr absolut (read-modify-write upsert), sondern ueber zwei atomare RPCs:
//   * increment_lifetime_stats(p_water,p_steps,p_meals,p_weight_logs,p_workouts)
//   * record_tracking_day(p_day) — Logging-Streak (seit 2026-08-04; ersetzt
//     record_workout_day nach dem Training-Tab-Aus)
// Beide geben die frische public.lifetime_stats-Zeile zurueck. Diese Tests
// treiben den echten SupabaseClient mit einem MockClient (package:http/testing)
// und verifizieren das beobachtbare Verhalten ueber die PUBLIC API:
//   1. increment schickt die DELTAS als RPC-Params (nicht absolute Summen).
//   2. increment parst die zurueckgegebene Zeile in LifetimeStats.
//   3. recordTrackingDay schickt p_day als yyyy-MM-dd und parst die Zeile.

LifetimeStatsSync _sync(
  Future<http.Response> Function(http.Request request) handler,
) {
  final client = SupabaseClient(
    'https://example.supabase.co',
    'test-anon-key',
    httpClient: MockClient((req) => handler(req)),
  );
  addTearDown(client.dispose);
  return LifetimeStatsSync(client, 'user-123');
}

http.Response _row(Map<String, dynamic> row, {http.Request? request}) =>
    http.Response(
      jsonEncode(row),
      200,
      headers: const {'Content-Type': 'application/json'},
      request: request,
    );

Map<String, dynamic> _statsRow({
  int workouts = 0,
  int meals = 0,
  int water = 0,
  int steps = 0,
  int weightLogs = 0,
  int currentStreak = 0,
  int longestStreak = 0,
  String? lastTrackedDate,
}) {
  return <String, dynamic>{
    'workouts_completed': workouts,
    'meals_logged': meals,
    'water_total_ml': water,
    'steps_recorded': steps,
    'weight_logs': weightLogs,
    'current_streak': currentStreak,
    'longest_streak': longestStreak,
    'last_workout_date': lastTrackedDate,
    'session_start': '2026-06-01T00:00:00Z',
  };
}

void main() {
  group('LifetimeStatsSync.increment', () {
    test('schickt die Deltas als RPC-Params und parst die Server-Zeile', () async {
      Map<String, dynamic>? sentBody;
      String? sentPath;
      final sync = _sync((req) async {
        sentPath = req.url.path;
        sentBody = jsonDecode(req.body) as Map<String, dynamic>;
        return _row(_statsRow(water: 1500, steps: 8000, meals: 3),
            request: req);
      });

      final result = await sync.increment(water: 250, steps: 2000, meals: 1);

      expect(sentPath, contains('rpc/increment_lifetime_stats'));
      // DELTAS, nicht absolute Summen.
      expect(sentBody, containsPair('p_water', 250));
      expect(sentBody, containsPair('p_steps', 2000));
      expect(sentBody, containsPair('p_meals', 1));
      expect(sentBody, containsPair('p_weight_logs', 0));
      // workouts laeuft NICHT ueber increment.
      expect(sentBody!.containsKey('p_workouts'), isFalse);

      // Zurueckgegebene Server-Zeile wird adoptiert.
      expect(result.waterTotalMl, 1500);
      expect(result.stepsRecorded, 8000);
      expect(result.mealsLogged, 3);
    });

    test('weightLogs-Delta wird durchgereicht', () async {
      Map<String, dynamic>? sentBody;
      final sync = _sync((req) async {
        sentBody = jsonDecode(req.body) as Map<String, dynamic>;
        return _row(_statsRow(weightLogs: 5), request: req);
      });

      final result = await sync.increment(weightLogs: 1);
      expect(sentBody, containsPair('p_weight_logs', 1));
      expect(result.weightLogs, 5);
    });

    test('RPC-Fehler (500) wird durchgereicht (rethrow)', () async {
      final sync = _sync((req) async {
        return http.Response(jsonEncode({'message': 'boom'}), 500,
            headers: const {'Content-Type': 'application/json'});
      });

      await expectLater(
        sync.increment(water: 100),
        throwsA(isA<Object>()),
      );
    });
  });

  group('LifetimeStatsSync.recordTrackingDay', () {
    test('schickt p_day als yyyy-MM-dd und parst Streak-Felder', () async {
      Map<String, dynamic>? sentBody;
      String? sentPath;
      final sync = _sync((req) async {
        sentPath = req.url.path;
        sentBody = jsonDecode(req.body) as Map<String, dynamic>;
        return _row(
          _statsRow(
            workouts: 12,
            currentStreak: 4,
            longestStreak: 9,
            lastTrackedDate: '2026-06-04',
          ),
          request: req,
        );
      });

      final result = await sync.recordTrackingDay(DateTime(2026, 6, 4, 18, 30));

      expect(sentPath, contains('rpc/record_tracking_day'));
      // Uhrzeit wird gestrippt → reines Datum.
      expect(sentBody, containsPair('p_day', '2026-06-04'));

      expect(result.workoutsCompleted, 12);
      expect(result.currentStreak, 4);
      expect(result.longestStreak, 9);
      expect(result.lastTrackedDate, DateTime(2026, 6, 4));
    });
  });
}
