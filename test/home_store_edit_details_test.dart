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

// Edit sheet (2026-08-06): updateLoggedMealDetails changes portion, slot and/or
// day of a logged meal in ONE update. These tests cover the pure store logic
// (no sync): a slot change sets forcedSlot and keeps time and day total; a day
// move keeps the local wall-clock time and updates BOTH days; moving ONTO today
// tracks today idempotently while moving into the past leaves the streak alone;
// undo restores the previous state.

class _SnackCapture {
  final List<String> messages = <String>[];
  final List<SnackBarAction?> actions = <SnackBarAction?>[];

  void call(
    String message, {
    IconData icon = Icons.info_outline,
    SnackTone tone = SnackTone.positive,
    Duration? duration,
    SnackBarAction? action,
  }) {
    messages.add(message);
    actions.add(action);
  }
}

({HomeStore store, _SnackCapture snacks}) _setup() {
  final snacks = _SnackCapture();
  final store = HomeStore(
    sync: null,
    health: const NoopHealthService(),
    notificationService: const NoopNotificationService(),
    initialUserName: 'Test',
    emitSnack: snacks.call,
  );
  addTearDown(store.dispose);
  return (store: store, snacks: snacks);
}

MealAnalysisResult _meal(String name) => MealAnalysisResult(
      mealName: name,
      caloriesKcal: 300,
      estimatedGrams: 300,
      kcalPer100G: 100,
      protein: '30 g',
      carbs: '40 g',
      fat: '10 g',
      confidence: 'Mittel',
      portionNotes: 'Test.',
      sourceLabel: 'Foto-KI',
    );

DateTime get _today => DateUtils.dateOnly(DateTime.now());
DateTime get _yesterday => _today.subtract(const Duration(days: 1));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Slot aendern setzt forcedSlot, Zeitpunkt und Tagessumme bleiben', () {
    final s = _setup();
    final id = s.store.addResultToDailyTotal(_meal('Bowl'));
    final before = s.store.loggedMeals.single;

    final updated = s.store.updateLoggedMealDetails(id, slot: MealSlot.snack);

    expect(updated, isNotNull);
    expect(updated!.forcedSlot, MealSlot.snack);
    expect(updated.slot, MealSlot.snack);
    expect(updated.loggedAt, before.loggedAt);
    expect(s.store.loggedMeals.single.slot, MealSlot.snack);
    expect(s.store.dailyConsumedKcal, 300);
    expect(s.snacks.messages.last, 'Mahlzeit aktualisiert.');
  });

  test(
      'Tag verschieben: Wanduhr-Zeit bleibt, localDay wird kanonisch, '
      'Tageszaehler/Makros BEIDER Tage konsistent', () {
    final s = _setup();
    final id = s.store.addResultToDailyTotal(_meal('Bowl'));
    final before = s.store.loggedMeals.single;

    final updated = s.store.updateLoggedMealDetails(id, day: _yesterday);

    expect(updated, isNotNull);
    expect(updated!.localDay, localDayKey(_yesterday));
    expect(DateUtils.isSameDay(updated.loggedAt, _yesterday), isTrue);
    expect(updated.loggedAt.hour, before.loggedAt.hour);
    expect(updated.loggedAt.minute, before.loggedAt.minute);

    // Today is cleared, yesterday filled, including the store fields for today.
    expect(s.store.consumedKcalForFoodDate(DateTime.now()), 0);
    expect(s.store.consumedKcalForFoodDate(_yesterday), 300);
    expect(s.store.dailyConsumedKcal, 0);
    expect(s.store.macroProgress.proteinG, 0);
    expect(s.store.mealsForFoodDate(_yesterday).single.id, id);
    expect(s.snacks.messages.last, 'Mahlzeit auf gestern verschoben.');
  });

  test('Verschieben AUF heute markiert heute als getrackt — idempotent', () {
    final s = _setup();
    // A late entry for yesterday does not count towards the streak.
    final id = s.store.addResultToDailyTotal(_meal('Nachtrag'),
        foodDate: _yesterday);
    expect(s.store.lifetimeStats.currentStreak, 0);

    s.store.updateLoggedMealDetails(id, day: DateTime.now());

    expect(s.store.lifetimeStats.currentStreak, 1);
    expect(s.store.lifetimeStats.lastTrackedDate, _today);

    // A second move onto today does not count the day twice.
    final id2 = s.store.addResultToDailyTotal(_meal('Nachtrag 2'),
        foodDate: _yesterday);
    s.store.updateLoggedMealDetails(id2, day: DateTime.now());
    expect(s.store.lifetimeStats.currentStreak, 1);
  });

  test(
      'Verschieben auf einen VERGANGENEN Tag ist ein Nachtrag — Streak und '
      'lastTrackedDate bleiben stehen', () {
    final s = _setup();
    final id = s.store.addResultToDailyTotal(_meal('Bowl')); // today -> 1
    expect(s.store.lifetimeStats.currentStreak, 1);

    s.store.updateLoggedMealDetails(id, day: _yesterday);

    expect(s.store.lifetimeStats.currentStreak, 1);
    expect(s.store.lifetimeStats.lastTrackedDate, _today);
  });

  test('Portion aendern (result) zieht die Tagessumme nach', () {
    final s = _setup();
    final id = s.store.addResultToDailyTotal(_meal('Bowl'));
    final scaled = s.store.loggedMeals.single.result.adjustedToGrams(150);

    s.store.updateLoggedMealDetails(id, result: scaled);

    expect(s.store.dailyConsumedKcal, 150);
    expect(s.store.loggedMeals.single.result.estimatedGrams, 150);
  });

  test('Undo (Rückgängig) stellt Slot, Tag und Tagessumme wieder her', () {
    final s = _setup();
    final id = s.store.addResultToDailyTotal(_meal('Bowl'));
    final before = s.store.loggedMeals.single;

    s.store.updateLoggedMealDetails(id, slot: MealSlot.snack, day: _yesterday);
    expect(s.store.dailyConsumedKcal, 0);

    final action = s.snacks.actions.last;
    expect(action, isNotNull);
    expect(action!.label, 'Rückgängig');
    action.onPressed();

    final restored = s.store.loggedMeals.single;
    expect(restored.forcedSlot, before.forcedSlot);
    expect(restored.loggedAt, before.loggedAt);
    expect(restored.effectiveLocalDay, before.effectiveLocalDay);
    expect(s.store.dailyConsumedKcal, 300);
    expect(s.store.consumedKcalForFoodDate(_yesterday), 0);
  });

  test('Keine Aenderung uebergeben -> No-op ohne Snack', () {
    final s = _setup();
    final id = s.store.addResultToDailyTotal(_meal('Bowl'));
    final countBefore = s.snacks.messages.length;

    final result = s.store.updateLoggedMealDetails(id);

    expect(result, same(s.store.loggedMeals.single));
    expect(s.snacks.messages.length, countBefore);
  });

  test('Unbekannte id -> null, nichts passiert', () {
    final s = _setup();
    s.store.addResultToDailyTotal(_meal('Bowl'));

    expect(s.store.updateLoggedMealDetails('gibt-es-nicht',
        slot: MealSlot.snack), isNull);
    expect(s.store.dailyConsumedKcal, 300);
  });

  // B5: _moveDayLabel measured the distance in absolute time, so across the
  // spring DST switch a 23-hour day read as 0 days and the confirmation claimed
  // "moved to today" for a meal on yesterday. The clock is pinned via withClock;
  // a UTC machine has no 23-hour day, but the assertions hold in every zone.
  group('B5 — Verschiebe-Label ueber die Fruehjahrsumstellung 29.03.2026', () {
    test('vom 30.03. auf den 29.03. meldet „gestern", nicht „heute"', () {
      withClock(Clock.fixed(DateTime(2026, 3, 30, 10)), () {
        final s = _setup();
        final id = s.store.addResultToDailyTotal(_meal('Bowl'));

        s.store.updateLoggedMealDetails(id, day: DateTime(2026, 3, 29));

        expect(s.snacks.messages.last, 'Mahlzeit auf gestern verschoben.');
      });
    });

    test('vom 30.03. auf den 28.03. meldet das Datum, nicht „gestern"', () {
      withClock(Clock.fixed(DateTime(2026, 3, 30, 10)), () {
        final s = _setup();
        final id = s.store.addResultToDailyTotal(_meal('Bowl'));

        s.store.updateLoggedMealDetails(id, day: DateTime(2026, 3, 28));

        expect(s.snacks.messages.last, 'Mahlzeit auf den 28.3. verschoben.');
      });
    });

    test('auf den laufenden Tag selbst meldet weiterhin „heute"', () {
      withClock(Clock.fixed(DateTime(2026, 3, 30, 10)), () {
        final s = _setup();
        final id = s.store.addResultToDailyTotal(_meal('Bowl'),
            foodDate: DateTime(2026, 3, 28));

        s.store.updateLoggedMealDetails(id, day: DateTime(2026, 3, 30));

        expect(s.snacks.messages.last, 'Mahlzeit auf heute verschoben.');
      });
    });
  });
}
