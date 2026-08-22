import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/kcal_calculator.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/local_day.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';

// Burned kcal per day: it used to be derived live from TODAY's steps only, so
// every archive day showed "—". Now each verified health refresh pins the day
// value into [HomeStore.dailyActivity] and the cache slot, and setFoodDate
// backfills an archive day once per session.
//
// "Burned" counts EVERY step (ACSM net, 0.5 kcal/kg/km) with no baseline, so
// even a 4000-step day yields a value, not 0.

/// Health double: controllable steps for today plus a per-day history.
class _FakeHealth implements HealthService {
  int stepsToday = 12000;

  /// Answers for readStepsOnDay by localDayKey; missing means null.
  final Map<String, int?> stepsByDay = <String, int?>{};

  /// Every readStepsOnDay call, for the once-per-session assertion.
  final List<DateTime> dayReads = <DateTime>[];

  @override
  HealthAuthState get authState => HealthAuthState.granted;

  @override
  void reset() {}

  @override
  Future<HealthAuthState> requestAuthorization() async =>
      HealthAuthState.granted;

  @override
  Future<HealthSnapshot?> readSnapshot() async =>
      HealthSnapshot(stepsToday: stepsToday, fetchedAt: clock.now());

  @override
  Future<int?> readStepsOnDay(DateTime day) async {
    dayReads.add(day);
    return stepsByDay[localDayKey(day)];
  }

  @override
  Future<bool> writeWeight(double kg, DateTime when) async => false;

  @override
  Future<List<WeightSample>> readWeightSamples({
    required DateTime from,
    required DateTime to,
  }) async =>
      const <WeightSample>[];

  @override
  Future<SleepSample?> readLastSleep({DateTime? before}) async => null;
}

void _ignoreSnack(
  String message, {
  IconData icon = Icons.info_outline,
  SnackTone tone = SnackTone.positive,
  Duration? duration,
  SnackBarAction? action,
}) {}

/// Empty fake PostgREST, so the boot completes without server data.
http.Client _emptyServer() => MockClient((req) async {
      if (req.method == 'GET') {
        return http.Response(jsonEncode(const <dynamic>[]), 200,
            headers: const {'Content-Type': 'application/json'}, request: req);
      }
      return http.Response('', 201, request: req);
    });

/// Store WITH sync and cache, so pinning and hydration are exercised.
({HomeStore store, _FakeHealth health, LocalCache cache}) _setupSynced(
    InMemoryKeyValueStore kv) {
  final client = SupabaseClient(
    'https://example.supabase.co',
    'test-anon-key',
    httpClient: _emptyServer(),
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  addTearDown(client.dispose);
  final cache = LocalCache(kv, 'user-activity');
  final health = _FakeHealth();
  final store = HomeStore(
    sync: EatovaSync.forUser(client, 'user-activity'),
    health: health,
    notificationService: const NoopNotificationService(),
    initialUserName: 'Test',
    emitSnack: _ignoreSnack,
    debugCache: cache,
  );
  addTearDown(store.dispose);
  return (store: store, health: health, cache: cache);
}

/// Light store WITHOUT sync for the pure in-memory paths (display, backfill).
({HomeStore store, _FakeHealth health}) _setupLight() {
  final health = _FakeHealth();
  final store = HomeStore(
    sync: null,
    health: health,
    notificationService: const NoopNotificationService(),
    initialUserName: 'Test',
    emitSnack: _ignoreSnack,
  );
  addTearDown(store.dispose);
  return (store: store, health: health);
}

/// Same maths as HomeStore: every step counts, no baseline.
int _erwarteteKcal(HomeStore store, int steps) => estimateKcalBurnedFromSteps(
      steps: steps,
      weightKg: store.profile.weightKg,
      heightCm: store.profile.heightCm,
      sex: store.profile.sex,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  DateTime tageZurueck(int n) =>
      DateUtils.dateOnly(clock.now()).subtract(Duration(days: n));

  test('Health-Refresh schreibt den heutigen Tageswert in Map + Cache fest',
      () async {
    final s = _setupSynced(InMemoryKeyValueStore());
    s.store.start();
    await s.store.profileReady;

    await s.store.refreshHealthSteps();

    final key = localDayKey(clock.now());
    final kcal = _erwarteteKcal(s.store, 12000);
    // Default profile 78 kg / 178 cm / neutral:
    // 12 000 steps × 0.73692 m = 8.843 km × 78 kg × 0.5 = 344.9 kcal.
    expect(kcal, 345);
    expect(s.store.dailyActivity[key], (steps: 12000, kcal: kcal));
    expect(await s.cache.readDailyActivity(),
        containsPair(key, (steps: 12000, kcal: kcal)));
  });

  test('burnedKcalForFoodDate: heute live, Archivtag gespeichert, sonst 0',
      () async {
    final s = _setupLight();
    await s.store.refreshHealthSteps();

    // Today: live derivation from dailySteps.
    expect(s.store.burnedKcalForFoodDate(clock.now()),
        _erwarteteKcal(s.store, 12000));
    // Archive day without an entry: 0, so the tile shows "—".
    expect(s.store.burnedKcalForFoodDate(tageZurueck(1)), 0);

    // Backfilled: 9000 × 0.73692 m = 6.632 km × 39 = 258.7 → 259 kcal.
    final gestern = tageZurueck(1);
    s.health.stepsByDay[localDayKey(gestern)] = 9000;
    s.store.setFoodDate(gestern);
    await Future<void>.delayed(Duration.zero);
    final gesternKcal = _erwarteteKcal(s.store, 9000);
    expect(gesternKcal, 259);
    expect(s.store.burnedKcalForFoodDate(gestern), gesternKcal);
    // Today stays live even if an older entry exists for today.
    expect(s.store.burnedKcalForFoodDate(clock.now()),
        _erwarteteKcal(s.store, 12000));

    // A small day counts fully: no baseline (4000 × 0.73692 × 39 → 115).
    final vorgestern = tageZurueck(2);
    s.health.stepsByDay[localDayKey(vorgestern)] = 4000;
    s.store.setFoodDate(vorgestern);
    await Future<void>.delayed(Duration.zero);
    expect(s.store.dailyActivity[localDayKey(vorgestern)],
        (steps: 4000, kcal: 115));
    expect(s.store.burnedKcalForFoodDate(vorgestern), 115);
  });

  test('stepsForFoodDate: null ohne Schrittquelle, heute live, Archivtag '
      'gespeichert', () async {
    final s = _setupLight();

    // No verified permission and no step count yet: no source -> null.
    expect(s.store.stepsForFoodDate(clock.now()), isNull);

    await s.store.refreshHealthSteps();
    expect(s.store.stepsForFoodDate(clock.now()), 12000);

    // Granted plus 0 steps is a real 0 (early morning), not null.
    s.health.stepsToday = 0;
    await s.store.refreshHealthSteps();
    expect(s.store.stepsForFoodDate(clock.now()), 0);

    // Null without an entry; after the backfill the stored value.
    final gestern = tageZurueck(1);
    expect(s.store.stepsForFoodDate(gestern), isNull);
    s.health.stepsByDay[localDayKey(gestern)] = 9000;
    s.store.setFoodDate(gestern);
    await Future<void>.delayed(Duration.zero);
    expect(s.store.stepsForFoodDate(gestern), 9000);
    expect(s.store.burnedKcalForFoodDate(gestern), _erwarteteKcal(s.store, 9000));
  });

  test('Backfill fragt die Historie genau einmal pro Tag und Sitzung',
      () async {
    final s = _setupLight();
    final gestern = tageZurueck(1);
    s.health.stepsByDay[localDayKey(gestern)] = 6000;

    s.store.setFoodDate(gestern);
    await Future<void>.delayed(Duration.zero);
    s.store.setFoodDate(clock.now());
    s.store.setFoodDate(gestern);
    await Future<void>.delayed(Duration.zero);

    // Today never triggers a history query, yesterday exactly one.
    expect(s.health.dayReads, hasLength(1));
  });

  test('Backfill ohne Daten (null) schreibt nichts fest', () async {
    final s = _setupLight();
    final vorgestern = tageZurueck(2);

    s.store.setFoodDate(vorgestern);
    await Future<void>.delayed(Duration.zero);

    expect(s.store.dailyActivity, isEmpty);
    expect(s.store.burnedKcalForFoodDate(vorgestern), 0);
  });

  test('Hydration: der Tageswert uebersteht den Kaltstart', () async {
    final kv = InMemoryKeyValueStore();
    final erste = _setupSynced(kv);
    erste.store.start();
    await erste.store.profileReady;
    await erste.store.refreshHealthSteps();
    final key = localDayKey(clock.now());
    final erwartet = erste.store.dailyActivity[key];
    expect(erwartet, isNotNull);

    // "Next session": fresh store on the same storage, NO refresh.
    final zweite = _setupSynced(kv);
    zweite.store.start();
    await zweite.store.profileReady;

    expect(zweite.store.dailyActivity[key], erwartet);
  });

  test('clear() raeumt den Aktivitaets-Slot (M-1)', () async {
    final kv = InMemoryKeyValueStore();
    final cache = LocalCache(kv, 'user-activity');
    await cache.writeDailyActivity({
      '2026-08-11': (steps: 6000, kcal: 250),
    });
    expect(await cache.readDailyActivity(), isNotNull);

    await cache.clear();

    expect(await cache.readDailyActivity(), isNull);
  });

  test('korrupter Slot liefert null bzw. ueberspringt kaputte Tage', () async {
    final kv = InMemoryKeyValueStore({
      'eatova.v1.daily_activity.user-activity': jsonEncode({
        'days': {
          '2026-08-10': {'steps': 5000, 'kcal': 210},
          '2026-08-11': 'kaputt',
        },
      }),
    });
    final cache = LocalCache(kv, 'user-activity');
    final back = await cache.readDailyActivity();
    expect(back, {'2026-08-10': (steps: 5000, kcal: 210)});

    final kaputt = InMemoryKeyValueStore({
      'eatova.v1.daily_activity.user-activity': 'kein json',
    });
    expect(await LocalCache(kaputt, 'user-activity').readDailyActivity(),
        isNull);
  });
}
