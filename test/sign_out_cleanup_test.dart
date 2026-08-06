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

HomeStore _storeWith(LocalCache cache) => HomeStore(
      sync: null,
      health: const NoopHealthService(),
      notificationService: const NoopNotificationService(),
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
