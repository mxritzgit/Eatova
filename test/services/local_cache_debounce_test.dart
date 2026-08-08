import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/favorite_meal.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/weight_log.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/sync_outbox.dart';

// G9b: `jsonEncode + AES-GCM + base64` kostet laut Review 91,5 ms bei 210
// Mahlzeiten (Desktop-JIT; mobiles AOT 2-4x langsamer) — und laeuft synchron
// im Tap-Handler. Eine Fuenfer-Serie (Mahlzeit hinzufuegen, korrigieren,
// loeschen, ...) verschluesselte den GANZEN Blob bisher fuenfmal.
//
// Diese Tests messen die Schreibfrequenz ueber einen zaehlenden KeyValueStore
// und sichern:
//   1. Mehrere Aufrufe innerhalb des Debounce-Fensters -> genau EIN Write.
//   2. Der letzte Stand gewinnt (kein alter Blob ueberschreibt den neuen).
//   3. flush() zwingt den ausstehenden Write sofort raus (App-Pause/Detach!).
//   4. Lesen sieht den ausstehenden Stand (kein Read-after-Write-Loch).
//   5. clear() verwirft ausstehende Writes (keine PII-Auferstehung).

MealAnalysisResult _result() => const MealAnalysisResult(
      mealName: 'Bowl',
      caloriesKcal: 300,
      estimatedGrams: 350,
      kcalPer100G: 85.7,
      protein: '30 g',
      carbs: '40 g',
      fat: '10 g',
      confidence: 'Hoch',
      portionNotes: 'Testportion.',
      sourceLabel: 'Foto-KI',
    );

LoggedMeal _meal(String id) => LoggedMeal(
      id: id,
      result: _result(),
      loggedAt: DateTime(2026, 8, 5, 12, 30),
      forcedSlot: MealSlot.lunch,
      localDay: '2026-08-05',
    );

/// Zaehlt setString pro Slot — der Stellvertreter fuer "einmal den ganzen
/// Blob verschluesseln".
class _ZaehlenderStore implements KeyValueStore {
  final Map<String, String> _data = {};
  final Map<String, int> _writes = {};

  int writesFuer(String key) => _writes[key] ?? 0;
  Map<String, String> get snapshot => Map.unmodifiable(_data);

  @override
  Future<String?> getString(String key) async => _data[key];

  @override
  Future<void> setString(String key, String value) async {
    _writes[key] = (_writes[key] ?? 0) + 1;
    _data[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    _data.remove(key);
  }
}

const _mealsKey = 'eatova.v1.logged_meals.user-1';

void main() {
  group('LocalCache entprellte Blob-Writes (G9b)', () {
    test('fuenf schnelle Tagebuch-Writes ergeben genau EINEN Write', () async {
      final store = _ZaehlenderStore();
      final cache = LocalCache(store, 'user-1');

      for (var i = 1; i <= 5; i++) {
        cache.writeLoggedMealsDebounced([_meal('m-$i')]);
      }
      // Waehrend des Fensters ist noch NICHTS verschluesselt worden.
      expect(store.writesFuer(_mealsKey), 0);
      expect(cache.hasPendingWrites, isTrue);

      await cache.flush();

      expect(store.writesFuer(_mealsKey), 1,
          reason: 'eine Fuenfer-Serie darf den Blob nur einmal verschluesseln');
      expect(cache.hasPendingWrites, isFalse);
    });

    test('flush() schreibt den LETZTEN Stand raus', () async {
      final store = _ZaehlenderStore();
      final cache = LocalCache(store, 'user-1');

      cache.writeLoggedMealsDebounced([_meal('m-1')]);
      cache.writeLoggedMealsDebounced([_meal('m-1'), _meal('m-2')]);
      cache.writeLoggedMealsDebounced([_meal('m-9')]);

      await cache.flush();

      final back = await cache.readLoggedMeals();
      expect(back, hasLength(1));
      expect(back!.single.id, 'm-9');
      expect(store.writesFuer(_mealsKey), 1);
    });

    test('ohne flush() feuert der Timer nach writeDebounce von selbst',
        () async {
      final store = _ZaehlenderStore();
      final cache = LocalCache(store, 'user-1');

      cache.writeLoggedMealsDebounced([_meal('m-1')]);
      cache.writeLoggedMealsDebounced([_meal('m-2')]);
      await Future<void>.delayed(
          LocalCache.writeDebounce + const Duration(milliseconds: 200));

      expect(store.writesFuer(_mealsKey), 1);
      expect((await cache.readLoggedMeals())!.single.id, 'm-2');
    });

    test('Lesen sieht den ausstehenden Stand vor dem Write', () async {
      final store = _ZaehlenderStore();
      final cache = LocalCache(store, 'user-1');

      cache.writeLoggedMealsDebounced([_meal('m-7')]);

      // Noch nichts auf der Platte …
      expect(store.snapshot.containsKey(_mealsKey), isFalse);
      // … der Cache liefert den ausstehenden Stand trotzdem.
      final back = await cache.readLoggedMeals();
      expect(back, hasLength(1));
      expect(back!.single.id, 'm-7');

      await cache.flush();
    });

    test('Favoriten und Gewichts-Log werden ebenfalls entprellt', () async {
      final store = _ZaehlenderStore();
      final cache = LocalCache(store, 'user-1');

      for (var i = 0; i < 4; i++) {
        cache.writeFavoritesDebounced([
          FavoriteMeal(
              id: 'name:bowl-$i',
              result: _result(),
              addedAt: DateTime(2026, 8, 5)),
        ]);
        cache.writeWeightLogDebounced(WeightLog(entries: [
          WeightLogEntry(
              timestamp: DateTime(2026, 8, 5, 7), weightKg: 81.0 + i),
        ]));
      }

      await cache.flush();

      expect(store.writesFuer('eatova.v1.favorites.user-1'), 1);
      expect(store.writesFuer('eatova.v1.weight_log.user-1'), 1);
      expect((await cache.readFavorites())!.single.id, 'name:bowl-3');
      expect((await cache.readWeightLog())!.latest!.weightKg, 84.0);
    });

    test('Outbox und Stats-Deltas bleiben SOFORT (Kill-Sicherheit, DATA-7)',
        () async {
      final store = _ZaehlenderStore();
      final cache = LocalCache(store, 'user-1');

      await cache.writeOutbox([SyncOp.mealDelete('m-1')]);
      await cache.writeOutbox([SyncOp.mealDelete('m-2')]);
      await cache.writePendingStatsDeltas(meals: 1, weightLogs: 0);

      // Kein flush() — die beiden Slots liegen schon roh auf der Platte.
      expect(store.writesFuer('eatova.v1.outbox.user-1'), 2);
      expect(store.snapshot.containsKey('eatova.v1.outbox.user-1'), isTrue);
      expect(
          store.snapshot.containsKey('eatova.v1.pending_stats.user-1'), isTrue);
      expect(cache.hasPendingWrites, isFalse);
    });

    test('ein sofortiger Write entwertet den ausstehenden entprellten Write',
        () async {
      final store = _ZaehlenderStore();
      final cache = LocalCache(store, 'user-1');

      cache.writeLoggedMealsDebounced([_meal('m-alt')]);
      await cache.writeLoggedMeals([_meal('m-neu')]);
      await cache.flush();

      expect(store.writesFuer(_mealsKey), 1);
      expect((await cache.readLoggedMeals())!.single.id, 'm-neu',
          reason: 'der alte Blob darf den frischeren nicht ueberschreiben');
    });

    test('clear() verwirft ausstehende Writes (keine PII-Auferstehung)',
        () async {
      final store = _ZaehlenderStore();
      final cache = LocalCache(store, 'user-1');

      cache.writeLoggedMealsDebounced([_meal('m-privat')]);
      await cache.clear();

      // Timer haette laengst gefeuert — es darf nichts nachkommen.
      await Future<void>.delayed(
          LocalCache.writeDebounce + const Duration(milliseconds: 200));

      expect(store.writesFuer(_mealsKey), 0);
      expect(store.snapshot, isEmpty);
      expect(await cache.readLoggedMeals(), isNull);
    });

    test('clear(preserveOutbox: true) verwirft die Spiegel-Writes ebenfalls',
        () async {
      final store = _ZaehlenderStore();
      final cache = LocalCache(store, 'user-1');

      await cache.writeOutbox([SyncOp.mealInsert(_meal('m-2'), trackDay: true)]);
      cache.writeLoggedMealsDebounced([_meal('m-privat')]);

      await cache.clear(preserveOutbox: true);
      await Future<void>.delayed(
          LocalCache.writeDebounce + const Duration(milliseconds: 200));

      expect(store.writesFuer(_mealsKey), 0);
      expect(store.snapshot.keys.toSet(), {'eatova.v1.outbox.user-1'});
      expect((await cache.readOutbox())!.single.entityId, 'm-2');
    });
  });
}
