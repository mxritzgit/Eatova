import 'dart:convert';

import 'package:clock/clock.dart';
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
