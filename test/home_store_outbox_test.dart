import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/local_day.dart';
import 'package:eatova/src/services/meals_sync.dart' show mealResultToJson;
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/services/sync_error_messages.dart'
    show SyncDelivery, outboxDeleteLossHint, outboxLossHint;
import 'package:eatova/src/services/sync_outbox.dart';
import 'package:eatova/src/services/uuid.dart' show deriveStatsRequestId;
import 'package:eatova/src/widgets/common/app_snack.dart';

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
//  11. Luecke A: Eigen-Rezepte haben (wie Mahlzeiten/Favoriten) einen lokalen
//      Write-Through-Cache und ueberleben damit einen Kaltstart ohne Netz.
//  12. Fix 3: der Zaehler einer NACHGEHOLTEN Op laeuft als eigener
//      statsIncrement-Eintrag mit abgeleiteter Request-Id — atomar mit der
//      Op-Entfernung erzeugt, exactly-once ueber App-Kills hinweg.

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

  /// user_recipes-Writes ANTWORTEN NIE. Supabase-/PostgREST-Aufrufe tragen
  /// kein Timeout (die Policies in eatova_http.dart gelten nur fuer
  /// Meilisearch/OFF/analyze-meal), ein haengender Request scheitert also
  /// nicht — dadurch feuert weder `then` noch `catchError`, und es entsteht
  /// GAR KEINE Outbox-Op. Genau dieser Schalter trennt im Test das
  /// Cache-Sicherungsnetz vom Outbox-Sicherungsnetz.
  bool hangRecipeWrites = false;

  /// user_recipes-Writes werden mit 500 abgelehnt — der Server ANTWORTET also
  /// (Luecke E: „Offline" waere in dem Fall gelogen).
  bool rejectRecipeWrites = false;

  /// NUR record_tracking_day faellt aus (500), alles andere laeuft. Genau die
  /// Kombination, an der der Streak-Tag verschwand: die Mahlzeit kommt an,
  /// increment_lifetime_stats kommt an — und der Tag nicht.
  bool rejectTrackingDay = false;

  /// Der zuletzt per record_tracking_day verbuchte Tag (`YYYY-MM-DD`), also
  /// `lifetime_stats.last_workout_date`. Vorher lieferte der Fake dort hart
  /// `null` und konnte deshalb gar nicht zeigen, ob ein Tag ankommt.
  String? trackedDay;

  final List<http.Request> requests = <http.Request>[];

  /// Die eine Zeile aus public.profiles, die zu diesem Nutzer gehoert — oder
  /// null, wenn es noch keine gibt. Das Profil ist die einzige Sammlung mit
  /// GENAU EINER Zeile; genau daran haengt Luecke D.
  Map<String, dynamic>? profileRow;
  final Map<String, Map<String, dynamic>> mealRows =
      <String, Map<String, dynamic>>{};
  final Map<String, Map<String, dynamic>> weightRows =
      <String, Map<String, dynamic>>{};

  /// favorite_key -> Zeile, wie public.favorite_meals sie fuehrt.
  ///
  /// Zweitpruefung 2026-08-10: bis hierher beantwortete der Fake JEDEN
  /// favorite_meals-/weight_log-GET mit `[]` und quittierte jeden Write mit
  /// 201, ohne etwas zu merken. Ein Boot-Load nach erfolgreicher Zustellung
  /// bekam damit eine leere Liste zurueck — und die Inventur konnte gar nicht
  /// unterscheiden, ob der Store den Stand verliert oder der Fake ihn nie
  /// hatte. Genau die Falle, vor der der Kommentar am logged_meals-GET warnt
  /// („Fake bestaetigt Fake").
  final Map<String, Map<String, dynamic>> favoriteRows =
      <String, Map<String, dynamic>>{};

  /// Slug -> Zeile, wie public.user_recipes sie fuehrt (Konflikt-Schluessel
  /// ist (user_id, slug)).
  final Map<String, Map<String, dynamic>> recipeRows =
      <String, Map<String, dynamic>>{};
  int mealsCounted = 0;
  int weightLogsCounted = 0;

  /// `p_request_id` JEDES increment_lifetime_stats-Aufrufs, in Reihenfolge —
  /// auch der abgelehnten (die Aufzeichnung laeuft vor [statsOffline]). Das ist
  /// der Beweis-Kanal fuer Befund B: ein Retry desselben Delta-Buendels muss
  /// dieselbe Id tragen, sonst kann der Server ihn nicht als Wiederholung
  /// erkennen und zaehlt ein zweites Mal.
  final List<String?> statsRequestIds = <String?>[];

  /// Server-Dedup der Migration 20260814120000: verbrauchte `p_request_id`.
  /// Nur ERFOLGREICHE Aufrufe verbrauchen (der echte RPC laeuft in einer
  /// Transaktion — ein 500 committet den Marker nicht). Ohne diesen Zustand
  /// addierte der Fake blind und konnte gar nicht zeigen, ob ein Retry
  /// serverseitig als Wiederholung ankommt.
  final Set<String> verbrauchteStatsIds = <String>{};

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
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      // VOR dem Ausfall-Schalter: gerade der gescheiterte Versuch ist der, mit
      // dem der spaetere Retry verglichen wird.
      final rid = body['p_request_id'] as String?;
      statsRequestIds.add(rid);
      if (statsOffline) return fail();
      if (rid != null && !verbrauchteStatsIds.add(rid)) {
        // Wiederholung: NICHT addieren, aktuelle Zeile liefern — exakt das
        // FOUND-Verhalten der Migration (`on conflict do nothing` + FOUND).
        return ok(_statsRow());
      }
      mealsCounted += (body['p_meals'] as num?)?.toInt() ?? 0;
      weightLogsCounted += (body['p_weight_logs'] as num?)?.toInt() ?? 0;
      return ok(_statsRow());
    }
    if (path.contains('/rpc/record_tracking_day')) {
      if (rejectTrackingDay) return fail();
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      trackedDay = body['p_day'] as String?;
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
      // GET: Zeilen in der vom Client erwarteten Select-Form — MIT
      // angewandten Filtern wie bei PostgREST: das Boot-Fenster (gte/lt auf
      // logged_at) und der id=in.(...)-Read der Wiedereinblendung. Ein Fake,
      // der immer alle Zeilen liefert, hatte das 35-Tage-Loch der
      // Wiedereinblendung unsichtbar gemacht (Fake bestaetigt Fake).
      Iterable<Map<String, dynamic>> rows = mealRows.values;
      for (final p in req.url.queryParametersAll['logged_at'] ?? const <String>[]) {
        if (p.startsWith('gte.')) {
          final cutoff = DateTime.parse(p.substring(4));
          rows = rows.where((r) =>
              !DateTime.parse(r['logged_at'] as String).isBefore(cutoff));
        } else if (p.startsWith('lt.')) {
          final end = DateTime.parse(p.substring(3));
          rows = rows.where(
              (r) => DateTime.parse(r['logged_at'] as String).isBefore(end));
        }
      }
      final idParam = req.url.queryParameters['id'];
      if (idParam != null && idParam.startsWith('in.(') && idParam.endsWith(')')) {
        final ids = idParam
            .substring(4, idParam.length - 1)
            .split(',')
            .map((s) => s.replaceAll('"', ''))
            .toSet();
        rows = rows.where((r) => ids.contains(r['id']));
      }
      return ok(rows
          .map((r) => <String, dynamic>{
                'id': r['id'],
                'logged_at': r['logged_at'],
                'forced_slot': r['forced_slot'],
                'local_day': r['local_day'],
                'payload': r['payload'],
              })
          .toList());
    }
    if (path.contains('/profiles')) {
      if (req.method == 'GET') {
        // maybeSingle() auf einem GET erwartet eine LISTE mit 0 oder 1 Zeile.
        return ok(profileRow == null
            ? const <dynamic>[]
            : <Map<String, dynamic>>[profileRow!]);
      }
      // ProfileSync.save ist ein UPSERT(.select().single()) — PostgREST
      // liefert dafuer EIN Objekt zurueck, keine Liste.
      for (final row in _rowsOf(req.body)) {
        profileRow = <String, dynamic>{...?profileRow, ...row};
      }
      return ok(profileRow!);
    }
    if (path.contains('/user_recipes')) {
      if (hangRecipeWrites && req.method != 'GET') {
        // Nie erfuellte Antwort: der Aufrufer wartet ewig (kein Timeout).
        return Completer<http.Response>().future;
      }
      if (rejectRecipeWrites && req.method != 'GET') return fail();
      if (req.method == 'POST') {
        for (final row in _rowsOf(req.body)) {
          recipeRows[row['slug'] as String] = row;
        }
        return http.Response('', 201, request: req);
      }
      if (req.method == 'DELETE') {
        recipeRows.remove(_eqParam(req, 'slug'));
        return ok(const <dynamic>[]);
      }
      return ok(recipeRows.values.toList());
    }
    if (path.contains('/favorite_meals')) {
      if (req.method == 'POST') {
        for (final row in _rowsOf(req.body)) {
          favoriteRows[row['favorite_key'] as String] = row;
        }
        return http.Response('', 201, request: req);
      }
      if (req.method == 'DELETE') {
        favoriteRows.remove(_eqParam(req, 'favorite_key'));
        return ok(const <dynamic>[]);
      }
      // GET in der Select-Form von MealsSync.loadFavorites.
      return ok(favoriteRows.values
          .map((r) => <String, dynamic>{
                'favorite_key': r['favorite_key'],
                'added_at': r['added_at'],
                'payload': r['payload'],
                'pinned': r['pinned'],
              })
          .toList());
    }
    if (path.contains('/weight_log')) {
      if (req.method == 'POST') {
        for (final row in _rowsOf(req.body)) {
          final id = row['id'] as String? ?? 'srv-${weightRows.length}';
          weightRows[id] = row;
        }
        return ambiguousWrites ? fail() : http.Response('', 201, request: req);
      }
      // GET in der Select-Form von TrackingSync.loadWeightLog.
      return ok(weightRows.values
          .map((r) => <String, dynamic>{
                'recorded_at': r['recorded_at'],
                'weight_kg': r['weight_kg'],
              })
          .toList());
    }
    // Uebrige Reads (profiles, lifetime_stats): leer — _safeLoad/maybeSingle
    // behandeln das als "nichts da", der Boot bleibt gruen.
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
        'last_workout_date': trackedDay,
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
  final List<SnackTone> tones = <SnackTone>[];

  void call(
    String message, {
    IconData icon = Icons.info_outline,
    SnackTone tone = SnackTone.positive,
    Duration? duration,
    SnackBarAction? action,
  }) {
    messages.add(message);
    tones.add(tone);
  }

  Iterable<String> get offlineHints =>
      messages.where((m) => m.startsWith('Offline'));
}

/// Cache, dessen PROFIL-Slot beim Lesen wirft. Modelliert Luecke F: die
/// Boot-Hydration liest sieben Slots, und ein einziger Wurf darf die
/// nachfolgenden — allen voran die Outbox — nicht mitreissen. Die
/// Schreibpfade bleiben die echten.
class _ProfilLesefehlerCache extends LocalCache {
  _ProfilLesefehlerCache(super.store, super.userId);

  @override
  Future<UserProfile?> readProfile() async =>
      throw StateError('Profil-Slot unlesbar');
}

/// Cache, dessen OUTBOX-Slot beim ERSTEN Lesen wirft und danach normal
/// antwortet. Modelliert die zweite Haelfte von Luecke F: der persistierte
/// Blob darf nie auf Basis eines fehlgeschlagenen Lesevorgangs ueberschrieben
/// werden.
class _OutboxLesefehlerCache extends LocalCache {
  _OutboxLesefehlerCache(super.store, super.userId);

  int leseversuche = 0;

  @override
  Future<List<SyncOp>?> readOutbox() {
    leseversuche++;
    if (leseversuche == 1) {
      return Future<List<SyncOp>?>.error(StateError('Outbox-Slot unlesbar'));
    }
    return super.readOutbox();
  }
}

/// Cache, dessen OUTBOX-Writes nie die „Platte" erreichen — die eine Haelfte
/// des Kill-Fensters: der Deltas-/sonstige Slot committet, der Outbox-Blob
/// nicht. Lesen bleibt echt (der geseedete Blob der „Vorsession"), damit die
/// naechste Sitzung genau den Stand vorfindet, den ein App-Kill zwischen den
/// beiden Writes hinterlaesst.
class _EingefrorenerOutboxCache extends LocalCache {
  _EingefrorenerOutboxCache(super.store, super.userId);

  @override
  Future<void> writeOutbox(List<SyncOp> ops) async {}
}

/// Dasselbe fuer den DELTAS-Slot (W7b): die zweite Haelfte des kill-sicheren
/// Sync-Zustands hatte bis zum Audit 2026-08-14 keine Bremse — ein
/// fehlgeschlagener Lesevorgang beim Boot liess den naechsten Flush den Slot
/// bei 0 beginnend niederschreiben, und die nie verbuchten Mahlzeiten der
/// Vorsession fehlten dauerhaft in den Lebenszeit-Zaehlern.
///
/// [kaputteVersuche] steuert, ob der Slot nur VORUEBERGEHEND unlesbar ist
/// (1 = Bremse greift, Nachhydration gelingt) oder DAUERHAFT (2 = auch die
/// Nachhydration scheitert; danach muss der normale Schreibpfad wieder
/// uebernehmen, sonst koennte die Sitzung nie mehr etwas ablegen).
class _DeltaLesefehlerCache extends LocalCache {
  _DeltaLesefehlerCache(super.store, super.userId, {this.kaputteVersuche = 1});

  final int kaputteVersuche;
  int leseversuche = 0;

  @override
  Future<({int meals, int weightLogs, String? requestId})?>
      readPendingStatsDeltas() {
    leseversuche++;
    if (leseversuche <= kaputteVersuche) {
      return Future<({int meals, int weightLogs, String? requestId})?>.error(
          StateError('Deltas-Slot unlesbar'));
    }
    return super.readPendingStatsDeltas();
  }
}

({
  HomeStore store,
  _FakeServer server,
  LocalCache cache,
  _SnackCapture snacks,
}) _setup({
  InMemoryKeyValueStore? kv,
  LocalCache? injizierterCache,
  // Zwei Sitzungen, die sich denselben Server teilen (Kill-Simulation): der
  // Dedup-Zustand (verbrauchteStatsIds) und die Tabellen muessen den
  // „Neustart" ueberleben, sonst prueft der Test nur einen frischen Server.
  _FakeServer? geteilterServer,
}) {
  final server = geteilterServer ?? _FakeServer();
  final client = SupabaseClient(
    'https://example.supabase.co',
    'test-anon-key',
    httpClient: server.client(),
    // Kein GoTrue-Auto-Refresh-Ticker im Test (siehe clobber_guard_test).
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  addTearDown(client.dispose);
  final cache =
      injizierterCache ?? LocalCache(kv ?? InMemoryKeyValueStore(), 'user-outbox');
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

/// Wie [_setup], aber OHNE jeden [LocalCache] — der Zustand, in dem
/// `LocalCache.create` null liefert (DEK weder lesbar noch neu anlegbar, oder
/// der Plugin-Kanal ist tot). `debugCache: null` heisst hier wirklich „kein
/// Cache": der Boot-Pfad faellt danach auf `client.auth.currentUser?.id`
/// zurueck, und die ist in dieser Test-Schale null — es wird also nie ein
/// echter SharedPreferences-Kanal angefasst.
({HomeStore store, _FakeServer server, _SnackCapture snacks})
    _setupOhneCache() {
  final server = _FakeServer();
  final client = SupabaseClient(
    'https://example.supabase.co',
    'test-anon-key',
    httpClient: server.client(),
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  addTearDown(client.dispose);
  final snacks = _SnackCapture();
  final store = HomeStore(
    sync: EatovaSync.forUser(client, 'user-outbox'),
    health: const NoopHealthService(),
    notificationService: const NoopNotificationService(),
    initialUserName: 'Test',
    emitSnack: snacks.call,
  );
  addTearDown(store.dispose);
  return (store: store, server: server, snacks: snacks);
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

/// Eigen-Rezept, wie es das Erstell-Sheet baut (recipes_screen).
FitnessRecipe _recipe(String slug, {String title = 'Eigene Bowl'}) =>
    FitnessRecipe(
      slug: slug,
      title: title,
      description: 'Eigenes Rezept',
      portion: '1 Teller',
      ingredients: 'Reis\nHaehnchen',
      preparation: 'Eigenes Rezept — keine Zubereitung hinterlegt.',
      professionalHint: 'Selbst angelegt. Werte beruhen auf deinen Angaben.',
      imageAsset: '',
      caloriesKcal: 600,
      proteinG: 50,
      carbsG: 60,
      fatG: 15,
      estimatedGrams: 400,
      categories: const <String>['Eigene'],
      userCreated: true,
    );

/// Serverzeile von public.user_recipes (Select-Form von UserRecipesSync.load).
Map<String, dynamic> _serverRecipeRow(String slug,
        {String title = 'Server-Rezept'}) =>
    <String, dynamic>{
      'slug': slug,
      'title': title,
      'description': 'Eigenes Rezept',
      'portion': '1 Teller',
      'ingredients': 'Reis',
      'preparation': 'Kochen.',
      'image_asset': '',
      'calories_kcal': 600,
      'protein_g': 50,
      'carbs_g': 60,
      'fat_g': 15,
      'estimated_g': 400,
      'categories': <String>['Eigene'],
    };

/// Ein abgeschlossenes Profil, wie es nach dem Onboarding aussieht.
UserProfile _profile({
  int weightKg = 80,
  int dailyKcalGoal = 2200,
  DietPreference diet = DietPreference.none,
  bool onboardingCompleted = true,
}) =>
    UserProfile(
      weightKg: weightKg,
      dailyKcalGoal: dailyKcalGoal,
      diet: diet,
      onboardingCompleted: onboardingCompleted,
    );

/// Serverzeile von public.profiles — dieselben Spalten, die ProfileSync
/// schreibt und liest. Bewusst ausgeschrieben statt aus ProfileSync abgeleitet:
/// faellt eine Spalte weg, wirft `ProfileSync.load` (leseZahl) und der Boot
/// hydriert stillschweigend gar nicht — der Test soll das merken.
Map<String, dynamic> _serverProfileRow(UserProfile p) => <String, dynamic>{
      'id': 'user-outbox',
      'weight_kg': p.weightKg,
      'height_cm': p.heightCm,
      'age_years': p.ageYears,
      'sex': p.sex.name,
      'activity_level': p.activityLevel.name,
      'target_weight_kg': p.targetWeightKg,
      'daily_steps_goal': p.dailyStepsGoal,
      'daily_kcal_goal': p.dailyKcalGoal,
      'daily_water_goal_ml': p.dailyWaterGoalMl,
      'daily_sleep_goal_minutes': p.dailySleepGoalMinutes,
      'protein_goal_g': p.proteinGoalG,
      'carbs_goal_g': p.carbsGoalG,
      'fat_goal_g': p.fatGoalG,
      'weight_goal': p.weightGoal.name,
      'diet_preference': p.diet.name,
      'onboarding_completed': p.onboardingCompleted,
    };

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
    final ton = s.snacks.tones[
        s.snacks.messages.indexWhere((m) => m.startsWith('Offline'))];
    expect(ton, isNot(SnackTone.error), reason: 'kein Rot-Alarm');
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

  // --- Befund B: Idempotenz-Schluessel der Stats-Deltas ---------------------
  //
  // `increment_lifetime_stats` ADDIERT. Bricht die Verbindung NACH dem Commit
  // ab, reiht der catch-Zweig dasselbe Delta wieder ein — und ohne
  // Wiedererkennung zaehlt der Retry ein zweites Mal, dauerhaft und ohne
  // Neuberechnungspfad. Seit der Migration 20260814120000_audit_rls_guard.sql
  // haelt der Server verbrauchte `p_request_id` fest; der Schutz steht und
  // faellt aber damit, dass der Client bei einem Retry DIESELBE Id sendet. Eine
  // pro Versuch neu erzeugte Id waere fuer den Server ein neuer Vorgang — der
  // Fix waere reine Fassade. Genau das pruefen diese beiden Tests.

  test(
      'Retry des Stats-Deltas sendet DIESELBE Anfrage-Id — auch ueber einen '
      'Kaltstart hinweg; erst ein verbuchtes Buendel bekommt eine neue',
      () async {
    final kv = InMemoryKeyValueStore();

    // Session 1: Mahlzeiten-Write kommt durch, nur der Stats-RPC faellt aus.
    final a = _setup(kv: kv);
    await _boot(a.store);
    a.server.statsOffline = true;
    a.store.addResultToDailyTotal(_result('Bowl'));
    await _settle();
    a.store.flushPendingWrites();
    await _settle();

    expect(a.server.statsRequestIds, isNotEmpty,
        reason: 'der Flush muss den Server ueberhaupt erreicht haben');
    final id = a.server.statsRequestIds.first;
    expect(id, isNotNull, reason: 'ohne Id ist der Aufruf rein additiv');
    expect(a.server.statsRequestIds.toSet(), <String?>{id},
        reason: 'mehrere Versuche desselben Buendels sind EIN Vorgang');

    // Die Id liegt beim Buendel, nicht nur im Speicher — sonst ueberlebt sie
    // den App-Kill nicht und der naechste Versuch waere wieder ein neuer
    // Vorgang.
    expect((await a.cache.readPendingStatsDeltas())!.requestId, id);

    // Session 2 (Kaltstart, RPC weiterhin kaputt): der Boot-Flush ist der
    // eigentliche Retry — und er traegt die Id des ERSTEN Versuchs.
    final b = _setup(kv: kv);
    b.server.statsOffline = true;
    await _boot(b.store);
    b.store.flushPendingWrites();
    await _settle();

    expect(b.server.statsRequestIds, isNotEmpty);
    expect(b.server.statsRequestIds.toSet(), <String?>{id},
        reason: 'eine frisch erzeugte Id koennte der Server nicht als '
            'Wiederholung erkennen — er wuerde ein zweites Mal addieren');

    // Zustellung: derselbe Vorgang kommt endlich durch.
    b.server.statsOffline = false;
    b.store.flushPendingWrites();
    await _settle();
    expect(b.server.statsRequestIds.last, id);
    expect(b.server.mealsCounted, 1);
    expect((await b.cache.readPendingStatsDeltas())!.meals, 0);

    // Und die Gegenprobe: ein NEUES Buendel ist ein neuer Vorgang. Erbte es die
    // verbrauchte Id, wuerde der Server es als Wiederholung abtun und die
    // Mahlzeit zaehlte nie.
    b.store.addResultToDailyTotal(_result('Zweite Bowl'));
    await _settle();
    b.store.flushPendingWrites();
    await _settle();
    expect(b.server.statsRequestIds.last, isNot(id));
    expect(b.server.mealsCounted, 2);
  });

  test(
      'Bestandsdaten: ein persistiertes Buendel OHNE Anfrage-Id (aelterer '
      'Build) geht nicht verloren — es bekommt eine nachtraeglich, und die '
      'haelt', () async {
    final kv = InMemoryKeyValueStore();
    // Exakt die Wire-Form von vorher: Zahlen, kein 'request_id'.
    await LocalCache(kv, 'user-outbox')
        .writePendingStatsDeltas(meals: 2, weightLogs: 1);

    final s = _setup(kv: kv);
    s.server.statsOffline = true;
    await _boot(s.store);
    s.store.flushPendingWrites();
    await _settle();

    // Weder an `null` gescheitert noch stillschweigend verworfen: das Buendel
    // ist gesendet worden, mit einer nachtraeglich vergebenen Id …
    expect(s.server.statsRequestIds, isNotEmpty);
    final id = s.server.statsRequestIds.first;
    expect(id, isNotNull);
    expect(s.server.statsRequestIds.toSet(), <String?>{id});

    // … die ab jetzt beim Buendel liegt (sonst waere jeder weitere Versuch
    // wieder ein neuer Vorgang).
    final pending = await s.cache.readPendingStatsDeltas();
    expect(pending!.requestId, id);
    expect(pending.meals, 2);
    expect(pending.weightLogs, 1);

    // Und die alten Zahlen kommen vollstaendig an.
    s.server.statsOffline = false;
    s.store.flushPendingWrites();
    await _settle();
    expect(s.server.mealsCounted, 2);
    expect(s.server.weightLogsCounted, 1);
  });

  // --- Fix 3: exactly-once fuer die Zaehler NACHGEHOLTER Ops ----------------
  //
  // Fuer den INHALT war der Replay immer idempotent (jeder Write ist ein
  // voller Upsert auf die Client-UUID), fuer seinen ZAEHLER nicht:
  // `_performOp` persistierte das +1 SOFORT in den Deltas-Slot, waehrend die
  // Op erst einen zweiten Blob-Write spaeter aus der Outbox fiel. Ein App-Kill
  // dazwischen liess den naechsten Boot BEIDES vorfinden — Delta und Op — und
  // die Mahlzeit ein zweites Mal zaehlen, unter einer frischen Buendel-Id und
  // damit am Server-Dedup vorbei. `meals_logged` stand danach dauerhaft +1,
  // ohne Neuberechnungspfad.
  //
  // Seit Fix 3 erzeugt der Replay stattdessen einen eigenen
  // statsIncrement-Eintrag: ATOMAR mit der Entfernung der Quell-Op (ein
  // Listenupdate, ein Blob-Write — es gibt kein Fenster mehr) und mit einer
  // aus der Quell-UUID ABGELEITETEN Request-Id. Jede Wiederholung ist fuer den
  // Server derselbe Vorgang, auch die nach einem Kill neu ERZEUGTE.

  test(
      'Fix 3: Kill nach der Replay-Zustellung, VOR der Op-Entfernung — der '
      'naechste Boot zaehlt die Mahlzeit NICHT ein zweites Mal', () async {
    const mealId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    final abgeleitet = deriveStatsRequestId(mealId)!;
    final kv = InMemoryKeyValueStore();
    // EIN Server fuer beide Sitzungen: sein Dedup-Zustand ist genau das, was
    // den Neustart ueberleben muss.
    final server = _FakeServer();
    // Der Blob der Vorsession: eine liegengebliebene Mahlzeit. Die Id ist
    // bewusst UUID-foermig — aus einer anderen liesse sich keine Request-Id
    // ableiten und es gaebe gar keinen Folgeeintrag.
    await _seedRawOutbox(kv, <Map<String, dynamic>>[
      SyncOp.mealInsert(
        LoggedMeal(
            id: mealId, result: _result('Kill-Bowl'), loggedAt: DateTime.now()),
        trackDay: false,
      ).toJson(),
    ]);

    // Sitzung A: Zustellung und Increment laufen durch, der OUTBOX-Write
    // erreicht die Platte aber nie — exakt der Kill zwischen den beiden
    // Commits.
    final a = _setup(
      kv: kv,
      geteilterServer: server,
      injizierterCache: _EingefrorenerOutboxCache(kv, 'user-outbox'),
    );
    await _boot(a.store);
    // Den Debounce des (auf HEAD noch vorhandenen) Buendel-Flushes abkuerzen:
    // ohne ihn bliebe das alte +1 im Speicher haengen und der Befund waere
    // nicht gemessen, sondern nur nicht ausgeloest.
    a.store.flushPendingWrites();
    await _settle();

    expect(server.mealRows.keys, contains(mealId),
        reason: 'Vorbedingung: die Mahlzeit ist zugestellt');
    expect(server.mealsCounted, 1,
        reason: 'Vorbedingung: sie ist genau einmal gezaehlt');
    expect(kv.snapshot['eatova.v1.outbox.user-outbox'],
        contains('"entity_id":"$mealId"'),
        reason: 'Vorbedingung: der persistierte Blob traegt die Op WEITERHIN '
            '— sonst prueft dieser Test gar nichts');
    // Kein explizites dispose(): den Teardown haengt _setup selbst an, und die
    // Sitzung hat nach dem Flush keinen Ausloeser mehr. Der „Kill" ist der
    // Zustand, den sie auf der Platte hinterlaesst.

    // Sitzung B: derselbe Blob, derselbe Server.
    final b = _setup(kv: kv, geteilterServer: server);
    await _boot(b.store);
    b.store.flushPendingWrites();
    await _settle();

    expect(server.mealsCounted, 1,
        reason: 'DER Befund: vorher buchte der Boot-Replay ein zweites +1 — '
            'unter frischer Buendel-Id, also fuer den Server ein neuer '
            'Vorgang, den nichts deduplizieren konnte');
    expect(
        server.statsRequestIds
            .whereType<String>()
            .where((id) => id == abgeleitet),
        hasLength(greaterThanOrEqualTo(2)),
        reason: 'Sitzung A verbucht, Sitzung B wiederholt — und beide senden '
            'DIESELBE, aus der Meal-UUID abgeleitete Id');
    expect(server.verbrauchteStatsIds, <String>{abgeleitet},
        reason: 'serverseitig ist das EIN Vorgang, kein zweiter');
    expect(server.mealRows, hasLength(1),
        reason: 'Beifang: der Inhalt war schon immer idempotent');
    expect(b.store.pendingOutbox, isEmpty);
    expect(await b.cache.readOutbox(), isEmpty,
        reason: 'nach dem zweiten Lauf ist der Blob wirklich leer');
  });

  test(
      'Fix 3: ein serverseitig bereits verbuchter statsIncrement-Eintrag '
      'verlaesst die Queue als ERFOLG, ohne erneut zu addieren', () async {
    const rid = '6561746f-7661-6d73-f461-74732d726964';
    final kv = InMemoryKeyValueStore();
    // Die Vorsession hat den Eintrag zugestellt — nur die ANTWORT ging
    // verloren, also liegt er noch in der Queue.
    await _seedRawOutbox(kv, <Map<String, dynamic>>[
      SyncOp.statsIncrement(requestId: rid, meals: 1).toJson(),
    ]);

    final s = _setup(kv: kv);
    s.server.verbrauchteStatsIds.add(rid);
    s.server.mealsCounted = 1;
    await _boot(s.store);

    expect(s.server.statsRequestIds, contains(rid),
        reason: 'Vorbedingung: der Retry hat den Server erreicht');
    expect(s.server.mealsCounted, 1,
        reason: 'FOUND-Zweig der Migration: eine verbrauchte Id addiert nicht '
            'noch einmal, sie liefert nur die aktuelle Zeile');
    expect(s.store.pendingOutbox, isEmpty,
        reason: 'der Eintrag ist kein Gift — das Server-Verhalten macht den '
            'Retry gruen, er wird als Erfolg abgeraeumt');
    expect(await s.cache.readOutbox(), isEmpty);
  });

  test(
      'Fix 3: faellt increment_lifetime_stats aus, bleibt NUR der '
      'Zaehler-Eintrag liegen — mit stabiler Id ueber Versuche und Neustarts',
      () async {
    final kv = InMemoryKeyValueStore();
    final server = _FakeServer();

    // Sitzung A: offline geloggt -> mealInsert liegt in der Queue.
    final a = _setup(kv: kv, geteilterServer: server);
    await _boot(a.store);
    server.offline = true;
    final mealId = a.store.addResultToDailyTotal(_result('Nachhol-Bowl'));
    await _settle();
    expect(a.store.pendingOutbox.map((o) => o.kind),
        contains(SyncOpKind.mealInsert),
        reason: 'Vorbedingung');

    // Netz zurueck, aber der Zaehler-RPC faellt aus.
    server.offline = false;
    server.statsOffline = true;
    a.store.flushPendingWrites();
    await _settle();

    final abgeleitet = deriveStatsRequestId(mealId)!;
    expect(server.mealRows.keys, contains(mealId),
        reason: 'der Inhalt ist durch — nur sein Zaehler nicht');
    expect(a.store.pendingOutbox.map((o) => o.kind).toList(),
        <SyncOpKind>[SyncOpKind.statsIncrement],
        reason: 'Mahlzeit, Favorit und Streak-Tag sind zugestellt; liegen '
            'bleibt genau der Zaehler');
    expect(a.store.pendingOutbox.single.entityId, abgeleitet,
        reason: 'die entityId IST die Request-Id');
    expect((await a.cache.readPendingStatsDeltas())?.meals ?? 0, 0,
        reason: 'DER Beweis, dass der alte Pfad tot ist: der Replay fasst das '
            'Buendel nicht mehr an (vorher stand hier 1)');
    expect(server.statsRequestIds, contains(abgeleitet));

    // Kaltstart, RPC weiterhin kaputt: der Boot-Replay wiederholt.
    final b = _setup(kv: kv, geteilterServer: server);
    await _boot(b.store);
    b.store.flushPendingWrites();
    await _settle();

    expect(b.store.pendingOutbox.map((o) => o.kind).toList(),
        <SyncOpKind>[SyncOpKind.statsIncrement]);
    expect(server.statsRequestIds.whereType<String>().toSet(),
        <String>{abgeleitet},
        reason: 'eine pro Versuch neu erzeugte Id koennte der Server nicht als '
            'Wiederholung erkennen — er wuerde ein zweites Mal addieren');

    // Und endlich durch.
    server.statsOffline = false;
    b.store.flushPendingWrites();
    await _settle();

    expect(server.mealsCounted, 1);
    expect(server.verbrauchteStatsIds, <String>{abgeleitet});
    expect(b.store.pendingOutbox, isEmpty);
  });

  test(
      'Fix 3: dasselbe fuer das Gewicht — der nachgeholte weightInsert zaehlt '
      'ueber seinen eigenen Eintrag, nicht ueber das Buendel', () async {
    final s = _setup();
    await _boot(s.store);

    // Unklarer Ausgang: der Server wendet den Write an, antwortet aber 500 —
    // der Live-Pfad zaehlt deshalb NICHT (onDelivered bleibt aus).
    s.server.ambiguousWrites = true;
    s.store.logWeight(80.5);
    await _settle();
    final op = s.store.pendingOutbox
        .singleWhere((o) => o.kind == SyncOpKind.weightInsert);
    final abgeleitet = deriveStatsRequestId(op.entityId)!;

    s.server.ambiguousWrites = false;
    s.store.flushPendingWrites();
    await _settle();

    expect(s.server.weightLogsCounted, 1);
    expect(s.server.statsRequestIds, <String?>[abgeleitet],
        reason: 'genau EIN Increment, und seine Id ist aus der weight_log-UUID '
            'abgeleitet — kein Buendel beteiligt');
    expect((await s.cache.readPendingStatsDeltas())?.weightLogs ?? 0, 0);
    expect(s.store.pendingOutbox, isEmpty);
  });

  test(
      'Fix 3: der Verwurf eines Zaehler-Eintrags ist STILL — er ist kein '
      'Nutzer-Inhalt, „etwas fehlt" waere die falsche Meldung', () async {
    const rid = '6561746f-7661-6d73-f461-74732d726964';
    final kv = InMemoryKeyValueStore();
    // Budget aufgebraucht UND seit ueber 24 h liegen: beides muss zusammen-
    // kommen, sonst greift die Notbremse nicht (A4).
    await _seedRawOutbox(kv, <Map<String, dynamic>>[
      SyncOp.statsIncrement(requestId: rid, meals: 1).toJson()
        ..['queued_at'] = DateTime.now()
            .subtract(const Duration(hours: 25))
            .toIso8601String()
        ..['attempts'] = kOutboxMaxAttempts - 1,
    ]);

    final s = _setup(kv: kv);
    s.server.statsOffline = true; // aktive Ablehnung (500) zaehlt
    await _boot(s.store);

    expect(s.store.pendingOutbox, isEmpty, reason: 'verworfen');
    expect(s.server.mealsCounted, 0);
    expect(s.snacks.messages.where((m) => m == outboxLossHint()), isEmpty,
        reason: 'die Mahlzeit ist laengst zugestellt — es fehlt kein Eintrag, '
            'nur ein Zaehler. Der Snack waere gelogen.');
    expect(s.snacks.messages.where((m) => m == outboxDeleteLossHint()), isEmpty);
  });

  // --- W7b: die Bremse fuer den Deltas-Slot ---------------------------------
  //
  // Fuer die Outbox gibt es sie seit Luecke F (`_outboxHydrationFailed`), fuer
  // die pendenden Deltas fehlte sie: `readPendingStatsDeltasOrThrow` meldete
  // den Lesefehler zwar, aber niemand hielt daraufhin den Schreibpfad an.
  // `_persistPendingStatsDeltas` schreibt den Slot IMMER komplett neu — genau
  // der Schaden, den der Docstring der Methode benennt.

  test(
      'ein kaputter pending_stats-Slot loest die Bremse aus, statt still eine '
      'leere Menge zu liefern', () async {
    final kv = InMemoryKeyValueStore();
    // Vorsession: drei nie verbuchte Mahlzeiten liegen im Slot, mit ihrer
    // Anfrage-Id.
    await LocalCache(kv, 'user-outbox')
        .writePendingStatsDeltas(meals: 3, weightLogs: 0, requestId: 'alt-id');

    final cache = _DeltaLesefehlerCache(kv, 'user-outbox');
    final s = _setup(kv: kv, injizierterCache: cache);
    // Der Stats-RPC bleibt aus: so kann kein Flush die Zahlen wegraeumen und
    // der Test misst wirklich den Slot-Inhalt.
    s.server.statsOffline = true;
    await _boot(s.store);
    expect(cache.leseversuche, 1,
        reason: 'Vorbedingung: die Hydration hat den Slot nicht gesehen');

    // Eine neue Mahlzeit — ihr Delta laeuft in _persistPendingStatsDeltas.
    s.store.addResultToDailyTotal(_result('Bowl'));
    await _settle();

    expect(cache.leseversuche, greaterThan(1),
        reason: 'ohne Bremse schriebe der Flush den Slot ungeprueft nieder — '
            'die Nachhydration waere toter Code');
    final pending =
        await LocalCache(kv, 'user-outbox').readPendingStatsDeltas();
    expect(pending!.meals, 4,
        reason: 'ein verschluckter Lesefehler liess den Slot bei 0 anfangen: '
            'drei nie verbuchte Mahlzeiten fehlten danach dauerhaft in den '
            'Lebenszeit-Zaehlern');
    expect(pending.requestId, 'alt-id',
        reason: 'die Id des nachgelesenen Buendels gewinnt — nur sie kann '
            'serverseitig schon verbucht sein');
  });

  test(
      'ein DAUERHAFT unlesbarer pending_stats-Slot blockiert das Persistieren '
      'nicht auf Dauer — die Nachhydration laeuft genau einmal', () async {
    final kv = InMemoryKeyValueStore();
    await LocalCache(kv, 'user-outbox')
        .writePendingStatsDeltas(meals: 3, weightLogs: 0);

    final cache = _DeltaLesefehlerCache(kv, 'user-outbox', kaputteVersuche: 2);
    final s = _setup(kv: kv, injizierterCache: cache);
    s.server.statsOffline = true;
    await _boot(s.store);

    s.store.addResultToDailyTotal(_result('Bowl'));
    await _settle();

    expect(cache.leseversuche, 2,
        reason: 'Hydration + GENAU EIN Nachlesevorgang');
    expect(
        (await LocalCache(kv, 'user-outbox').readPendingStatsDeltas())!.meals,
        1,
        reason: 'nach dem zweiten Fehlschlag ist der Slot mit diesem Code '
            'ohnehin nicht mehr verbuchbar — ab da gilt wieder der normale '
            'Schreibpfad, sonst koennte die Sitzung nie mehr etwas ablegen');

    // Und jedes weitere Delta laeuft ohne einen dritten Lesevorgang durch.
    s.store.addResultToDailyTotal(_result('Zweite Bowl'));
    await _settle();
    expect(cache.leseversuche, 2);
    expect(
        (await LocalCache(kv, 'user-outbox').readPendingStatsDeltas())!.meals,
        2);
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
    expect(s.snacks.messages.where((m) => m == outboxLossHint()), hasLength(1));

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
    expect(s.snacks.messages.where((m) => m == outboxLossHint()), isEmpty,
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
    expect(s.snacks.messages.where((m) => m == outboxLossHint()), isEmpty);

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
    expect(s.snacks.messages.where((m) => m == outboxLossHint()), hasLength(1));
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
    expect(s.snacks.messages.where((m) => m == outboxLossHint()), isEmpty);

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
    expect(s.snacks.messages.where((m) => m == outboxLossHint()), hasLength(1));
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
    expect(s.snacks.messages.where((m) => m == outboxLossHint()), hasLength(1));

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
    expect(s.snacks.messages.where((m) => m == outboxLossHint()), hasLength(1));
  });

  test(
      'A2: Ausloggen mit ungesyncten Ops — was der Zustellversuch nicht '
      'losgeworden ist, ueberlebt den Logout', () async {
    final s = _setup();
    // Echte PII-Basis VOR dem Boot: seit dem A1-Guard schreibt der Boot ohne
    // echte Hydrationsquelle keinen Default-Snapshot mehr — die erste Fassung
    // dieses Tests bezog ihr „Profil liegt im Cache" genau aus diesem
    // Nebeneffekt (Ctor-Defaults als PII).
    await s.cache.writeProfile(
        const UserProfile(weightKg: 80, onboardingCompleted: true));
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

  test(
      'Misch-Drop am Cap: faellt neben Deletes auch ein Write, meldet die '
      'Episode BEIDE Verluste — nicht nur die Loeschung', () async {
    final kv = InMemoryKeyValueStore();
    final meal = LoggedMeal(
      id: 'm-write-verlust',
      result: _result('Cap-Bowl'),
      loggedAt: DateTime.now(),
    );
    await _seedRawOutbox(kv, [
      // Aeltester Eintrag: ein WRITE — der faellt am Cap zuerst.
      SyncOp.mealInsert(meal, trackDay: false).toJson(),
      // Danach so viele Deletes, dass der Ueberlauf (503 - 500 = 3) nach dem
      // einzigen Write auch noch zwei Deletes mitnimmt: der Misch-Fall, in
      // dem per capOutbox-Reihenfolge ALLE Writes gefallen sind.
      for (var i = 0; i < 502; i++) SyncOp.mealDelete('m-del-$i').toJson(),
    ]);

    final s = _setup(kv: kv);
    s.server.offline = true;
    await _boot(s.store);

    expect(s.store.pendingOutbox, hasLength(kOutboxMaxOps));
    expect(s.snacks.messages.where((m) => m == outboxDeleteLossHint()),
        hasLength(1),
        reason: 'zwei Deletes sind gefallen — ihre Eintraege kommen wieder');
    expect(s.snacks.messages.where((m) => m == outboxLossHint()), hasLength(1),
        reason: 'der Write ist gefallen und FEHLT damit — diese Meldung '
            'verschluckte der gemeinsame Aufruf mit deletesLost==true');
  });

  test(
      'A2-Restfenster: Logout VOR der Boot-Hydration raeumt die persistierte '
      'Outbox der Vorsession nicht', () async {
    final kv = InMemoryKeyValueStore();
    final meal = LoggedMeal(
      id: 'm-vorsession',
      result: _result('Vorsession-Bowl'),
      loggedAt: DateTime.now(),
    );
    await _seedRawOutbox(kv, [SyncOp.mealInsert(meal, trackDay: false).toJson()]);

    final s = _setup(kv: kv);
    // BEWUSST kein _boot: der Logout kommt, bevor die Hydration den Blob in
    // den In-Memory-Zustand uebernommen hat. `_outbox` ist dann leer — der
    // persistierte Blob der Vorsession nicht, und nur er zaehlt.
    await s.store.signOutCleanup();

    final surviving = await s.cache.readOutbox();
    expect(surviving, isNotNull,
        reason: 'ein leerer In-Memory-Zustand vor der Hydration ist KEINE '
            'Aussage ueber den persistierten Blob — er darf nicht als '
            '"nichts zu erhalten" gelesen werden');
    expect(surviving!.map((o) => o.entityKey), contains('meal:m-vorsession'));
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
    expect(s.snacks.messages.where((m) => m == outboxLossHint()), isEmpty);
    expect(s.snacks.messages.where((m) => m == outboxDeleteLossHint()), isEmpty);

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
    expect(s.snacks.messages.where((m) => m == outboxDeleteLossHint()),
        hasLength(1));
    for (final m in s.snacks.messages) {
      expect(m, isNot(contains('logged_meals')));
      expect(m, isNot(contains('23502')));
      expect(m, isNot(contains('PostgrestException')));
    }
  });

  test(
      'L2 ausserhalb des Boot-Fensters: auch eine ALTE Mahlzeit wird nach dem '
      'endgueltigen Delete-Verwurf wieder eingeblendet — der "wieder da"-'
      'Hinweis muss auch fuer Alt-Tage stimmen', () async {
    final kv = InMemoryKeyValueStore();
    await _seedRawOutbox(kv, [
      SyncOp.mealDelete('m-alt').toJson()
        ..['queued_at'] = DateTime.now()
            .subtract(kOutboxDeleteMinAge + const Duration(hours: 1))
            .toIso8601String()
        ..['attempts'] = kOutboxDeleteMaxAttempts - 1,
    ]);
    final s = _setup(kv: kv);
    s.server.offline = true;
    await _boot(s.store);

    // Die Zeile ist 60 Tage alt — der Fenster-Load des Boots sieht sie NIE,
    // nur ein gezielter Read auf die Id kann sie zurueckholen. (Erreichbar
    // ist so ein Delete ueber den Archiv-Tag-Picker des Edit-Sheets.)
    s.server.offline = false;
    final oldRow = _serverMealRow('m-alt', kcal: 1200);
    oldRow['logged_at'] = DateTime.now()
        .toUtc()
        .subtract(const Duration(days: 60))
        .toIso8601String();
    s.server.mealRows['m-alt'] = oldRow;
    s.server.poisonMealWrites = true;
    s.store.flushPendingWrites();
    await _settle();

    expect(s.store.pendingOutbox, isEmpty);
    expect(s.snacks.messages.where((m) => m == outboxDeleteLossHint()),
        hasLength(1));
    expect(s.store.loggedMeals.map((m) => m.id), contains('m-alt'),
        reason: 'die Meldung verspricht die Wiedereinblendung — fuer eine '
            'Zeile ausserhalb des 35-Tage-Fensters muss sie gezielt geladen '
            'werden, nicht ueber den Fenster-Load');
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
    expect(s.snacks.messages.where((m) => m == outboxLossHint()), hasLength(1));
    expect(s.snacks.messages.where((m) => m == outboxDeleteLossHint()),
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

  // --- Luecke A: Eigen-Rezepte bekommen lokale Persistenz -------------------
  //
  // Mahlzeiten, Favoriten, Gewicht und Stats hingen von Anfang an in ZWEI
  // unabhaengigen Netzen: dem lokalen Write-Through-Cache UND der Outbox.
  // `user_recipes` hatte nur die Outbox. Faellt die aus — weil sie zugestellt
  // hat, weil der Cap sie gekappt hat, oder weil sie mangels Antwort nie
  // entstanden ist — war das selbst angelegte Rezept spurlos weg. Diese Tests
  // waren allesamt ROT, bevor `user_recipes` einen eigenen Cache-Slot bekam.

  test(
      'Luecke A: ein im Flugmodus angelegtes Rezept ueberlebt den Kaltstart — '
      'auch nachdem die Outbox es zugestellt hat und damit leer ist', () async {
    final kv = InMemoryKeyValueStore();

    final a = _setup(kv: kv);
    await _boot(a.store);
    a.server.offline = true;
    a.store.createUserRecipe(_recipe('user_flug', title: 'Flugmodus-Bowl'));
    await _settle();
    expect(a.store.userRecipes.map((r) => r.slug), contains('user_flug'),
        reason: 'Vorbedingung: im Flugmodus ist das Rezept sichtbar');

    // Nach der Landung stellt die Outbox zu und ist danach LEER — ab hier
    // haelt das Rezept lokal nur noch der Cache.
    a.server.offline = false;
    a.store.flushPendingWrites();
    await _settle();
    expect(a.store.pendingOutbox, isEmpty);
    // App wird beendet: der Lifecycle-Uebergang paused|hidden|detached ruft
    // flushPendingWrites() und erzwingt die entprellten Cache-Writes
    // (eatova_home_page.dart) — genau das wird hier modelliert.
    a.store.flushPendingWrites();
    await _settle();

    // Kaltstart, wieder ohne Netz.
    final b = _setup(kv: kv);
    b.server.offline = true;
    await _boot(b.store);

    expect(b.store.userRecipes.map((r) => r.slug), contains('user_flug'),
        reason: 'ohne Cache-Slot war das Rezept nach dem Kaltstart weg: die '
            'Outbox war das EINZIGE Netz und hatte ihre Schuldigkeit getan');
  });

  test(
      'Luecke A+B: haengt der Rezept-Write (Supabase-Aufrufe tragen kein '
      'Timeout), tragen BEIDE Netze — die Op liegt vor dem Write in der '
      'Outbox, das Rezept im Cache', () async {
    final kv = InMemoryKeyValueStore();
    final a = _setup(kv: kv);
    await _boot(a.store);
    a.server.hangRecipeWrites = true;

    a.store.createUserRecipe(_recipe('user_haenger'));
    await _settle();
    // Luecke B: ohne Antwort feuert weder `then` noch `catchError`. Frueher
    // entstand deshalb GAR KEINE Op — jetzt liegt sie schon vor dem Netz-Write.
    expect(a.store.pendingOutbox.map((o) => o.entityKey),
        contains('recipe:user_haenger'),
        reason: 'die Op darf nicht erst im Fehler-Callback entstehen — der '
            'kommt hier nie');
    a.store.flushPendingWrites();
    await _settle();
    // Luecke A: unabhaengig von der Outbox traegt der Cache-Slot das Rezept.
    expect((await a.cache.readUserRecipes())!.map((r) => r.slug),
        contains('user_haenger'),
        reason: 'zwei unabhaengige Netze — der Cache haelt auch ohne Op');

    // Kaltstart bewusst OHNE Netz: dass ein erfolgreicher Server-Load die
    // Liste bedingungslos ersetzt (Luecke C), ist ein eigener Schritt.
    final b = _setup(kv: kv);
    b.server.offline = true;
    await _boot(b.store);

    expect(b.store.userRecipes.map((r) => r.slug), contains('user_haenger'),
        reason: 'zwischen Tap und (ausbleibendem) Fehler existierte das '
            'Rezept nur im RAM');
  });

  test(
      'Luecke A: der Kaltstart ohne Netz zeigt die BESTEHENDEN Eigen-Rezepte '
      '— frueher waren dabei ALLE weg, nicht nur das neue', () async {
    final kv = InMemoryKeyValueStore();
    final a = _setup(kv: kv);
    // Echtes Profil im Cache: ohne Hydrationsquelle laesst der A1-Guard
    // _writeCacheSnapshot() gar nicht erst laufen (s. Test „A2: Ausloggen …").
    await a.cache.writeProfile(
        const UserProfile(weightKg: 80, onboardingCompleted: true));
    a.server.recipeRows['user_alt_1'] = _serverRecipeRow('user_alt_1');
    a.server.recipeRows['user_alt_2'] = _serverRecipeRow('user_alt_2');
    await _boot(a.store);
    expect(a.store.userRecipes.map((r) => r.slug),
        containsAll(<String>['user_alt_1', 'user_alt_2']),
        reason: 'Vorbedingung: der Boot hat sie vom Server geladen');
    a.store.flushPendingWrites();
    await _settle();

    final b = _setup(kv: kv);
    b.server.offline = true;
    await _boot(b.store);

    expect(b.store.userRecipes.map((r) => r.slug),
        containsAll(<String>['user_alt_1', 'user_alt_2']),
        reason: 'der Boot-Snapshot muss die Rezepte mitnehmen — sonst zeigt '
            'jeder Start im Flugmodus eine leere Eigen-Rezept-Liste');
  });

  test(
      'Luecke A: eine Offline-Loeschung ueberlebt den Kaltstart und reisst '
      'die uebrigen Eigen-Rezepte nicht mit', () async {
    final kv = InMemoryKeyValueStore();
    final a = _setup(kv: kv);
    await a.cache.writeProfile(
        const UserProfile(weightKg: 80, onboardingCompleted: true));
    a.server.recipeRows['user_bleibt'] = _serverRecipeRow('user_bleibt');
    a.server.recipeRows['user_weg'] = _serverRecipeRow('user_weg');
    await _boot(a.store);

    a.server.offline = true;
    a.store.deleteUserRecipe('user_weg');
    await _settle();
    a.store.flushPendingWrites();
    await _settle();

    final b = _setup(kv: kv);
    b.server.offline = true;
    await _boot(b.store);

    expect(b.store.userRecipes.map((r) => r.slug), contains('user_bleibt'));
    expect(
        b.store.userRecipes.map((r) => r.slug), isNot(contains('user_weg')));
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

  // --- Luecke C: der Boot-Load ersetzt die Eigen-Rezepte nicht mehr blind ---
  //
  // `_bootFromSupabase` setzte `_userRecipes = loadedRecipes` bedingungslos.
  // Einzige Gegenkraft war `_applyPendingOpsToState` — und die greift nur,
  // solange die Op noch in der Queue liegt. Ist sie nie entstanden (haengender
  // Live-Write, Luecke B) oder am Queue-Cap gefallen, war der Cache-Slot aus
  // Luecke A wertlos: der erste Start MIT Netz ueberschrieb ihn mit der
  // Serverliste, und `_writeCacheSnapshot` schrieb den Verlust anschliessend
  // fest.

  test(
      'Luecke C: ein nur lokal bekanntes Rezept ueberlebt den Boot MIT Netz — '
      'die Serverliste ERGAENZT den lokalen Stand, sie ersetzt ihn nicht',
      () async {
    final kv = InMemoryKeyValueStore();
    final seed = LocalCache(kv, 'user-outbox');
    await seed.writeProfile(
        const UserProfile(weightKg: 80, onboardingCompleted: true));
    // Der Cache traegt ein Rezept, das der Server NICHT kennt und fuer das
    // KEINE Outbox-Op existiert — genau der Zustand nach einem haengenden
    // Live-Write oder einem am Cap gefallenen Eintrag.
    await seed.writeUserRecipes(<FitnessRecipe>[_recipe('user_nur_lokal')]);

    final s = _setup(kv: kv);
    s.server.recipeRows['user_server'] = _serverRecipeRow('user_server');
    await _boot(s.store);

    expect(s.store.userRecipes.map((r) => r.slug),
        containsAll(<String>['user_nur_lokal', 'user_server']),
        reason: 'der Server-Load hat den lokalen Stand frueher restlos '
            'ueberschrieben');
    expect((await s.cache.readUserRecipes())!.map((r) => r.slug),
        contains('user_nur_lokal'),
        reason: 'der Boot-Snapshot darf den Verlust nicht auch noch '
            'festschreiben');
  });

  test(
      'Luecke C: ein lokal geloeschtes Rezept kommt NICHT zurueck, obwohl der '
      'Cache-Blob es noch fuehrt und der Server es kannte', () async {
    final kv = InMemoryKeyValueStore();
    final seed = LocalCache(kv, 'user-outbox');
    await seed.writeProfile(
        const UserProfile(weightKg: 80, onboardingCompleted: true));
    // Der Blob ist VERALTET: die Loeschung lag noch im 400-ms-Entprellfenster,
    // als die App starb. Die Outbox-Op dagegen liegt sofort auf der Platte.
    await seed.writeUserRecipes(
        <FitnessRecipe>[_recipe('user_bleibt'), _recipe('user_weg')]);
    await _seedRawOutbox(kv, [SyncOp.recipeDelete('user_weg').toJson()]);

    final s = _setup(kv: kv);
    s.server.recipeRows['user_bleibt'] = _serverRecipeRow('user_bleibt');
    s.server.recipeRows['user_weg'] = _serverRecipeRow('user_weg');
    await _boot(s.store);

    expect(s.store.userRecipes.map((r) => r.slug), contains('user_bleibt'));
    expect(s.store.userRecipes.map((r) => r.slug), isNot(contains('user_weg')),
        reason: 'der Merge muss vom LEBENDEN Stand ausgehen (Cache + bereits '
            'angewandte Ops), nicht vom rohen Cache-Blob — der kennt die '
            'Loeschung noch nicht');
    expect(s.server.recipeRows.keys, isNot(contains('user_weg')),
        reason: 'Vorbedingung: der Boot-Replay hat die Loeschung zugestellt');
    expect((await s.cache.readUserRecipes())!.map((r) => r.slug),
        isNot(contains('user_weg')));
  });

  test(
      'Fehlerbild des Nutzers: Flugmodus -> Rezept angelegt -> App zu -> '
      'Flugmodus aus -> App auf. Das Rezept ist noch da', () async {
    final kv = InMemoryKeyValueStore();
    final a = _setup(kv: kv);
    await a.cache.writeProfile(
        const UserProfile(weightKg: 80, onboardingCompleted: true));
    await _boot(a.store);
    // Flugmodus in seiner unangenehmen Form: der Request scheitert nicht, er
    // ANTWORTET NIE (Supabase-/PostgREST-Aufrufe tragen kein Timeout).
    a.server.hangRecipeWrites = true;
    a.store.createUserRecipe(_recipe('user_flugmodus', title: 'Flug-Bowl'));
    await _settle();
    expect(a.store.userRecipes.map((r) => r.slug), contains('user_flugmodus'),
        reason: 'Vorbedingung: im Flugmodus war das Rezept sichtbar');
    a.store.flushPendingWrites(); // App wird beendet
    await _settle();

    // Flugmodus aus, App auf — der frische Server kennt das Rezept nicht.
    final b = _setup(kv: kv);
    await _boot(b.store);

    expect(b.store.userRecipes.map((r) => r.slug), contains('user_flugmodus'),
        reason: 'genau hier war das Rezept weg: der erfolgreiche Server-Load '
            'ersetzte die Liste, und der Boot-Snapshot schrieb das fest');
  });

  // --- Luecke B: die Outbox-Op entsteht VOR dem Netz-Write ------------------
  //
  // `_syncOrQueue` feuerte den Live-Write und reihte die Op NUR im
  // `catchError` ein. Zwischen Tap und Fehler existierte der Eintrag nur im
  // RAM — und wenn der Request haengt statt zu scheitern, entsteht ueberhaupt
  // nie eine Op. Jetzt: Op anlegen und persistieren, dann zustellen, bei
  // Erfolg wieder entfernen.

  test(
      'Luecke B: die Op liegt schon in der PERSISTIERTEN Queue, bevor der '
      'Server geantwortet hat — und ist nach der Zustellung wieder raus',
      () async {
    final s = _setup();
    await _boot(s.store);

    s.store.createUserRecipe(_recipe('user_sofort'));
    // Bewusst OHNE _settle: der Live-Write ist noch unterwegs.
    expect(s.store.pendingOutbox.map((o) => o.entityKey),
        contains('recipe:user_sofort'),
        reason: 'zwischen Tap und Antwort existierte das Rezept nur im RAM');
    expect((await s.cache.readOutbox())!.map((o) => o.entityKey),
        contains('recipe:user_sofort'),
        reason: 'ein App-Kill in diesem Fenster darf das Rezept nicht kosten');

    await _settle();

    expect(s.server.recipeRows.keys, contains('user_sofort'));
    expect(s.store.pendingOutbox, isEmpty,
        reason: 'zugestellt heisst: die Op ist wieder raus');
    expect((await s.cache.readOutbox())!, isEmpty);
    // Der Erfolgspfad darf keinen Warteschlangen-Hinweis erzeugen.
    expect(s.snacks.offlineHints, isEmpty);
    expect(
        s.snacks.messages.where((m) => m.contains('erneut versucht')), isEmpty);
  });

  test(
      'Luecke B: ein haengender Live-Write blockiert die Outbox nicht — Ops '
      'anderer Entitaeten laufen weiter', () async {
    final s = _setup();
    await _boot(s.store);
    s.server.hangRecipeWrites = true;
    s.store.createUserRecipe(_recipe('user_haenger'));
    await _settle();

    // Zweite, unabhaengige Aenderung: offline eingereiht, danach online
    // nachgespielt. Sie muss trotz des haengenden Rezept-Requests durchkommen.
    s.server.offline = true;
    final id = s.store.addResultToDailyTotal(_result('Bowl'));
    await _settle();
    s.server.offline = false;
    s.store.flushPendingWrites();
    await _settle();

    expect(s.server.mealRows.keys, contains(id),
        reason: 'der Replay darf nicht am haengenden Rezept-Request stehen '
            'bleiben — sonst kostet EIN Request die ganze Queue');
    expect(s.store.pendingOutbox.map((o) => o.entityKey),
        contains('recipe:user_haenger'),
        reason: 'die haengende Op bleibt liegen und wird beim naechsten Start '
            'nachgeholt');
  });

  test(
      'Luecke B: auch der Mahlzeiten-Insert reiht ZUERST ein — die Op liegt '
      'auf der Platte, bevor der Server geantwortet hat', () async {
    final kv = InMemoryKeyValueStore();
    final s = _setup(kv: kv);
    await _boot(s.store);

    final id = s.store.addResultToDailyTotal(_result('Bowl'));
    // Bewusst OHNE jeden Event-Loop-Durchlauf und direkt am rohen Blob: genau
    // so sieht ein App-Kill unmittelbar nach dem Tap die Platte. Der
    // wertvollste Write der App hatte bis hierher sein eigenes
    // then/catchError — und damit dieselbe Luecke wie _syncOrQueue.
    expect(s.store.pendingOutbox.map((o) => o.entityKey), contains('meal:$id'));
    expect(kv.snapshot['eatova.v1.outbox.user-outbox'],
        contains('"entity_id":"$id"'));

    await _settle();
    expect(s.server.mealRows.keys, contains(id));
    expect(s.store.pendingOutbox, isEmpty);
  });

  test(
      'Luecke B: die kurz eingereihte mealInsert-Op wird nicht zusaetzlich '
      'nachgespielt — ein POST, eine gezaehlte Mahlzeit', () async {
    final s = _setup();
    await _boot(s.store);
    s.store.addResultToDailyTotal(_result('Bowl'));
    await _settle();
    s.store.flushPendingWrites();
    await _settle();

    expect(s.store.pendingOutbox, isEmpty);
    expect(
        s.server.requests.where((r) =>
            r.method == 'POST' && r.url.path.contains('/logged_meals')),
        hasLength(1));
    expect(s.server.mealsCounted, 1,
        reason: 'sonst zaehlten Live-Write UND Replay dieselbe Mahlzeit');
  });

  test(
      'Luecke B: eine zweite Aenderung waehrend des laufenden Live-Writes '
      'erzeugt keinen falschen Warteschlangen-Hinweis', () async {
    final s = _setup();
    await _boot(s.store);

    s.store.createUserRecipe(_recipe('user_doppelt', title: 'Erste Fassung'));
    s.store.createUserRecipe(_recipe('user_doppelt', title: 'Zweite Fassung'));
    await _settle();

    expect(s.snacks.messages.where((m) => m.contains('erneut versucht')),
        isEmpty,
        reason: 'nichts ist fehlgeschlagen — der Hinweis waere gelogen');
    expect(s.store.pendingOutbox, isEmpty);
    expect(s.server.recipeRows['user_doppelt']!['title'], 'Zweite Fassung',
        reason: 'der juengere Stand gewinnt, die Reihenfolge bleibt');
  });
  // --- Luecke D: Profil-Aenderungen ueberleben Offline ----------------------
  //
  // Der zweite echte Datenverlust — vom Nutzer nie gemeldet, weil er still
  // passiert. `applySettings`/`completeOnboarding` schrieben in den Cache und
  // direkt gegen Supabase, OHNE Outbox: offline geaendertes Gewicht/kcal-Ziel/
  // Diaet lag danach nur im Cache. Der naechste Start MIT Netz hydrierte
  // daraus, ueberschrieb den Stand mit der ALTEN Serverzeile
  // (`_bootFromSupabase`) und schrieb die alte Zeile per
  // `_writeCacheSnapshot` auch noch ueber den Cache. Die Aenderung war
  // restlos und ohne Hinweis weg.

  test(
      'Luecke D: offline geaendertes Gewicht steht nach dem naechsten '
      'ONLINE-Start noch da — und ist zugestellt', () async {
    final kv = InMemoryKeyValueStore();
    final a = _setup(kv: kv);
    a.server.profileRow = _serverProfileRow(_profile(weightKg: 80));
    await _boot(a.store);
    expect(a.store.profile.weightKg, 80,
        reason: 'Vorbedingung: der Boot hat den Server-Stand hydriert');

    a.server.offline = true;
    await a.store.applySettings(
      newProfile: a.store.profile.copyWith(weightKg: 84, dailyKcalGoal: 1900),
      notificationsEnabled: false,
    );
    await _settle();
    expect(a.store.profile.weightKg, 84,
        reason: 'Vorbedingung: offline sieht der Nutzer seinen neuen Wert');
    a.store.flushPendingWrites(); // App wird beendet
    await _settle();

    // Neustart MIT Netz. Der Server kennt weiterhin nur den alten Stand —
    // genau der Moment, in dem die Aenderung frueher verschwand.
    final b = _setup(kv: kv);
    b.server.profileRow = _serverProfileRow(_profile(weightKg: 80));
    await _boot(b.store);

    expect(b.store.profile.weightKg, 84,
        reason: 'die Serverzeile darf eine pendende Profil-Aenderung nicht '
            'ueberschreiben');
    expect(b.store.profile.dailyKcalGoal, 1900);
    expect(b.server.profileRow!['weight_kg'], 84,
        reason: 'und sie muss zugestellt werden, nicht nur lokal ueberleben');
    expect((await b.cache.readProfile())!.weightKg, 84,
        reason: 'der Boot-Snapshot darf den Verlust nicht auch noch '
            'festschreiben');
  });

  test(
      'Luecke D: offline aendern, OFFLINE neu starten — der neue Wert steht',
      () async {
    final kv = InMemoryKeyValueStore();
    final a = _setup(kv: kv);
    a.server.profileRow = _serverProfileRow(_profile(weightKg: 80));
    await _boot(a.store);

    a.server.offline = true;
    await a.store.applySettings(
      newProfile: a.store.profile.copyWith(weightKg: 84),
      notificationsEnabled: false,
    );
    await _settle();
    a.store.flushPendingWrites();
    await _settle();

    final b = _setup(kv: kv);
    b.server.offline = true;
    await _boot(b.store);

    expect(b.store.profile.weightKg, 84);
    expect(b.store.pendingOutbox.map((o) => o.kind),
        contains(SyncOpKind.profileUpsert),
        reason: 'die Zustellung steht weiterhin aus und muss die Sitzung '
            'ueberleben');
  });

  test(
      'Luecke D: zwei Offline-Aenderungen erzeugen EINE Op — das Profil ist '
      'eine einzelne Zeile, die letzte Aenderung gewinnt', () async {
    final a = _setup();
    a.server.profileRow = _serverProfileRow(_profile(weightKg: 80));
    await _boot(a.store);

    a.server.offline = true;
    await a.store.applySettings(
      newProfile: a.store.profile.copyWith(weightKg: 84),
      notificationsEnabled: false,
    );
    await _settle();
    await a.store.applySettings(
      newProfile: a.store.profile.copyWith(weightKg: 86, dailyKcalGoal: 2000),
      notificationsEnabled: false,
    );
    await _settle();

    final profilOps = a.store.pendingOutbox
        .where((o) => o.kind == SyncOpKind.profileUpsert)
        .toList();
    expect(profilOps, hasLength(1),
        reason: 'zwei Ops wuerden sich beim Replay gegenseitig ueberholen');
    expect(profilOps.single.profile!.weightKg, 86);
    expect(profilOps.single.profile!.dailyKcalGoal, 2000);

    a.server.offline = false;
    a.store.flushPendingWrites();
    await _settle();

    expect(a.server.profileRow!['weight_kg'], 86);
    expect(a.server.profileRow!['daily_kcal_goal'], 2000);
    expect(
        a.server.requests.where(
            (r) => r.method == 'POST' && r.url.path.contains('/profiles')),
        hasLength(1),
        reason: 'genau ein Zustellversuch fuer beide Aenderungen');
    expect(a.store.pendingOutbox, isEmpty);
  });

  test(
      'Luecke D: der Profil-Save meldet die WARTESCHLANGE, nicht mehr '
      '„bitte speichere es später erneut" — es gibt jetzt einen Auto-Retry',
      () async {
    final a = _setup();
    a.server.profileRow = _serverProfileRow(_profile(weightKg: 80));
    await _boot(a.store);

    a.server.offline = true;
    await a.store.applySettings(
      newProfile: a.store.profile.copyWith(weightKg: 84),
      notificationsEnabled: false,
    );
    await _settle();

    expect(a.snacks.offlineHints.single,
        'Offline — wird synchronisiert, sobald du wieder online bist.',
        reason: 'die alte Meldung bat den Nutzer, spaeter selbst erneut zu '
            'speichern — das waere jetzt gelogen');
    expect(a.snacks.tones, isNot(contains(SnackTone.error)),
        reason: 'eine Warteschlange ist kein Fehler');
  });

  test(
      'Luecke D: ein offline abgeschlossenes Onboarding ueberlebt den '
      'naechsten ONLINE-Start — sonst wirft die Bootstrap-Zeile den Nutzer '
      'zurueck und seine Koerperdaten sind weg', () async {
    final kv = InMemoryKeyValueStore();
    // Die Zeile, die der Signup-Trigger anlegt: Defaults, Onboarding offen.
    Map<String, dynamic> bootstrapZeile() =>
        _serverProfileRow(const UserProfile());

    final a = _setup(kv: kv);
    a.server.profileRow = bootstrapZeile();
    await _boot(a.store);
    expect(a.store.needsOnboarding, isTrue, reason: 'Vorbedingung');

    a.server.offline = true;
    await a.store.completeOnboarding(
        const UserProfile(weightKg: 91, heightCm: 186, onboardingCompleted: true));
    await _settle();
    a.store.flushPendingWrites();
    await _settle();

    final b = _setup(kv: kv);
    b.server.profileRow = bootstrapZeile();
    await _boot(b.store);

    expect(b.store.profile.weightKg, 91);
    expect(b.store.needsOnboarding, isFalse,
        reason: 'die alte Bootstrap-Zeile schickte den Nutzer erneut durchs '
            'Onboarding — mit den Defaults statt seinen Angaben');
    expect(b.server.profileRow!['weight_kg'], 91);
    expect(b.server.profileRow!['onboarding_completed'], isTrue);
  });

  test(
      'Luecke D: eine pendende Profil-Op IST eine echte Quelle — sonst '
      'verschluckt der Clobber-Schutz die naechste Aenderung', () async {
    final kv = InMemoryKeyValueStore();
    // Nur die Outbox liegt auf der Platte: der Profil-Slot fehlt (korrupt oder
    // von clear() geraeumt), der Server ist weg. Der Zustand entsteht also
    // ALLEIN aus der Op — und die traegt ein echtes, vom Nutzer eingegebenes
    // Profil, keine Ctor-Defaults.
    await _seedRawOutbox(kv, <Map<String, dynamic>>[
      SyncOp.profileUpsert(_profile(weightKg: 91, dailyKcalGoal: 1800))
          .toJson(),
    ]);

    final s = _setup(kv: kv);
    s.server.offline = true;
    await _boot(s.store);

    expect(s.store.profile.weightKg, 91);

    // Der eigentliche Punkt: die naechste Aenderung muss ankommen. Gilt der
    // Zustand als „nicht aus echter Quelle hydriert", sperrt der A1-Guard sie
    // stumm weg — kein Cache-Write, keine Op, kein Hinweis.
    await s.store.applySettings(
      newProfile: s.store.profile.copyWith(weightKg: 92),
      notificationsEnabled: false,
    );
    await _settle();

    final imCache = await s.cache.readProfile();
    expect(imCache, isNotNull,
        reason: 'ohne diese Zuordnung schrieb applySettings gar nichts mehr — '
            'weder Cache noch Op, und ohne jeden Hinweis');
    expect(imCache!.weightKg, 92);
    expect(
        s.store.pendingOutbox
            .where((o) => o.kind == SyncOpKind.profileUpsert)
            .single
            .profile!
            .weightKg,
        92);
  });

  test(
      'Luecke D: auch die Diaet-Praeferenz ueberlebt — sie ist Teil derselben '
      'Profilzeile', () async {
    final kv = InMemoryKeyValueStore();
    final a = _setup(kv: kv);
    a.server.profileRow = _serverProfileRow(_profile());
    await _boot(a.store);

    a.server.offline = true;
    await a.store.applySettings(
      newProfile: a.store.profile.copyWith(diet: DietPreference.vegan),
      notificationsEnabled: false,
    );
    await _settle();
    a.store.flushPendingWrites();
    await _settle();

    final b = _setup(kv: kv);
    b.server.profileRow = _serverProfileRow(_profile());
    await _boot(b.store);

    expect(b.store.profile.diet, DietPreference.vegan);
    expect(b.server.profileRow!['diet_preference'], 'vegan');
  });

  // --- Luecke E: der Store MELDET den Ausgang, statt ihn behaupten zu lassen -
  //
  // Der Rezepte-Screen zeigte „„X" gespeichert." synchron und unbedingt und
  // bekam vom Store danach ggf. den generischen Warteschlangen-Hinweis
  // hinterhergeschoben (der den ersten Toast sofort wieder abraeumt). Jetzt
  // gibt der Store zurueck, was wirklich passiert ist, und ueberlaesst dem
  // Aufrufer die EINE Meldung.

  test('Luecke E: ein zugestelltes Rezept meldet delivered', () async {
    final s = _setup();
    await _boot(s.store);

    expect(await s.store.createUserRecipe(_recipe('user_ok')),
        SyncDelivery.delivered);
    expect(s.server.recipeRows.keys, contains('user_ok'));
  });

  test(
      'Luecke E: offline eingereiht meldet queuedOffline — und der Store '
      'toastet NICHT mehr selbst', () async {
    final s = _setup();
    await _boot(s.store);
    s.server.offline = true;

    expect(await s.store.createUserRecipe(_recipe('user_offline')),
        SyncDelivery.queuedOffline);
    await _settle();

    expect(s.store.pendingOutbox.map((o) => o.entityKey),
        contains('recipe:user_offline'));
    expect(s.snacks.messages, isEmpty,
        reason: 'zwei Meldungen hintereinander („gespeichert." und gleich '
            'darauf „Offline — …") waren der Bug; der Aufrufer sagt jetzt '
            'beides in einem Satz');
  });

  test('Luecke E: eine Server-Ablehnung meldet queuedRetry, nicht Offline',
      () async {
    final s = _setup();
    await _boot(s.store);
    // 500 auf user_recipes-Writes: der Server ANTWORTET, „Offline" waere
    // gelogen.
    s.server.rejectRecipeWrites = true;

    expect(await s.store.createUserRecipe(_recipe('user_500')),
        SyncDelivery.queuedRetry);
    expect(s.snacks.messages, isEmpty);
  });

  test('Luecke E: die Loeschung meldet ihren Ausgang genauso', () async {
    final s = _setup();
    s.server.recipeRows['user_weg'] = _serverRecipeRow('user_weg');
    await _boot(s.store);
    s.server.offline = true;

    expect(await s.store.deleteUserRecipe('user_weg'),
        SyncDelivery.queuedOffline);
    expect(s.snacks.messages, isEmpty);
  });

  test(
      'Luecke E: ein haengender Write blockiert die Rueckmeldung nicht ewig — '
      'nach dem Feedback-Fenster gilt „liegt in der Warteschlange"', () async {
    // Supabase-/PostgREST-Aufrufe tragen kein Timeout (Luecke B). Ohne eigenes
    // Fenster wartete der Aufrufer — und mit ihm die Erfolgsmeldung des
    // Nutzers — unbegrenzt auf eine Antwort, die nie kommt. Der Test wartet
    // deshalb bewusst echte [kSyncDeliveryWindow].
    final s = _setup();
    await _boot(s.store);
    s.server.hangRecipeWrites = true;

    final ausgang = await s.store.createUserRecipe(_recipe('user_haenger'));

    expect(ausgang, SyncDelivery.queuedRetry);
    expect(s.store.pendingOutbox.map((o) => o.entityKey),
        contains('recipe:user_haenger'),
        reason: 'die Meldung darf nur behaupten, was auch stimmt: die Op liegt '
            'in der persistierten Queue');
  }, timeout: const Timeout(Duration(seconds: 30)));

  // --- Luecke F: ein Lesefehler kippt nicht mehr die ganze Outbox -----------
  //
  // Alle sieben Cache-Reads der Boot-Hydration lagen in EINEM try, readOutbox
  // war der sechste. Wirft einer der fuenf davor, blieb `_outbox` leer — und
  // der naechste `_enqueueOp` schrieb via `_persistOutbox()` eine frische
  // Ein-Element-Queue ueber den Blob. Bis zu kOutboxMaxOps nicht zugestellte
  // Writes waren damit endgueltig weg.

  test(
      'Luecke F: ein Lesefehler im Profil-Slot laesst die Outbox unangetastet',
      () async {
    final kv = InMemoryKeyValueStore();
    final a = _setup(kv: kv);
    await _boot(a.store);
    a.server.offline = true;
    final id = a.store.addResultToDailyTotal(_result('Offline-Bowl'));
    await _settle();
    expect((await a.cache.readOutbox())!.map((o) => o.entityKey),
        contains('meal:$id'),
        reason: 'Vorbedingung: der Blob traegt den nicht zugestellten Write');

    // Kaltstart, bei dem AUSGERECHNET der erste Slot wirft.
    final b = _setup(
      injizierterCache: _ProfilLesefehlerCache(kv, 'user-outbox'),
    );
    b.server.offline = true;
    await _boot(b.store);

    expect(b.store.pendingOutbox.map((o) => o.entityKey), contains('meal:$id'),
        reason: 'der Wurf im Profil-Slot uebersprang frueher jeden weiteren '
            'Read — auch den der Outbox');

    // Und der Beweis, warum das teuer war: der naechste Write persistiert die
    // Queue. Stand sie leer da, war der Blob danach ueberschrieben.
    final zweite = b.store.addResultToDailyTotal(_result('Zweite-Bowl'));
    await _settle();
    final blob = await b.cache.readOutbox();
    expect(blob!.map((o) => o.entityKey), containsAll(<String>[
      'meal:$id',
      'meal:$zweite',
    ]));
  });

  test(
      'Luecke F: ein Lesefehler im Outbox-Slot selbst ueberschreibt den Blob '
      'nicht — der naechste Schreibversuch holt ihn nach', () async {
    final kv = InMemoryKeyValueStore();
    final a = _setup(kv: kv);
    await _boot(a.store);
    a.server.offline = true;
    final id = a.store.addResultToDailyTotal(_result('Alt-Bowl'));
    await _settle();

    final kaputt = _OutboxLesefehlerCache(kv, 'user-outbox');
    final b = _setup(injizierterCache: kaputt);
    b.server.offline = true;
    await _boot(b.store);
    expect(b.store.pendingOutbox, isEmpty,
        reason: 'Vorbedingung: die Hydration konnte den Blob nicht lesen');

    final neue = b.store.addResultToDailyTotal(_result('Neu-Bowl'));
    await _settle();

    final blob = await b.cache.readOutbox();
    expect(blob!.map((o) => o.entityKey), containsAll(<String>[
      'meal:$id',
      'meal:$neue',
    ]), reason: 'ein fehlgeschlagener Lesevorgang darf NIE die Grundlage '
        'eines Ueberschreibens sein');
    // Der nachgeholte Write ist auch wieder sichtbar — er haengt nicht als
    // unsichtbare Op in der Queue.
    expect(b.store.loggedMeals.map((m) => m.id), contains(id));
  });

  // =========================================================================
  // GEGENVERIFIKATION (Zweitpruefung 2026-08-10)
  //
  // Alles oben ist von denselben Haenden geschrieben worden wie der jeweilige
  // Fix — ein Test, der zum Fix passt, beweist nur, dass beide dieselbe
  // Annahme teilen. Die folgenden Tests gehen von der GEMELDETEN HANDLUNG aus
  // und greifen die Nachbarfaelle an, die in keiner der vier Runden vorkamen:
  // die Gegenrichtung (Loeschen), die Kombination (anlegen + loeschen), die
  // Wiederholung (zwei Starts), den antwortenden Server (500 statt Netz weg),
  // den fehlenden Cache und den Nutzerwechsel.
  // =========================================================================

  test(
      'Gegenprobe 1 — der gemeldete Fall wortgetreu: Flugmodus AN, Rezept '
      'angelegt, Store weggeworfen, Flugmodus AUS, Boot. Das Rezept ist da '
      'UND beim Server angekommen', () async {
    final kv = InMemoryKeyValueStore();
    final a = _setup(kv: kv);
    await a.cache.writeProfile(
        const UserProfile(weightKg: 80, onboardingCompleted: true));
    await _boot(a.store);

    // Flugmodus an: der Request SCHEITERT (ClientException) — das ist die
    // Form, die der Nutzer beschrieben hat. Der haengende Request ist der
    // andere Fall und hat oben seinen eigenen Test.
    a.server.offline = true;
    final ausgang =
        await a.store.createUserRecipe(_recipe('user_gemeldet', title: 'Bowl'));
    expect(ausgang, SyncDelivery.queuedOffline);
    expect(a.store.userRecipes.map((r) => r.slug), contains('user_gemeldet'),
        reason: 'Vorbedingung des Berichts: „war sichtbar"');

    // App zu (Lifecycle paused|hidden|detached).
    a.store.flushPendingWrites();
    await _settle();

    // Flugmodus aus, App auf: NEUER Store, NEUER Server (kennt das Rezept
    // nicht), DERSELBE Cache.
    final b = _setup(kv: kv);
    await _boot(b.store);

    expect(b.store.userRecipes.map((r) => r.slug), contains('user_gemeldet'),
        reason: 'genau hier war das Rezept weg');
    expect(b.server.recipeRows.keys, contains('user_gemeldet'),
        reason: 'sichtbar reicht nicht — es muss auch ankommen, sonst haengt '
            'der Bestand fuer immer an diesem einen Geraet');
    expect(b.store.pendingOutbox, isEmpty);
    expect((await b.cache.readUserRecipes())!.map((r) => r.slug),
        contains('user_gemeldet'));
  });

  test(
      'Gegenprobe 2 — die Gegenrichtung: offline GELOESCHT, dann online neu '
      'gestartet. Das Rezept aufersteht nicht, und die Loeschung kommt an',
      () async {
    final kv = InMemoryKeyValueStore();
    final a = _setup(kv: kv);
    await a.cache.writeProfile(
        const UserProfile(weightKg: 80, onboardingCompleted: true));
    a.server.recipeRows['user_bleibt'] = _serverRecipeRow('user_bleibt');
    a.server.recipeRows['user_weg'] = _serverRecipeRow('user_weg');
    await _boot(a.store);
    expect(a.store.userRecipes.map((r) => r.slug),
        containsAll(<String>['user_bleibt', 'user_weg']),
        reason: 'Vorbedingung: beide sind da');

    a.server.offline = true;
    expect(await a.store.deleteUserRecipe('user_weg'),
        SyncDelivery.queuedOffline);
    a.store.flushPendingWrites();
    await _settle();

    // Neustart MIT Netz. Der Server fuehrt die Zeile weiter — die Loeschung
    // ist ja nie angekommen. Ohne Replay-vor-Boot und ohne die Ueberlagerung
    // durch die pendende Op waere das Rezept jetzt wieder da.
    final b = _setup(kv: kv);
    b.server.recipeRows['user_bleibt'] = _serverRecipeRow('user_bleibt');
    b.server.recipeRows['user_weg'] = _serverRecipeRow('user_weg');
    await _boot(b.store);

    expect(b.store.userRecipes.map((r) => r.slug), contains('user_bleibt'));
    expect(b.store.userRecipes.map((r) => r.slug), isNot(contains('user_weg')),
        reason: 'eine Loeschung, die wiederkommt, ist derselbe Vertrauens'
            'bruch wie ein Rezept, das verschwindet');
    expect(b.server.recipeRows.keys, isNot(contains('user_weg')),
        reason: 'lokal weg reicht nicht — sonst kommt es auf dem naechsten '
            'Geraet zurueck');
    expect((await b.cache.readUserRecipes())!.map((r) => r.slug),
        isNot(contains('user_weg')));
  });

  test(
      'Gegenprobe 3 — offline ANGELEGT und offline wieder GELOESCHT: nach der '
      'Landung existiert es weder lokal noch beim Server', () async {
    final kv = InMemoryKeyValueStore();
    final s = _setup(kv: kv);
    await s.cache.writeProfile(
        const UserProfile(weightKg: 80, onboardingCompleted: true));
    await _boot(s.store);

    s.server.offline = true;
    await s.store.createUserRecipe(_recipe('user_kurz'));
    await _settle();
    await s.store.deleteUserRecipe('user_kurz');
    await _settle();

    // Der Delete darf den Upsert NICHT wegkoaleszieren: die Reihenfolge pro
    // Entitaet ist der ganze Verlass des Replays. Waere nur der Delete
    // uebrig, entstuende serverseitig nie eine Zeile — das faellt hier nicht
    // auf, aber der umgekehrte Fall (nur der Upsert bleibt) waere ein
    // wiederauferstandenes Rezept.
    expect(
        s.store.pendingOutbox
            .where((o) => o.entityKey == 'recipe:user_kurz')
            .map((o) => o.kind)
            .toList(),
        <SyncOpKind>[SyncOpKind.recipeUpsert, SyncOpKind.recipeDelete]);

    s.server.offline = false;
    s.store.flushPendingWrites();
    await _settle();

    expect(s.store.pendingOutbox, isEmpty);
    expect(s.server.recipeRows.keys, isNot(contains('user_kurz')),
        reason: 'insert -> delete muss den Replay in dieser Reihenfolge '
            'ueberleben, sonst bleibt eine Leiche auf dem Server');
    expect(
        s.store.userRecipes.map((r) => r.slug), isNot(contains('user_kurz')));

    final b = _setup(kv: kv);
    await _boot(b.store);
    expect(
        b.store.userRecipes.map((r) => r.slug), isNot(contains('user_kurz')),
        reason: 'auch der naechste Kaltstart darf es nicht zurueckholen');
  });

  test(
      'Gegenprobe 4 — offline angelegt, OFFLINE neu gestartet, DANN online: '
      'genau EINE Zustellung. Zwei Netze duerfen nicht zweimal liefern',
      () async {
    final kv = InMemoryKeyValueStore();
    final a = _setup(kv: kv);
    await a.cache.writeProfile(
        const UserProfile(weightKg: 80, onboardingCompleted: true));
    await _boot(a.store);
    a.server.offline = true;
    await a.store.createUserRecipe(_recipe('user_zweimal'));
    a.store.flushPendingWrites();
    await _settle();

    final b = _setup(kv: kv);
    b.server.offline = true;
    await _boot(b.store);
    expect(b.store.userRecipes.map((r) => r.slug), contains('user_zweimal'),
        reason: 'Vorbedingung: der zweite Start ohne Netz zeigt es');
    expect(b.store.pendingOutbox.map((o) => o.entityKey),
        contains('recipe:user_zweimal'),
        reason: 'Vorbedingung: die Zustellung steht weiterhin aus');

    b.server.offline = false;
    b.store.flushPendingWrites();
    await _settle();

    expect(
        b.server.requests.where((r) =>
            r.method == 'POST' && r.url.path.contains('/user_recipes')),
        hasLength(1),
        reason: 'der Cache-Stand darf keine zweite Zustellung ausloesen — '
            'der Upsert waere zwar idempotent, aber ein doppelter Write ist '
            'der erste Schritt zu einem doppelten Zaehler');
    expect(b.server.recipeRows.keys, contains('user_zweimal'));
    expect(b.store.pendingOutbox, isEmpty);
  });

  test(
      'Gegenprobe 5 — ZWEI Rezepte offline: beide ueberleben den Kaltstart, '
      'beide kommen an, die Reihenfolge bleibt stabil', () async {
    final kv = InMemoryKeyValueStore();
    final a = _setup(kv: kv);
    await a.cache.writeProfile(
        const UserProfile(weightKg: 80, onboardingCompleted: true));
    await _boot(a.store);

    a.server.offline = true;
    await a.store.createUserRecipe(_recipe('user_eins', title: 'Eins'));
    await _settle();
    await a.store.createUserRecipe(_recipe('user_zwei', title: 'Zwei'));
    await _settle();
    expect(a.store.userRecipes.map((r) => r.slug).toList(),
        <String>['user_zwei', 'user_eins'],
        reason: 'zuletzt angelegt steht oben — darauf schaut der Nutzer');
    a.store.flushPendingWrites();
    await _settle();

    final b = _setup(kv: kv);
    b.server.offline = true;
    await _boot(b.store);
    expect(b.store.userRecipes.map((r) => r.slug).toList(),
        <String>['user_zwei', 'user_eins'],
        reason: 'Cache-Blob und Op-Ueberlagerung duerfen die Liste nicht '
            'durcheinanderbringen');

    b.server.offline = false;
    b.store.flushPendingWrites();
    await _settle();

    expect(b.server.recipeRows.keys,
        containsAll(<String>['user_eins', 'user_zwei']));
    expect(b.store.userRecipes.map((r) => r.slug),
        containsAll(<String>['user_eins', 'user_zwei']));
    expect(b.store.pendingOutbox, isEmpty);
  });

  test(
      'Gegenprobe 6 — der Server ANTWORTET beim Replay mit 500: das Rezept '
      'bleibt sichtbar, die Op bleibt liegen, nichts wird als Verlust '
      'gemeldet', () async {
    final kv = InMemoryKeyValueStore();
    final a = _setup(kv: kv);
    await a.cache.writeProfile(
        const UserProfile(weightKg: 80, onboardingCompleted: true));
    await _boot(a.store);
    a.server.offline = true;
    await a.store.createUserRecipe(_recipe('user_500'));
    a.store.flushPendingWrites();
    await _settle();

    // Neustart: Netz da, aber user_recipes-Writes werden abgelehnt. Der
    // LESENDE Boot-Load laeuft durch und liefert eine LEERE Liste — genau die
    // Kombination, an der ein „Server gewinnt"-Boot das Rezept verschluckte.
    final b = _setup(kv: kv);
    b.server.rejectRecipeWrites = true;
    await _boot(b.store);

    expect(b.store.userRecipes.map((r) => r.slug), contains('user_500'));
    final op = b.store.pendingOutbox
        .where((o) => o.entityKey == 'recipe:user_500')
        .single;
    expect(op.attempts, 1, reason: 'ein 500 verbrennt genau einen Versuch');
    expect((await b.cache.readUserRecipes())!.map((r) => r.slug),
        contains('user_500'),
        reason: 'der Boot-Snapshot darf den Stand nicht wegschreiben');
    expect(b.snacks.messages, isNot(contains(outboxLossHint())),
        reason: 'ein retrybarer 500 ist kein Verlust');

    // Erholung vor dem Budget-Ende: der naechste Flush stellt zu.
    b.server.rejectRecipeWrites = false;
    b.store.flushPendingWrites();
    await _settle();
    expect(b.server.recipeRows.keys, contains('user_500'));
    expect(b.store.pendingOutbox, isEmpty);
  });

  test(
      'Gegenprobe 7 — KEIN Cache (DEK weg): der Store taeuscht keinen Erfolg '
      'vor. Das Rezept bleibt sichtbar, gilt als eingereiht (nicht als '
      'zugestellt) und geht raus, sobald das Netz wieder da ist', () async {
    final s = _setupOhneCache();
    await _boot(s.store);
    s.server.offline = true;

    final ausgang = await s.store.createUserRecipe(_recipe('user_ohne_cache'));

    expect(ausgang, SyncDelivery.queuedOffline,
        reason: 'ohne Cache waere ein blankes „gespeichert." die Luege — der '
            'Aufrufer muss den Warteschlangen-Zusatz bekommen');
    expect(s.store.userRecipes.map((r) => r.slug), contains('user_ohne_cache'));
    expect(s.store.pendingOutbox.map((o) => o.entityKey),
        contains('recipe:user_ohne_cache'),
        reason: 'die Op existiert — nur persistieren kann sie sich nirgends');

    s.server.offline = false;
    s.store.flushPendingWrites();
    await _settle();

    expect(s.server.recipeRows.keys, contains('user_ohne_cache'),
        reason: 'innerhalb der Sitzung traegt die Outbox auch ohne Platte');
    expect(s.store.pendingOutbox, isEmpty);
  });

  test(
      'Gegenprobe 8 — Nutzerwechsel: die Eigen-Rezepte von A tauchen bei B '
      'nicht auf, und A bekommt sie beim naechsten Login zurueck', () async {
    final kv = InMemoryKeyValueStore();
    final a = _setup(injizierterCache: LocalCache(kv, 'user-a'));
    await _boot(a.store);
    a.server.offline = true;
    await a.store.createUserRecipe(_recipe('user_a_geheim'));
    a.store.flushPendingWrites();
    await _settle();
    expect(kv.snapshot.keys, contains('eatova.v1.user_recipes.user-a'),
        reason: 'Vorbedingung: A hat wirklich etwas auf der Platte');

    await a.store.signOutCleanup();
    expect(kv.snapshot.keys, isNot(contains('eatova.v1.user_recipes.user-a')),
        reason: 'Zutaten und Mengen sind Nutzerinhalt — der Slot faellt beim '
            'Logout auch dann, wenn die Outbox erhalten bleibt (M-1)');

    // B meldet sich auf demselben Geraet an.
    final b = _setup(injizierterCache: LocalCache(kv, 'user-b'));
    b.server.offline = true;
    await _boot(b.store);

    expect(b.store.userRecipes, isEmpty,
        reason: 'jeder Slot-Name traegt die User-ID — B liest seinen eigenen, '
            'leeren Namensraum');
    expect(b.store.pendingOutbox, isEmpty,
        reason: 'auch die beim Logout ERHALTENE Outbox gehoert A, nicht B');

    // A wieder da: die erhaltene Outbox ist der Grund, warum der Rezept-Slot
    // beim Logout ueberhaupt fallen darf.
    final a2 = _setup(injizierterCache: LocalCache(kv, 'user-a'));
    a2.server.offline = true;
    await _boot(a2.store);
    expect(a2.store.userRecipes.map((r) => r.slug), contains('user_a_geheim'));
  });

  test(
      'Gegenprobe 9 — EIN Netz faellt aus: der Outbox-Slot ist beim Lesen '
      'kaputt, der Cache traegt allein. Ein Boot MIT Netz darf das Rezept '
      'trotzdem nicht wegwerfen', () async {
    // Der Kern der ganzen Reparatur, auf dem einzigen Weg geprueft, der ohne
    // vorgesetzten Cache-Blob auskommt: das Rezept entsteht durch die echte
    // Nutzer-Handlung, und danach faellt genau EINES der beiden Netze aus.
    // Bleibt der Bestand, waren es wirklich zwei; faellt er, war die Outbox
    // immer noch das einzige.
    final kv = InMemoryKeyValueStore();
    final a = _setup(kv: kv);
    await a.cache.writeProfile(
        const UserProfile(weightKg: 80, onboardingCompleted: true));
    await _boot(a.store);
    a.server.offline = true;
    await a.store.createUserRecipe(_recipe('user_nur_cache'));
    a.store.flushPendingWrites();
    await _settle();

    // Kaltstart MIT Netz — und der Outbox-Slot wirft beim Lesen (Luecke F).
    // Die Op ist fuer diesen Start damit unsichtbar, der Server kennt das
    // Rezept nicht: genau der Zustand, in dem `_userRecipes = loadedRecipes`
    // es verschluckte und `_writeCacheSnapshot` den Verlust festschrieb.
    final b =
        _setup(injizierterCache: _OutboxLesefehlerCache(kv, 'user-outbox'));
    await _boot(b.store);

    expect(b.store.pendingOutbox, isEmpty,
        reason: 'Vorbedingung: das Outbox-Netz ist fuer diesen Start weg');
    expect(b.store.userRecipes.map((r) => r.slug), contains('user_nur_cache'),
        reason: 'EIN Netz muss reichen — sonst waren es nie zwei');
    expect((await b.cache.readUserRecipes())!.map((r) => r.slug),
        contains('user_nur_cache'),
        reason: 'und der Boot-Snapshot darf den Verlust nicht auch noch '
            'festschreiben');
  });

  // --- Frage 3: gibt es noch eine Datenart mit nur EINEM Netz? -------------
  //
  // Die Inventur in EINER Offline-Sitzung: mutieren, App killen, ohne Netz
  // neu starten. Fuer jede Sammlung muss BEIDES belegbar sein — der eigene
  // Cache-Slot (Netz 1) und die persistierte Op (Netz 2). Faellt eines der
  // beiden aus, ist die Sammlung wieder da, wo `user_recipes` vor dem Fix war.

  test(
      'Inventur: jede Nutzer-Sammlung haelt ihren Offline-Stand in ZWEI '
      'unabhaengigen Netzen — eigener Cache-Slot UND persistierte Outbox-Op',
      () async {
    final kv = InMemoryKeyValueStore();
    final a = _setup(kv: kv);
    a.server.profileRow = _serverProfileRow(_profile(weightKg: 80));
    await _boot(a.store);

    a.server.offline = true;
    final mealId = a.store.addResultToDailyTotal(_result('Inventur-Bowl'));
    a.store.toggleFavorite(_result('Inventur-Bowl'));
    a.store.logWeight(79.4);
    await a.store.createUserRecipe(_recipe('user_inventur'));
    await a.store.applySettings(
      newProfile: a.store.profile.copyWith(dailyKcalGoal: 1750),
      notificationsEnabled: false,
    );
    await _settle();
    a.store.flushPendingWrites(); // App wird beendet
    await _settle();

    // Netz 1 — die Cache-Slots. Jeder einzeln, damit ein fehlender Slot nicht
    // hinter einem anderen verschwindet.
    expect(
        (await a.cache.readLoggedMeals())!.map((m) => m.id), contains(mealId));
    expect((await a.cache.readFavorites())!.where((f) => f.pinned), isNotEmpty);
    expect((await a.cache.readWeightLog())!.latest!.weightKg, 79.4);
    expect((await a.cache.readUserRecipes())!.map((r) => r.slug),
        contains('user_inventur'));
    expect((await a.cache.readProfile())!.dailyKcalGoal, 1750);

    // Netz 2 — die persistierte Outbox.
    final blob = (await a.cache.readOutbox())!.map((o) => o.kind).toSet();
    expect(
        blob,
        containsAll(<SyncOpKind>[
          SyncOpKind.mealInsert,
          SyncOpKind.favoriteUpsert,
          SyncOpKind.weightInsert,
          SyncOpKind.recipeUpsert,
          SyncOpKind.profileUpsert,
        ]),
        reason: 'faellt eine Familie hier weg, haengt diese Sammlung wieder '
            'allein am Cache — und ein Kaltstart MIT Netz wuerde sie mit dem '
            'Server-Stand ueberschreiben');

    // Kaltstart OHNE Netz: alles wieder da.
    final b = _setup(kv: kv);
    b.server.offline = true;
    await _boot(b.store);
    expect(b.store.loggedMeals.map((m) => m.id), contains(mealId));
    expect(b.store.favorites.where((f) => f.pinned), isNotEmpty);
    expect(b.store.weightLog.latest!.weightKg, 79.4);
    expect(b.store.userRecipes.map((r) => r.slug), contains('user_inventur'));
    expect(b.store.profile.dailyKcalGoal, 1750);

    // Kaltstart MIT Netz, und der Server kennt nichts davon: der Boot-Merge
    // + Op-Ueberlagerung muessen ALLE fuenf halten, nicht nur die Rezepte.
    final c = _setup(kv: kv);
    c.server.profileRow = _serverProfileRow(_profile(weightKg: 80));
    await _boot(c.store);
    expect(c.store.loggedMeals.map((m) => m.id), contains(mealId));
    expect(c.store.favorites.where((f) => f.pinned), isNotEmpty);
    expect(c.store.weightLog.latest!.weightKg, 79.4);
    expect(c.store.userRecipes.map((r) => r.slug), contains('user_inventur'));
    expect(c.store.profile.dailyKcalGoal, 1750);
    expect(c.store.pendingOutbox, isEmpty,
        reason: 'und alles ist zugestellt, nicht nur lokal ueberlebt');
    expect(c.server.mealRows.keys, contains(mealId));
    expect(c.server.recipeRows.keys, contains('user_inventur'));
    expect(c.server.weightRows, isNotEmpty);
    expect(c.server.profileRow!['daily_kcal_goal'], 1750);
  });

  // --- Der Befund der Inventur: der Streak-Tag hatte NULL Netze ------------
  //
  // `_recordTrackingDay` war ein reines fire-and-forget: der RPC lief, sein
  // Fehler ging an dev.log + CrashReporter, und das war es. Keine Op, kein
  // Cache-Merker, kein Retry. Der Kommentar behauptete, der optimistische
  // lokale Stand gelte „bis zum naechsten Load/Log weiter" — tatsaechlich
  // hielt er 600 ms: dann adoptierte `_flushStatsDelta` die frische
  // Serverzeile, die den Tag nicht kennt, und `_cacheLifetimeStats` schrieb
  // den Verlust fest. Die Mahlzeit kam an, die Zaehler kamen an, und die
  // Streak war trotzdem gerissen.

  test(
      'Streak-Tag: scheitert record_tracking_day, landet der Tag in der '
      'Outbox statt im Nichts — und die Anzeige haelt, obwohl der Stats-Flush '
      'gleich darauf die Serverzeile adoptiert', () async {
    final s = _setup();
    await _boot(s.store);
    // NUR der Streak-RPC faellt aus. Mahlzeit und Zaehler kommen an — genau
    // deshalb war der Verlust unsichtbar.
    s.server.rejectTrackingDay = true;

    final id = s.store.addResultToDailyTotal(_result('Streak-Bowl'));
    await _settle();
    expect(s.server.mealRows.keys, contains(id),
        reason: 'Vorbedingung: an der Mahlzeit selbst liegt es nicht');

    // Den 600-ms-Debounce des Stats-Flushs wirklich ablaufen lassen: erst da
    // adoptierte der Store die Serverzeile und verlor den Tag.
    await Future<void>.delayed(const Duration(milliseconds: 900));
    await _settle();

    expect(s.server.mealsCounted, 1,
        reason: 'Vorbedingung: der Zaehler-RPC ist durchgekommen — nur der '
            'Streak-RPC nicht');
    expect(s.store.lifetimeStats.lastTrackedDate, isNotNull,
        reason: 'genau hier sprang die Anzeige auf „Streak gerissen"');
    expect(s.store.lifetimeStats.currentStreak, 1);
    expect(s.store.pendingOutbox.map((o) => o.entityKey),
        contains('tracking:${localDayKey(DateTime.now())}'),
        reason: 'ohne Op gab es keine Stelle, die den Tag je nachgeholt '
            'haette');
    expect((await s.cache.readOutbox())!.map((o) => o.kind),
        contains(SyncOpKind.trackingDay),
        reason: 'und sie muss den App-Kill ueberleben wie jeder andere Write');
  });

  test(
      'Streak-Tag: der liegengebliebene Tag ueberlebt den Kaltstart und wird '
      'beim naechsten Start nachgeholt', () async {
    final kv = InMemoryKeyValueStore();
    final a = _setup(kv: kv);
    await a.cache.writeProfile(
        const UserProfile(weightKg: 80, onboardingCompleted: true));
    await _boot(a.store);
    a.server.rejectTrackingDay = true;
    a.store.addResultToDailyTotal(_result('Streak-Bowl'));
    await _settle();
    a.store.flushPendingWrites();
    await _settle();
    expect(a.server.trackedDay, isNull, reason: 'Vorbedingung: nicht angekommen');

    // Neustart, der RPC laeuft wieder.
    final b = _setup(kv: kv);
    await _boot(b.store);

    expect(b.server.trackedDay, localDayKey(DateTime.now()),
        reason: 'der Boot-Replay muss den Tag serverseitig nachtragen — sonst '
            'reisst die Streak beim naechsten Log, weil der Server eine '
            'Luecke sieht');
    expect(b.store.lifetimeStats.lastTrackedDate, isNotNull);
    expect(
        b.store.pendingOutbox
            .where((o) => o.kind == SyncOpKind.trackingDay),
        isEmpty,
        reason: 'zugestellt heisst: die Op ist wieder raus');
  });

  test(
      'Streak-Tag: mehrfaches Loggen am selben Tag erzeugt EINE Op, nicht eine '
      'pro Mahlzeit', () async {
    final s = _setup();
    await _boot(s.store);
    s.server.rejectTrackingDay = true;

    s.store.addResultToDailyTotal(_result('Bowl 1'));
    await _settle();
    s.store.addResultToDailyTotal(_result('Bowl 2'));
    await _settle();
    s.store.addResultToDailyTotal(_result('Bowl 3'));
    await _settle();

    expect(
        s.store.pendingOutbox
            .where((o) => o.kind == SyncOpKind.trackingDay)
            .length,
        1,
        reason: 'alle Ops eines Tages teilen den Entitaets-Schluessel und '
            'koaleszieren — sonst waechst die Queue mit jedem Log um eine '
            'voellig identische Op');
  });

  test(
      'Streak-Tag: kommt der RPC LIVE durch, bleibt keine alte Op liegen',
      () async {
    final s = _setup();
    await _boot(s.store);
    s.server.rejectTrackingDay = true;
    s.store.addResultToDailyTotal(_result('Bowl 1'));
    await _settle();
    expect(
        s.store.pendingOutbox.where((o) => o.kind == SyncOpKind.trackingDay),
        hasLength(1),
        reason: 'Vorbedingung');

    // Der RPC laeuft wieder, der naechste Log stellt live zu.
    s.server.rejectTrackingDay = false;
    s.store.addResultToDailyTotal(_result('Bowl 2'));
    await _settle();

    expect(s.server.trackedDay, localDayKey(DateTime.now()));
    expect(
        s.store.pendingOutbox.where((o) => o.kind == SyncOpKind.trackingDay),
        isEmpty,
        reason: 'eine Op, deren Tag laengst verbucht ist, haelt sonst die '
            'Queue (und damit preserveOutbox beim Logout) unnoetig offen');
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
