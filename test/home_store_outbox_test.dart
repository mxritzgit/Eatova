import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/local_day.dart';
import 'package:eatova/src/services/meals_sync.dart' show mealResultToJson;
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/services/sync_error_messages.dart'
    show outboxDeleteLossHint, outboxLossHint;
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
//   9. Gift-Ops (Check-Constraint) werden beim ersten Replay verworfen statt
//      ewig retryt; 500er verbrennen nur Budget; Netzfehler kosten NICHTS;
//      attempts ueberleben den App-Neustart.
//  10. Die Queue ist gedeckelt — beim Einreihen UND beim Hydrieren.

/// Zustandsbehafteter Fake-PostgREST: zeichnet Requests auf, fuehrt Upserts/
/// Deletes auf In-Memory-Tabellen aus und laesst sich offline schalten.
class _FakeServer {
  /// Alles faellt aus (Netz weg). Requests werden dann NICHT aufgezeichnet —
  /// [requests] enthaelt nur, was den "Server" wirklich erreicht hat.
  bool offline = false;

  /// Nur increment_lifetime_stats faellt aus (Stats-Delta-Szenarien).
  bool statsOffline = false;

  /// Nur logged_meals-Writes fallen aus (Poison-Entity-Szenario) — als 500,
  /// also ein RETRYBARER Fehler.
  bool rejectMealWrites = false;

  /// logged_meals-Writes werden dauerhaft und aussichtslos abgelehnt:
  /// payload-determinierte Constraint-Verletzung. Realistische Wire-Form —
  /// HTTP 400, aber im Body steht der SQLSTATE, und GENAU DER landet in
  /// `PostgrestException.code` (der Status ist dort NICHT sichtbar, weil
  /// `fromJson` `json['code'] ?? '$statusCode'` macht).
  bool poisonMealWrites = false;

  /// SQLSTATE der Gift-Antwort. Default 23502 (not_null_violation) — der
  /// bleibt ein SOFORT-Verwurf. 23514 (check_violation) taugt dafuer bewusst
  /// nicht mehr: das ist der Normalfall einer Nutzereingabe und laeuft seit
  /// dem Review 2026-08-08 ins Versuchs-Budget statt in den Muell.
  String poisonCode = '23502';

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
    // Constraint-Verletzung: der Body traegt den SQLSTATE, deshalb ist
    // PostgrestException.code hinterher '$poisonCode' und NICHT '400'.
    // (Body bewusst rein ASCII — http.Response kodiert den String nach der
    // Charset-Angabe des Content-Type, Default latin1, und wirft sonst
    // ArgumentError statt die Antwort zu liefern.)
    http.Response poison() => http.Response(
        jsonEncode({
          'code': poisonCode,
          'message': 'null value in column "payload" of relation '
              '"logged_meals" violates not-null constraint',
          'details': 'Failing row contains (...).',
          'hint': null,
        }),
        400,
        headers: const {'Content-Type': 'application/json'},
        request: req);

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
      if (poisonMealWrites && req.method != 'GET') return poison();
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
    // App wird beendet. Seit G9b sind die Tagebuch-Writes entprellt (400 ms),
    // damit eine Fuenfer-Serie den Blob nicht fuenfmal verschluesselt. Der
    // Lifecycle-Uebergang paused|hidden|detached ruft flushPendingWrites()
    // (eatova_home_page.dart) und erzwingt sie — genau das wird hier
    // modelliert. Ohne diese Zeile prueft der Test nicht "Cache ueberlebt den
    // Neustart", sondern "Cache ist innerhalb von 400 ms schon geschrieben".
    a.store.flushPendingWrites();
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

  test(
      'Bearbeiten (Slot+Tag) offline: Aenderung landet als mealUpsert in der '
      'Outbox, der Replay schreibt logged_at/local_day/forced_slot — und '
      'zaehlt KEINE neue Mahlzeit', () async {
    final s = _setup();
    await _boot(s.store);

    final id = s.store.addResultToDailyTotal(_result('Bowl'));
    await _settle();
    expect(s.server.mealRows.keys, contains(id));

    // Netz weg — dann im Bearbeiten-Sheet Slot + Tag aendern.
    s.server.offline = true;
    final yesterday =
        DateUtils.dateOnly(DateTime.now()).subtract(const Duration(days: 1));
    s.store.updateLoggedMealDetails(id, slot: MealSlot.snack, day: yesterday);
    await _settle();

    // Kein Rollback: der lokale Stand traegt die Aenderung sofort.
    final local = s.store.loggedMeals.singleWhere((m) => m.id == id);
    expect(local.forcedSlot, MealSlot.snack);
    expect(local.localDay, localDayKey(yesterday));

    // Genau EINE mealUpsert-Op mit dem vollen neuen Stand haengt in der Queue.
    final ops = s.store.pendingOutbox
        .where((o) => o.entityKey == 'meal:$id')
        .toList();
    expect(ops, hasLength(1));
    expect(ops.single.kind, SyncOpKind.mealUpsert);
    final queued = ops.single.meal!;
    expect(queued.forcedSlot, MealSlot.snack);
    expect(queued.localDay, localDayKey(yesterday));

    // Wieder online: Replay schreibt die verschobene Zeile idempotent.
    s.server.offline = false;
    s.store.flushPendingWrites();
    await _settle();

    expect(s.store.pendingOutbox, isEmpty);
    final row = s.server.mealRows[id]!;
    expect(row['forced_slot'], 'snack');
    expect(row['local_day'], localDayKey(yesterday));
    final loggedAt = DateTime.parse(row['logged_at'] as String).toLocal();
    expect(DateUtils.isSameDay(loggedAt, yesterday), isTrue);

    // Ein Edit ist KEIN neuer Log: die Lifetime-Stats zaehlen weiterhin 1.
    s.store.flushPendingWrites();
    await _settle();
    expect(s.server.mealsCounted, 1);
  });

  test(
      'Bearbeiten online: der PATCH traegt logged_at + local_day — die '
      'Tag-Verschiebung erreicht den Server auch ohne Outbox', () async {
    final s = _setup();
    await _boot(s.store);
    final id = s.store.addResultToDailyTotal(_result('Bowl'));
    await _settle();

    final yesterday =
        DateUtils.dateOnly(DateTime.now()).subtract(const Duration(days: 1));
    s.store.updateLoggedMealDetails(id, day: yesterday);
    await _settle();

    expect(s.store.pendingOutbox, isEmpty);
    final patches = s.server.requests
        .where((r) =>
            r.method == 'PATCH' && r.url.path.contains('/logged_meals'))
        .toList();
    expect(patches, hasLength(1));
    final row = s.server.mealRows[id]!;
    expect(row['local_day'], localDayKey(yesterday));
    final loggedAt = DateTime.parse(row['logged_at'] as String).toLocal();
    expect(DateUtils.isSameDay(loggedAt, yesterday), isTrue);
  });

  // --- Gift-Ops, Versuchs-Budget, Queue-Cap ---------------------------------

  test(
      'Gift-Op (23502 not_null_violation) wird beim ERSTEN Replay verworfen, '
      'verschwindet aus der persistierten Queue und meldet sich GENAU EINMAL',
      () async {
    final s = _setup();
    await _boot(s.store);
    s.server.poisonMealWrites = true;

    final id = s.store.addResultToDailyTotal(_result('Kaputt-Bowl'));
    await _settle();

    // Der Live-Write klassifiziert nicht — die Op landet erstmal in der Queue.
    expect(s.store.pendingOutbox.map((o) => o.entityKey),
        contains('meal:$id'));

    s.store.flushPendingWrites();
    await _settle();

    // EIN Replay reicht: die Op ist weg, aus dem Speicher UND vom Blob.
    expect(s.store.pendingOutbox.where((o) => o.entityKey == 'meal:$id'),
        isEmpty);
    final persisted = await s.cache.readOutbox();
    expect(persisted!.where((o) => o.entityKey == 'meal:$id'), isEmpty);

    // Genau EIN Verlust-Hinweis, auch nach weiteren Flush-Runden.
    s.store.flushPendingWrites();
    await _settle();
    expect(s.snacks.messages.where((m) => m == outboxLossHint), hasLength(1));

    // Schema-Leakage-Guard: kein Snack traegt SQLSTATE, Tabellen-/
    // Constraint-Namen oder Exception-Typen.
    for (final m in s.snacks.messages) {
      expect(m, isNot(contains('23502')));
      expect(m, isNot(contains('logged_meals')));
      expect(m, isNot(contains('not-null constraint')));
      expect(m, isNot(contains('PostgrestException')));
    }
  });

  test(
      '500 verbrennt Versuche, wird aber NICHT vorzeitig verworfen — '
      'Erholung vor dem Budget-Ende synchronisiert normal', () async {
    final s = _setup();
    await _boot(s.store);
    s.server.rejectMealWrites = true;

    final id = s.store.addResultToDailyTotal(_result('Flaky-Bowl'));
    await _settle();
    expect(
        s.store.pendingOutbox
            .singleWhere((o) => o.entityKey == 'meal:$id')
            .attempts,
        0,
        reason: 'der Live-Versuch zaehlt nicht, erst der Replay');

    for (var i = 0; i < 3; i++) {
      s.store.flushPendingWrites();
      await _settle();
    }

    final op =
        s.store.pendingOutbox.singleWhere((o) => o.entityKey == 'meal:$id');
    expect(op.attempts, 3);
    expect(s.snacks.messages.where((m) => m == outboxLossHint), isEmpty,
        reason: 'ein 500 ist kein Grund, Nutzerdaten wegzuwerfen');

    // Server erholt sich rechtzeitig -> ganz normaler Sync.
    s.server.rejectMealWrites = false;
    s.store.flushPendingWrites();
    await _settle();

    expect(s.store.pendingOutbox, isEmpty);
    expect(s.server.mealRows.keys, contains(id));
  });

  test(
      'Netzwerkfehler verbrennen NIE Versuche: 3x das ganze Budget offline '
      'durchspielen laesst die Op unangetastet', () async {
    final s = _setup();
    await _boot(s.store);
    s.server.offline = true;

    final id = s.store.addResultToDailyTotal(_result('Offline-Bowl'));
    await _settle();

    for (var i = 0; i < kOutboxMaxAttempts * 3; i++) {
      s.store.flushPendingWrites();
      await _settle();
    }

    final op =
        s.store.pendingOutbox.singleWhere((o) => o.entityKey == 'meal:$id');
    expect(op.attempts, 0,
        reason: 'ein Offline-Wochenende darf kein Budget kosten');
    expect(s.snacks.messages.where((m) => m == outboxLossHint), isEmpty);

    // Wieder online -> die Mahlzeit ist vollstaendig da.
    s.server.offline = false;
    s.store.flushPendingWrites();
    await _settle();

    expect(s.store.pendingOutbox, isEmpty);
    expect(s.server.mealRows.keys, contains(id));
  });

  test('attempts ueberleben den App-Neustart (sonst waere Gift unsterblich)',
      () async {
    final kv = InMemoryKeyValueStore();

    // Session 1: zwei Replays gegen einen 500er -> Zaehler steht auf 2.
    final a = _setup(kv: kv);
    await _boot(a.store);
    a.server.rejectMealWrites = true;
    final id = a.store.addResultToDailyTotal(_result('Zaeh-Bowl'));
    await _settle();
    for (var i = 0; i < 2; i++) {
      a.store.flushPendingWrites();
      await _settle();
    }
    expect(
        a.store.pendingOutbox
            .singleWhere((o) => o.entityKey == 'meal:$id')
            .attempts,
        2);
    expect(
        (await a.cache.readOutbox())!
            .singleWhere((o) => o.entityKey == 'meal:$id')
            .attempts,
        2,
        reason: 'der Zaehler muss PERSISTIERT sein');

    // Session 2 (Neustart, Server weiter kaputt): der Boot-Replay zaehlt
    // WEITER statt bei 0 zu beginnen — ein Crash-Loop macht Gift sonst
    // unsterblich.
    final b = _setup(kv: kv);
    b.server.rejectMealWrites = true;
    await _boot(b.store);

    expect(
        b.store.pendingOutbox
            .singleWhere((o) => o.entityKey == 'meal:$id')
            .attempts,
        3);
  });

  test(
      'Queue-Cap: eine Offline-Flut sprengt die persistierte Outbox nicht — '
      'das Neueste bleibt, das Aelteste faellt raus', () async {
    final s = _setup();
    await _boot(s.store);
    s.server.offline = true;

    final ids = <String>[];
    for (var i = 0; i < kOutboxMaxOps + 5; i++) {
      ids.add(s.store.addResultToDailyTotal(_result('Bowl')));
    }
    await pumpEventQueue(times: 200);

    expect(s.store.pendingOutbox.length, lessThanOrEqualTo(kOutboxMaxOps));
    final keys = s.store.pendingOutbox.map((o) => o.entityKey).toSet();
    expect(keys, contains('meal:${ids.last}'),
        reason: 'worauf der User gerade schaut, bleibt');
    expect(keys, isNot(contains('meal:${ids.first}')),
        reason: 'die aelteste Op ist die wahrscheinlichste Leiche');

    final persisted = await s.cache.readOutbox();
    expect(persisted!.length, lessThanOrEqualTo(kOutboxMaxOps));

    // Der Verlust wird gemeldet — aber nur EINMAL, nicht 5x.
    expect(s.snacks.messages.where((m) => m == outboxLossHint), hasLength(1));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test(
      'Hydrations-Cap: eine von einem alten, ungedeckelten Build gewachsene '
      'Queue wird beim Boot gekappt', () async {
    final kv = InMemoryKeyValueStore();
    // Direkt in den Cache schreiben — dieser Pfad laeuft NIE durch das
    // Einreihen, der Cap muss hier trotzdem greifen.
    final seed = LocalCache(kv, 'user-outbox');
    // Bewusst SCHREIB-Ops: Deletes sind seit dem Review 2026-08-08 vom Cap
    // ausgenommen (ein verworfener Delete laesst die geloeschte Mahlzeit beim
    // naechsten Boot vom Server zurueckkehren), eine reine Delete-Queue wuerde
    // hier also gar nicht gekappt.
    await seed.writeOutbox(<SyncOp>[
      for (var i = 0; i < kOutboxMaxOps + 100; i++)
        SyncOp.weightInsert(
          id: 'legacy-$i',
          weightKg: 80,
          recordedAt: DateTime(2026, 8, 1).add(Duration(minutes: i)),
        ),
    ]);

    final s = _setup(kv: kv);
    // Offline, damit der Boot-Replay die Queue nicht einfach leerraeumt und
    // der Test dadurch vakuum-gruen wird.
    s.server.offline = true;
    await _boot(s.store);

    expect(s.store.pendingOutbox, hasLength(kOutboxMaxOps));
    expect(s.store.pendingOutbox.map((o) => o.entityId),
        isNot(contains('legacy-0')));
    expect(s.store.pendingOutbox.last.entityId,
        'legacy-${kOutboxMaxOps + 99}');
  }, timeout: const Timeout(Duration(minutes: 3)));

  // --- Review 2026-08-08: A4 (Budget), A6 (Waise), A8 (korrupte Payload),
  //     A2 (Logout) -----------------------------------------------------------

  test(
      'A4: Lifecycle-Churn frisst das Versuchs-Budget nicht mehr auf — 12 '
      'Durchlaeufe in Sekunden lassen die Op stehen', () async {
    final s = _setup();
    await _boot(s.store);
    // Kurzer Server-Ausfall mit schnellen 500ern.
    s.server.rejectMealWrites = true;

    final id = s.store.addResultToDailyTotal(_result('Ausfall-Bowl'));
    await _settle();

    // Ein App-Wechsel loest bis zu 4 flushPendingWrites aus (inactive ->
    // hidden -> paused beim Wegschalten, hidden -> inactive -> resumed
    // zurueck). Drei App-Wechsel waehrend eines 5-Minuten-Ausfalls = 12
    // Durchlaeufe in wenigen Sekunden. Frueher war die Mahlzeit ab dem 8.
    // Durchlauf DAUERHAFT weg.
    for (var i = 0; i < 12; i++) {
      s.store.flushPendingWrites();
      await _settle();
    }

    expect(
      s.store.pendingOutbox.where((o) => o.entityKey == 'meal:$id'),
      hasLength(1),
      reason: 'Wanduhrzeit entscheidet, nicht die Zahl der Durchlaeufe',
    );
    expect(s.snacks.messages.where((m) => m == outboxLossHint), isEmpty);

    // Der Ausfall geht vorbei — die Mahlzeit landet ganz normal.
    s.server.rejectMealWrites = false;
    s.store.flushPendingWrites();
    await _settle();
    expect(s.store.pendingOutbox, isEmpty);
    expect(s.server.mealRows.keys, contains(id));
  });

  test(
      'A4: das Budget ist trotzdem eine Notbremse — eine seit ueber 24 h '
      'abgelehnte Op wird verworfen', () async {
    final kv = InMemoryKeyValueStore();
    final meal = LoggedMeal(
      id: 'm-uralt',
      result: _result('Uralt-Bowl'),
      loggedAt: DateTime.now(),
    );
    await _seedRawOutbox(kv, [
      SyncOp.mealInsert(meal, trackDay: false).toJson()
        ..['queued_at'] = DateTime.now()
            .subtract(const Duration(hours: 25))
            .toIso8601String()
        ..['attempts'] = kOutboxMaxAttempts - 1,
    ]);

    final s = _setup(kv: kv);
    s.server.rejectMealWrites = true;
    await _boot(s.store);

    expect(s.store.pendingOutbox.where((o) => o.entityKey == 'meal:m-uralt'),
        isEmpty);
    expect(s.snacks.messages.where((m) => m == outboxLossHint), hasLength(1));
  });

  test(
      'A6: nach einem Verwurf ist die Entitaet nicht verwaist — die naechste '
      'Aenderung laeuft als frischer Upsert statt als 0-Zeilen-PATCH',
      () async {
    final s = _setup();
    await _boot(s.store);
    s.server.poisonMealWrites = true;

    final id = s.store.addResultToDailyTotal(_result('Waisen-Bowl'));
    await _settle();
    s.store.flushPendingWrites();
    await _settle();

    // Vorbedingung: Op verworfen, Mahlzeit lokal noch sichtbar, serverseitig
    // existiert sie NICHT.
    expect(
        s.store.pendingOutbox.where((o) => o.entityKey == 'meal:$id'), isEmpty);
    expect(s.store.loggedMeals.map((m) => m.id), contains(id));
    expect(s.server.mealRows.keys, isNot(contains(id)));
    expect(s.snacks.messages.where((m) => m == outboxLossHint), hasLength(1));

    // Server ist wieder gesund, der Nutzer korrigiert die Portion.
    s.server.poisonMealWrites = false;
    s.store.updateLoggedMealResult(id, _result('Waisen-Bowl', kcal: 500));
    await _settle();

    // Frueher: ein PATCH auf 0 Zeilen. Der ist ein 204, also KEIN Fehler —
    // _onSyncSuccess feuerte, der Nutzer sah nichts, und die Mahlzeit war beim
    // naechsten Kaltstart weg.
    expect(
      s.server.requests.where(
          (r) => r.method == 'PATCH' && r.url.path.contains('/logged_meals')),
      isEmpty,
      reason: 'kein PATCH auf eine Zeile, die es serverseitig nicht gibt',
    );

    s.store.flushPendingWrites();
    await _settle();

    expect(s.server.mealRows.keys, contains(id),
        reason: 'der Upsert-Weg repariert die Entitaet');
    expect(s.server.mealRows[id]!['calories_kcal'], 500);
    expect(s.store.pendingOutbox, isEmpty);
  });

  test(
      'A8: eine korrupte Payload verschwindet nicht als "Erfolg", sondern '
      'laeuft ueber den Verwurfs-Pfad', () async {
    final kv = InMemoryKeyValueStore();
    await _seedRawOutbox(kv, [
      <String, dynamic>{
        'kind': 'mealInsert',
        'entity_id': 'm-korrupt',
        'queued_at': DateTime.now().toIso8601String(),
        // Nicht-Map-Payload: SyncOp.tryFromJson BEHAELT die Op und setzt {}
        // ein — genau so ist der Pfad erreichbar.
        'payload': 'kaputt',
      },
    ]);

    final s = _setup(kv: kv);
    await _boot(s.store);

    // Die Op ist weg (sie ist unzustellbar) …
    expect(s.store.pendingOutbox, isEmpty);
    // … sie hat den Server nie erreicht …
    expect(
      s.server.requests.where(
          (r) => r.method == 'POST' && r.url.path.contains('/logged_meals')),
      isEmpty,
    );
    // … und der Nutzer erfaehrt davon. Frueher war das der EINZIGE Verlustpfad
    // ohne Snack, ohne Breadcrumb, ohne Crash-Report.
    expect(s.snacks.messages.where((m) => m == outboxLossHint), hasLength(1));
  });

  test(
      'A2: Ausloggen mit ungesyncten Ops — was der Zustellversuch nicht '
      'losgeworden ist, ueberlebt den Logout', () async {
    final s = _setup();
    await _boot(s.store);
    s.server.offline = true;

    final id = s.store.addResultToDailyTotal(_result('Flugzeug-Bowl'));
    await _settle();
    expect((await s.cache.readOutbox())!, isNotEmpty);
    expect(await s.cache.readProfile(), isNotNull);

    await s.store.signOutCleanup();

    // Die sechs Mahlzeiten aus dem Flugzeug sind NICHT weg …
    final surviving = await s.cache.readOutbox();
    expect(surviving, isNotNull);
    expect(surviving!.map((o) => o.entityKey), contains('meal:$id'));
    // … der uebrige PII-Cache dagegen schon (Audit M-1 bleibt erfuellt).
    expect(await s.cache.readProfile(), isNull);
    expect(await s.cache.readLoggedMeals(), isNull);
    expect(await s.cache.readWeightLog(), isNull);
    expect(await s.cache.readFavorites(), isNull);
  });

  // --- Verifikation V1 (Welle 6): Restluecken aus A2/A4/A5 ------------------

  test(
      'L1: ein Delete gegen einen kalten Schema-Cache (400/SQLSTATE) wird '
      'NICHT sofort verworfen — die Mahlzeit bleibt geloescht', () async {
    final s = _setup();
    await _boot(s.store);
    final id = s.store.addResultToDailyTotal(_result('Fehlscan-Bowl'));
    await _settle();
    expect(s.server.mealRows.keys, contains(id),
        reason: 'Vorbedingung: die Zeile steht auf dem Server');

    // Migration laeuft, der Schema-Cache ist kalt: JEDER logged_meals-Write —
    // auch der DELETE — kommt als 400 mit SQLSTATE im Body zurueck.
    s.server.poisonMealWrites = true;
    s.store.removeLoggedMeal(id);
    await _settle();
    for (var i = 0; i < 5; i++) {
      s.store.flushPendingWrites();
      await _settle();
    }

    // Frueher: Sofort-Verwurf beim ersten Replay. Die Serverzeile blieb, der
    // lokale Zustand nicht — der naechste Kaltstart holte die 1800 kcal
    // zurueck, ohne dass irgendetwas davon erzaehlt haette.
    expect(s.store.pendingOutbox.map((o) => o.entityKey), contains('meal:$id'),
        reason: 'die Loeschung darf nicht am Code-Verdikt sterben');
    expect(s.server.mealRows.keys, contains(id));
    expect(s.snacks.messages.where((m) => m == outboxLossHint), isEmpty);
    expect(s.snacks.messages.where((m) => m == outboxDeleteLossHint), isEmpty);

    // Die Migration ist durch: die Loeschung geht ganz normal raus.
    s.server.poisonMealWrites = false;
    s.store.flushPendingWrites();
    await _settle();
    expect(s.store.pendingOutbox, isEmpty);
    expect(s.server.mealRows.keys, isNot(contains(id)));
  });

  test(
      'L2: ein endgueltig gescheiterter Delete blendet die Mahlzeit lokal '
      'wieder ein und sagt es — statt sie still auferstehen zu lassen',
      () async {
    final kv = InMemoryKeyValueStore();
    // Ein Delete am Ende seines (grossen) Budgets und seiner Frist.
    await _seedRawOutbox(kv, [
      SyncOp.mealDelete('m-geist').toJson()
        ..['queued_at'] = DateTime.now()
            .subtract(kOutboxDeleteMinAge + const Duration(hours: 1))
            .toIso8601String()
        ..['attempts'] = kOutboxDeleteMaxAttempts - 1,
    ]);

    final s = _setup(kv: kv);
    // Boot offline: der Replay ist gratis (Netzfehler), die Op bleibt liegen,
    // und der Boot-Load bringt die Mahlzeit NICHT mit — nur so beweist der
    // Test hinterher die Wiedereinblendung und nicht den Boot.
    s.server.offline = true;
    await _boot(s.store);
    expect(s.store.pendingOutbox, hasLength(1));
    expect(s.store.loggedMeals, isEmpty);

    // Netz zurueck, die Zeile steht serverseitig weiterhin (1800 kcal), und
    // der Delete scheitert weiter.
    s.server.offline = false;
    s.server.mealRows['m-geist'] = _serverMealRow('m-geist', kcal: 1800);
    s.server.poisonMealWrites = true;
    s.store.flushPendingWrites();
    await _settle();

    // Die Op ist weg — die Queue laeuft wieder leer (sonst: 4-Minuten-Timer
    // ohne Ende, Cap ausgehebelt, preserveOutbox fuer immer true).
    expect(s.store.pendingOutbox, isEmpty);
    expect((await s.cache.readOutbox())!, isEmpty);
    // … und die Mahlzeit ist wieder sichtbar, samt ihrer Kalorien.
    expect(s.store.loggedMeals.map((m) => m.id), contains('m-geist'));
    expect(s.store.dailyConsumedKcal, 1800,
        reason: 'die Kalorien zaehlen wieder — das darf nicht unsichtbar sein');
    // … und der Nutzer erfaehrt, was zu tun ist.
    expect(s.snacks.messages.where((m) => m == outboxDeleteLossHint),
        hasLength(1));
    for (final m in s.snacks.messages) {
      expect(m, isNot(contains('logged_meals')));
      expect(m, isNot(contains('23502')));
      expect(m, isNot(contains('PostgrestException')));
    }
  });

  test(
      'L2: der Nutzer kann die wieder eingeblendete Mahlzeit erneut loeschen '
      '— frisches Budget, frische Frist', () async {
    final kv = InMemoryKeyValueStore();
    await _seedRawOutbox(kv, [
      SyncOp.mealDelete('m-geist').toJson()
        ..['queued_at'] = DateTime.now()
            .subtract(kOutboxDeleteMinAge + const Duration(hours: 1))
            .toIso8601String()
        ..['attempts'] = kOutboxDeleteMaxAttempts - 1,
    ]);
    final s = _setup(kv: kv);
    s.server.offline = true;
    await _boot(s.store);
    s.server.offline = false;
    s.server.mealRows['m-geist'] = _serverMealRow('m-geist', kcal: 1800);
    s.server.poisonMealWrites = true;
    s.store.flushPendingWrites();
    await _settle();
    expect(s.store.loggedMeals.map((m) => m.id), contains('m-geist'));

    // Migration durch — der Nutzer loescht erneut, diesmal klappt es.
    s.server.poisonMealWrites = false;
    s.store.removeLoggedMeal('m-geist');
    await _settle();
    s.store.flushPendingWrites();
    await _settle();

    expect(s.store.loggedMeals, isEmpty);
    expect(s.server.mealRows.keys, isNot(contains('m-geist')));
    expect(s.store.pendingOutbox, isEmpty);
  });

  test(
      'L2: verlorener Write UND verlorene Loeschung im selben Replay — beide '
      'Meldungen kommen, die Loeschung wird nicht verschluckt', () async {
    final kv = InMemoryKeyValueStore();
    await _seedRawOutbox(kv, [
      SyncOp.mealDelete('m-geist').toJson()
        ..['queued_at'] = DateTime.now()
            .subtract(kOutboxDeleteMinAge + const Duration(hours: 1))
            .toIso8601String()
        ..['attempts'] = kOutboxDeleteMaxAttempts - 1,
    ]);
    final s = _setup(kv: kv);
    s.server.offline = true;
    await _boot(s.store);

    // Online, Server vergiftet: der frische Write stirbt als Gift-Op (23502),
    // der alte Delete an Budget + Frist — beides in EINEM Replay.
    s.server.offline = false;
    s.server.mealRows['m-geist'] = _serverMealRow('m-geist', kcal: 1800);
    s.server.poisonMealWrites = true;
    s.store.addResultToDailyTotal(_result('Gift-Bowl'));
    await _settle();
    s.store.flushPendingWrites();
    await _settle();

    // Der Episoden-Merker darf die zweite, ANDERE Nachricht nicht schlucken:
    // beim Write fehlt etwas, bei der Loeschung ist etwas wieder da.
    expect(s.snacks.messages.where((m) => m == outboxLossHint), hasLength(1));
    expect(s.snacks.messages.where((m) => m == outboxDeleteLossHint),
        hasLength(1));
    expect(s.store.loggedMeals.map((m) => m.id), contains('m-geist'));
  });

  test(
      'Nebenbefund: die 24-h-Frist haengt an der injizierten Uhr, nicht an '
      'DateTime.now() — vorher war sie ueberhaupt nicht pruefbar', () async {
    // Referenz-Zeitpunkt weit weg von der echten Systemzeit: laeuft die Regel
    // gegen DateTime.now(), waere die Op hier IMMER 24 h alt und beide Faelle
    // fielen zusammen.
    final queuedAt = DateTime(2030, 5, 17, 8);
    Future<List<SyncOp>> runAt(DateTime now) async {
      final kv = InMemoryKeyValueStore();
      await _seedRawOutbox(kv, [
        SyncOp.mealInsert(
                LoggedMeal(
                    id: 'm-uhr', result: _result('Uhr-Bowl'), loggedAt: queuedAt),
                trackDay: false)
            .toJson()
          ..['queued_at'] = queuedAt.toIso8601String()
          ..['attempts'] = kOutboxMaxAttempts - 1,
      ]);
      return withClock(Clock.fixed(now), () async {
        final s = _setup(kv: kv);
        s.server.rejectMealWrites = true;
        await _boot(s.store);
        return s.store.pendingOutbox.toList();
      });
    }

    // 23 h nach dem Einreihen: das Budget ist aufgebraucht, die Wanduhr sagt
    // nein — die Mahlzeit bleibt.
    expect(
      (await runAt(queuedAt.add(const Duration(hours: 23))))
          .map((o) => o.entityKey),
      contains('meal:m-uhr'),
    );
    // 25 h: jetzt greift die Notbremse.
    expect(
      (await runAt(queuedAt.add(const Duration(hours: 25))))
          .map((o) => o.entityKey),
      isNot(contains('meal:m-uhr')),
    );
  });

  test(
      'L3: Ausloggen mit LEERER Outbox, aber pendenden Stats-Deltas — die '
      'Lebenszeit-Zaehler ueberleben den Logout', () async {
    final s = _setup();
    await _boot(s.store);
    // Der Mahlzeiten-Write gelingt, nur increment_lifetime_stats faellt aus:
    // eigener RPC, eigener Zustand. Die Outbox bleibt dabei LEER.
    s.server.statsOffline = true;
    s.store.addResultToDailyTotal(_result('Streak-Bowl'));
    await _settle();
    s.store.flushPendingWrites();
    await _settle();

    expect(s.store.pendingOutbox, isEmpty,
        reason: 'genau die Kombination, die A2 uebersehen hat');
    expect((await s.cache.readPendingStatsDeltas())!.meals, 1);

    await s.store.signOutCleanup();

    // Frueher haing preserveOutbox allein an _outbox.length — die Deltas
    // (Streak-Grundlage) fielen still weg.
    final surviving = await s.cache.readPendingStatsDeltas();
    expect(surviving, isNotNull);
    expect(surviving!.meals, 1);
    // Der uebrige PII-Cache faellt weiterhin (Audit M-1).
    expect(await s.cache.readProfile(), isNull);
    expect(await s.cache.readLoggedMeals(), isNull);
  });

  test(
      'L3: Ausloggen online mit pendenden Deltas — der Zustellversuch verbucht '
      'sie, danach faellt der ganze Cache (Audit M-1)', () async {
    final s = _setup();
    await _boot(s.store);
    s.server.statsOffline = true;
    s.store.addResultToDailyTotal(_result('Streak-Bowl'));
    await _settle();
    s.store.flushPendingWrites();
    await _settle();
    expect((await s.cache.readPendingStatsDeltas())!.meals, 1);

    // RPC ist wieder gesund, DANN erst der Logout.
    s.server.statsOffline = false;
    await s.store.signOutCleanup();

    expect(s.server.mealsCounted, 1, reason: 'Zustellversuch VOR dem Verwerfen');
    expect(await s.cache.readPendingStatsDeltas(), isNull);
    expect(await s.cache.readOutbox(), isNull);
    expect(await s.cache.readProfile(), isNull);
  });

  test(
      'A2: Ausloggen online — der Zustellversuch raeumt die Queue leer, danach '
      'faellt auch die Outbox', () async {
    final s = _setup();
    await _boot(s.store);
    s.server.offline = true;
    final id = s.store.addResultToDailyTotal(_result('Landung-Bowl'));
    await _settle();

    // Nach der Landung: Netz ist zurueck, DANN erst der Logout.
    s.server.offline = false;
    await s.store.signOutCleanup();

    expect(s.server.mealRows.keys, contains(id),
        reason: 'Zustellversuch VOR dem Verwerfen');
    expect(await s.cache.readOutbox(), isNull);
    expect(await s.cache.readProfile(), isNull);
  });
}

/// Schreibt Outbox-Zeilen ROH in den Key-Value-Store, vorbei an
/// [LocalCache.writeOutbox] und den [SyncOp]-Factories. Nur so lassen sich
/// Wire-Formen erzeugen, die kein Produktionspfad baut: eine nicht lesbare
/// Payload (A8) und ein uraltes `queued_at` (A4). Der Slot-Name ist das
/// dokumentierte Cache-Format `eatova.v1.outbox.<user-id>`, die User-ID die
/// aus [_setup].
Future<void> _seedRawOutbox(
  InMemoryKeyValueStore kv,
  List<Map<String, dynamic>> items,
) =>
    kv.setString('eatova.v1.outbox.user-outbox',
        jsonEncode(<String, dynamic>{'items': items}));
