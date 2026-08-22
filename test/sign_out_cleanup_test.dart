import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/favorite_meal.dart';
import 'package:eatova/src/models/lifetime_stats.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/models/weight_log.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/services/sync_outbox.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';

// Audit 2026-06-09, M-1: the local PII cache used to be cleared only on account
// deletion, not on a normal sign-out, so health/profile data stayed in
// SharedPreferences after logout.
//
// signOutCleanup() closes that gap. The test drives the store without sync
// (no Supabase needed) against an injected in-memory cache and checks that no
// cached row is readable afterwards.
//
// DATA-7: the cache also mirrors diary, favorites, weight log, the write outbox
// and pending stats deltas — all PII, so those slots must go too.

void _noopSnack(
  String message, {
  IconData icon = Icons.info_outline_rounded,
  SnackTone tone = SnackTone.positive,
  Duration? duration,
  SnackBarAction? action,
}) {}

/// Counts [cancelAll] — D9: scheduled reminders are OS state and know no user,
/// so they survive logout AND account deletion unless discarded.
class _SpyNotificationService implements NotificationService {
  int cancelAllCalls = 0;

  @override
  Future<void> init() async {}

  @override
  Future<bool> requestPermission() async => false;

  @override
  Future<void> scheduleAll(List<NotificationSpec> specs) async {}

  @override
  Future<void> cancelAll() async => cancelAllCalls++;
}

/// Counts [reset] — B3: health state is process-local and knows no user, so
/// without a reset user B keeps seeing A's connection on a shared device.
///
/// BOTH must be reset: the verifier AND the cached [authState] in
/// `AppleHealthService` — `refreshHealthSteps` reads the latter, so a
/// verifier-only reset would stay invisible.
class _SpyHealthService implements HealthService {
  int resetCalls = 0;
  HealthAuthState _state = HealthAuthState.granted;

  @override
  HealthAuthState get authState => _state;

  @override
  void reset() {
    resetCalls++;
    _state = HealthAuthState.unknown;
  }

  @override
  Future<HealthAuthState> requestAuthorization() async => _state;

  @override
  Future<HealthSnapshot?> readSnapshot() async => null;

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

  @override
  Future<int?> readStepsOnDay(DateTime day) async => null;
}

HomeStore _storeWith(
  LocalCache cache, {
  NotificationService? notifications,
  HealthService? health,
}) =>
    HomeStore(
      sync: null,
      health: health ?? const NoopHealthService(),
      notificationService: notifications ?? const NoopNotificationService(),
      initialUserName: 'Test',
      emitSnack: _noopSnack,
      debugCache: cache,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'signOutCleanup räumt den gesamten PII-Cache — nur die nicht '
      'zugestellten Sync-Slots überleben (A2)', () async {
    final store = InMemoryKeyValueStore();
    final cache = LocalCache(store, 'user-signout');
    await cache.writeProfile(const UserProfile(
      weightKg: 81,
      heightCm: 182,
      onboardingCompleted: true,
    ));
    await cache.writeLifetimeStats(LifetimeStats(mealsLogged: 12));
    await cache.writeNotificationsEnabled(true);
    // DATA-7 slots: diary, favorites, weight, outbox, stats deltas.
    const result = MealAnalysisResult(
      mealName: 'Private Bowl',
      caloriesKcal: 500,
      estimatedGrams: 400,
      kcalPer100G: 125,
      protein: '35 g',
      carbs: '55 g',
      fat: '15 g',
      confidence: 'Hoch',
      portionNotes: 'privat',
    );
    final meal = LoggedMeal(
      id: 'm-privat',
      result: result,
      loggedAt: DateTime(2026, 8, 6, 12),
    );
    await cache.writeLoggedMeals([meal]);
    await cache.writeFavorites([
      FavoriteMeal(
          id: 'name:private bowl',
          result: result,
          addedAt: DateTime(2026, 8, 6)),
    ]);
    await cache.writeWeightLog(WeightLog(entries: [
      WeightLogEntry(timestamp: DateTime(2026, 8, 6, 7), weightKg: 81.0),
    ]));
    await cache.writeOutbox([SyncOp.mealInsert(meal, trackDay: true)]);
    await cache.writePendingStatsDeltas(meals: 1, weightLogs: 1);

    // Precondition: everything is present.
    expect(await cache.readProfile(), isNotNull);
    expect(await cache.readLifetimeStats(), isNotNull);
    expect(await cache.readNotificationsEnabled(), isTrue);
    expect(await cache.readLoggedMeals(), isNotNull);
    expect(await cache.readFavorites(), isNotNull);
    expect(await cache.readWeightLog(), isNotNull);
    expect(await cache.readOutbox(), isNotNull);
    expect(await cache.readPendingStatsDeltas(), isNotNull);
    expect(store.snapshot, isNotEmpty);

    await _storeWith(cache).signOutCleanup();

    // After logout nothing of the PII cache may be readable.
    expect(await cache.readProfile(), isNull);
    expect(await cache.readLifetimeStats(), isNull);
    expect(await cache.readNotificationsEnabled(), isNull);
    expect(await cache.readLoggedMeals(), isNull);
    expect(await cache.readFavorites(), isNull);
    expect(await cache.readWeightLog(), isNull);
    // The two sync slots survive: this store never hydrated (no start()) and
    // never delivered (sync: null), so the seeded op would otherwise be
    // destroyed without a delivery attempt (the A2 window). The slots are
    // AES-encrypted and namespaced by user id, so another account on the same
    // device never reads them.
    expect(await cache.readOutbox(), isNotNull);
    expect(await cache.readPendingStatsDeltas(), isNotNull);
    expect(
        store.snapshot.keys.toSet(),
        {
          'eatova.v1.outbox.user-signout',
          'eatova.v1.pending_stats.user-signout',
        },
        reason: 'kein PII-Rest (Essverhalten/Gewicht) nach dem Sign-Out — '
            'nur die nicht zugestellten Sync-Slots bleiben');
  });

  test(
      'D9: signOutCleanup verwirft die geplanten Erinnerungen — sonst zeigt '
      'das Familien-Tablet der nächsten Person die fremde Streak', () async {
    final spy = _SpyNotificationService();
    final cache = LocalCache(InMemoryKeyValueStore(), 'user-signout');

    await _storeWith(cache, notifications: spy).signOutCleanup();

    expect(spy.cancelAllCalls, 1);
  });

  test(
      'D9: deleteAccount verwirft die geplanten Erinnerungen — der Dialog '
      'verspricht „unwiderruflich gelöscht"', () async {
    final spy = _SpyNotificationService();
    final cache = LocalCache(InMemoryKeyValueStore(), 'user-signout');

    expect(await _storeWith(cache, notifications: spy).deleteAccount(), isTrue);

    expect(spy.cancelAllCalls, 1);
  });

  test(
      'B3: signOutCleanup trennt Apple Health — sonst zeigt Nutzer B auf dem '
      'geteilten Gerät As „Synchronisiert"', () async {
    final health = _SpyHealthService();
    final cache = LocalCache(InMemoryKeyValueStore(), 'user-signout');
    final store = _storeWith(cache, health: health);
    expect(health.authState, HealthAuthState.granted,
        reason: 'Ausgangslage: A ist verbunden');

    await store.signOutCleanup();

    expect(health.resetCalls, 1);
    expect(health.authState, HealthAuthState.unknown);
    expect(store.healthAuthState, HealthAuthState.unknown,
        reason: 'der Store-Zustand speist die Profilkarte und muss mitziehen');
  });

  test(
      'B3: deleteAccount trennt Apple Health — der Dialog verspricht '
      '„unwiderruflich gelöscht"', () async {
    final health = _SpyHealthService();
    final cache = LocalCache(InMemoryKeyValueStore(), 'user-signout');
    final store = _storeWith(cache, health: health);

    expect(await store.deleteAccount(), isTrue);

    expect(health.resetCalls, 1);
    expect(store.healthAuthState, HealthAuthState.unknown);
  });

  test('signOutCleanup ist ohne Cache ein gefahrloses No-Op', () async {
    // No debugCache, no sync -> nothing to clear, no crash/channel.
    final store = HomeStore(
      sync: null,
      health: const NoopHealthService(),
      notificationService: const NoopNotificationService(),
      initialUserName: 'Test',
      emitSnack: _noopSnack,
    );
    await expectLater(store.signOutCleanup(), completes);
  });
}
