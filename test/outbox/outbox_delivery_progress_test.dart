import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:eatova/src/models/lifetime_stats.dart';
import 'package:eatova/src/models/weight_log.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/sync_outbox.dart';
import 'package:eatova/src/services/sqlite_key_value_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/atomic_store_faults.dart';
import 'outbox_test_helpers.dart';

const _queueKey = 'eatova.v1.outbox.user-outbox';
final _now = DateTime.utc(2026, 9, 25, 12);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('blocked successors cannot starve an unrelated entity', () async {
    await withClock(Clock.fixed(_now), () async {
      final s = setup();
      await bootUntilIdle(s.store);
      final blocked = SyncOp.recipeUpsert(userRecipe('user_blocked'));
      final weight = SyncOp.weightInsert(
        id: '72000000-0000-4000-8000-000000000001',
        weightKg: 80,
        recordedAt: _now,
      );
      await s.cache.commitSyncOperations([
        blocked.withBlockedReason(SyncBlockedReason.rejected),
        for (var i = 0; i < 25; i++)
          SyncOp.recipeUpsert(userRecipe('user_blocked', title: 'Edit $i')),
        weight,
      ]);

      await s.store.syncPendingWrites();

      expect(s.server.weightRows.keys, contains(weight.entityId));
      expect(s.server.operations('recipeUpsert'), isEmpty);
      final retained = await s.cache.readSyncOperations();
      expect(retained, hasLength(26));
      expect(retained.first.operationId, blocked.operationId);
      expect(retained.first.blockedReason, SyncBlockedReason.rejected);
      expect(retained.skip(1).every((op) => !op.deliveryStarted), isTrue);
    });
  });

  test(
    'rejected local meal stays visible without restoring a server streak',
    () async {
      await withClock(Clock.fixed(_now), () async {
        final kv = InMemoryKeyValueStore();
        final server = FakeServer()..poisonMealWrites = true;
        final first = setup(kv: kv, geteilterServer: server);
        await bootUntilIdle(first.store);
        final id = await first.store.addResultToDailyTotal(
          mealResult('Rejected'),
        );
        expect(server.mealsCounted, 0);
        expect(
          first.store.pendingOutbox.single.blockedReason,
          SyncBlockedReason.rejected,
        );
        expect(first.store.loggedMeals.map((meal) => meal.id), contains(id));

        // An authoritative zero row has been fetched and atomically cached.
        // The fake server has no lifetime_stats GET row, so seed that exact
        // cache handoff before exercising the real cold-start projection.
        final versions =
            (await first.cache.readMutationSnapshot()).snapshot.versions;
        await first.cache.commitStoreSnapshot(
          expectedVersions: versions,
          stats: LifetimeStats(),
        );
        expect((await first.cache.readLifetimeStats())!.currentStreak, 0);

        final restarted = setup(kv: kv, geteilterServer: server);
        await bootUntilIdle(restarted.store);
        expect(
          restarted.store.loggedMeals.map((meal) => meal.id),
          contains(id),
        );
        expect(
          restarted.store.pendingOutbox.single.blockedReason,
          SyncBlockedReason.rejected,
        );
        expect(restarted.store.lifetimeStats.mealsLogged, 0);
        expect(restarted.store.lifetimeStats.currentStreak, 0);
        expect(restarted.store.lifetimeStats.longestStreak, 0);
        expect(restarted.store.lifetimeStats.lastTrackedDate, isNull);
      });
    },
  );

  test(
    'an ACK and cold boot retain a later offline meal in lifetime count',
    () async {
      await withClock(Clock.fixed(_now), () async {
        final kv = InMemoryKeyValueStore();
        final server = FakeServer();
        final firstSession = setup(kv: kv, geteilterServer: server);
        await bootUntilIdle(firstSession.store);
        server.offline = true;
        await firstSession.store.addResultToDailyTotal(mealResult('First'));
        await firstSession.store.addResultToDailyTotal(mealResult('Second'));
        expect(firstSession.store.lifetimeStats.mealsLogged, 2);
        final meals = (await firstSession.cache.readSyncOperations())
            .where((op) => op.kind == SyncOpKind.mealInsert)
            .toList();
        expect(meals, hasLength(2));
        await firstSession.cache.recordSyncFailure(
          meals.last.operationId,
          countAttempt: false,
          blockedReason: SyncBlockedReason.backendUnavailable,
        );
        server.offline = false;
        await firstSession.store.syncPendingWrites();
        expect(server.mealsCounted, 1);
        expect(firstSession.store.lifetimeStats.mealsLogged, 2);
        expect((await firstSession.cache.readLifetimeStats())!.mealsLogged, 2);

        final restarted = setup(kv: kv, geteilterServer: server);
        await bootUntilIdle(restarted.store);
        expect(restarted.store.lifetimeStats.mealsLogged, 2);
        expect(
          (await restarted.cache.readSyncOperations())
              .singleWhere((op) => op.kind == SyncOpKind.mealInsert)
              .operationId,
          meals.last.operationId,
        );
      });
    },
  );

  test(
    'pending weight replay keeps the visible history within its cap',
    () async {
      await withClock(Clock.fixed(_now), () async {
        final kv = InMemoryKeyValueStore();
        final cache = LocalCache(kv, 'user-outbox');
        final entries = [
          for (var i = 0; i < WeightLog.maxEntries; i++)
            WeightLogEntry(
              timestamp: _now.subtract(
                Duration(days: WeightLog.maxEntries - i),
              ),
              weightKg: 80 + i / 100,
            ),
        ];
        await cache.writeWeightLog(WeightLog(entries: entries));
        final pending = SyncOp.weightInsert(
          id: '89000000-0000-4000-8000-000000000001',
          weightKg: 84,
          recordedAt: _now,
        );
        expect(await cache.writeOutbox([pending]), isTrue);
        final server = FakeServer()..offline = true;
        final session = setup(kv: kv, geteilterServer: server);
        await bootUntilIdle(session.store);
        expect(
          session.store.weightLog.entries,
          hasLength(WeightLog.maxEntries),
        );
        expect(
          session.store.weightLog.baseline!.timestamp,
          entries[1].timestamp,
        );
        expect(
          session.store.weightLog.latest!.timestamp.isAtSameMomentAs(_now),
          isTrue,
        );
        expect(
          (await cache.readSyncOperations()).single.operationId,
          pending.operationId,
        );
      });
    },
  );

  test(
    'local ACK failures retain automatic replay without spending attempts',
    () async {
      await withClock(Clock.fixed(_now), () async {
        final faults = AtomicStoreFaults(InMemoryKeyValueStore());
        final cache = LocalCache(faults, 'user-outbox');
        final s = setup(injizierterCache: cache);
        await bootUntilIdle(s.store);
        final op = SyncOp.weightInsert(
          id: '72000000-0000-4000-8000-000000000002',
          weightKg: 81,
          recordedAt: _now,
        );
        await cache.commitSyncOperations([op]);
        var failedAcknowledgments = 0;
        faults.beforeWrite = (changes) async {
          final encoded = changes[_queueKey];
          if (encoded == null) return;
          final items = (jsonDecode(encoded) as Map)['items'] as List;
          if (items.isEmpty) {
            failedAcknowledgments++;
            throw StateError('Local commit unavailable');
          }
        };

        for (var i = 0; i < kOutboxMaxAttempts + 1; i++) {
          await s.store.syncPendingWrites();
        }
        final retained = (await cache.readSyncOperations()).single;
        expect(retained.operationId, op.operationId);
        expect(retained.attempts, 0);
        expect(retained.blockedReason, isNull);
        expect(failedAcknowledgments, kOutboxMaxAttempts + 1);
        expect(s.server.weightRows, hasLength(1));

        faults.beforeWrite = null;
        await s.store.syncPendingWrites();
        expect(await cache.readSyncOperations(), isEmpty);
        expect(s.server.weightRows, hasLength(1));
        final requests = s.server.operations('weightInsert');
        expect(requests, hasLength(kOutboxMaxAttempts + 2));
        expect(
          requests
              .map((r) => (jsonDecode(r.body) as Map)['p_operation_id'])
              .toSet(),
          {op.operationId},
        );
        expect(s.server.weightLogsCounted, 1);
      });
    },
  );

  test(
    'a failed local ACK allows other entities to finish in the same replay',
    () async {
      await withClock(Clock.fixed(_now), () async {
        final faults = AtomicStoreFaults(InMemoryKeyValueStore());
        final cache = LocalCache(faults, 'user-outbox');
        final s = setup(injizierterCache: cache);
        await bootUntilIdle(s.store);
        final first = SyncOp.weightInsert(
          id: '72000000-0000-4000-8000-000000000003',
          weightKg: 82,
          recordedAt: _now,
        );
        final second = SyncOp.weightInsert(
          id: '72000000-0000-4000-8000-000000000004',
          weightKg: 83,
          recordedAt: _now,
        );
        await cache.commitSyncOperations([first, second]);
        faults.beforeWrite = (changes) async {
          final encoded = changes[_queueKey];
          if (encoded == null) return;
          final items = (jsonDecode(encoded) as Map)['items'] as List;
          if (!items.any((row) => row['operation_id'] == first.operationId)) {
            throw const DurableStorageException('database operation failed');
          }
        };

        await s.store.syncPendingWrites();

        expect(s.server.weightRows, hasLength(2));
        final pending = (await cache.readSyncOperations()).single;
        expect(pending.operationId, first.operationId);
        expect(pending.attempts, 0);
        expect(pending.blockedReason, isNull);
        faults.beforeWrite = null;
        await s.store.syncPendingWrites();
        expect(await cache.readSyncOperations(), isEmpty);
        expect(s.server.weightRows, hasLength(2));
        expect(s.server.weightLogsCounted, 2);
      });
    },
  );
}
