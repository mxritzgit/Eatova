import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/services/sync_outbox.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';

// REGRESSION: the live log path took the streak day from the delivery clock,
// not from the meal. `addResultToDailyTotal` called `_recordTrackingDay()`
// without a day from the onDelivered callback, which runs AFTER the network
// roundtrip — a log at 23:59:58 booked p_day = D+1. There is no logged_meals
// row for that day, so the hardened RPC rejected it with EX_DAY_NOT_LOGGED.
// Since that error is thrown without an errcode (P0001 = retryable), an
// unfulfillable op sat in the outbox retrying for 24 h until the drop
// deadline, while day D was never recorded and the streak fell back to 1.
//
// The outbox replay always passed `DateTime.parse(meal.effectiveLocalDay)`;
// these tests pin that the live path sends the same day.

/// Small stateful fake PostgREST reproducing the real `record_tracking_day`
/// source check: a day only counts if a logged_meals row exists for it.
/// Without that guard the fake would acknowledge any date and the test could
/// not show what a wrong day does.
class _FakeServer {
  /// Every `p_day` ever passed to `record_tracking_day`, in call order.
  final List<String?> angefragteTage = <String?>[];

  /// `lifetime_stats.last_workout_date` — only successful calls set it.
  String? trackedDay;

  /// id -> row from public.logged_meals (only the columns that matter here).
  final Map<String, Map<String, dynamic>> mealRows =
      <String, Map<String, dynamic>>{};

  int mealsCounted = 0;

  http.Client client() => MockClient(_handle);

  Future<http.Response> _handle(http.Request req) async {
    final path = req.url.path;
    http.Response ok(Object body) => http.Response(jsonEncode(body), 200,
        headers: const {'Content-Type': 'application/json'}, request: req);

    if (path.contains('/rpc/record_tracking_day')) {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      final day = body['p_day'] as String?;
      angefragteTage.add(day);
      final hatQuelle = mealRows.values.any((r) => r['local_day'] == day);
      if (!hatQuelle) {
        // Wire form of the server error: HTTP 400 with the SQLSTATE in the
        // body, which becomes PostgrestException.code. P0001 means
        // "retryable with budget" to the client outbox.
        return http.Response(
            jsonEncode({
              'code': 'P0001',
              'message': 'EX_DAY_NOT_LOGGED',
              'details': null,
              'hint': null,
            }),
            400,
            headers: const {'Content-Type': 'application/json'},
            request: req);
      }
      trackedDay = day;
      return ok(_statsRow());
    }
    if (path.contains('/rpc/increment_lifetime_stats')) {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      mealsCounted += (body['p_meals'] as num?)?.toInt() ?? 0;
      return ok(_statsRow());
    }
    if (path.contains('/logged_meals')) {
      if (req.method == 'POST') {
        final decoded = jsonDecode(req.body);
        final rows = <Map<String, dynamic>>[
          if (decoded is List)
            ...decoded.whereType<Map>().map((m) => m.cast<String, dynamic>())
          else if (decoded is Map)
            decoded.cast<String, dynamic>(),
        ];
        for (final row in rows) {
          mealRows[row['id'] as String] = row;
        }
        return http.Response('', 201, request: req);
      }
      if (req.method == 'GET') {
        return ok(mealRows.values
            .map((r) => <String, dynamic>{
                  'id': r['id'],
                  'logged_at': r['logged_at'],
                  'forced_slot': r['forced_slot'],
                  'local_day': r['local_day'],
                  'payload': r['payload'],
                })
            .toList());
      }
      return ok(const <dynamic>[]);
    }
    // Remaining reads (profiles, lifetime_stats, favorite_meals, …) return
    // empty; maybeSingle/_safeLoad read that as "nothing there".
    if (req.method == 'GET') return ok(const <dynamic>[]);
    return http.Response('', 201, request: req);
  }

  Map<String, dynamic> _statsRow() => <String, dynamic>{
        'workouts_completed': 0,
        'meals_logged': mealsCounted,
        'water_total_ml': 0,
        'steps_recorded': 0,
        'weight_logs': 0,
        'current_streak': 1,
        'longest_streak': 1,
        'last_workout_date': trackedDay,
        'session_start': '2026-08-01T00:00:00Z',
      };
}

void _noopSnack(
  String message, {
  IconData icon = Icons.info_outline,
  SnackTone tone = SnackTone.positive,
  Duration? duration,
  SnackBarAction? action,
}) {}

({HomeStore store, _FakeServer server}) _setup() {
  final server = _FakeServer();
  final client = SupabaseClient(
    'https://example.supabase.co',
    'test-anon-key',
    httpClient: server.client(),
    // No GoTrue auto-refresh ticker in tests (see clobber_guard_test).
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  addTearDown(client.dispose);
  final store = HomeStore(
    sync: EatovaSync.forUser(client, 'user-streak'),
    health: const NoopHealthService(),
    notificationService: const NoopNotificationService(),
    initialUserName: 'Test',
    emitSnack: _noopSnack,
    debugCache: LocalCache(InMemoryKeyValueStore(), 'user-streak'),
  );
  addTearDown(store.dispose);
  return (store: store, server: server);
}

MealAnalysisResult _result(String name) => MealAnalysisResult(
      mealName: name,
      caloriesKcal: 300,
      estimatedGrams: 350,
      kcalPer100G: 300 * 100 / 350,
      protein: '30 g',
      carbs: '40 g',
      fat: '10 g',
      confidence: 'Hoch',
      portionNotes: 'Test.',
      sourceLabel: 'Foto-KI',
    );

Future<void> _settle() => pumpEventQueue(times: 60);

/// The log just before midnight …
final DateTime _kurzVorMitternacht = DateTime(2026, 8, 14, 23, 59, 58);

/// … and the response three seconds later, on the next local day. That window
/// separates the meal's day from the delivery clock's day.
final DateTime _kurzNachMitternacht = DateTime(2026, 8, 15, 0, 0, 3);

/// Logs a meal for the 14th and lets the wall clock cross midnight DURING the
/// network roundtrip. [HomeStore] reads time only via `clock.now()`, so the
/// injected clock carries through the async continuations.
Future<({HomeStore store, _FakeServer server})> _logUeberMitternacht() {
  var jetzt = _kurzVorMitternacht;
  return withClock(Clock(() => jetzt), () async {
    final s = _setup();
    s.store.start();
    await s.store.profileReady;
    await _settle();

    s.store.addResultToDailyTotal(_result('Spaet-Bowl'));
    jetzt = _kurzNachMitternacht;
    await _settle();
    return s;
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'Live-Log: der verbuchte Streak-Tag ist der Tag der MAHLZEIT, nicht der '
      'der Zustellung', () async {
    final s = await _logUeberMitternacht();

    expect(s.server.mealRows.values.single['local_day'], '2026-08-14',
        reason: 'Vorbedingung: die Mahlzeit selbst liegt auf dem 14.');
    expect(s.server.angefragteTage, ['2026-08-14'],
        reason: 'der onDelivered-Callback laeuft nach dem Roundtrip — mit der '
            'Zustelluhr als Quelle stand dort der 15., fuer den es keine '
            'Mahlzeit gibt');
    expect(s.server.trackedDay, '2026-08-14');
    expect(s.store.lifetimeStats.lastTrackedDate, DateTime(2026, 8, 14),
        reason: 'die adoptierte Serverzeile muss den geloggten Tag tragen — '
            'sonst faellt die Streak beim naechsten Log auf 1 zurueck');
  });

  test(
      'Live-Log: kein unerfuellbarer Streak-Tag in der Outbox — ein Tag ohne '
      'Mahlzeit wird vom Server abgewiesen und retryt sonst 24 h lang',
      () async {
    final s = await _logUeberMitternacht();

    expect(
        s.store.pendingOutbox.where((o) => o.kind == SyncOpKind.trackingDay),
        isEmpty,
        reason: 'EX_DAY_NOT_LOGGED kommt bewusst als P0001 (retrybar) — eine '
            'Op fuer einen Tag ohne Quellzeile kann deshalb nie zugestellt '
            'werden und endet erst im Verlust-Hinweis');
  });

  test(
      'Nachtrag fuer einen vergangenen Tag ruft record_tracking_day gar nicht '
      'auf', () async {
    await withClock(Clock.fixed(DateTime(2026, 8, 14, 12)), () async {
      final s = _setup();
      s.store.start();
      await s.store.profileReady;
      await _settle();

      s.store.addResultToDailyTotal(_result('Nachtrag'),
          foodDate: DateTime(2026, 8, 13));
      await _settle();

      expect(s.server.angefragteTage, isEmpty,
          reason: 'Nachtraege lassen die Streak unangetastet — der Zieltag '
              'darf den targetIsToday-Guard nicht aushebeln');
      expect(s.server.trackedDay, isNull);
    });
  });
}
