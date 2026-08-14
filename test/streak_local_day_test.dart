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

// REGRESSION: der Streak-Tag des LIVE-Log-Pfads kam aus der Zustelluhr, nicht
// aus der Mahlzeit. `addResultToDailyTotal` rief `_recordTrackingDay()` ohne
// Tag aus dem onDelivered-Callback — und der laeuft erst NACH dem
// Netz-Roundtrip. Ein Log um 23:59:58 mit drei Sekunden Laufzeit buchte
// dadurch p_day = D+1. Fuer diesen Tag gibt es keine Zeile in logged_meals,
// also wies der gehaertete RPC ihn mit EX_DAY_NOT_LOGGED ab
// (20260811120000_lifetime_stats_integrity.sql, Guard b). Weil dieser Fehler
// bewusst OHNE errcode geworfen wird (P0001 = retrybar), landete eine
// unerfuellbare Op in der Outbox, retryte 24 Stunden lang bis zur
// Verwurfs-Frist und endete im roten Verlust-Hinweis — waehrend Tag D nie
// verbucht wurde und die Streak beim naechsten Log auf 1 zurueckfiel.
//
// Der Outbox-Replay (`_performOp`) machte es von Anfang an richtig und
// uebergab `DateTime.parse(meal.effectiveLocalDay)`. Diese Tests nageln fest,
// dass der Live-Pfad denselben Tag schickt.

/// Kleiner zustandsbehafteter Fake-PostgREST, der GENAU den Quell-Beweis des
/// echten `record_tracking_day` nachbildet: ein Tag zaehlt nur, wenn fuer ihn
/// eine Zeile in logged_meals liegt. Ohne diesen Guard koennte der Test gar
/// nicht zeigen, was ein falscher Tag anrichtet — der Fake wuerde jedes Datum
/// quittieren.
class _FakeServer {
  /// Alle je an `record_tracking_day` uebergebenen `p_day`-Werte, in
  /// Aufrufreihenfolge.
  final List<String?> angefragteTage = <String?>[];

  /// `lifetime_stats.last_workout_date` — nur erfolgreiche Aufrufe setzen ihn.
  String? trackedDay;

  /// id -> Zeile aus public.logged_meals (nur die Spalten, die hier zaehlen).
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
        // Wire-Form des Server-Fehlers: HTTP 400, im Body der SQLSTATE —
        // genau der landet in PostgrestException.code. P0001 (kein
        // errcode in der Migration) heisst fuer die Client-Outbox
        // „retrybar mit Budget".
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
    // Uebrige Reads (profiles, lifetime_stats, favorite_meals, …): leer —
    // maybeSingle/_safeLoad lesen das als „nichts da", der Boot bleibt gruen.
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
    // Kein GoTrue-Auto-Refresh-Ticker im Test (siehe clobber_guard_test).
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

/// Der Log kurz vor Mitternacht …
final DateTime _kurzVorMitternacht = DateTime(2026, 8, 14, 23, 59, 58);

/// … und die Zustellung der Antwort drei Sekunden spaeter, lokal also am
/// Folgetag. Genau dieses Fenster trennt den Tag der Mahlzeit vom Tag der
/// Zustelluhr.
final DateTime _kurzNachMitternacht = DateTime(2026, 8, 15, 0, 0, 3);

/// Loggt eine Mahlzeit fuer den 14.08. und laesst die Wanduhr WAEHREND des
/// Netz-Roundtrips ueber Mitternacht laufen. [HomeStore] liest die Zeit
/// ausschliesslich ueber `clock.now()`, deshalb traegt die injizierte Uhr auch
/// durch die asynchronen Fortsetzungen.
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
