import 'package:clock/clock.dart';
import 'package:eatova/src/models/weight_log.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/sync_outbox.dart';
import 'package:flutter_test/flutter_test.dart';

const _owner = 'weight-user';
const _pendingId = '7a000000-0000-4000-8000-000000000001';
final _now = DateTime.utc(2026, 9, 28, 6);

Future<void> _snapshot(LocalCache cache, WeightLog log) async {
  final before = await cache.readMutationSnapshot();
  await cache.commitStoreSnapshot(
    expectedVersions: before.snapshot.versions,
    weightLog: log,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a store snapshot does not duplicate a pending weigh-in', () async {
    await withClock(Clock.fixed(_now), () async {
      final recordedAt = DateTime.utc(2026, 9, 28, 5, 30).toLocal();
      final cache = LocalCache(InMemoryKeyValueStore(), _owner);
      await cache.commitSyncOperations([
        SyncOp.weightInsert(
          id: _pendingId,
          weightKg: 80,
          recordedAt: recordedAt,
        ),
      ]);
      // The store merges the pending operation into memory and then writes
      // its snapshot, which carries no operation ids.
      await _snapshot(
        cache,
        WeightLog(
          entries: [WeightLogEntry(timestamp: recordedAt, weightKg: 80)],
        ),
      );

      final log = (await cache.readWeightLog())!;
      expect(log.entries, hasLength(1));
      expect(log.entries.single.timestamp.isAtSameMomentAs(recordedAt), isTrue);
      expect(log.entries.single.weightKg, 80);
      expect((await cache.readSyncOperations()).single.entityId, _pendingId);
    });
  });

  test('a pending weigh-in at another instant is still projected', () async {
    await withClock(Clock.fixed(_now), () async {
      final earlier = DateTime.utc(2026, 9, 27, 5, 30).toLocal();
      final recordedAt = DateTime.utc(2026, 9, 28, 5, 30).toLocal();
      final cache = LocalCache(InMemoryKeyValueStore(), _owner);
      await cache.commitSyncOperations([
        SyncOp.weightInsert(
          id: _pendingId,
          weightKg: 80,
          recordedAt: recordedAt,
        ),
      ]);
      await _snapshot(
        cache,
        WeightLog(entries: [WeightLogEntry(timestamp: earlier, weightKg: 81)]),
      );

      final log = (await cache.readWeightLog())!;
      expect(log.entries.map((e) => e.weightKg), [81, 80]);
      expect(log.entries.last.timestamp.isAtSameMomentAs(recordedAt), isTrue);
    });
  });
}
