import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';

// REGRESSION (2026-08-04): Nach dem Training-Tab-Aus (a267e15) hatte die
// Streak keinen Schreiber mehr — sie blieb trotz taeglichem Essens-Logging
// fuer immer auf 0. Seitdem ist sie eine LOGGING-Streak: das Loggen einer
// Mahlzeit fuer HEUTE fuehrt sie (auch offline/optimistisch) fort;
// Nachtraege fuer vergangene Tage lassen sie unangetastet.

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

  test('Mahlzeit fuer HEUTE loggen fuehrt die Streak — 0 -> 1', () {
    final store = _store();
    expect(store.lifetimeStats.currentStreak, 0);

    store.addResultToDailyTotal(_meal('Bowl'));

    expect(store.lifetimeStats.currentStreak, 1);
    expect(store.lifetimeStats.effectiveStreakOn(DateTime.now()), 1);
    final today = DateUtils.dateOnly(DateTime.now());
    expect(store.lifetimeStats.lastTrackedDate, today);
  });

  test('zweite Mahlzeit am selben Tag zaehlt nicht doppelt', () {
    final store = _store();
    store.addResultToDailyTotal(_meal('Fruehstueck'));
    store.addResultToDailyTotal(_meal('Mittag'));

    expect(store.lifetimeStats.currentStreak, 1);
    expect(store.lifetimeStats.mealsLogged, 2);
  });

  test('Nachtrag fuer einen vergangenen Tag laesst die Streak unangetastet',
      () {
    final store = _store();
    store.addResultToDailyTotal(_meal('Heute'));
    expect(store.lifetimeStats.currentStreak, 1);

    final yesterday = DateUtils.dateOnly(
      DateTime.now().subtract(const Duration(days: 1)),
    );
    store.addResultToDailyTotal(_meal('Nachtrag'), foodDate: yesterday);

    expect(store.lifetimeStats.currentStreak, 1);
    final today = DateUtils.dateOnly(DateTime.now());
    expect(store.lifetimeStats.lastTrackedDate, today);
    expect(store.lifetimeStats.mealsLogged, 2);
  });
}
