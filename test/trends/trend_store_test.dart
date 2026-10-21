// HomeStore's side of the trends page (2026-10-18): the day totals it knows
// completely (laid over the server window, TRN-9) and the step backfill of a
// range, which reads only the days without a value and skips without a
// usable health connection.

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/local_day.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';

final DateTime _now = DateTime(2026, 10, 14, 12, 30);

DateTime _day(int back) => DateTime(2026, 10, 14 - back);

class _Health implements HealthService {
  _Health(this.authState, this.steps);

  @override
  HealthAuthState authState;

  /// Steps per local day key; a missing day reads as null.
  final Map<String, int> steps;
  final List<DateTime> reads = <DateTime>[];

  @override
  Future<HealthAuthState> requestAuthorization() async => authState;

  @override
  Future<HealthSnapshot?> readSnapshot() async => null;

  @override
  void reset() {}

  @override
  Future<bool> writeWeight(double kg, DateTime when) async => false;

  @override
  Future<int?> readStepsOnDay(DateTime day) async {
    reads.add(day);
    return steps[localDayKey(day)];
  }
}

HomeStore _store({HealthService health = const NoopHealthService()}) {
  final store = HomeStore(
    sync: null,
    health: health,
    notificationService: const NoopNotificationService(),
    initialUserName: 'Test',
    emitSnack:
        (
          String message, {
          IconData icon = Icons.info_outline,
          SnackTone tone = SnackTone.positive,
          Duration? duration,
          SnackBarAction? action,
        }) {},
  );
  addTearDown(store.dispose);
  return store;
}

MealAnalysisResult _meal(int kcal) => MealAnalysisResult(
  mealName: 'Test',
  caloriesKcal: kcal,
  estimatedGrams: 100,
  kcalPer100G: kcal.toDouble(),
  protein: '20 g',
  carbs: '30 g',
  fat: '10 g',
  confidence: 'Hoch',
  portionNotes: 'Test.',
  sourceLabel: 'manual',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('trendLocalTotals', () {
    test('summiert die bekannten Tage, ein leerer Tag ist null', () async {
      await withClock(Clock.fixed(_now), () async {
        final store = _store();
        await store.addResultToDailyTotal(
          _meal(400),
          slot: MealSlot.lunch,
          foodDate: _day(1),
        );
        await store.addResultToDailyTotal(
          _meal(250),
          slot: MealSlot.dinner,
          foodDate: _day(1),
        );
        await store.addResultToDailyTotal(_meal(300), slot: MealSlot.lunch);
        await store.addResultToDailyTotal(
          MealAnalysisResult.quickEntry(name: 'Kaffee', caloriesKcal: 150),
          slot: MealSlot.snack,
          foodDate: _day(1),
        );

        final known = store.trendLocalTotals(days: 7);
        expect(known, hasLength(7));
        final yesterday = known[localDayKey(_day(1))]!;
        expect(yesterday.kcal, 800);
        expect(yesterday.proteinG, 40);
        expect(yesterday.proteinMissing, 1, reason: 'kcal-only quick entry');
        expect(known[localDayKey(_day(0))]!.proteinMissing, 0);
        expect(yesterday.day, _day(1));
        expect(known[localDayKey(_day(0))]!.kcal, 300);
        expect(known.containsKey(localDayKey(_day(2))), isTrue);
        expect(known[localDayKey(_day(2))], isNull);
        expect(known.containsKey(localDayKey(_day(7))), isFalse);
      });
    });

    test('Tage ausserhalb des Boot-Fensters sind unbekannt, nicht leer', () {
      withClock(Clock.fixed(_now), () {
        final known = _store().trendLocalTotals();
        // The 35-day boot window is known (empty); older days are not.
        expect(known.containsKey(localDayKey(_day(34))), isTrue);
        expect(known.containsKey(localDayKey(_day(40))), isFalse);
      });
    });
  });

  group('backfillStepsForTrends', () {
    test('liest nur Tage ohne Wert, einmal, und legt sie ab', () async {
      await withClock(Clock.fixed(_now), () async {
        final health = _Health(HealthAuthState.granted, {
          localDayKey(_day(1)): 9000,
          localDayKey(_day(3)): 4000,
        });
        final store = _store(health: health);
        store.dailyActivity = {localDayKey(_day(2)): (steps: 7000, kcal: 0)};

        await store.backfillStepsForTrends(7);

        expect(
          [for (final day in health.reads) localDayKey(day)],
          [
            for (final n in [1, 3, 4, 5, 6]) localDayKey(_day(n)),
          ],
          reason: 'today and the known day are not read',
        );
        expect(store.stepsForFoodDate(_day(1)), 9000);
        expect(store.stepsForFoodDate(_day(2)), 7000);
        expect(store.stepsForFoodDate(_day(3)), 4000);

        // A second pass in the same session reads nothing again.
        health.reads.clear();
        await store.backfillStepsForTrends(7);
        expect(health.reads, isEmpty);
      });
    });

    test('ohne nutzbare Health-Verbindung wird nichts gelesen', () async {
      await withClock(Clock.fixed(_now), () async {
        for (final state in [
          HealthAuthState.denied,
          HealthAuthState.unsupported,
          HealthAuthState.unknown,
        ]) {
          final health = _Health(state, {localDayKey(_day(1)): 9000});
          await _store(health: health).backfillStepsForTrends(30);
          expect(health.reads, isEmpty, reason: '$state');
        }
      });
    });
  });
}
