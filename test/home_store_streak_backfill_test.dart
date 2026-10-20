import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/lifetime_stats.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';

// 2026-10-19: an entry back-filled for YESTERDAY tracks yesterday when that
// continues the chain (it ended the day before yesterday), like the server's
// record_tracking_day(yesterday): +1. Other back-dated entries, and
// yesterday once today is tracked, stay back-fills; the server could not
// merge them. The wire half is test/flows/streak_yesterday_flow_test.dart.

void _noopSnack(
  String message, {
  IconData icon = Icons.info_outline,
  SnackTone tone = SnackTone.positive,
  Duration? duration,
  SnackBarAction? action,
}) {}

MealAnalysisResult _meal(String name) => MealAnalysisResult(
  mealName: name,
  caloriesKcal: 300,
  estimatedGrams: 300,
  kcalPer100G: 100,
  protein: '30 g',
  carbs: '50 g',
  fat: '20 g',
  confidence: 'Mittel',
  portionNotes: 'Test-Mahlzeit.',
);

/// Friday 2026-06-05 morning; the chain of five ended on Wednesday.
final DateTime _now = DateTime(2026, 6, 5, 9);
final DateTime _thu = DateTime(2026, 6, 4);
final DateTime _wed = DateTime(2026, 6, 3);

Future<HomeStore> _store({required DateTime lastTracked}) async {
  final cache = LocalCache(InMemoryKeyValueStore(), 'user-a');
  final store = HomeStore(
    sync: null,
    health: const NoopHealthService(),
    notificationService: const NoopNotificationService(),
    initialUserName: 'Test',
    emitSnack: _noopSnack,
    debugCache: cache,
  );
  addTearDown(store.dispose);
  store.lifetimeStats = LifetimeStats(
    mealsLogged: 20,
    currentStreak: 5,
    longestStreak: 5,
    lastTrackedDate: lastTracked,
  );
  return store;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('ein Eintrag fuer gestern setzt die Kette fort und zaehlt den Tag', () {
    return withClock(Clock.fixed(_now), () async {
      final store = await _store(lastTracked: _wed);
      expect(store.loggingStreak, 0, reason: 'shown as broken before');
      expect(store.yesterdayRescuesStreak, isTrue);

      await store.addResultToDailyTotal(_meal('Abendessen'), foodDate: _thu);

      expect(store.lifetimeStats.currentStreak, 6);
      expect(store.lifetimeStats.lastTrackedDate, _thu);
      expect(store.loggingStreak, 6);
      expect(store.yesterdayRescuesStreak, isFalse);

      // Today continues the saved chain.
      await store.addResultToDailyTotal(_meal('Fruehstueck'));
      expect(store.lifetimeStats.currentStreak, 7);
    });
  });

  test('eine laengst gerissene Kette bleibt beim Nachtrag stehen', () {
    return withClock(Clock.fixed(_now), () async {
      final store = await _store(lastTracked: DateTime(2026, 6, 2));
      expect(store.yesterdayRescuesStreak, isFalse);

      await store.addResultToDailyTotal(_meal('Abendessen'), foodDate: _thu);

      expect(store.lifetimeStats.currentStreak, 5);
      expect(store.lifetimeStats.lastTrackedDate, DateTime(2026, 6, 2));
    });
  });

  test('nach dem ersten Eintrag heute bleibt gestern ein Nachtrag', () {
    return withClock(Clock.fixed(_now), () async {
      final store = await _store(lastTracked: _wed);
      await store.addResultToDailyTotal(_meal('Fruehstueck'));
      expect(store.lifetimeStats.currentStreak, 1);
      expect(store.yesterdayRescuesStreak, isFalse);

      await store.addResultToDailyTotal(_meal('Abendessen'), foodDate: _thu);

      expect(store.lifetimeStats.currentStreak, 1);
      expect(store.lifetimeStats.lastTrackedDate, DateTime(2026, 6, 5));
    });
  });

  test('eine Kopie auf gestern zaehlt wie ein Eintrag', () {
    return withClock(Clock.fixed(_now), () async {
      final store = await _store(lastTracked: _wed);
      store.loggedMeals = [
        LoggedMeal(
          id: 'old',
          result: _meal('Linsen'),
          loggedAt: DateTime(2026, 6, 1, 12),
          forcedSlot: MealSlot.lunch,
          localDay: '2026-06-01',
        ),
      ];

      await store.copyLoggedMeals(['old'], day: _thu);

      expect(store.lifetimeStats.currentStreak, 6);
      expect(store.lifetimeStats.lastTrackedDate, _thu);
    });
  });

  test('verschieben auf gestern zaehlt den Tag', () {
    return withClock(Clock.fixed(_now), () async {
      final store = await _store(lastTracked: _wed);
      store.loggedMeals = [
        LoggedMeal(
          id: 'old',
          result: _meal('Linsen'),
          loggedAt: DateTime(2026, 6, 1, 12),
          forcedSlot: MealSlot.lunch,
          localDay: '2026-06-01',
        ),
      ];

      await store.updateLoggedMealDetails('old', day: _thu);

      expect(store.lifetimeStats.currentStreak, 6);
      expect(store.lifetimeStats.lastTrackedDate, _thu);
    });
  });

  test('der Hinweis braucht ein leeres Heute und ein leeres Gestern', () {
    return withClock(Clock.fixed(_now), () async {
      final store = await _store(lastTracked: _wed);
      expect(store.yesterdayRescuesStreak, isTrue);
      // An entry on yesterday that did not count (logged before this rule)
      // means yesterday is not empty: no hint.
      store.loggedMeals = [
        LoggedMeal(
          id: 'y',
          result: _meal('Snack'),
          loggedAt: DateTime(2026, 6, 4, 15),
          forcedSlot: MealSlot.snack,
          localDay: '2026-06-04',
        ),
      ];
      expect(store.yesterdayRescuesStreak, isFalse);
    });
  });
}
