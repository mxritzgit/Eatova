import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/weight_log.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/sync_outbox.dart';

import 'sync_test_helpers.dart';

// G9b: `jsonEncode + AES-GCM + base64` costs ~91.5 ms at 210 meals (desktop
// JIT, mobile AOT 2-4x slower) and runs synchronously in the tap handler. A
// burst of five actions used to encrypt the whole blob five times.
//
// These tests count writes through a counting KeyValueStore: several calls
// inside the debounce window produce exactly one write, the last state wins,
// flush() forces the pending write out, reads see the pending state, and
// clear() discards pending writes (no PII resurrection).
//
// The four mirror slots share one mechanism, so they run as one parametrised
// block — one named case per slot, so a slot that forgets the debounce still
// names itself in the failure.

const _mealsKey = 'eatova.v1.logged_meals.user-1';
const _favoritesKey = 'eatova.v1.favorites.user-1';
const _weightKey = 'eatova.v1.weight_log.user-1';
const _recipesKey = 'eatova.v1.user_recipes.user-1';

/// One debounced mirror slot: how the i-th state is written, how it is read
/// back and which marker identifies it.
class _Slot {
  const _Slot({
    required this.name,
    required this.key,
    required this.schreibe,
    required this.lies,
    required this.marke,
  });

  final String name;
  final String key;
  final void Function(LocalCache cache, int i) schreibe;
  final Future<Object?> Function(LocalCache cache) lies;
  final String Function(int i) marke;
}

final _slots = <_Slot>[
  _Slot(
    name: 'Tagebuch',
    key: _mealsKey,
    schreibe: (cache, i) => cache.writeLoggedMealsDebounced([testMeal('m-$i')]),
    lies: (cache) async => (await cache.readLoggedMeals())?.single.id,
    marke: (i) => 'm-$i',
  ),
  _Slot(
    name: 'Favoriten',
    key: _favoritesKey,
    schreibe: (cache, i) =>
        cache.writeFavoritesDebounced([testFavorite('name:bowl-$i')]),
    lies: (cache) async => (await cache.readFavorites())?.single.id,
    marke: (i) => 'name:bowl-$i',
  ),
  _Slot(
    name: 'Gewichts-Log',
    key: _weightKey,
    schreibe: (cache, i) => cache.writeWeightLogDebounced(WeightLog(entries: [
      WeightLogEntry(timestamp: DateTime(2026, 8, 5, 7), weightKg: 80.0 + i),
    ])),
    lies: (cache) async =>
        (await cache.readWeightLog())?.latest?.weightKg.toString(),
    marke: (i) => (80.0 + i).toString(),
  ),
  _Slot(
    name: 'Eigen-Rezepte',
    key: _recipesKey,
    schreibe: (cache, i) => cache.writeUserRecipesDebounced([
      testRecipe('user_$i', ingredients: 'Reis', preparation: 'Kochen.'),
    ]),
    lies: (cache) async => (await cache.readUserRecipes())?.single.slug,
    marke: (i) => 'user_$i',
  ),
];

void main() {
  group('LocalCache entprellte Blob-Writes (G9b)', () {
    for (final slot in _slots) {
      test('${slot.name}: fuenf schnelle Writes ergeben genau EINEN Write mit '
          'dem LETZTEN Stand', () async {
        final store = CountingKeyValueStore();
        final cache = LocalCache(store, 'user-1');

        for (var i = 1; i <= 5; i++) {
          slot.schreibe(cache, i);
        }
        // Nothing has been encrypted yet inside the window.
        expect(store.writesFuer(slot.key), 0);
        expect(cache.hasPendingWrites, isTrue);

        await cache.flush();

        expect(store.writesFuer(slot.key), 1,
            reason:
                'eine Fuenfer-Serie darf den Blob nur einmal verschluesseln');
        expect(await slot.lies(cache), slot.marke(5),
            reason: 'der letzte Stand gewinnt');
        expect(cache.hasPendingWrites, isFalse);
      });

      test('${slot.name}: Lesen sieht den ausstehenden Stand vor dem Write',
          () async {
        final store = CountingKeyValueStore();
        final cache = LocalCache(store, 'user-1');

        slot.schreibe(cache, 7);

        // Nothing on disk yet …
        expect(store.snapshot.containsKey(slot.key), isFalse);
        // … the cache still returns the pending state (no read-after-write
        // hole for the boot hydration).
        expect(await slot.lies(cache), slot.marke(7));

        await cache.flush();
      });

      test('${slot.name}: clear() verwirft den ausstehenden Write (keine '
          'PII-Auferstehung)', () async {
        final store = CountingKeyValueStore();
        final cache = LocalCache(store, 'user-1');

        slot.schreibe(cache, 1);
        await cache.clear();
        // The timer would long have fired — nothing may follow.
        await Future<void>.delayed(
            LocalCache.writeDebounce + const Duration(milliseconds: 200));

        expect(store.writesFuer(slot.key), 0,
            reason: 'ein laufender Timer darf den geraeumten Stand nicht '
                'zurueckschreiben');
        expect(store.snapshot, isEmpty);
        expect(await slot.lies(cache), isNull);
      });
    }

    test('ohne flush() feuert der Timer nach writeDebounce von selbst',
        () async {
      final store = CountingKeyValueStore();
      final cache = LocalCache(store, 'user-1');

      cache.writeLoggedMealsDebounced([testMeal('m-1')]);
      cache.writeLoggedMealsDebounced([testMeal('m-2')]);
      await Future<void>.delayed(
          LocalCache.writeDebounce + const Duration(milliseconds: 200));

      expect(store.writesFuer(_mealsKey), 1);
      expect((await cache.readLoggedMeals())!.single.id, 'm-2');
    });

    test(
        'das Fenster laeuft ab dem ERSTEN Aufruf — eine laufende Serie kann '
        'den Write nicht vor sich herschieben', () async {
      // The case above fires both writes back to back, so cancel+restart on
      // every call would still land inside its 600 ms window and it stays
      // green. The invariant the debounce actually promises (see
      // `writeDebounce`) is the one below: a series with gaps SHORTER than
      // the window must not postpone the write indefinitely, or a tapping
      // user's diary never reaches disk and an app kill in that stretch takes
      // the whole series with it.
      final store = CountingKeyValueStore();
      final cache = LocalCache(store, 'user-1');

      for (var i = 1; i <= 4; i++) {
        cache.writeLoggedMealsDebounced([testMeal('s-$i')]);
        await Future<void>.delayed(LocalCache.writeDebounce ~/ 2);
      }

      expect(store.writesFuer(_mealsKey), greaterThanOrEqualTo(1),
          reason: 'Nach vier Aufrufen ueber rund die doppelte Fensterlaenge '
              'muss mindestens ein Write auf Platte sein.');
      await cache.flush();
      expect((await cache.readLoggedMeals())!.single.id, 's-4');
    });

    test('Outbox und Stats-Deltas bleiben SOFORT (Kill-Sicherheit, DATA-7)',
        () async {
      final store = CountingKeyValueStore();
      final cache = LocalCache(store, 'user-1');

      await cache.writeOutbox([SyncOp.mealDelete('m-1')]);
      await cache.writeOutbox([SyncOp.mealDelete('m-2')]);
      await cache.writePendingStatsDeltas(meals: 1, weightLogs: 0);

      // No flush() — both slots are already on disk.
      expect(store.writesFuer('eatova.v1.outbox.user-1'), 2);
      expect(store.snapshot.containsKey('eatova.v1.outbox.user-1'), isTrue);
      expect(
          store.snapshot.containsKey('eatova.v1.pending_stats.user-1'), isTrue);
      expect(cache.hasPendingWrites, isFalse);
    });

    test('ein sofortiger Write entwertet den ausstehenden entprellten Write',
        () async {
      final store = CountingKeyValueStore();
      final cache = LocalCache(store, 'user-1');

      cache.writeLoggedMealsDebounced([testMeal('m-alt')]);
      await cache.writeLoggedMeals([testMeal('m-neu')]);
      await cache.flush();

      expect(store.writesFuer(_mealsKey), 1);
      expect((await cache.readLoggedMeals())!.single.id, 'm-neu',
          reason: 'der alte Blob darf den frischeren nicht ueberschreiben');
    });

    test('clear(preserveOutbox: true) verwirft die Spiegel-Writes ebenfalls',
        () async {
      final store = CountingKeyValueStore();
      final cache = LocalCache(store, 'user-1');

      await cache
          .writeOutbox([SyncOp.mealInsert(testMeal('m-2'), trackDay: true)]);
      cache.writeLoggedMealsDebounced([testMeal('m-privat')]);

      await cache.clear(preserveOutbox: true);
      await Future<void>.delayed(
          LocalCache.writeDebounce + const Duration(milliseconds: 200));

      expect(store.writesFuer(_mealsKey), 0);
      expect(store.snapshot.keys.toSet(), {'eatova.v1.outbox.user-1'});
      expect((await cache.readOutbox())!.single.entityId, 'm-2');
    });
  });
}
