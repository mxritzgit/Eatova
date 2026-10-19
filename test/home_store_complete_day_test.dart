import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/day_math.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';

// 2026-10-19: Today's day strip marks the days that pass the one
// complete-day rule (half the daily goal), the days the trends averages and
// the weekly check count. The store answers per day.

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

MealAnalysisResult _meal(int kcal) => MealAnalysisResult(
  mealName: 'Essen $kcal',
  caloriesKcal: kcal,
  estimatedGrams: 300,
  kcalPer100G: 100,
  protein: '30 g',
  carbs: '50 g',
  fat: '20 g',
  confidence: 'Mittel',
  portionNotes: 'Test-Mahlzeit.',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime(2026, 10, 19, 12);

  test('ein Tag ist ab der Haelfte des Tagesziels vollstaendig', () async {
    await withClock(Clock.fixed(now), () async {
      final store = _store();
      addTearDown(store.dispose);
      final yesterday = addDays(startOfDay(now), -1);
      final twoAgo = addDays(startOfDay(now), -2);
      expect(store.profile.dailyKcalGoal, 2200);

      await store.addResultToDailyTotal(_meal(1099), foodDate: yesterday);
      await store.addResultToDailyTotal(_meal(1100), foodDate: twoAgo);
      await store.addResultToDailyTotal(_meal(400));

      expect(store.isCompleteFoodDay(yesterday), isFalse);
      expect(store.isCompleteFoodDay(twoAgo), isTrue);
      expect(store.isCompleteFoodDay(now), isFalse);
      // An empty day is never complete.
      expect(store.isCompleteFoodDay(addDays(now, -3)), isFalse);

      await store.addResultToDailyTotal(_meal(1), foodDate: yesterday);
      expect(store.isCompleteFoodDay(yesterday), isTrue);
    });
  });

  test('ein Tag ausserhalb des geladenen Fensters wird nie markiert', () async {
    await withClock(Clock.fixed(now), () async {
      final store = _store();
      addTearDown(store.dispose);
      final old = addDays(startOfDay(now), -40);
      await store.addResultToDailyTotal(_meal(2500), foodDate: old);
      expect(store.mealsForFoodDate(old), hasLength(1));
      // Only part of such a day may be in memory: no judgement on it.
      expect(store.isCompleteFoodDay(old), isFalse);
    });
  });
}
