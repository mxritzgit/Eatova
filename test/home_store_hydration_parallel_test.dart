import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/local_cache.dart';

import 'outbox/outbox_test_helpers.dart';

// Preserve the cold-start latency guarantee at the current storage boundary:
// one consistent disk snapshot supplies the collections. Subsequent decoding
// uses that in-memory snapshot, without one storage round trip per slot.
class _SlowSnapshots extends InMemoryKeyValueStore {
  final requests = <Set<String>>[];
  int scalarCollectionReads = 0;
  int active = 0;
  int maxActive = 0;

  @override
  Future<KeyValueSnapshot> readSnapshot(Iterable<String> keys) async {
    requests.add(keys.toSet());
    active++;
    if (active > maxActive) maxActive = active;
    try {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return await super.readSnapshot(keys);
    } finally {
      active--;
    }
  }

  @override
  Future<String?> getString(String key) {
    if (_collectionKeys.contains(key)) scalarCollectionReads++;
    return super.getString(key);
  }
}

final _collectionKeys = {
  for (final name in [
    'profile',
    'stats',
    'logged_meals',
    'favorites',
    'weight_log',
    'outbox',
    'pending_stats',
    'user_recipes',
    'daily_activity',
  ])
    'eatova.v1.$name.user-outbox',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Boot-Hydration liest die Collections in einem konsistenten Snapshot',
    () async {
      await withClock(Clock.fixed(DateTime(2026, 9, 20, 12)), () async {
        final storage = _SlowSnapshots();
        final cache = LocalCache(storage, 'user-outbox');
        await cache.writeProfile(
          const UserProfile(weightKg: 83, onboardingCompleted: true),
        );
        await cache.writeLoggedMeals([
          LoggedMeal(
            id: 'cached-meal',
            result: mealResult('Cached', kcal: 420),
            loggedAt: clock.now(),
          ),
        ]);
        final env = setup(injizierterCache: cache);
        env.server.offline = true;
        env.store.start();
        await env.store.profileReady;

        final collectionSnapshots = storage.requests.where(
          (keys) => keys.contains('eatova.v1.profile.user-outbox'),
        );
        expect(
          collectionSnapshots,
          hasLength(1),
          reason:
              'The initial hydration must not pay one disk-read latency per collection',
        );
        expect(collectionSnapshots.single, containsAll(_collectionKeys));
        expect(
          storage.scalarCollectionReads,
          0,
          reason:
              'Reading collections individually loses both snapshot consistency and latency bounds',
        );
        expect(
          storage.maxActive,
          1,
          reason: 'Hydration must not fan out concurrent database reads',
        );
        expect(env.store.profile.weightKg, 83);
        expect(env.store.loggedMeals.single.result.mealName, 'Cached');
        expect(env.store.dailyConsumedKcal, 420);
      });
    },
  );
}
