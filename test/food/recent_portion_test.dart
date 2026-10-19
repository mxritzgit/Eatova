import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';

// FOOD-7 (2026-10-19): re-portioning a logged meal left its auto-recent at
// the old portion, so the next add from "recent" brought the stale amount
// back. The recent now takes the last used portion; key, place and cap stay,
// a pinned favorite keeps its own portion, and undo hands the old one back.

class _Snacks {
  final List<SnackBarAction?> actions = <SnackBarAction?>[];

  void call(
    String message, {
    IconData icon = Icons.info_outline,
    SnackTone tone = SnackTone.positive,
    Duration? duration,
    SnackBarAction? action,
  }) => actions.add(action);
}

MealAnalysisResult _oats({int grams = 60}) => MealAnalysisResult(
  mealName: 'Haferflocken',
  caloriesKcal: (grams * 3.7).round(),
  estimatedGrams: grams,
  kcalPer100G: 370,
  protein: '${(grams * 0.13).round()} g',
  carbs: '${(grams * 0.6).round()} g',
  fat: '${(grams * 0.07).round()} g',
  confidence: 'Hoch',
  portionNotes: '',
  barcode: '4000000000017',
);

MealAnalysisResult _other(String name) => MealAnalysisResult(
  mealName: name,
  caloriesKcal: 200,
  estimatedGrams: 100,
  kcalPer100G: 200,
  protein: '5 g',
  carbs: '20 g',
  fat: '5 g',
  confidence: 'Mittel',
  portionNotes: '',
);

HomeStore _store(_Snacks snacks) {
  final store = HomeStore(
    sync: null,
    health: const NoopHealthService(),
    notificationService: const NoopNotificationService(),
    initialUserName: 'Test',
    emitSnack: snacks.call,
  );
  addTearDown(store.dispose);
  return store;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime(2026, 10, 19, 8);

  test('die neue Portion wird die des Recents, Schluessel und Platz bleiben', () {
    return withClock(Clock.fixed(now), () async {
      final snacks = _Snacks();
      final store = _store(snacks);
      final id = await store.addResultToDailyTotal(_oats());
      await store.addResultToDailyTotal(_other('Apfel'));
      final before = [for (final f in store.favorites) f.id];
      final key = store.favorites.firstWhere((f) => f.id != 'name:apfel');

      await store.updateLoggedMealDetails(id, result: _oats(grams: 90));

      expect([for (final f in store.favorites) f.id], before);
      final recent = store.favorites.firstWhere((f) => f.id == key.id);
      expect(recent.result.estimatedGrams, 90);
      expect(recent.result.caloriesKcal, 333);
      expect(recent.pinned, isFalse);
      expect(recent.addedAt, key.addedAt);

      // Undo hands the old portion back.
      snacks.actions.last!.onPressed();
      await pumpEventQueue();
      final undone = store.favorites.firstWhere((f) => f.id == key.id);
      expect(undone.result.estimatedGrams, 60);
      expect(
        store.loggedMeals.firstWhere((m) => m.id == id).result.estimatedGrams,
        60,
      );
    });
  });

  test('ein angehefteter Favorit behaelt seine Portion', () {
    return withClock(Clock.fixed(now), () async {
      final store = _store(_Snacks());
      final id = await store.addResultToDailyTotal(_oats());
      await store.toggleFavorite(_oats());
      expect(store.favorites.single.pinned, isTrue);

      await store.updateLoggedMealDetails(id, result: _oats(grams: 120));

      expect(store.favorites.single.result.estimatedGrams, 60);
    });
  });

  test('ein vergessenes Recent kommt nicht zurueck', () {
    return withClock(Clock.fixed(now), () async {
      final store = _store(_Snacks());
      final id = await store.addResultToDailyTotal(_oats());
      await store.removeFavorite(store.favorites.single.id);
      expect(store.favorites, isEmpty);

      await store.updateLoggedMealDetails(id, result: _oats(grams: 120));

      expect(store.favorites, isEmpty);
    });
  });

  test('nur Slot oder Tag zu aendern laesst das Recent in Ruhe', () {
    return withClock(Clock.fixed(now), () async {
      final store = _store(_Snacks());
      final id = await store.addResultToDailyTotal(_oats());
      final recent = store.favorites.single;

      await store.updateLoggedMealDetails(id, slot: MealSlot.snack);

      expect(identical(store.favorites.single, recent), isTrue);
    });
  });
}
