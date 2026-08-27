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

// DATA-7 data-loss fix: a failed sync write no longer rolls back local state
// but becomes a persisted outbox op. These tests drive the REAL HomeStore with
// a real EatovaSync over a stateful MockClient and an injected cache: no
// rollback, idempotent replay, cold-start hydration, boot merge, attempt budget
// and queue cap, poison-op drops, and exactly-once counters.

/// Stateful fake PostgREST: records requests, applies upserts and deletes to
/// in-memory tables, and can be switched offline.
class _FakeServer {
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

  /// ONLY record_tracking_day fails — the combination that lost the streak day.
  bool rejectTrackingDay = false;

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
      for (final row in _rowsOf(req.body)) {
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
        for (final row in _rowsOf(req.body)) {
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

/// Cache whose PROFILE slot throws on read (gap F): one failing boot-hydration
/// read must not take the later slots, above all the outbox, down with it.
class _ProfilLesefehlerCache extends LocalCache {
  _ProfilLesefehlerCache(super.store, super.userId);

  @override
  Future<UserProfile?> readProfile() async =>
      throw StateError('Profil-Slot unlesbar');
}

/// Cache whose OUTBOX slot throws on the FIRST read only (gap F, second half):
/// the persisted blob must never be overwritten off a failed read.
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

/// Cache whose OUTBOX writes never reach storage: the kill window where the
/// other slots commit and the outbox blob does not. Reads stay real.
class _EingefrorenerOutboxCache extends LocalCache {
  _EingefrorenerOutboxCache(super.store, super.userId);

  // `false` is the truth here: the blob never reaches storage.
  @override
  Future<bool> writeOutbox(List<SyncOp> ops) async => false;
}

/// Same for the DELTAS slot (W7b): a failed boot read used to let the next
/// flush rewrite the slot from 0, losing the previous session's meals.
/// [kaputteVersuche] picks a temporary failure (1) or a permanent one (2).
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
  // Two sessions sharing one server (kill simulation): dedup state and tables
  // must survive the "restart".
  _FakeServer? geteilterServer,
}) {
  final server = geteilterServer ?? _FakeServer();
  final client = SupabaseClient(
    'https://example.supabase.co',
    'test-anon-key',
    httpClient: server.client(),
    // No GoTrue auto-refresh ticker in tests (see clobber_guard_test).
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

/// Like [_setup] but with NO [LocalCache], the state where `LocalCache.create`
/// returns null; nothing here touches a real SharedPreferences channel.
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

/// A user recipe as the create sheet builds it (recipes_screen).
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

/// Server row of public.user_recipes (select shape of UserRecipesSync.load).
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

/// A completed profile, as it looks after onboarding.
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

/// Server row of public.profiles, spelled out rather than derived: a missing
/// column makes `ProfileSync.load` throw and the boot hydrate nothing.
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

    expect(s.store.loggedMeals.map((m) => m.id), contains(id));
    expect(s.store.dailyConsumedKcal, 300);

    expect(s.store.pendingOutbox.map((o) => o.kind),
        contains(SyncOpKind.mealInsert));
    final persisted = await s.cache.readOutbox();
    expect(persisted!.map((o) => o.kind), contains(SyncOpKind.mealInsert));

    // A quiet hint, not a red toast, and only ONE per episode.
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
    // Server reachable, writes rejected: a PostgrestException, not a net error.
    s.server.rejectMealWrites = true;

    final id = s.store.addResultToDailyTotal(_result('Constraint-Bowl'));
    await _settle();

    // Same as offline: no rollback, the op sits in the outbox.
    expect(s.store.loggedMeals.map((m) => m.id), contains(id));
    expect(s.store.pendingOutbox.map((o) => o.kind),
        contains(SyncOpKind.mealInsert));

    // The server answered, so it is the retry message, once per episode.
    expect(s.snacks.offlineHints, isEmpty);
    expect(
      s.snacks.messages.where((m) =>
          m ==
          'Änderung konnte nicht gespeichert werden — wird automatisch erneut versucht.'),
      hasLength(1),
    );

    // Schema-leak guard: no raw error text, no table names.
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

    // Coalesced: ONE op, kind stays mealInsert (stats!), newest payload.
    final mealOps = s.store.pendingOutbox
        .where((o) => o.entityKey == 'meal:$id')
        .toList();
    expect(mealOps, hasLength(1));
    expect(mealOps.single.kind, SyncOpKind.mealInsert);
    expect(mealOps.single.meal!.result.caloriesKcal, 500);

    s.server.offline = false;
    s.store.flushPendingWrites();
    await _settle();

    expect(s.store.pendingOutbox, isEmpty);
    expect(await s.cache.readOutbox(), isEmpty);
    expect(s.server.mealRows, hasLength(1));
    final row = s.server.mealRows[id]!;
    expect(row['calories_kcal'], 500);
    expect((row['payload'] as Map)['caloriesKcal'], 500);

    // ONE POST reached the server, upsert-keyed on the client UUID.
    final posts = s.server.requests
        .where((r) =>
            r.method == 'POST' && r.url.path.contains('/logged_meals'))
        .toList();
    expect(posts, hasLength(1));
    expect(posts.single.headers['Prefer'], contains('resolution=merge-duplicates'));

    s.store.flushPendingWrites(); // short-circuit the delta-queue debounce
    await _settle();
    expect(s.server.mealsCounted, 1);
  });

  test(
      'Gewicht: unklarer Timeout + Retry schreiben dieselbe Client-UUID '
      '-> Upsert, KEIN Duplikat', () async {
    final s = _setup();
    await _boot(s.store);

    s.server.ambiguousWrites = true;
    s.store.logWeight(80.5);
    await _settle();

    expect(s.store.weightLog.latest?.weightKg, 80.5);
    final op = s.store.pendingOutbox
        .singleWhere((o) => o.kind == SyncOpKind.weightInsert);
    expect(s.server.weightRows, hasLength(1),
        reason: 'der erste Versuch hat die Zeile bereits geschrieben');

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

    final a = _setup(kv: kv);
    await _boot(a.store);
    a.store.addResultToDailyTotal(_result('Gestern-online-Bowl'));
    await _settle();
    // App shutdown flushes the 400 ms debounced diary writes; without it the
    // test would only prove the debounce is short.
    a.store.flushPendingWrites();
    await _settle();

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

    final a = _setup(kv: kv);
    await _boot(a.store);
    a.server.offline = true;
    final id = a.store.addResultToDailyTotal(_result('Offline-Bowl'));
    await _settle();
    expect((await a.cache.readOutbox())!, isNotEmpty);

    // Session 2: server knows a DIFFERENT meal; replay-then-load keeps both.
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

    // Session 1: meal sync fine, stats RPC fails, so the delta stays.
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

    final b = _setup(kv: kv);
    await _boot(b.store);

    expect(b.server.mealsCounted, 1);
    final after = await b.cache.readPendingStatsDeltas();
    expect(after!.meals, 0, reason: 'Delta wurde verbucht, nicht dupliziert');
  });

  // --- Finding B: idempotency key of the stats deltas -----------------------
  //
  // `increment_lifetime_stats` ADDS, so a drop after the commit re-queues the
  // same delta. The server tracks consumed `p_request_id`, which only helps if
  // the client resends the SAME id.

  test(
      'Retry des Stats-Deltas sendet DIESELBE Anfrage-Id — auch ueber einen '
      'Kaltstart hinweg; erst ein verbuchtes Buendel bekommt eine neue',
      () async {
    final kv = InMemoryKeyValueStore();

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

    // The id lives with the bundle, or an app kill makes the retry a new op.
    expect((await a.cache.readPendingStatsDeltas())!.requestId, id);

    // Session 2 (cold start): the boot flush is the retry, with the FIRST id.
    final b = _setup(kv: kv);
    b.server.statsOffline = true;
    await _boot(b.store);
    b.store.flushPendingWrites();
    await _settle();

    expect(b.server.statsRequestIds, isNotEmpty);
    expect(b.server.statsRequestIds.toSet(), <String?>{id},
        reason: 'eine frisch erzeugte Id koennte der Server nicht als '
            'Wiederholung erkennen — er wuerde ein zweites Mal addieren');

    b.server.statsOffline = false;
    b.store.flushPendingWrites();
    await _settle();
    expect(b.server.statsRequestIds.last, id);
    expect(b.server.mealsCounted, 1);
    expect((await b.cache.readPendingStatsDeltas())!.meals, 0);

    // Counter-check: a NEW bundle needs a new id, else the server dismisses it.
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
    // The old wire form: numbers, no 'request_id'.
    await LocalCache(kv, 'user-outbox')
        .writePendingStatsDeltas(meals: 2, weightLogs: 1);

    final s = _setup(kv: kv);
    s.server.statsOffline = true;
    await _boot(s.store);
    s.store.flushPendingWrites();
    await _settle();

    // Neither tripped up by `null` nor dropped: sent with a retrofitted id …
    expect(s.server.statsRequestIds, isNotEmpty);
    final id = s.server.statsRequestIds.first;
    expect(id, isNotNull);
    expect(s.server.statsRequestIds.toSet(), <String?>{id});

    // … which now lives with the bundle, keeping further attempts one op.
    final pending = await s.cache.readPendingStatsDeltas();
    expect(pending!.requestId, id);
    expect(pending.meals, 2);
    expect(pending.weightLogs, 1);

    s.server.statsOffline = false;
    s.store.flushPendingWrites();
    await _settle();
    expect(s.server.mealsCounted, 2);
    expect(s.server.weightLogsCounted, 1);
  });

  // --- Fix 3: exactly-once counters for replayed ops ------------------------
  //
  // The replay was idempotent for CONTENT but not for its COUNTER: the +1 was
  // persisted before the op left the outbox, so an app kill made the next boot
  // count the meal twice. Fix 3 creates a statsIncrement entry ATOMICALLY with
  // removing the source op, keyed on an id DERIVED from the source UUID.

  test(
      'Fix 3: Kill nach der Replay-Zustellung, VOR der Op-Entfernung — der '
      'naechste Boot zaehlt die Mahlzeit NICHT ein zweites Mal', () async {
    const mealId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    final abgeleitet = deriveStatsRequestId(mealId)!;
    final kv = InMemoryKeyValueStore();
    // ONE server for both sessions: its dedup state must survive the restart.
    final server = _FakeServer();
    // The previous session's blob: one stranded meal, UUID-shaped so a request
    // id can be derived.
    await _seedRawOutbox(kv, <Map<String, dynamic>>[
      SyncOp.mealInsert(
        LoggedMeal(
            id: mealId, result: _result('Kill-Bowl'), loggedAt: DateTime.now()),
        trackDay: false,
      ).toJson(),
    ]);

    // Session A: delivery and increment land, the OUTBOX write does not.
    final a = _setup(
      kv: kv,
      geteilterServer: server,
      injizierterCache: _EingefrorenerOutboxCache(kv, 'user-outbox'),
    );
    await _boot(a.store);
    // Short-circuit the bundle-flush debounce, else the +1 never leaves memory.
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
    // No explicit dispose(): the "kill" is just the state left on storage.

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
    // The previous session delivered it; only the ANSWER was lost.
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

    final a = _setup(kv: kv, geteilterServer: server);
    await _boot(a.store);
    server.offline = true;
    final mealId = a.store.addResultToDailyTotal(_result('Nachhol-Bowl'));
    await _settle();
    expect(a.store.pendingOutbox.map((o) => o.kind),
        contains(SyncOpKind.mealInsert),
        reason: 'Vorbedingung');

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

    // Cold start, RPC still broken: the boot replay retries.
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

    // Applied but answered 500, so the live path does NOT count.
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
    // Budget spent AND older than 24 h: both are required for the drop (A4).
    await _seedRawOutbox(kv, <Map<String, dynamic>>[
      SyncOp.statsIncrement(requestId: rid, meals: 1).toJson()
        ..['queued_at'] = DateTime.now()
            .subtract(const Duration(hours: 25))
            .toIso8601String()
        ..['attempts'] = kOutboxMaxAttempts - 1,
    ]);

    final s = _setup(kv: kv);
    s.server.statsOffline = true; // an active rejection (500) counts
    await _boot(s.store);

    expect(s.store.pendingOutbox, isEmpty, reason: 'verworfen');
    expect(s.server.mealsCounted, 0);
    expect(s.snacks.messages.where((m) => m == outboxLossHint()), isEmpty,
        reason: 'die Mahlzeit ist laengst zugestellt — es fehlt kein Eintrag, '
            'nur ein Zaehler. Der Snack waere gelogen.');
    expect(s.snacks.messages.where((m) => m == outboxDeleteLossHint()), isEmpty);
  });

  // --- W7b: the brake for the deltas slot -----------------------------------
  //
  // The outbox has one since gap F; the deltas had none, and
  // `_persistPendingStatsDeltas` always rewrites the whole slot.

  test(
      'ein kaputter pending_stats-Slot loest die Bremse aus, statt still eine '
      'leere Menge zu liefern', () async {
    final kv = InMemoryKeyValueStore();
    // Previous session: three unbooked meals in the slot.
    await LocalCache(kv, 'user-outbox')
        .writePendingStatsDeltas(meals: 3, weightLogs: 0, requestId: 'alt-id');

    final cache = _DeltaLesefehlerCache(kv, 'user-outbox');
    final s = _setup(kv: kv, injizierterCache: cache);
    // The stats RPC stays down so the test really measures the slot.
    s.server.statsOffline = true;
    await _boot(s.store);
    expect(cache.leseversuche, 1,
        reason: 'Vorbedingung: die Hydration hat den Slot nicht gesehen');

    // Its delta runs into _persistPendingStatsDeltas.
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

    // And every further delta passes without a third read.
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

    s.server.offline = false;
    s.server.rejectMealWrites = true;
    s.store.flushPendingWrites();
    await _settle();

    // Weight is through, the meal op stays, and nothing rolled back.
    expect(s.server.weightRows, hasLength(1));
    expect(
      s.store.pendingOutbox.map((o) => o.kind),
      [SyncOpKind.mealInsert],
    );
    expect(s.store.loggedMeals.map((m) => m.id), contains(mealId));

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

    s.server.offline = true;
    final yesterday =
        DateUtils.dateOnly(DateTime.now()).subtract(const Duration(days: 1));
    s.store.updateLoggedMealDetails(id, slot: MealSlot.snack, day: yesterday);
    await _settle();

    final local = s.store.loggedMeals.singleWhere((m) => m.id == id);
    expect(local.forcedSlot, MealSlot.snack);
    expect(local.localDay, localDayKey(yesterday));

    // ONE mealUpsert op with the full new state.
    final ops = s.store.pendingOutbox
        .where((o) => o.entityKey == 'meal:$id')
        .toList();
    expect(ops, hasLength(1));
    expect(ops.single.kind, SyncOpKind.mealUpsert);
    final queued = ops.single.meal!;
    expect(queued.forcedSlot, MealSlot.snack);
    expect(queued.localDay, localDayKey(yesterday));

    s.server.offline = false;
    s.store.flushPendingWrites();
    await _settle();

    expect(s.store.pendingOutbox, isEmpty);
    final row = s.server.mealRows[id]!;
    expect(row['forced_slot'], 'snack');
    expect(row['local_day'], localDayKey(yesterday));
    final loggedAt = DateTime.parse(row['logged_at'] as String).toLocal();
    expect(DateUtils.isSameDay(loggedAt, yesterday), isTrue);

    // An edit is NOT a new log: the lifetime stats still count 1.
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

  // --- Poison ops, attempt budget, queue cap --------------------------------

  test(
      'Gift-Op (23502 not_null_violation) wird beim ERSTEN Replay verworfen, '
      'verschwindet aus der persistierten Queue und meldet sich GENAU EINMAL',
      () async {
    final s = _setup();
    await _boot(s.store);
    s.server.poisonMealWrites = true;

    final id = s.store.addResultToDailyTotal(_result('Kaputt-Bowl'));
    await _settle();

    // The live write does not classify: the op is queued first.
    expect(s.store.pendingOutbox.map((o) => o.entityKey),
        contains('meal:$id'));

    s.store.flushPendingWrites();
    await _settle();

    // ONE replay is enough: the op is gone from memory AND the blob.
    expect(s.store.pendingOutbox.where((o) => o.entityKey == 'meal:$id'),
        isEmpty);
    final persisted = await s.cache.readOutbox();
    expect(persisted!.where((o) => o.entityKey == 'meal:$id'), isEmpty);

    // ONE loss hint, even after further flush rounds.
    s.store.flushPendingWrites();
    await _settle();
    expect(s.snacks.messages.where((m) => m == outboxLossHint()), hasLength(1));

    // Schema-leak guard.
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

    s.server.offline = false;
    s.store.flushPendingWrites();
    await _settle();

    expect(s.store.pendingOutbox, isEmpty);
    expect(s.server.mealRows.keys, contains(id));
  });

  test('attempts ueberleben den App-Neustart (sonst waere Gift unsterblich)',
      () async {
    final kv = InMemoryKeyValueStore();

    // Session 1: two replays against a 500 -> the counter is at 2.
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

    // Session 2 (restart): the replay CONTINUES the count, else a crash loop
    // makes poison immortal.
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

    expect(s.snacks.messages.where((m) => m == outboxLossHint()), hasLength(1));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test(
      'Hydrations-Cap: eine von einem alten, ungedeckelten Build gewachsene '
      'Queue wird beim Boot gekappt', () async {
    final kv = InMemoryKeyValueStore();
    // Written straight into the cache: no enqueue, yet the cap must bite.
    final seed = LocalCache(kv, 'user-outbox');
    // WRITE ops on purpose: deletes are cap-exempt (a dropped one resurrects).
    await seed.writeOutbox(<SyncOp>[
      for (var i = 0; i < kOutboxMaxOps + 100; i++)
        SyncOp.weightInsert(
          id: 'legacy-$i',
          weightKg: 80,
          recordedAt: DateTime(2026, 8, 1).add(Duration(minutes: i)),
        ),
    ]);

    final s = _setup(kv: kv);
    // Offline, else the boot replay empties the queue and the test is vacuous.
    s.server.offline = true;
    await _boot(s.store);

    expect(s.store.pendingOutbox, hasLength(kOutboxMaxOps));
    expect(s.store.pendingOutbox.map((o) => o.entityId),
        isNot(contains('legacy-0')));
    expect(s.store.pendingOutbox.last.entityId,
        'legacy-${kOutboxMaxOps + 99}');
  }, timeout: const Timeout(Duration(minutes: 3)));

  // --- Review 2026-08-08: A4 (budget), A6 (orphan), A8 (corrupt payload),
  //     A2 (logout) -----------------------------------------------------------

  test(
      'A4: Lifecycle-Churn frisst das Versuchs-Budget nicht mehr auf — 12 '
      'Durchlaeufe in Sekunden lassen die Op stehen', () async {
    final s = _setup();
    await _boot(s.store);
    s.server.rejectMealWrites = true;

    final id = s.store.addResultToDailyTotal(_result('Ausfall-Bowl'));
    await _settle();

    // One app switch triggers up to four flushes: an outage burns a dozen.
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

    // Precondition: op dropped, meal visible locally, absent on the server.
    expect(
        s.store.pendingOutbox.where((o) => o.entityKey == 'meal:$id'), isEmpty);
    expect(s.store.loggedMeals.map((m) => m.id), contains(id));
    expect(s.server.mealRows.keys, isNot(contains(id)));
    expect(s.snacks.messages.where((m) => m == outboxLossHint()), hasLength(1));

    s.server.poisonMealWrites = false;
    s.store.updateLoggedMealResult(id, _result('Waisen-Bowl', kcal: 500));
    await _settle();

    // A PATCH hitting 0 rows is a 204, not an error: silent loss.
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
        // Non-map payload: tryFromJson KEEPS the op with {}, reaching this.
        'payload': 'kaputt',
      },
    ]);

    final s = _setup(kv: kv);
    await _boot(s.store);

    expect(s.store.pendingOutbox, isEmpty);
    expect(
      s.server.requests.where(
          (r) => r.method == 'POST' && r.url.path.contains('/logged_meals')),
      isEmpty,
    );
    // The user is told: this used to be the only silent data-loss path.
    expect(s.snacks.messages.where((m) => m == outboxLossHint()), hasLength(1));
  });

  test(
      'A2: Ausloggen mit ungesyncten Ops — was der Zustellversuch nicht '
      'losgeworden ist, ueberlebt den Logout', () async {
    final s = _setup();
    // Real PII before the boot: the A1 guard writes no default snapshot.
    await s.cache.writeProfile(
        const UserProfile(weightKg: 80, onboardingCompleted: true));
    await _boot(s.store);
    s.server.offline = true;

    final id = s.store.addResultToDailyTotal(_result('Flugzeug-Bowl'));
    await _settle();
    expect((await s.cache.readOutbox())!, isNotEmpty);
    expect(await s.cache.readProfile(), isNotNull);

    await s.store.signOutCleanup();

    // The six offline meals are NOT gone …
    final surviving = await s.cache.readOutbox();
    expect(surviving, isNotNull);
    expect(surviving!.map((o) => o.entityKey), contains('meal:$id'));
    // … while the rest of the PII cache is (audit M-1 still holds).
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
      // Oldest entry is a WRITE, so it falls to the cap first.
      SyncOp.mealInsert(meal, trackDay: false).toJson(),
      // Then enough deletes that the overflow takes two after the one write.
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
    // Deliberately no _boot: `_outbox` is empty, the persisted blob is not.
    await s.store.signOutCleanup();

    final surviving = await s.cache.readOutbox();
    expect(surviving, isNotNull,
        reason: 'ein leerer In-Memory-Zustand vor der Hydration ist KEINE '
            'Aussage ueber den persistierten Blob — er darf nicht als '
            '"nichts zu erhalten" gelesen werden');
    expect(surviving!.map((o) => o.entityKey), contains('meal:m-vorsession'));
  });

  // --- Verification V1 (wave 6): remaining gaps from A2/A4/A5 ---------------

  test(
      'L1: ein Delete gegen einen kalten Schema-Cache (400/SQLSTATE) wird '
      'NICHT sofort verworfen — die Mahlzeit bleibt geloescht', () async {
    final s = _setup();
    await _boot(s.store);
    final id = s.store.addResultToDailyTotal(_result('Fehlscan-Bowl'));
    await _settle();
    expect(s.server.mealRows.keys, contains(id),
        reason: 'Vorbedingung: die Zeile steht auf dem Server');

    // Schema cache cold: EVERY logged_meals write, DELETE included, 400s.
    s.server.poisonMealWrites = true;
    s.store.removeLoggedMeal(id);
    await _settle();
    for (var i = 0; i < 5; i++) {
      s.store.flushPendingWrites();
      await _settle();
    }

    // Dropping on the first replay left the server row, so the next cold
    // start brought the meal back.
    expect(s.store.pendingOutbox.map((o) => o.entityKey), contains('meal:$id'),
        reason: 'die Loeschung darf nicht am Code-Verdikt sterben');
    expect(s.server.mealRows.keys, contains(id));
    expect(s.snacks.messages.where((m) => m == outboxLossHint()), isEmpty);
    expect(s.snacks.messages.where((m) => m == outboxDeleteLossHint()), isEmpty);

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
    // A delete at the end of its budget and its deadline.
    await _seedRawOutbox(kv, [
      SyncOp.mealDelete('m-geist').toJson()
        ..['queued_at'] = DateTime.now()
            .subtract(kOutboxDeleteMinAge + const Duration(hours: 1))
            .toIso8601String()
        ..['attempts'] = kOutboxDeleteMaxAttempts - 1,
    ]);

    final s = _setup(kv: kv);
    // Boot offline: the replay is free and the boot load brings no meal, so
    // the re-display is what is proven.
    s.server.offline = true;
    await _boot(s.store);
    expect(s.store.pendingOutbox, hasLength(1));
    expect(s.store.loggedMeals, isEmpty);

    // Network back; the row is still there and the delete keeps failing.
    s.server.offline = false;
    s.server.mealRows['m-geist'] = _serverMealRow('m-geist', kcal: 1800);
    s.server.poisonMealWrites = true;
    s.store.flushPendingWrites();
    await _settle();

    // The op is gone and the queue drains, else the retry timer never stops.
    expect(s.store.pendingOutbox, isEmpty);
    expect((await s.cache.readOutbox())!, isEmpty);
    // The meal is visible again and the user is told what to do.
    expect(s.store.loggedMeals.map((m) => m.id), contains('m-geist'));
    expect(s.store.dailyConsumedKcal, 1800,
        reason: 'die Kalorien zaehlen wieder — das darf nicht unsichtbar sein');
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

    // The row is 60 days old: only a targeted read by id brings it back.
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

    // Server poisoned: the fresh write dies as poison, the old delete on age.
    s.server.offline = false;
    s.server.mealRows['m-geist'] = _serverMealRow('m-geist', kcal: 1800);
    s.server.poisonMealWrites = true;
    s.store.addResultToDailyTotal(_result('Gift-Bowl'));
    await _settle();
    s.store.flushPendingWrites();
    await _settle();

    // The episode latch must not swallow the second, DIFFERENT message.
    expect(s.snacks.messages.where((m) => m == outboxLossHint()), hasLength(1));
    expect(s.snacks.messages.where((m) => m == outboxDeleteLossHint()),
        hasLength(1));
    expect(s.store.loggedMeals.map((m) => m.id), contains('m-geist'));
  });

  test(
      'Nebenbefund: die 24-h-Frist haengt an der injizierten Uhr, nicht an '
      'DateTime.now() — vorher war sie ueberhaupt nicht pruefbar', () async {
    // Reference time far from the system clock, else both cases collapse.
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

    // 23 h after enqueueing: budget spent, wall clock says no, meal stays.
    expect(
      (await runAt(queuedAt.add(const Duration(hours: 23))))
          .map((o) => o.entityKey),
      contains('meal:m-uhr'),
    );
    // 25 h: now the emergency brake bites.
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
    // Only increment_lifetime_stats fails; the outbox stays EMPTY.
    s.server.statsOffline = true;
    s.store.addResultToDailyTotal(_result('Streak-Bowl'));
    await _settle();
    s.store.flushPendingWrites();
    await _settle();

    expect(s.store.pendingOutbox, isEmpty,
        reason: 'genau die Kombination, die A2 uebersehen hat');
    expect((await s.cache.readPendingStatsDeltas())!.meals, 1);

    await s.store.signOutCleanup();

    // preserveOutbox used to hang on _outbox.length alone, dropping deltas.
    final surviving = await s.cache.readPendingStatsDeltas();
    expect(surviving, isNotNull);
    expect(surviving!.meals, 1);
    // The rest of the PII cache is still dropped (audit M-1).
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

    s.server.statsOffline = false;
    await s.store.signOutCleanup();

    expect(s.server.mealsCounted, 1, reason: 'Zustellversuch VOR dem Verwerfen');
    expect(await s.cache.readPendingStatsDeltas(), isNull);
    expect(await s.cache.readOutbox(), isNull);
    expect(await s.cache.readProfile(), isNull);
  });

  // --- Gap A: user recipes get local persistence ----------------------------
  //
  // Meals, favorites, weight and stats always had TWO nets: the write-through
  // cache AND the outbox. `user_recipes` only had the outbox.

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

    // The outbox delivers and empties: only the cache still holds the recipe.
    a.server.offline = false;
    a.store.flushPendingWrites();
    await _settle();
    expect(a.store.pendingOutbox, isEmpty);
    // App shutdown forces the debounced cache writes.
    a.store.flushPendingWrites();
    await _settle();

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
    // Gap B: with no answer neither callback fires, so the op must pre-exist.
    expect(a.store.pendingOutbox.map((o) => o.entityKey),
        contains('recipe:user_haenger'),
        reason: 'die Op darf nicht erst im Fehler-Callback entstehen — der '
            'kommt hier nie');
    a.store.flushPendingWrites();
    await _settle();
    // Gap A: independently of the outbox, the cache slot holds the recipe.
    expect((await a.cache.readUserRecipes())!.map((r) => r.slug),
        contains('user_haenger'),
        reason: 'zwei unabhaengige Netze — der Cache haelt auch ohne Op');

    // Cold start deliberately WITHOUT network; gap C has its own test.
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
    // Real profile in the cache: the A1 guard needs a hydration source.
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

    s.server.offline = false;
    await s.store.signOutCleanup();

    expect(s.server.mealRows.keys, contains(id),
        reason: 'Zustellversuch VOR dem Verwerfen');
    expect(await s.cache.readOutbox(), isNull);
    expect(await s.cache.readProfile(), isNull);
  });

  // --- Gap C: the boot load no longer blindly replaces user recipes ---------
  //
  // `_bootFromSupabase` set `_userRecipes = loadedRecipes` unconditionally, so
  // with no pending op the first online start overwrote the cache slot.

  test(
      'Luecke C: ein nur lokal bekanntes Rezept ueberlebt den Boot MIT Netz — '
      'die Serverliste ERGAENZT den lokalen Stand, sie ersetzt ihn nicht',
      () async {
    final kv = InMemoryKeyValueStore();
    final seed = LocalCache(kv, 'user-outbox');
    await seed.writeProfile(
        const UserProfile(weightKg: 80, onboardingCompleted: true));
    // A recipe only the cache knows: no server row, no outbox op.
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
    // The blob is STALE: the delete died in the debounce window, the op did not.
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
    // Airplane mode at its nastiest: the request never fails, it NEVER ANSWERS.
    a.server.hangRecipeWrites = true;
    a.store.createUserRecipe(_recipe('user_flugmodus', title: 'Flug-Bowl'));
    await _settle();
    expect(a.store.userRecipes.map((r) => r.slug), contains('user_flugmodus'),
        reason: 'Vorbedingung: im Flugmodus war das Rezept sichtbar');
    a.store.flushPendingWrites(); // app shutdown
    await _settle();

    final b = _setup(kv: kv);
    await _boot(b.store);

    expect(b.store.userRecipes.map((r) => r.slug), contains('user_flugmodus'),
        reason: 'genau hier war das Rezept weg: der erfolgreiche Server-Load '
            'ersetzte die Liste, und der Boot-Snapshot schrieb das fest');
  });

  // --- Gap B: the outbox op exists BEFORE the network write -----------------
  //
  // `_syncOrQueue` used to enqueue only in `catchError`, so a hanging request
  // produced no op at all. Now the op is persisted before delivery.

  test(
      'Luecke B: die Op liegt schon in der PERSISTIERTEN Queue, bevor der '
      'Server geantwortet hat — und ist nach der Zustellung wieder raus',
      () async {
    final s = _setup();
    await _boot(s.store);

    s.store.createUserRecipe(_recipe('user_sofort'));
    // No _settle: the live write is still in flight.
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
    // The success path must not produce a queue hint.
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

    // A second change must get through despite the hanging recipe request.
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
    // No event-loop turn, raw blob: what an app kill right after the tap sees.
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
  // --- Gap D: profile changes survive offline -------------------------------
  //
  // `applySettings`/`completeOnboarding` wrote cache and Supabase WITHOUT an
  // outbox, so the next online start overwrote the offline change silently.

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
      newProfile: a.store.profile.copyWith(weightKg: 84, dailyKcalGoal: 1900, manualEnergy: true),
      notificationsEnabled: false,
    );
    await _settle();
    expect(a.store.profile.weightKg, 84,
        reason: 'Vorbedingung: offline sieht der Nutzer seinen neuen Wert');
    a.store.flushPendingWrites(); // app shutdown
    await _settle();

    // Restart WITH network; the server still knows only the old state.
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

    // Only the replay counts: the hand-set 2200 kcal of the fixture is a
    // stale live row, so the boot itself already wrote the healed goals back
    // (F7-01 write-back on `ProfileSync.lastLoadHealed`).
    int profilPosts() => a.server.requests
        .where((r) => r.method == 'POST' && r.url.path.contains('/profiles'))
        .length;
    final vorReplay = profilPosts();

    a.server.offline = false;
    a.store.flushPendingWrites();
    await _settle();

    expect(a.server.profileRow!['weight_kg'], 86);
    expect(a.server.profileRow!['daily_kcal_goal'], 2000);
    expect(profilPosts() - vorReplay, 1,
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
    // The row the signup trigger creates: defaults, onboarding open.
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
    // Only the outbox is on storage, so the state comes from the op alone.
    await _seedRawOutbox(kv, <Map<String, dynamic>>[
      SyncOp.profileUpsert(_profile(weightKg: 91, dailyKcalGoal: 1800))
          .toJson(),
    ]);

    final s = _setup(kv: kv);
    s.server.offline = true;
    await _boot(s.store);

    expect(s.store.profile.weightKg, 91);

    // The point: the next change must land, not be blocked by the A1 guard.
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

  // --- Gap E: the store REPORTS the outcome instead of letting it be claimed -
  //
  // The recipes screen showed a success toast unconditionally. Now the store
  // returns what happened and leaves the ONE message to the caller.

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
    // 500 on user_recipes writes: the server ANSWERS, so "offline" would lie.
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
    // PostgREST has no timeout (gap B): the test waits a real window.
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

  // --- Gap F: one read error no longer topples the whole outbox -------------
  //
  // All seven boot-hydration reads sat in ONE try. An earlier throw left
  // `_outbox` empty and the next enqueue overwrote the blob.

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

    final b = _setup(
      injizierterCache: _ProfilLesefehlerCache(kv, 'user-outbox'),
    );
    b.server.offline = true;
    await _boot(b.store);

    expect(b.store.pendingOutbox.map((o) => o.entityKey), contains('meal:$id'),
        reason: 'der Wurf im Profil-Slot uebersprang frueher jeden weiteren '
            'Read — auch den der Outbox');

    // Why that was expensive: the next write persists the queue over the blob.
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
    // The replayed write is visible again, not stuck as an invisible op.
    expect(b.store.loggedMeals.map((m) => m.id), contains(id));
  });

  // =========================================================================
  // COUNTER-VERIFICATION
  //
  // The tests above share their authors' assumptions with the fix. These start
  // from the REPORTED ACTION and attack the neighbours: delete, the
  // combination, two starts, an answering server, no cache, a user switch.
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

    // Airplane mode on: the request FAILS; the hanging case has its own test.
    a.server.offline = true;
    final ausgang =
        await a.store.createUserRecipe(_recipe('user_gemeldet', title: 'Bowl'));
    expect(ausgang, SyncDelivery.queuedOffline);
    expect(a.store.userRecipes.map((r) => r.slug), contains('user_gemeldet'),
        reason: 'Vorbedingung des Berichts: „war sichtbar"');

    a.store.flushPendingWrites();
    await _settle();

    // Airplane mode off, app up: NEW store, NEW server, SAME cache.
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

    // Restart WITH network: without replay-before-boot the recipe would be back.
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

    // The delete must NOT coalesce away the upsert; the reverse resurrects it.
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

    // Restart: recipe writes rejected, the READING boot load returns EMPTY.
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

    final b = _setup(injizierterCache: LocalCache(kv, 'user-b'));
    b.server.offline = true;
    await _boot(b.store);

    expect(b.store.userRecipes, isEmpty,
        reason: 'jeder Slot-Name traegt die User-ID — B liest seinen eigenen, '
            'leeren Namensraum');
    expect(b.store.pendingOutbox, isEmpty,
        reason: 'auch die beim Logout ERHALTENE Outbox gehoert A, nicht B');

    // A is back: the preserved outbox is why the slot may be dropped on logout.
    final a2 = _setup(injizierterCache: LocalCache(kv, 'user-a'));
    a2.server.offline = true;
    await _boot(a2.store);
    expect(a2.store.userRecipes.map((r) => r.slug), contains('user_a_geheim'));
  });

  test(
      'Gegenprobe 9 — EIN Netz faellt aus: der Outbox-Slot ist beim Lesen '
      'kaputt, der Cache traegt allein. Ein Boot MIT Netz darf das Rezept '
      'trotzdem nicht wegwerfen', () async {
    // The core of the repair without a pre-seeded blob: real user action, then
    // ONE of the two nets fails. If it survives, there were two.
    final kv = InMemoryKeyValueStore();
    final a = _setup(kv: kv);
    await a.cache.writeProfile(
        const UserProfile(weightKg: 80, onboardingCompleted: true));
    await _boot(a.store);
    a.server.offline = true;
    await a.store.createUserRecipe(_recipe('user_nur_cache'));
    a.store.flushPendingWrites();
    await _settle();

    // Cold start WITH network and a throwing outbox slot (gap F): op invisible,
    // server does not know the recipe.
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

  // --- Question 3: is any data kind still down to ONE net? -----------------
  //
  // The inventory in ONE offline session: mutate, kill, restart offline. Every
  // collection must show BOTH nets — its cache slot and the persisted op.

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
      newProfile: a.store.profile.copyWith(dailyKcalGoal: 1750, manualEnergy: true),
      notificationsEnabled: false,
    );
    await _settle();
    a.store.flushPendingWrites(); // app shutdown
    await _settle();

    // Net 1, the cache slots, each checked separately.
    expect(
        (await a.cache.readLoggedMeals())!.map((m) => m.id), contains(mealId));
    expect((await a.cache.readFavorites())!.where((f) => f.pinned), isNotEmpty);
    expect((await a.cache.readWeightLog())!.latest!.weightKg, 79.4);
    expect((await a.cache.readUserRecipes())!.map((r) => r.slug),
        contains('user_inventur'));
    expect((await a.cache.readProfile())!.dailyKcalGoal, 1750);

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

    final b = _setup(kv: kv);
    b.server.offline = true;
    await _boot(b.store);
    expect(b.store.loggedMeals.map((m) => m.id), contains(mealId));
    expect(b.store.favorites.where((f) => f.pinned), isNotEmpty);
    expect(b.store.weightLog.latest!.weightKg, 79.4);
    expect(b.store.userRecipes.map((r) => r.slug), contains('user_inventur'));
    expect(b.store.profile.dailyKcalGoal, 1750);

    // Cold start WITH network, empty server: merge + overlay must hold ALL five.
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

  // --- The inventory finding: the streak day had ZERO nets -----------------
  //
  // `_recordTrackingDay` was pure fire-and-forget: no op, no marker, no retry.
  // The optimistic state held 600 ms, then `_flushStatsDelta` adopted the
  // server row that does not know the day and pinned the loss.

  test(
      'Streak-Tag: scheitert record_tracking_day, landet der Tag in der '
      'Outbox statt im Nichts — und die Anzeige haelt, obwohl der Stats-Flush '
      'gleich darauf die Serverzeile adoptiert', () async {
    final s = _setup();
    await _boot(s.store);
    // ONLY the streak RPC fails, which is why the loss was invisible.
    s.server.rejectTrackingDay = true;

    final id = s.store.addResultToDailyTotal(_result('Streak-Bowl'));
    await _settle();
    expect(s.server.mealRows.keys, contains(id),
        reason: 'Vorbedingung: an der Mahlzeit selbst liegt es nicht');

    // Let the 600 ms stats-flush debounce elapse: that is when the day was lost.
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

/// Writes outbox rows RAW into the key-value store, bypassing
/// [LocalCache.writeOutbox] and the [SyncOp] factories — the only way to build
/// wire forms no production path creates (unreadable payload A8, ancient
/// `queued_at` A4).
Future<void> _seedRawOutbox(
  InMemoryKeyValueStore kv,
  List<Map<String, dynamic>> items,
) =>
    kv.setString('eatova.v1.outbox.user-outbox',
        jsonEncode(<String, dynamic>{'items': items}));
