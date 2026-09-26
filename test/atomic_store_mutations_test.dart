import 'dart:async';

import 'package:clock/clock.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:flutter_test/flutter_test.dart';

import 'outbox/outbox_test_helpers.dart';

class _HeldStore extends InMemoryKeyValueStore {
  bool hold = false;
  bool fail = false;
  final gate = Completer<void>();

  @override
  Future<KeyValueCommit> writeBatch(
    Map<String, String?> changes, {
    Map<String, int> expectedVersions = const {},
  }) async {
    if (changes.keys.any((key) => key.contains('.outbox.'))) {
      if (hold) await gate.future;
      if (fail) throw StateError('Injected disk failure');
    }
    return super.writeBatch(changes, expectedVersions: expectedVersions);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'onboarding shares an uncommitted attempt and permits retry after failure',
    () async {
      await withClock(Clock.fixed(DateTime(2026, 9, 20, 12)), () async {
        final kv = _HeldStore();
        final env = setup(
          kv: kv,
          injizierterCache: LocalCache(kv, 'user-outbox'),
        );
        await bootUntilIdle(env.store);
        final before = env.store.profile;
        const finished = UserProfile(weightKg: 91, onboardingCompleted: true);
        kv.hold = true;
        kv.fail = true;
        final first = env.store.completeOnboarding(finished);
        final second = env.store.completeOnboarding(finished);
        expect(identical(first, second), isTrue);
        final failed = Future.wait([
          expectLater(first, throwsStateError),
          expectLater(second, throwsStateError),
        ]);
        await settle();
        expect(env.store.profile, before);
        kv.gate.complete();
        await failed;
        expect(env.store.profile, before);
        expect(env.store.pendingOutbox, isEmpty);
        kv.hold = false;
        kv.fail = false;
        await env.store.completeOnboarding(finished);
        expect(env.store.profile.weightKg, 91);
        expect(env.store.profile.onboardingCompleted, isTrue);
        expect(env.server.operations('profileUpsert'), hasLength(1));
      });
    },
  );
  test(
    'meal stays unconfirmed until durable entity and outbox commit',
    () async {
      await withClock(Clock.fixed(DateTime(2026, 9, 20, 12)), () async {
        final kv = _HeldStore();
        final cache = LocalCache(kv, 'user-outbox');
        final env = setup(kv: kv, injizierterCache: cache);
        await bootUntilIdle(env.store);
        kv.hold = true;
        final pending = Future.sync(
          () => env.store.addResultToDailyTotal(mealResult('Pending')),
        );
        await settle();
        try {
          expect(
            env.store.loggedMeals,
            isEmpty,
            reason: 'No confirmed row may publish before the transaction',
          );
          expect(
            env.server.mealRows,
            isEmpty,
            reason: 'HTTP must follow the durable transaction',
          );
        } finally {
          kv.gate.complete();
          await pending;
        }
      });
    },
  );

  test('failed commit publishes no meal, recent or lifetime count', () async {
    await withClock(Clock.fixed(DateTime(2026, 9, 20, 12)), () async {
      final kv = _HeldStore();
      final env = setup(
        kv: kv,
        injizierterCache: LocalCache(kv, 'user-outbox'),
      );
      await bootUntilIdle(env.store);
      final count = env.store.lifetimeStats.mealsLogged;
      kv.fail = true;
      await expectLater(
        env.store.addResultToDailyTotal(mealResult('Failed')),
        throwsStateError,
      );
      expect(env.store.loggedMeals, isEmpty);
      expect(env.store.favorites, isEmpty);
      expect(env.store.lifetimeStats.mealsLogged, count);
    });
  });

  test('simultaneous confirmed meals retain both automatic recents', () async {
    await withClock(Clock.fixed(DateTime(2026, 9, 20, 12)), () async {
      final kv = _HeldStore();
      final env = setup(
        kv: kv,
        injizierterCache: LocalCache(kv, 'user-outbox'),
      );
      await bootUntilIdle(env.store);
      await Future.wait([
        env.store.addResultToDailyTotal(mealResult('First')),
        env.store.addResultToDailyTotal(mealResult('Second')),
      ]);
      expect(env.store.loggedMeals, hasLength(2));
      expect(
        env.store.favorites.map((favorite) => favorite.result.mealName).toSet(),
        {'First', 'Second'},
      );
    });
  });

  test(
    'a queued meal keeps the diary date selected when logging began',
    () async {
      await withClock(Clock.fixed(DateTime(2026, 9, 20, 12)), () async {
        final kv = _HeldStore();
        final env = setup(
          kv: kv,
          injizierterCache: LocalCache(kv, 'user-outbox'),
        );
        await bootUntilIdle(env.store);
        kv.hold = true;
        final favorite = env.store.toggleFavorite(mealResult('Held favorite'));
        await settle();
        final logging = env.store.addResultToDailyTotal(
          mealResult('Dated meal'),
        );
        env.store.setFoodDate(DateTime(2026, 9, 19));

        kv.gate.complete();
        await favorite;
        await logging;
        expect(
          env.store
              .mealsForFoodDate(DateTime(2026, 9, 20))
              .map((meal) => meal.result.mealName),
          ['Dated meal'],
        );
        expect(env.store.mealsForFoodDate(DateTime(2026, 9, 19)), isEmpty);
      });
    },
  );
}
