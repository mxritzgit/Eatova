import 'dart:convert';

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
import 'package:eatova/src/services/meals_sync.dart' show mealResultToJson;
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/services/sync_outbox.dart';
import 'package:eatova/src/theme/app_colors.dart';

// DATA-7 Datenverlust-Fix: ein fehlgeschlagener Sync-Write rollt den lokalen
// State NICHT mehr zurueck (der Eintrag des Nutzers war sonst WEG), sondern
// wandert als persistierte Outbox-Op in die Retry-Queue. Diese Tests treiben
// den ECHTEN HomeStore mit einem echten EatovaSync ueber einen zustands-
// behafteten MockClient (schaltbar offline/online) und einem injizierten
// In-Memory-Cache (debugCache) und sichern:
//   1. Kein Rollback mehr + Op persistiert + dezenter Offline-Hinweis
//      (kein roter "Sync (...)"-Toast).
//   2. Replay ist idempotent und koalesziert (Insert+Update -> EIN Upsert
//      mit dem neuesten Payload, Stats zaehlen genau 1 Mahlzeit).
//   3. Gewicht: Live-Write und Retry teilen dieselbe Client-UUID -> Upsert,
//      ein wiederholter Versuch erzeugt KEIN Duplikat.
//   4. Kaltstart ohne Netz hydriert das Tagebuch aus dem Cache.
//   5. Boot-Merge: Outbox-Eintraege ueberleben den Server-Refresh und werden
//      beim Boot nachgespielt.
//   6. Pendende Stats-Deltas ueberleben einen App-Neustart.
//   7. Eine blockierte Entitaet haelt die Ops anderer Entitaeten nicht auf.
//   8. Server-Fehler (500/Constraint — KEIN Netzfehler) queuen genauso, zeigen
//      aber die neutrale Retry-Meldung statt "Offline" und leaken nie
//      Roh-Fehlertext (Schema-Details) in die UI.

/// Zustandsbehafteter Fake-PostgREST: zeichnet Requests auf, fuehrt Upserts/
/// Deletes auf In-Memory-Tabellen aus und laesst sich offline schalten.
class _FakeServer {
  /// Alles faellt aus (Netz weg). Requests werden dann NICHT aufgezeichnet —
  /// [requests] enthaelt nur, was den "Server" wirklich erreicht hat.
  bool offline = false;

  /// Nur increment_lifetime_stats faellt aus (Stats-Delta-Szenarien).
  bool statsOffline = false;

  /// Nur logged_meals-Writes fallen aus (Poison-Entity-Szenario).
  bool rejectMealWrites = false;

  /// Unklarer Ausgang: der Write wird serverseitig ANGEWENDET, die Antwort
  /// ist aber ein 500 (Timeout-Simulation) — der Klassiker, der frueher
  /// Duplikate erzeugte.
  bool ambiguousWrites = false;

  final List<http.Request> requests = <http.Request>[];
  final Map<String, Map<String, dynamic>> mealRows =
      <String, Map<String, dynamic>>{};
  final Map<String, Map<String, dynamic>> weightRows =
      <String, Map<String, dynamic>>{};
  int mealsCounted = 0;
  int weightLogsCounted = 0;

  http.Client client() => MockClient(_handle);

  Future<http.Response> _handle(http.Request req) async {
    if (offline) {
      throw http.ClientException('offline', req.url);
    }
    requests.add(req);
    final path = req.url.path;

    http.Response ok(Object body) => http.Response(jsonEncode(body), 200,
        headers: const {'Content-Type': 'application/json'}, request: req);
    http.Response fail() => http.Response(
        jsonEncode({'message': 'kaputt'}), 500,
        headers: const {'Content-Type': 'application/json'}, request: req);

    if (path.contains('/rpc/increment_lifetime_stats')) {
      if (statsOffline) return fail();
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      mealsCounted += (body['p_meals'] as num?)?.toInt() ?? 0;
      weightLogsCounted += (body['p_weight_logs'] as num?)?.toInt() ?? 0;
      return ok(_statsRow());
    }
    if (path.contains('/rpc/record_tracking_day')) {
      return ok(_statsRow());
    }
    if (path.contains('/logged_meals')) {
      if (req.method == 'POST') {
        if (rejectMealWrites) return fail();
        for (final row in _rowsOf(req.body)) {
          mealRows[row['id'] as String] = row;
        }
        return ambiguousWrites
            ? fail()
            : http.Response('', 201, request: req);
      }
      if (req.method == 'PATCH') {
        final id = _eqParam(req, 'id');
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        final existing = mealRows[id];
        if (existing != null) mealRows[id!] = {...existing, ...body};
        return ok(const <dynamic>[]);
      }
      if (req.method == 'DELETE') {
        mealRows.remove(_eqParam(req, 'id'));
        return ok(const <dynamic>[]);
      }
      // GET: Zeilen in der vom Client erwarteten Select-Form.
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
    if (path.contains('/weight_log') && req.method == 'POST') {
      for (final row in _rowsOf(req.body)) {
        final id = row['id'] as String? ?? 'srv-${weightRows.length}';
        weightRows[id] = row;
      }
      return ambiguousWrites ? fail() : http.Response('', 201, request: req);
    }
    // Uebrige Reads (profiles, favorites, weight_log, lifetime_stats,
    // user_recipes): leer — _safeLoad/maybeSingle behandeln das als "nichts
    // da", der Boot bleibt gruen.
    if (req.method == 'GET') return ok(const <dynamic>[]);
    // Uebrige Writes (favorite_meals, user_recipes, ...): Erfolg.
    return http.Response('', 201, request: req);
  }

  Map<String, dynamic> _statsRow() => <String, dynamic>{
        'workouts_completed': 0,
        'meals_logged': mealsCounted,
        'water_total_ml': 0,
        'steps_recorded': 0,
        'weight_logs': weightLogsCounted,
        'current_streak': 1,
        'longest_streak': 1,
        'last_workout_date': null,
        'session_start': '2026-08-01T00:00:00Z',
      };

  static List<Map<String, dynamic>> _rowsOf(String body) {
    final decoded = jsonDecode(body);
    if (decoded is List) {
      return decoded
          .whereType<Map>()
          .map((m) => m.cast<String, dynamic>())
          .toList();
    }
    if (decoded is Map) return [decoded.cast<String, dynamic>()];
    return const [];
  }

  static String? _eqParam(http.Request req, String key) {
    final raw = req.url.queryParameters[key];
    if (raw == null) return null;
    return raw.startsWith('eq.') ? raw.substring(3) : raw;
  }
}

class _SnackCapture {
  final List<String> messages = <String>[];
  final List<Color> accents = <Color>[];

  void call(
    String message, {
    IconData icon = Icons.info_outline,
    Color accent = Colors.white,
    Duration? duration,
    SnackBarAction? action,
  }) {
    messages.add(message);
    accents.add(accent);
  }

  Iterable<String> get offlineHints =>
      messages.where((m) => m.startsWith('Offline'));
}

({
  HomeStore store,
  _FakeServer server,
  LocalCache cache,
  _SnackCapture snacks,
}) _setup({InMemoryKeyValueStore? kv}) {
  final server = _FakeServer();
  final client = SupabaseClient(
    'https://example.supabase.co',
    'test-anon-key',
    httpClient: server.client(),
    // Kein GoTrue-Auto-Refresh-Ticker im Test (siehe clobber_guard_test).
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  addTearDown(client.dispose);
  final cache = LocalCache(kv ?? InMemoryKeyValueStore(), 'user-outbox');
  final snacks = _SnackCapture();
  final store = HomeStore(
    sync: EatovaSync.forUser(client, 'user-outbox'),
    health: const NoopHealthService(),
    notificationService: const NoopNotificationService(),
    initialUserName: 'Test',
    emitSnack: snacks.call,
    debugCache: cache,
  );
  addTearDown(store.dispose);
  return (store: store, server: server, cache: cache, snacks: snacks);
}

MealAnalysisResult _result(String name, {int kcal = 300}) =>
    MealAnalysisResult(
      mealName: name,
      caloriesKcal: kcal,
      estimatedGrams: 350,
      kcalPer100G: kcal * 100 / 350,
      protein: '30 g',
      carbs: '40 g',
      fat: '10 g',
      confidence: 'Hoch',
      portionNotes: 'Test.',
      sourceLabel: 'Foto-KI',
    );

Map<String, dynamic> _serverMealRow(String id, {int kcal = 250}) =>
    <String, dynamic>{
      'id': id,
      'logged_at': DateTime.now().toUtc().toIso8601String(),
      'forced_slot': null,
      'local_day': null,
      'payload': mealResultToJson(_result('Server-Gericht', kcal: kcal)),
    };

Future<void> _settle() => pumpEventQueue(times: 60);

Future<void> _boot(HomeStore store) async {
  store.start();
  await store.profileReady;
  await _settle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'Offline-Log: KEIN Rollback, Op persistiert in der Outbox, '
      'dezenter Hinweis statt rotem Sync-Fehler', () async {
    final s = _setup();
    s.server.offline = true;
    await _boot(s.store);

    final id = s.store.addResultToDailyTotal(_result('Offline-Bowl'));
    await _settle();

    // Der Eintrag des Nutzers bleibt stehen — frueher war er hier WEG.
    expect(s.store.loggedMeals.map((m) => m.id), contains(id));
    expect(s.store.dailyConsumedKcal, 300);

    // Insert (und der Auto-Recent-Favorit) haengen als Ops in der Outbox …
    expect(s.store.pendingOutbox.map((o) => o.kind),
        contains(SyncOpKind.mealInsert));
    // … und zwar PERSISTIERT (App-Kill-sicher).
    final persisted = await s.cache.readOutbox();
    expect(persisted!.map((o) => o.kind), contains(SyncOpKind.mealInsert));

    // UI-Feedback: dezenter deutscher Hinweis, kein roter "Sync (...)"-Toast,
    // und trotz mehrerer fehlgeschlagener Ops nur EIN Hinweis pro Episode.
    expect(s.snacks.messages.where((m) => m.startsWith('Sync (')), isEmpty);
    expect(s.snacks.offlineHints, hasLength(1));
    expect(s.snacks.offlineHints.single,
        'Offline — wird synchronisiert, sobald du wieder online bist.');
    final accent = s.snacks.accents[
        s.snacks.messages.indexWhere((m) => m.startsWith('Offline'))];
    expect(accent, isNot(danger), reason: 'kein Rot-Alarm');
  });

  test(
      'Server-Fehler (500) statt Netz weg: Op queued wie gehabt, aber der '
      'Hinweis ist die neutrale Retry-Meldung — kein "Offline", keine '
      'Roh-Details', () async {
    final s = _setup();
    await _boot(s.store);
    // Server erreichbar, aber logged_meals-Writes werden abgelehnt (der
    // Postgrest-500/Constraint-Fall) -> im Store kommt eine
    // PostgrestException an, KEIN Netzwerkfehler.
    s.server.rejectMealWrites = true;

    final id = s.store.addResultToDailyTotal(_result('Constraint-Bowl'));
    await _settle();

    // Verhalten wie offline: kein Rollback, Op haengt in der Outbox.
    expect(s.store.loggedMeals.map((m) => m.id), contains(id));
    expect(s.store.pendingOutbox.map((o) => o.kind),
        contains(SyncOpKind.mealInsert));

    // Aber der Text luegt nicht: "Offline" waere falsch (der Server hat ja
    // geantwortet) — stattdessen die freundliche Retry-Meldung, einmal pro
    // Episode.
    expect(s.snacks.offlineHints, isEmpty);
    expect(
      s.snacks.messages.where((m) =>
          m ==
          'Änderung konnte nicht gespeichert werden — wird automatisch erneut versucht.'),
      hasLength(1),
    );

    // Schema-Leakage-Guard: kein Snack traegt Roh-Fehlertext oder
    // Tabellen-/Exception-Namen.
    for (final m in s.snacks.messages) {
      expect(m, isNot(contains('PostgrestException')));
      expect(m, isNot(contains('logged_meals')));
      expect(m, isNot(contains('kaputt')));
      expect(m, isNot(startsWith('Sync (')));
    }
  });

  test(
      'Replay nach Reconnect: Insert+Update koalesziert zu EINEM Upsert '
      '(neuester Payload), Stats zaehlen genau 1 Mahlzeit', () async {
    final s = _setup();
    await _boot(s.store);
    s.server.offline = true;

    final id = s.store.addResultToDailyTotal(_result('Bowl'));
    await _settle();
    s.store.updateLoggedMealResult(id, _result('Bowl', kcal: 500));
    await _settle();

    // Koalesziert: genau EIN Meal-Op, Kind bleibt mealInsert (Stats!),
    // Payload traegt den neuesten Stand.
    final mealOps = s.store.pendingOutbox
        .where((o) => o.entityKey == 'meal:$id')
        .toList();
    expect(mealOps, hasLength(1));
    expect(mealOps.single.kind, SyncOpKind.mealInsert);
    expect(mealOps.single.meal!.result.caloriesKcal, 500);

    // Wieder online: Lifecycle-Flush spielt die Outbox nach.
    s.server.offline = false;
    s.store.flushPendingWrites();
    await _settle();

    expect(s.store.pendingOutbox, isEmpty);
    expect(await s.cache.readOutbox(), isEmpty);
    expect(s.server.mealRows, hasLength(1));
    final row = s.server.mealRows[id]!;
    expect(row['calories_kcal'], 500);
    expect((row['payload'] as Map)['caloriesKcal'], 500);

    // Genau EIN logged_meals-POST hat den Server erreicht — mit
    // Upsert-Semantik (Idempotenz-Schluessel: Client-UUID).
    final posts = s.server.requests
        .where((r) =>
            r.method == 'POST' && r.url.path.contains('/logged_meals'))
        .toList();
    expect(posts, hasLength(1));
    expect(posts.single.headers['Prefer'], contains('resolution=merge-duplicates'));

    // Stats: der nachgeholte Erst-Insert zaehlt genau 1 Mahlzeit.
    s.store.flushPendingWrites(); // Debounce-Fenster der Delta-Queue abkuerzen
    await _settle();
    expect(s.server.mealsCounted, 1);
  });

  test(
      'Gewicht: unklarer Timeout + Retry schreiben dieselbe Client-UUID '
      '-> Upsert, KEIN Duplikat', () async {
    final s = _setup();
    await _boot(s.store);

    // Unklarer Ausgang: Server wendet den Write an, antwortet aber 500.
    s.server.ambiguousWrites = true;
    s.store.logWeight(80.5);
    await _settle();

    // Kein Rollback: der Messpunkt bleibt lokal.
    expect(s.store.weightLog.latest?.weightKg, 80.5);
    final op = s.store.pendingOutbox
        .singleWhere((o) => o.kind == SyncOpKind.weightInsert);
    expect(s.server.weightRows, hasLength(1),
        reason: 'der erste Versuch hat die Zeile bereits geschrieben');

    // Retry: gleiche id -> Upsert ueberschreibt statt zu duplizieren.
    s.server.ambiguousWrites = false;
    s.store.flushPendingWrites();
    await _settle();

    expect(s.store.pendingOutbox, isEmpty);
    expect(s.server.weightRows, hasLength(1));
    expect(s.server.weightRows.keys.single, op.entityId);
    final posts = s.server.requests
        .where(
            (r) => r.method == 'POST' && r.url.path.contains('/weight_log'))
        .toList();
    expect(posts, hasLength(2));
    for (final post in posts) {
      expect(post.headers['Prefer'], contains('resolution=merge-duplicates'));
      expect(_FakeServer._rowsOf(post.body).single['id'], op.entityId);
    }
  });

  test('Kaltstart OHNE Netz: Tagebuch kommt aus dem Cache', () async {
    final kv = InMemoryKeyValueStore();

    // Session 1 (online): Mahlzeit loggen — Write-Through in den Cache.
    final a = _setup(kv: kv);
    await _boot(a.store);
    a.store.addResultToDailyTotal(_result('Gestern-online-Bowl'));
    await _settle();

    // Session 2 (Kaltstart offline): Tagebuch ist sofort da statt leer.
    final b = _setup(kv: kv);
    b.server.offline = true;
    await _boot(b.store);

    expect(b.store.loggedMeals, hasLength(1));
    expect(b.store.loggedMeals.single.result.mealName, 'Gestern-online-Bowl');
    expect(b.store.dailyConsumedKcal, 300);
  });

  test(
      'Boot-Merge: Outbox-Eintrag ueberlebt den Server-Refresh und wird '
      'beim Boot nachgespielt', () async {
    final kv = InMemoryKeyValueStore();

    // Session 1: offline geloggt -> Op + Tagebuch liegen persistiert.
    final a = _setup(kv: kv);
    await _boot(a.store);
    a.server.offline = true;
    final id = a.store.addResultToDailyTotal(_result('Offline-Bowl'));
    await _settle();
    expect((await a.cache.readOutbox())!, isNotEmpty);

    // Session 2: Server kennt bereits eine ANDERE Mahlzeit. Der Boot spielt
    // die Outbox nach und laedt dann — beide Eintraege sind im State UND auf
    // dem Server, nichts geht verloren.
    final b = _setup(kv: kv);
    b.server.mealRows['srv-1'] = _serverMealRow('srv-1');
    await _boot(b.store);

    expect(b.store.loggedMeals.map((m) => m.id), containsAll([id, 'srv-1']));
    expect(b.server.mealRows.keys, containsAll([id, 'srv-1']));
    expect(
      b.store.pendingOutbox.where((o) => o.entityKey == 'meal:$id'),
      isEmpty,
      reason: 'der Boot-Replay hat die Op abgearbeitet',
    );
  });

  test('Pendende Stats-Deltas ueberleben den App-Neustart', () async {
    final kv = InMemoryKeyValueStore();

    // Session 1: Meal-Sync ok, aber der Stats-RPC faellt aus -> Delta bleibt
    // persistiert liegen (frueher: bei App-Kill verloren).
    final a = _setup(kv: kv);
    await _boot(a.store);
    a.server.statsOffline = true;
    a.store.addResultToDailyTotal(_result('Bowl'));
    await _settle();
    a.store.flushPendingWrites();
    await _settle();

    expect(a.server.mealsCounted, 0);
    final pending = await a.cache.readPendingStatsDeltas();
    expect(pending, isNotNull);
    expect(pending!.meals, 1);

    // Session 2 (Neustart, RPC gesund): der Boot flusht die Deltas nach.
    final b = _setup(kv: kv);
    await _boot(b.store);

    expect(b.server.mealsCounted, 1);
    final after = await b.cache.readPendingStatsDeltas();
    expect(after!.meals, 0, reason: 'Delta wurde verbucht, nicht dupliziert');
  });

  test(
      'Blockierte Entitaet (Meal-Write faellt weiter aus) haelt andere '
      'Entitaeten nicht auf', () async {
    final s = _setup();
    await _boot(s.store);
    s.server.offline = true;

    final mealId = s.store.addResultToDailyTotal(_result('Bowl'));
    s.store.logWeight(80.5);
    await _settle();
    expect(s.store.pendingOutbox.length, greaterThanOrEqualTo(2));

    // Netz zurueck, aber logged_meals-Writes werden weiter abgelehnt.
    s.server.offline = false;
    s.server.rejectMealWrites = true;
    s.store.flushPendingWrites();
    await _settle();

    // Gewicht (und Favorit) sind durch, die Meal-Op bleibt liegen …
    expect(s.server.weightRows, hasLength(1));
    expect(
      s.store.pendingOutbox.map((o) => o.kind),
      [SyncOpKind.mealInsert],
    );
    // … und der lokale Eintrag steht weiterhin im Tagebuch (kein Rollback).
    expect(s.store.loggedMeals.map((m) => m.id), contains(mealId));

    // Sobald der Server das Meal akzeptiert, raeumt der naechste Flush auf.
    s.server.rejectMealWrites = false;
    s.store.flushPendingWrites();
    await _settle();
    expect(s.store.pendingOutbox, isEmpty);
    expect(s.server.mealRows.keys, contains(mealId));
  });
}
