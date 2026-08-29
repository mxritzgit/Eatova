import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/meals_sync.dart' show mealResultToJson;
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/services/sync_outbox.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';

// Shared harness for the outbox suites in this folder.
//
// DATA-7 data-loss fix: a failed sync write no longer rolls back local state
// but becomes a persisted outbox op. The suites drive the REAL HomeStore with
// a real EatovaSync over a stateful MockClient and an injected cache: no
// rollback, idempotent replay, cold-start hydration, boot merge, attempt budget
// and queue cap, poison-op drops, and exactly-once counters.

/// Stateful fake PostgREST: records requests, applies upserts and deletes to
/// in-memory tables, and can be switched offline.
class FakeServer {
  /// Everything fails; such requests are NOT recorded, so [requests] holds
  /// only what reached the "server".
  bool offline = false;

  /// Only increment_lifetime_stats fails (stats-delta scenarios).
  bool statsOffline = false;

  /// Only logged_meals writes fail, as a 500 — a RETRYABLE error.
  bool rejectMealWrites = false;

  /// logged_meals writes rejected hopelessly: HTTP 400 with the SQLSTATE in
  /// the body, which is what `PostgrestException.code` picks up, not the status.
  bool poisonMealWrites = false;

  /// SQLSTATE of the poison answer: 23502 drops at once, 23514 (normal for
  /// user input) runs into the attempt budget.
  String poisonCode = '23502';

  /// Ambiguous: the write IS applied but the answer is a 500 — the classic
  /// duplicate maker.
  bool ambiguousWrites = false;

  /// user_recipes writes NEVER answer. PostgREST has no timeout, so a hanging
  /// request neither resolves nor throws and NO outbox op is created.
  bool hangRecipeWrites = false;

  /// user_recipes writes fail with 500, i.e. the server ANSWERS (gap E:
  /// "offline" would be a lie there).
  bool rejectRecipeWrites = false;

  /// ONLY the user_recipes READ fails (500). The boot load then gets an answer
  /// for five collections and none for the sixth — the state
  /// `userRecipesAuthoritative` has to tell apart (P3-04b).
  bool rejectRecipeReads = false;

  /// ONLY record_tracking_day fails — the combination that lost the streak day.
  bool rejectTrackingDay = false;

  /// record_tracking_day NEVER answers while this holds.
  ///
  /// The kill window of P1-05b: the meal PATCH is through, the booking is on
  /// the wire, and the app dies before the answer. Neither `then` nor
  /// `catchError` ever runs, so only something already PERSISTED can catch the
  /// day. Requests already issued stay hanging when the flag is cleared —
  /// which is exactly how the restarted session gets a real answer while the
  /// session that died never gets one.
  bool hangTrackingDay = false;

  /// Mirrors the source proof of migration 20260811120000: the RPC counts a
  /// day only once a logged_meals row carries that local_day, otherwise it
  /// raises EX_DAY_NOT_LOGGED — SQLSTATE P0001, i.e. HTTP 400 with the code in
  /// the body. Opt-in, so the suites that are not about that guard keep the
  /// forgiving fake.
  bool enforceTrackingDaySourceProof = false;

  /// Days the source proof rejected. One entry means a wasted delivery
  /// attempt: the RPC reached the server before the meal row did.
  final List<String> trackingDayRejections = <String>[];

  /// logged_meals writes wait for [releaseMealWrites] before they are applied
  /// and answered: the window in which a LIVE write is still in flight while
  /// another path runs (P1-01b).
  Completer<void>? _mealWriteGate;

  /// Opens the window; every logged_meals write from here on hangs.
  void holdMealWrites() => _mealWriteGate ??= Completer<void>();

  /// Closes it again and answers everything that piled up.
  void releaseMealWrites() {
    final gate = _mealWriteGate;
    _mealWriteGate = null;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  /// Last day booked via record_tracking_day, i.e. last_workout_date.
  String? trackedDay;

  final List<http.Request> requests = <http.Request>[];

  /// The single public.profiles row, or null: the only collection with exactly
  /// one row, which is what gap D hangs on.
  Map<String, dynamic>? profileRow;
  final Map<String, Map<String, dynamic>> mealRows =
      <String, Map<String, dynamic>>{};
  final Map<String, Map<String, dynamic>> weightRows =
      <String, Map<String, dynamic>>{};

  /// favorite_key -> row. Real state, not a blanket `[]`: a forgetful fake
  /// cannot tell a losing store from itself.
  final Map<String, Map<String, dynamic>> favoriteRows =
      <String, Map<String, dynamic>>{};

  /// Slug -> row, as public.user_recipes holds it; conflict key is
  /// (user_id, slug).
  final Map<String, Map<String, dynamic>> recipeRows =
      <String, Map<String, dynamic>>{};
  int mealsCounted = 0;
  int weightLogsCounted = 0;

  /// `p_request_id` of EVERY increment_lifetime_stats call, rejected ones
  /// included. A retry must reuse the id, or the server counts twice.
  final List<String?> statsRequestIds = <String?>[];

  /// Server-side dedup of migration 20260814120000: consumed `p_request_id`.
  /// Only SUCCESSFUL calls consume one — a 500 does not commit the marker.
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
    // The body carries the SQLSTATE, so PostgrestException.code is
    // '$poisonCode', not '400'. ASCII-only: http.Response encodes as latin1.
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
      // Recorded before the failure switch: the failed attempt is the one the
      // later retry is compared against.
      final rid = body['p_request_id'] as String?;
      statsRequestIds.add(rid);
      if (statsOffline) return fail();
      if (rid != null && !verbrauchteStatsIds.add(rid)) {
        // Repeat: do not add, return the current row — the migration's FOUND
        // behaviour.
        return ok(_statsRow());
      }
      mealsCounted += (body['p_meals'] as num?)?.toInt() ?? 0;
      weightLogsCounted += (body['p_weight_logs'] as num?)?.toInt() ?? 0;
      return ok(_statsRow());
    }
    if (path.contains('/rpc/record_tracking_day')) {
      if (hangTrackingDay) return Completer<http.Response>().future;
      if (rejectTrackingDay) return fail();
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      final day = body['p_day'] as String?;
      if (enforceTrackingDaySourceProof &&
          !mealRows.values.any((r) => r['local_day'] == day)) {
        trackingDayRejections.add(day ?? '');
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
    if (path.contains('/logged_meals')) {
      final gate = _mealWriteGate;
      if (gate != null && req.method != 'GET') await gate.future;
      if (poisonMealWrites && req.method != 'GET') return poison();
      if (req.method == 'POST') {
        if (rejectMealWrites) return fail();
        for (final row in rowsOf(req.body)) {
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
      // GET: select shape, WITH PostgREST-like filters. A fake returning every
      // row hid the 35-day hole in the re-display path.
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
        // maybeSingle() on a GET expects a LIST of 0 or 1 rows.
        return ok(profileRow == null
            ? const <dynamic>[]
            : <Map<String, dynamic>>[profileRow!]);
      }
      // ProfileSync.save is an upsert with .single(): PostgREST returns ONE
      // object, not a list.
      for (final row in rowsOf(req.body)) {
        profileRow = <String, dynamic>{...?profileRow, ...row};
      }
      return ok(profileRow!);
    }
    if (path.contains('/user_recipes')) {
      if (hangRecipeWrites && req.method != 'GET') {
        // Never-completing answer: the caller waits forever (no timeout).
        return Completer<http.Response>().future;
      }
      if (rejectRecipeWrites && req.method != 'GET') return fail();
      if (rejectRecipeReads && req.method == 'GET') return fail();
      if (req.method == 'POST') {
        for (final row in rowsOf(req.body)) {
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
        for (final row in rowsOf(req.body)) {
          favoriteRows[row['favorite_key'] as String] = row;
        }
        return http.Response('', 201, request: req);
      }
      if (req.method == 'DELETE') {
        favoriteRows.remove(_eqParam(req, 'favorite_key'));
        return ok(const <dynamic>[]);
      }
      // GET in the select shape of MealsSync.loadFavorites.
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
        for (final row in rowsOf(req.body)) {
          final id = row['id'] as String? ?? 'srv-${weightRows.length}';
          weightRows[id] = row;
        }
        return ambiguousWrites ? fail() : http.Response('', 201, request: req);
      }
      // GET in the select shape of TrackingSync.loadWeightLog.
      return ok(weightRows.values
          .map((r) => <String, dynamic>{
                'recorded_at': r['recorded_at'],
                'weight_kg': r['weight_kg'],
              })
          .toList());
    }
    // Remaining reads: empty, which _safeLoad treats as "nothing there".
    if (req.method == 'GET') return ok(const <dynamic>[]);
    // Remaining writes: success.
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

  /// Rows of a PostgREST request body, single object or list.
  static List<Map<String, dynamic>> rowsOf(String body) {
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

/// Records what the store would have shown the user.
class SnackCapture {
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

/// Cache whose PROFILE slot throws on read (gap F): one failing boot-hydration
/// read must not take the later slots, above all the outbox, down with it.
class ProfilLesefehlerCache extends LocalCache {
  ProfilLesefehlerCache(super.store, super.userId);

  @override
  Future<UserProfile?> readProfile() async =>
      throw StateError('Profil-Slot unlesbar');
}

/// Cache whose OUTBOX slot throws on the FIRST read only (gap F, second half):
/// the persisted blob must never be overwritten off a failed read.
class OutboxLesefehlerCache extends LocalCache {
  OutboxLesefehlerCache(super.store, super.userId);

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

/// Cache whose OUTBOX writes never reach storage: the kill window where the
/// other slots commit and the outbox blob does not. Reads stay real.
class EingefrorenerOutboxCache extends LocalCache {
  EingefrorenerOutboxCache(super.store, super.userId);

  // `false` is the truth here: the blob never reaches storage.
  @override
  Future<bool> writeOutbox(List<SyncOp> ops) async => false;
}

/// Same for the DELTAS slot (W7b): a failed boot read used to let the next
/// flush rewrite the slot from 0, losing the previous session's meals.
/// [kaputteVersuche] picks a temporary failure (1) or a permanent one (2).
class DeltaLesefehlerCache extends LocalCache {
  DeltaLesefehlerCache(super.store, super.userId, {this.kaputteVersuche = 1});

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

/// A real HomeStore over a fake PostgREST and an in-memory cache.
({
  HomeStore store,
  FakeServer server,
  LocalCache cache,
  SnackCapture snacks,
}) setup({
  InMemoryKeyValueStore? kv,
  LocalCache? injizierterCache,
  // Two sessions sharing one server (kill simulation): dedup state and tables
  // must survive the "restart".
  FakeServer? geteilterServer,
  // Off under fakeAsync: the teardown runs outside the fake zone, where a
  // request that never answers would hang the dispose.
  bool disposeClient = true,
}) {
  final server = geteilterServer ?? FakeServer();
  final client = SupabaseClient(
    'https://example.supabase.co',
    'test-anon-key',
    httpClient: server.client(),
    // No GoTrue auto-refresh ticker in tests (see clobber_guard_test).
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  if (disposeClient) addTearDown(client.dispose);
  final cache =
      injizierterCache ?? LocalCache(kv ?? InMemoryKeyValueStore(), 'user-outbox');
  final snacks = SnackCapture();
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

/// Like [setup] but with NO [LocalCache], the state where `LocalCache.create`
/// returns null; nothing here touches a real SharedPreferences channel.
({HomeStore store, FakeServer server, SnackCapture snacks}) setupOhneCache() {
  final server = FakeServer();
  final client = SupabaseClient(
    'https://example.supabase.co',
    'test-anon-key',
    httpClient: server.client(),
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  addTearDown(client.dispose);
  final snacks = SnackCapture();
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

/// A scan result as the analyzer returns it.
MealAnalysisResult mealResult(String name, {int kcal = 300}) =>
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

/// A user recipe as the create sheet builds it (recipes_screen).
FitnessRecipe userRecipe(String slug, {String title = 'Eigene Bowl'}) =>
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

/// Server row of public.user_recipes (select shape of UserRecipesSync.load).
Map<String, dynamic> serverRecipeRow(String slug,
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

/// A completed profile, as it looks after onboarding.
UserProfile testProfile({
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

/// Server row of public.profiles, spelled out rather than derived: a missing
/// column makes `ProfileSync.load` throw and the boot hydrate nothing.
Map<String, dynamic> serverProfileRow(UserProfile p) => <String, dynamic>{
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

/// Server row of public.logged_meals (select shape of MealsSync.load).
Map<String, dynamic> serverMealRow(String id, {int kcal = 250}) =>
    <String, dynamic>{
      'id': id,
      'logged_at': DateTime.now().toUtc().toIso8601String(),
      'forced_slot': null,
      'local_day': null,
      'payload': mealResultToJson(mealResult('Server-Gericht', kcal: kcal)),
    };

/// Drains the microtask/event queue far enough for a boot or a replay round.
Future<void> settle() => pumpEventQueue(times: 60);

/// Starts the store and waits for the boot to finish.
Future<void> boot(HomeStore store) async {
  store.start();
  await store.profileReady;
  await settle();
}

/// Writes outbox rows RAW into the key-value store, bypassing
/// [LocalCache.writeOutbox] and the [SyncOp] factories — the only way to build
/// wire forms no production path creates (unreadable payload A8, ancient
/// `queued_at` A4).
Future<void> seedRawOutbox(
  InMemoryKeyValueStore kv,
  List<Map<String, dynamic>> items,
) =>
    kv.setString('eatova.v1.outbox.user-outbox',
        jsonEncode(<String, dynamic>{'items': items}));
