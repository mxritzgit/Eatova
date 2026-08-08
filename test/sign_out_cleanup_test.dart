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

// Audit 2026-06-09, M-1: der lokale Klartext-PII-Cache (Profil, Mood-Notiz,
// Lifetime-Stats, Notification-Flag) wurde bisher NUR bei der Konto-Löschung
// geräumt, nicht beim normalen Sign-Out. Damit blieben Gesundheits-/Profildaten
// nach dem Logout unverschlüsselt in den SharedPreferences liegen.
//
// signOutCleanup() schließt diese Lücke. Der Test treibt den Store ohne Sync
// (kein Supabase nötig) mit einem injizierten In-Memory-Cache und prüft, dass
// nach signOutCleanup() KEINE der gecachten Zeilen mehr lesbar ist.
//
// DATA-7 (2026-08-06): der Cache spiegelt inzwischen auch Tagebuch, Favoriten,
// Gewichts-Log, die Write-Outbox und pendende Stats-Deltas — alles PII
// (Essverhalten, Koerpergewicht). Auch diese Slots MUESSEN beim Sign-Out
// verschwinden.

void _noopSnack(
  String message, {
  IconData icon = Icons.info_outline_rounded,
  Color accent = const Color(0xFFFFFFFF),
  Duration? duration,
  SnackBarAction? action,
}) {}

/// Zählt [cancelAll] mit — D9 (Review 2026-08-08): geplante Erinnerungen sind
/// OS-Zustand und kennen keinen User, überleben also Logout UND Kontolöschung,
/// solange sie niemand verwirft.
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

/// Zählt [reset] mit — B3 (Review 2026-08-08): der Health-Zustand ist
/// prozesslokal und kennt keinen User. Ohne Reset zeigt Nutzer B auf einem
/// geteilten Gerät weiter As „Apple Health · Synchronisiert". Dieselbe
/// Fehlerklasse wie D9 bei den Benachrichtigungen.
///
/// Zurückgesetzt werden MUSS beides: der Verifier UND das gecachte
/// [authState] in `AppleHealthService` — `refreshHealthSteps` liest genau
/// letzteres, ein reiner Verifier-Reset bliebe also unsichtbar.
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

  test('signOutCleanup räumt den gesamten PII-Cache', () async {
    final store = InMemoryKeyValueStore();
    final cache = LocalCache(store, 'user-signout');
    await cache.writeProfile(const UserProfile(
      weightKg: 81,
      heightCm: 182,
      onboardingCompleted: true,
    ));
    await cache.writeLifetimeStats(LifetimeStats(mealsLogged: 12));
    await cache.writeNotificationsEnabled(true);
    // DATA-7-Slots: Tagebuch, Favoriten, Gewicht, Outbox, Stats-Deltas.
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

    // Vorbedingung: alles ist da.
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

    // Nach dem Logout darf nichts mehr lesbar sein.
    expect(await cache.readProfile(), isNull);
    expect(await cache.readLifetimeStats(), isNull);
    expect(await cache.readNotificationsEnabled(), isNull);
    expect(await cache.readLoggedMeals(), isNull);
    expect(await cache.readFavorites(), isNull);
    expect(await cache.readWeightLog(), isNull);
    expect(await cache.readOutbox(), isNull);
    expect(await cache.readPendingStatsDeltas(), isNull);
    expect(store.snapshot, isEmpty,
        reason: 'kein PII-Rest (Essverhalten/Gewicht) nach dem Sign-Out');
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
    // Kein debugCache, kein Sync -> nichts zu räumen, kein Crash/Channel.
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
