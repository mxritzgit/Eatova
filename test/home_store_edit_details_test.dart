import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/local_day.dart';
import 'package:eatova/src/services/notification_service.dart';

// Bearbeiten-Sheet (2026-08-06): updateLoggedMealDetails aendert Portion,
// Slot und/oder Tag einer geloggten Mahlzeit in EINEM Update. Diese Tests
// sichern die reine Store-Logik (ohne Sync):
//   * Slot-Wechsel setzt forcedSlot, laesst Zeitpunkt + Tagessumme stehen.
//   * Tag-Verschiebung erhaelt die lokale Wanduhr-Zeit, setzt localDay und
//     zieht die Tageszaehler BEIDER Tage konsistent nach.
//   * Streak-Entscheidung: Verschieben AUF heute trackt heute (idempotent),
//     Verschieben auf vergangene Tage ist ein Nachtrag (Streak unberuehrt).
//   * Undo (Snackbar-Aktion) stellt den vorherigen Stand vollstaendig her.

class _SnackCapture {
  final List<String> messages = <String>[];
  final List<SnackBarAction?> actions = <SnackBarAction?>[];

  void call(
    String message, {
    IconData icon = Icons.info_outline,
    Color accent = Colors.white,
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

    // Heute ist geraeumt, gestern gefuellt — inkl. der Store-Felder fuer heute.
    expect(s.store.consumedKcalForFoodDate(DateTime.now()), 0);
    expect(s.store.consumedKcalForFoodDate(_yesterday), 300);
    expect(s.store.dailyConsumedKcal, 0);
    expect(s.store.macroProgress.proteinG, 0);
    expect(s.store.mealsForFoodDate(_yesterday).single.id, id);
    expect(s.snacks.messages.last, 'Mahlzeit auf gestern verschoben.');
  });

  test('Verschieben AUF heute markiert heute als getrackt — idempotent', () {
    final s = _setup();
    // Nachtrag fuer gestern zaehlt beim Loggen nicht fuer die Streak.
    final id = s.store.addResultToDailyTotal(_meal('Nachtrag'),
        foodDate: _yesterday);
    expect(s.store.lifetimeStats.currentStreak, 0);

    s.store.updateLoggedMealDetails(id, day: DateTime.now());

    expect(s.store.lifetimeStats.currentStreak, 1);
    expect(s.store.lifetimeStats.lastTrackedDate, _today);

    // Zweite Verschiebung auf heute zaehlt den Tag nicht doppelt.
    final id2 = s.store.addResultToDailyTotal(_meal('Nachtrag 2'),
        foodDate: _yesterday);
    s.store.updateLoggedMealDetails(id2, day: DateTime.now());
    expect(s.store.lifetimeStats.currentStreak, 1);
  });

  test(
      'Verschieben auf einen VERGANGENEN Tag ist ein Nachtrag — Streak und '
      'lastTrackedDate bleiben stehen', () {
    final s = _setup();
    final id = s.store.addResultToDailyTotal(_meal('Bowl')); // heute -> 1
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

  // B5: _moveDayLabel rechnete den Abstand zum Zieltag mit
  // `today.difference(target).inDays` — Absolutzeit. Ueber die
  // Fruehjahrsumstellung (Europe/Berlin, Sonntag 29.03.2026, 23 Stunden)
  // misst das 23h und meldet 0 Tage: die Bestaetigung behauptete „auf heute
  // verschoben", waehrend die Mahlzeit auf gestern liegt.
  //
  // Der Test nagelt die Uhr per withClock fest (der Store liest sie ueber
  // clock.now()). Auf einer UTC-Maschine gibt es den 23-Stunden-Tag nicht, dort
  // war der Altcode zufaellig richtig — die Assertions sind aber in JEDER Zone
  // die korrekte Erwartung und halten die Regression fest.
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
