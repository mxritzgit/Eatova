import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';

// Regression (2026-08-04): with the training tab gone the streak had no writer
// and stayed at 0. It is now a LOGGING streak: logging a meal for TODAY
// continues it, even offline; late entries for past days do not.

void _noopSnack(
  String message, {
  IconData icon = Icons.info_outline,
  SnackTone tone = SnackTone.positive,
  Duration? duration,
  SnackBarAction? action,
}) {}

HomeStore _store() => HomeStore(
  sync: null,
  health: const NoopHealthService(),
  notificationService: const NoopNotificationService(),
  initialUserName: 'Test',
  emitSnack: _noopSnack,
);

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
  sourceLabel: 'Foto-KI',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final today = DateTime(2026, 9, 20, 12);

  test('Mahlzeit fuer HEUTE loggen fuehrt die Streak — 0 -> 1', () async {
    await withClock(Clock.fixed(today), () async {
      final store = _store();
      addTearDown(store.dispose);
      expect(store.lifetimeStats.currentStreak, 0);

      await store.addResultToDailyTotal(_meal('Bowl'));

      expect(store.lifetimeStats.currentStreak, 1);
      expect(store.lifetimeStats.effectiveStreakOn(clock.now()), 1);
      final today = DateUtils.dateOnly(clock.now());
      expect(store.lifetimeStats.lastTrackedDate, today);
    });
  });

  test('zweite Mahlzeit am selben Tag zaehlt nicht doppelt', () async {
    await withClock(Clock.fixed(today), () async {
      final store = _store();
      addTearDown(store.dispose);
      await store.addResultToDailyTotal(_meal('Fruehstueck'));
      await store.addResultToDailyTotal(_meal('Mittag'));

      expect(store.lifetimeStats.currentStreak, 1);
      expect(store.lifetimeStats.mealsLogged, 2);
    });
  });

  test(
    'Nachtrag fuer einen vergangenen Tag laesst die Streak unangetastet',
    () async {
      await withClock(Clock.fixed(today), () async {
        final store = _store();
        addTearDown(store.dispose);
        await store.addResultToDailyTotal(_meal('Heute'));
        expect(store.lifetimeStats.currentStreak, 1);

        final yesterday = DateUtils.dateOnly(
          clock.now().subtract(const Duration(days: 1)),
        );
        await store.addResultToDailyTotal(
          _meal('Nachtrag'),
          foodDate: yesterday,
        );

        expect(store.lifetimeStats.currentStreak, 1);
        final today = DateUtils.dateOnly(clock.now());
        expect(store.lifetimeStats.lastTrackedDate, today);
        expect(store.lifetimeStats.mealsLogged, 2);
      });
    },
  );
}
