// The encrypted cache's side of correctable weigh-ins (2026-10-19): an edit
// or delete commits with its operation, a queued edit wins over its queued
// insert on read, an id-less row of an older build cannot resurrect a
// deleted weigh-in, and a receipt naming a deletion drops the row.
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:eatova/src/models/weight_log.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/sync_outbox.dart';
import 'package:flutter_test/flutter_test.dart';

const _owner = 'weight-user';
const _id = '7b000000-0000-4000-8000-000000000001';
const _other = '7b000000-0000-4000-8000-000000000002';
final _now = DateTime.utc(2026, 10, 19, 8);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a queued edit wins over its queued insert, counted once', () async {
    await withClock(Clock.fixed(_now), () async {
      final logged = DateTime.utc(2026, 10, 19, 7).toLocal();
      final edited = DateTime.utc(2026, 10, 18, 6, 30).toLocal();
      final cache = LocalCache(InMemoryKeyValueStore(), _owner);
      await cache.commitSyncOperations([
        SyncOp.weightInsert(id: _id, weightKg: 95, recordedAt: logged),
      ]);
      await cache.commitSyncOperations([
        SyncOp.weightUpsert(id: _id, weightKg: 85, recordedAt: edited),
      ]);

      final entry = (await cache.readWeightLog())!.entries.single;
      expect((entry.id, entry.weightKg), (_id, 85));
      expect(entry.timestamp.isAtSameMomentAs(edited), isTrue);
      expect((await cache.readLifetimeStats())?.weightLogs, 1);
      expect(
        (await cache.readSyncOperations()).map((op) => op.kind),
        [SyncOpKind.weightInsert, SyncOpKind.weightUpsert],
      );
    });
  });

  test('a store snapshot keeps ids and re-projects the queued edit', () async {
    await withClock(Clock.fixed(_now), () async {
      final at = DateTime.utc(2026, 10, 18, 6).toLocal();
      final edited = DateTime.utc(2026, 10, 18, 7).toLocal();
      final cache = LocalCache(InMemoryKeyValueStore(), _owner);
      await cache.commitSyncOperations([
        SyncOp.weightUpsert(id: _id, weightKg: 84.5, recordedAt: edited),
      ]);
      // A server load from before the edit arrives afterwards.
      final before = await cache.readMutationSnapshot();
      await cache.commitStoreSnapshot(
        expectedVersions: before.snapshot.versions,
        weightLog: WeightLog(
          entries: [
            WeightLogEntry(timestamp: at, weightKg: 84, id: _id),
            WeightLogEntry(timestamp: at.subtract(const Duration(days: 1)), weightKg: 84.2, id: _other),
          ],
        ),
      );

      final log = (await cache.readWeightLog())!;
      expect(log.entries.map((e) => (e.id, e.weightKg)), [(_other, 84.2), (_id, 84.5)]);
      expect(log.entries.last.timestamp.isAtSameMomentAs(edited), isTrue);
    });
  });

  test('a row an older build cached without an id cannot outlive its delete', () async {
    await withClock(Clock.fixed(_now), () async {
      final kv = InMemoryKeyValueStore();
      final cache = LocalCache(kv, _owner);
      final at = DateTime.utc(2026, 10, 19, 6).toLocal();
      await cache.commitSyncOperations([
        SyncOp.weightInsert(id: _id, weightKg: 80, recordedAt: at),
      ]);
      // The weigh-in's row as an older build's store snapshot left it: no id.
      await kv.setString(
        'eatova.v1.weight_log.$_owner',
        jsonEncode({
          'items': [
            {'t': at.toUtc().toIso8601String(), 'kg': 80},
          ],
        }),
      );
      expect((await cache.readWeightLog())!.entries.single.id, _id,
          reason: 'precondition: the row reads as the queued weigh-in');

      await cache.commitSyncOperations([SyncOp.weightDelete(_id)]);

      expect((await cache.readWeightLog())!.entries, isEmpty);
    });
  });

  test('a receipt naming a deletion drops the row', () async {
    await withClock(Clock.fixed(_now), () async {
      final cache = LocalCache(InMemoryKeyValueStore(), _owner);
      final at = DateTime.utc(2026, 10, 18, 6).toLocal();
      await cache.writeWeightLog(
        WeightLog(entries: [WeightLogEntry(timestamp: at, weightKg: 84, id: _id)]),
      );
      final edit = SyncOp.weightUpsert(id: _id, weightKg: 83.5, recordedAt: at);
      await cache.commitSyncOperations([edit]);
      expect((await cache.readWeightLog())!.entries.single.weightKg, 83.5);

      await cache.acknowledgeSyncOperation(
        edit.operationId,
        const LocalSyncResult(entityDeleted: true),
      );

      expect((await cache.readWeightLog())!.entries, isEmpty);
      expect(await cache.readSyncOperations(), isEmpty);
    });
  });

  test('an acknowledged edit of a live row leaves it as edited', () async {
    await withClock(Clock.fixed(_now), () async {
      final cache = LocalCache(InMemoryKeyValueStore(), _owner);
      final at = DateTime.utc(2026, 10, 18, 6).toLocal();
      final edit = SyncOp.weightUpsert(id: _id, weightKg: 83.5, recordedAt: at);
      await cache.commitSyncOperations([edit]);

      await cache.acknowledgeSyncOperation(
        edit.operationId,
        const LocalSyncResult(),
      );

      final entry = (await cache.readWeightLog())!.entries.single;
      expect((entry.id, entry.weightKg), (_id, 83.5));
    });
  });
}
