import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/meals_sync.dart' show mealResultToJson;
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/services/recipe_image_store.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';

// Shared harness for the fix run 2026-08-27, package A (core/boot/sync).
//
// Same shape as the fake in test/outbox/outbox_test_helpers.dart, plus the one
// thing the boot-race tests need: reads can be HELD. A held GET captures its
// answer at request time and delivers it on release — exactly a server whose
// snapshot predates a live write that landed while the request was in flight.

const String kFixlaufUser = 'user-fixlauf-a';

/// Stateful fake PostgREST with holdable reads.
class FixlaufServer {
  /// Every request throws a [http.ClientException] (network error).
  bool offline = false;

  /// No request is ever answered.
  bool silent = false;

  /// GET requests are captured and answered only on [releaseReads].
  bool holdReads = false;

  /// Non-GET requests are applied at once but answered only on
  /// [releaseWrites] — a live write whose confirmation arrives late.
  bool holdWrites = false;

  /// `record_tracking_day` / `increment_lifetime_stats` fail with 500.
  bool rejectRpcs = false;

  /// The RPCs are recorded but never answered (a stats flush on the wire
  /// for good); table requests keep working.
  bool silentRpcs = false;

  /// logged_meals writes fail with 500 — a retryable SERVER error.
  bool rejectMealWrites = false;

  /// profiles GET fails with 500 — the server is reachable but says nothing
  /// about the row.
  bool rejectProfileReads = false;

  final List<http.Request> requests = <http.Request>[];
  final List<({Completer<http.Response> completer, http.Response snapshot})>
      _held = [];
  final List<({Completer<http.Response> completer, http.Response snapshot})>
      _heldWrites = [];

  Map<String, dynamic>? profileRow;
  final Map<String, Map<String, dynamic>> mealRows =
      <String, Map<String, dynamic>>{};
  final Map<String, Map<String, dynamic>> favoriteRows =
      <String, Map<String, dynamic>>{};
  final Map<String, Map<String, dynamic>> weightRows =
      <String, Map<String, dynamic>>{};
  final Map<String, Map<String, dynamic>> recipeRows =
      <String, Map<String, dynamic>>{};
  int mealsCounted = 0;
  int weightLogsCounted = 0;
  String? trackedDay;

  int get heldReads => _held.length;
  int get heldWrites => _heldWrites.length;

  /// Answers every held GET with the snapshot captured at request time.
  void releaseReads() {
    final pending = List.of(_held);
    _held.clear();
    for (final h in pending) {
      h.completer.complete(h.snapshot);
    }
  }

  /// Answers every held write.
  void releaseWrites() {
    final pending = List.of(_heldWrites);
    _heldWrites.clear();
    for (final h in pending) {
      h.completer.complete(h.snapshot);
    }
  }

  Iterable<http.Request> requestsTo(String path, {String? method}) =>
      requests.where((r) =>
          r.url.path.contains(path) && (method == null || r.method == method));

  http.Client client() => MockClient(_handle);

  Future<http.Response> _handle(http.Request req) async {
    if (offline) throw http.ClientException('offline', req.url);
    if (silent) return Completer<http.Response>().future;
    requests.add(req);
    if (silentRpcs && req.url.path.contains('/rpc/')) {
      return Completer<http.Response>().future;
    }
    final answer = _answer(req);
    if (holdReads && req.method == 'GET') {
      final c = Completer<http.Response>();
      _held.add((completer: c, snapshot: answer));
      return c.future;
    }
    if (holdWrites && req.method != 'GET') {
      final c = Completer<http.Response>();
      _heldWrites.add((completer: c, snapshot: answer));
      return c.future;
    }
    return answer;
  }

  http.Response _answer(http.Request req) {
    final path = req.url.path;
    http.Response ok(Object body) => http.Response(jsonEncode(body), 200,
        headers: const {'Content-Type': 'application/json'}, request: req);
    http.Response fail() => http.Response(jsonEncode({'message': 'kaputt'}),
        500,
        headers: const {'Content-Type': 'application/json'}, request: req);

    if (path.contains('/rpc/increment_lifetime_stats')) {
      if (rejectRpcs) return fail();
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      mealsCounted += (body['p_meals'] as num?)?.toInt() ?? 0;
      weightLogsCounted += (body['p_weight_logs'] as num?)?.toInt() ?? 0;
      return ok(statsRow());
    }
    if (path.contains('/rpc/record_tracking_day')) {
      if (rejectRpcs) return fail();
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      trackedDay = body['p_day'] as String?;
      return ok(statsRow());
    }
    if (path.contains('/logged_meals')) {
      if (rejectMealWrites && req.method != 'GET') return fail();
      if (req.method == 'POST') {
        for (final row in _rowsOf(req.body)) {
          mealRows[row['id'] as String] = row;
        }
        return http.Response('', 201, request: req);
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
    if (path.contains('/profiles')) {
      if (req.method == 'GET') {
        if (rejectProfileReads) return fail();
        return ok(profileRow == null
            ? const <dynamic>[]
            : <Map<String, dynamic>>[profileRow!]);
      }
      for (final row in _rowsOf(req.body)) {
        profileRow = <String, dynamic>{...?profileRow, ...row};
      }
      return ok(profileRow!);
    }
    if (path.contains('/user_recipes')) {
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
        return http.Response('', 201, request: req);
      }
      return ok(weightRows.values
          .map((r) => <String, dynamic>{
                'recorded_at': r['recorded_at'],
                'weight_kg': r['weight_kg'],
              })
          .toList());
    }
    if (req.method == 'GET') return ok(const <dynamic>[]);
    return http.Response('', 201, request: req);
  }

  Map<String, dynamic> statsRow() => <String, dynamic>{
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

class SnackCapture {
  final List<String> messages = <String>[];
  final List<SnackTone> tones = <SnackTone>[];

  void call(
    String message, {
    IconData icon = Icons.info_outline_rounded,
    SnackTone tone = SnackTone.positive,
    Duration? duration,
    SnackBarAction? action,
  }) {
    messages.add(message);
    tones.add(tone);
  }
}

typedef FixlaufSetup = ({
  HomeStore store,
  FixlaufServer server,
  LocalCache? cache,
  InMemoryKeyValueStore kv,
  SnackCapture snacks,
});

/// Builds the real HomeStore over [FixlaufServer]. [ohneCache] mirrors the
/// state where `LocalCache.create` returned null. [disposeClient] is off for
/// silent servers: `dispose` would wait a hanging request into the timeout.
/// [autoDispose] is off for tests that dispose the store themselves.
FixlaufSetup fixlaufSetup({
  InMemoryKeyValueStore? kv,
  LocalCache? cache,
  FixlaufServer? server,
  bool ohneCache = false,
  bool disposeClient = true,
  bool autoDispose = true,
  NotificationService notifications = const NoopNotificationService(),
}) {
  final srv = server ?? FixlaufServer();
  final client = SupabaseClient(
    'https://example.supabase.co',
    'test-anon-key',
    httpClient: srv.client(),
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  if (disposeClient) addTearDown(client.dispose);
  final store = kv ?? InMemoryKeyValueStore();
  final localCache = ohneCache ? null : (cache ?? LocalCache(store, kFixlaufUser));
  final snacks = SnackCapture();
  final home = HomeStore(
    sync: EatovaSync.forUser(client, kFixlaufUser),
    health: const NoopHealthService(),
    notificationService: notifications,
    initialUserName: 'Test',
    emitSnack: snacks.call,
    debugCache: localCache,
  );
  if (autoDispose) addTearDown(home.dispose);
  return (store: home, server: srv, cache: localCache, kv: store, snacks: snacks);
}

/// Photo store double without file IO: `signOutCleanup`/`deleteAccount` call
/// `RecipeImageStore.instance.clear()`, which under FakeAsync never returns.
class StummerFotoStore extends RecipeImageStore {
  @override
  Future<void> setActiveUser(String? userId) => Future<void>.value();

  @override
  Future<void> clear() => Future<void>.value();
}

Future<void> settle({int times = 60}) => pumpEventQueue(times: times);

Future<void> bootStore(HomeStore store) async {
  store.start();
  await store.profileReady;
  await settle();
}

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

/// Server row of public.profiles in the strict select shape.
Map<String, dynamic> serverProfileRow(UserProfile p) => <String, dynamic>{
      'id': kFixlaufUser,
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
      'manual_energy': p.manualEnergy,
    };

/// Server row of logged_meals (select shape of MealsSync.loadLoggedMeals).
Map<String, dynamic> serverMealRow(String id, {String name = 'Server-Gericht'}) =>
    <String, dynamic>{
      'id': id,
      'logged_at': DateTime.now().toUtc().toIso8601String(),
      'forced_slot': null,
      'local_day': null,
      'payload': mealResultToJson(mealResult(name, kcal: 250)),
    };

/// The completed profile of a returning user.
const UserProfile completedProfile = UserProfile(
  weightKg: 80,
  heightCm: 180,
  onboardingCompleted: true,
);

/// All PII slot keys of [kFixlaufUser] that a logout must clear.
const List<String> piiSlotKeys = <String>[
  'eatova.v1.profile.$kFixlaufUser',
  'eatova.v1.stats.$kFixlaufUser',
  'eatova.v1.notifications_enabled.$kFixlaufUser',
  'eatova.v1.logged_meals.$kFixlaufUser',
  'eatova.v1.favorites.$kFixlaufUser',
  'eatova.v1.weight_log.$kFixlaufUser',
  'eatova.v1.user_recipes.$kFixlaufUser',
  'eatova.v1.daily_activity.$kFixlaufUser',
];
