import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/lifetime_stats.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/models/weight_log.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/sync_outbox.dart';

import 'sync_test_helpers.dart';

// DATA-7: the LocalCache also mirrors the diary, favorites, weight log, the
// write outbox and the pending lifetime-stats deltas, so a cold start without
// network does not show an empty diary and no write is lost to an app kill.
// These tests pin the roundtrips, the defensive handling of corrupt slots and
// that clear() wipes ALL new (PII) slots.

// Meal, result, recipe and favorite fixtures live in sync_test_helpers.dart.

LocalCache _cache(InMemoryKeyValueStore store, [String userId = 'user-1']) =>
    LocalCache(store, userId);

void main() {
  group('LocalCache Tagebuch/Favoriten/Gewicht', () {
    test('loggedMeals roundtrippen verlustfrei (Slot, localDay, Result)',
        () async {
      final cache = _cache(InMemoryKeyValueStore());
      await cache.writeLoggedMeals([testMeal('m-1'), testMeal('m-2')]);

      final back = await cache.readLoggedMeals();
      expect(back, hasLength(2));
      expect(back![0].id, 'm-1');
      expect(back[0].forcedSlot, MealSlot.lunch);
      expect(back[0].localDay, '2026-08-05');
      expect(back[0].loggedAt, DateTime(2026, 8, 5, 12, 30));
      expect(back[0].result.caloriesKcal, 300);
      expect(back[0].result.mealName, 'Bowl');
    });

    test('favorites roundtrippen inkl. pinned', () async {
      final cache = _cache(InMemoryKeyValueStore());
      await cache.writeFavorites([testFavorite('name:bowl', pinned: true)]);

      final back = await cache.readFavorites();
      expect(back, hasLength(1));
      expect(back!.single.id, 'name:bowl');
      expect(back.single.pinned, isTrue);
      expect(back.single.addedAt, DateTime(2026, 8, 5, 13));
    });

    test('weightLog roundtrippt in Reihenfolge', () async {
      final cache = _cache(InMemoryKeyValueStore());
      final log = WeightLog(entries: [
        WeightLogEntry(timestamp: DateTime(2026, 8, 1, 7), weightKg: 82.0),
        WeightLogEntry(timestamp: DateTime(2026, 8, 5, 7), weightKg: 81.4),
      ]);
      await cache.writeWeightLog(log);

      final back = await cache.readWeightLog();
      expect(back, isNotNull);
      expect(back!.entries, hasLength(2));
      expect(back.latest!.weightKg, 81.4);
      expect(back.entries.first.timestamp, DateTime(2026, 8, 1, 7));
    });

    test('leerer Cache -> ueberall null', () async {
      final cache = _cache(InMemoryKeyValueStore());
      expect(await cache.readLoggedMeals(), isNull);
      expect(await cache.readFavorites(), isNull);
      expect(await cache.readWeightLog(), isNull);
      expect(await cache.readOutbox(), isNull);
      expect(await cache.readPendingStatsDeltas(), isNull);
      expect(await cache.readUserRecipes(), isNull);
    });

    test('korrupter Eintrag -> null statt Crash', () async {
      final store = InMemoryKeyValueStore({
        'eatova.v1.logged_meals.user-1': '{ kein json',
        'eatova.v1.weight_log.user-1': '{"items":[{"t":"quatsch"}]}',
        // A recipe row without a slug: FitnessRecipe.fromRow throws on purpose
        // (the slug is the upsert conflict key and must never be invented),
        // so the whole slot drops out.
        'eatova.v1.user_recipes.user-1': '{"items":[{"title":"Ohne Slug"}]}',
      });
      final cache = _cache(store);
      expect(await cache.readLoggedMeals(), isNull);
      expect(await cache.readWeightLog(), isNull);
      expect(await cache.readUserRecipes(), isNull);
    });
  });

  // Gap A: own recipes were the only user collection without a cache slot,
  // their only safety net was the outbox. A cold start without network
  // therefore never showed them, not even long-synced ones.
  group('LocalCache Eigen-Rezepte (Luecke A)', () {
    test('roundtrippen verlustfrei inkl. Kategorien und Makros', () async {
      final cache = _cache(InMemoryKeyValueStore());
      await cache.writeUserRecipes([
        testRecipe('user_1717500000000', title: 'Eigene Protein-Bowl'),
        testRecipe('user_1717500000001'),
      ]);

      final back = await cache.readUserRecipes();
      expect(back, hasLength(2));
      expect(back![0].slug, 'user_1717500000000');
      expect(back[0].title, 'Eigene Protein-Bowl');
      expect(back[0].ingredients, 'Reis\nHaehnchen');
      expect(back[0].caloriesKcal, 600);
      expect(back[0].proteinG, 50);
      expect(back[0].carbsG, 60);
      expect(back[0].fatG, 15);
      expect(back[0].estimatedGrams, 400);
      expect(back[0].categories, <String>['Eigene']);
      expect(back[1].slug, 'user_1717500000001');
    });

    test(
        'ein gecachtes Rezept ist von einem geladenen nicht zu unterscheiden '
        '(userCreated + Profi-Hinweis)', () async {
      // The wire format is the server row (toRow/fromRow); the table carries
      // neither field, fromRow sets them. A separate format would make a
      // recipe look different after an offline cold start than after an online
      // boot (no delete button, because the UI keys off userCreated).
      //
      // `fromRow` sets professionalHint neutrally (''), so the roundtrip
      // overwrites the fixture value regardless of what was written. Display
      // resolves the empty string into the current locale via
      // `FitnessRecipe.displayProfessionalHint`.
      final cache = _cache(InMemoryKeyValueStore());
      await cache.writeUserRecipes([testRecipe('user_1')]);

      final back = (await cache.readUserRecipes())!.single;
      expect(back.userCreated, isTrue);
      expect(back.professionalHint, '');
    });

    test('leere Liste ist NICHT dasselbe wie kein Cache', () async {
      // Matters for the boot hydration: `[]` means the user has no own
      // recipes, `null` means nothing was stored — only the latter may leave
      // the server state untouched.
      final cache = _cache(InMemoryKeyValueStore());
      await cache.writeUserRecipes(const <FitnessRecipe>[]);
      expect(await cache.readUserRecipes(), isEmpty);
    });

    test('Slot ist pro userId getrennt', () async {
      final store = InMemoryKeyValueStore();
      await _cache(store, 'user-a').writeUserRecipes([testRecipe('user_1')]);
      expect(await _cache(store, 'user-b').readUserRecipes(), isNull);
    });
  });

  group('LocalCache Outbox + Stats-Deltas', () {
    test('Outbox roundtrippt; korrupte Einzel-Ops werden uebersprungen',
        () async {
      final cache = _cache(InMemoryKeyValueStore());
      await cache.writeOutbox([
        SyncOp.mealInsert(testMeal('m-1'), trackDay: true),
        SyncOp.mealDelete('m-2'),
      ]);

      final back = await cache.readOutbox();
      expect(back, hasLength(2));
      expect(back![0].kind, SyncOpKind.mealInsert);
      expect(back[0].trackDay, isTrue);
      expect(back[0].meal!.id, 'm-1');
      expect(back[1].kind, SyncOpKind.mealDelete);

      // An unknown op kind in the middle does not take the queue down.
      final store = InMemoryKeyValueStore({
        'eatova.v1.outbox.user-1':
            '{"items":[{"kind":"zeitmaschine","entity_id":"x"},'
                '{"kind":"mealDelete","entity_id":"m-9","payload":{}}]}',
      });
      final partial = await _cache(store).readOutbox();
      expect(partial, hasLength(1));
      expect(partial!.single.entityId, 'm-9');
    });

    test('pendende Stats-Deltas roundtrippen', () async {
      final cache = _cache(InMemoryKeyValueStore());
      await cache.writePendingStatsDeltas(meals: 3, weightLogs: 1);

      final back = await cache.readPendingStatsDeltas();
      expect(back, isNotNull);
      expect(back!.meals, 3);
      expect(back.weightLogs, 1);
    });
  });

  group('LocalCache Housekeeping (DATA-7)', () {
    test('clear() raeumt auch Tagebuch, Favoriten, Gewicht, Outbox und Deltas',
        () async {
      final store = InMemoryKeyValueStore();
      final cache = _cache(store);
      await cache.writeLoggedMeals([testMeal('m-1')]);
      await cache
          .writeFavorites([testFavorite('name:bowl', addedAt: DateTime(2026, 8, 5))]);
      await cache.writeWeightLog(WeightLog(entries: [
        WeightLogEntry(timestamp: DateTime(2026, 8, 5, 7), weightKg: 81.4),
      ]));
      await cache.writeOutbox([SyncOp.mealDelete('m-2')]);
      await cache.writePendingStatsDeltas(meals: 1, weightLogs: 0);
      await cache.writeUserRecipes([testRecipe('user_1')]);

      await cache.clear();

      expect(await cache.readLoggedMeals(), isNull);
      expect(await cache.readFavorites(), isNull);
      expect(await cache.readWeightLog(), isNull);
      expect(await cache.readOutbox(), isNull);
      expect(await cache.readPendingStatsDeltas(), isNull);
      expect(await cache.readUserRecipes(), isNull);
      expect(store.snapshot, isEmpty,
          reason: 'kein PII-Rest in den SharedPreferences');
    });

    test('clear(preserveOutbox: true) haelt genau Outbox + Stats-Deltas',
        () async {
      // A2: logging out must not destroy unsynced meals. The two sync slots
      // survive logout and replay on the next login of the SAME user;
      // everything else (PII mirror) must go.
      final store = InMemoryKeyValueStore();
      final cache = _cache(store);
      await cache.writeProfile(const UserProfile(weightKg: 90));
      await cache.writeLifetimeStats(LifetimeStats(mealsLogged: 3));
      await cache.writeNotificationsEnabled(true);
      await cache.writeLoggedMeals([testMeal('m-1')]);
      await cache
          .writeFavorites([testFavorite('name:bowl', addedAt: DateTime(2026, 8, 5))]);
      await cache.writeWeightLog(WeightLog(entries: [
        WeightLogEntry(timestamp: DateTime(2026, 8, 5, 7), weightKg: 81.4),
      ]));
      await cache.writeOutbox([SyncOp.mealInsert(testMeal('m-2'), trackDay: true)]);
      await cache.writePendingStatsDeltas(meals: 1, weightLogs: 0);
      await cache.writeUserRecipes([testRecipe('user_1')]);

      await cache.clear(preserveOutbox: true);

      // The two sync slots are still there, content included.
      final outbox = await cache.readOutbox();
      expect(outbox, hasLength(1));
      expect(outbox!.single.entityId, 'm-2');
      expect((await cache.readPendingStatsDeltas())!.meals, 1);

      // Everything else is wiped.
      expect(await cache.readProfile(), isNull);
      expect(await cache.readLifetimeStats(), isNull);
      expect(await cache.readNotificationsEnabled(), isNull);
      expect(await cache.readLoggedMeals(), isNull);
      expect(await cache.readFavorites(), isNull);
      expect(await cache.readWeightLog(), isNull);
      // Own recipes are user content and fall under the same M-1 rule as the
      // diary: they do NOT survive logout. Their undelivered write sits in the
      // outbox.
      expect(await cache.readUserRecipes(), isNull);
      expect(
        store.snapshot.keys.toSet(),
        {'eatova.v1.outbox.user-1', 'eatova.v1.pending_stats.user-1'},
        reason: 'genau die zwei Sync-Slots, kein PII-Rest',
      );
    });

    test('clear() ohne Argument raeumt weiterhin auch die Outbox', () async {
      // The default must not change — account deletion relies on it.
      final store = InMemoryKeyValueStore();
      final cache = _cache(store);
      await cache.writeOutbox([SyncOp.mealDelete('m-2')]);
      await cache.writePendingStatsDeltas(meals: 1, weightLogs: 0);

      await cache.clear();

      expect(await cache.readOutbox(), isNull);
      expect(await cache.readPendingStatsDeltas(), isNull);
      expect(store.snapshot, isEmpty);
    });

    test('Slots sind pro userId getrennt', () async {
      final store = InMemoryKeyValueStore();
      await _cache(store, 'user-a').writeLoggedMeals([testMeal('m-1')]);
      expect(await _cache(store, 'user-b').readLoggedMeals(), isNull);
    });
  });
}
