import 'dart:io';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:eatova/src/models/lifetime_stats.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/weight_log.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/secure_cache_store.dart';
import 'package:eatova/src/services/sqlite_key_value_store.dart';
import 'package:eatova/src/services/sync_outbox.dart';
import 'package:flutter_test/flutter_test.dart';

import '../outbox/outbox_test_helpers.dart' show mealResult;

final _day = DateTime.utc(2026, 9, 24, 12);

LoggedMeal _meal(String id) =>
    LoggedMeal(id: id, result: mealResult(id), loggedAt: _day);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('partial ACK and a server reload retain an unsent meal count on disk',
      () async {
    await withClock(Clock.fixed(_day), () async {
      final directory = await Directory.systemTemp.createTemp('eatova_stats_');
      final path = '${directory.path}/cache.sqlite';
      final dek = Uint8List.fromList(List.generate(32, (index) => index));
      SqliteKeyValueStore? database;
      LocalCache? cache;
      try {
        Future<LocalCache> open() async {
          database = await SqliteKeyValueStore.open(path);
          return LocalCache(
            EncryptedKeyValueStore(
              database!,
              AesGcmCacheCipher(dek),
              acceptLegacyPlaintext: false,
            ),
            'owner-A',
          );
        }

        cache = await open();
        final first = SyncOp.mealInsert(_meal('meal-1'), trackDay: true);
        final second = SyncOp.mealInsert(_meal('meal-2'), trackDay: true);
        await cache.commitSyncOperations([first, second]);
        expect((await cache.readLifetimeStats())!.mealsLogged, 2);

        await cache.startSyncOperation(first.operationId);
        await cache.acknowledgeSyncOperation(
          first.operationId,
          LocalSyncResult(stats: LifetimeStats(mealsLogged: 1)),
        );
        expect((await cache.readSyncOperations()).single.operationId,
            second.operationId);
        expect((await cache.readLifetimeStats())!.mealsLogged, 2);

        await database!.close();
        cache = await open();
        expect((await cache.readLifetimeStats())!.mealsLogged, 2);
        final versions = (await cache.readMutationSnapshot()).snapshot.versions;
        await cache.commitStoreSnapshot(
          expectedVersions: versions,
          stats: LifetimeStats(mealsLogged: 1),
        );
        expect((await cache.readLifetimeStats())!.mealsLogged, 2);

        await cache.startSyncOperation(second.operationId);
        await cache.acknowledgeSyncOperation(
          second.operationId,
          LocalSyncResult(stats: LifetimeStats(mealsLogged: 2)),
        );
        expect(await cache.readSyncOperations(), isEmpty);
        expect((await cache.readLifetimeStats())!.mealsLogged, 2);
      } finally {
        cache?.close();
        await database?.close();
        await directory.delete(recursive: true);
      }
    });
  });

  test('already delivered but unacknowledged meal is never counted twice',
      () async {
    await withClock(Clock.fixed(_day), () async {
      final cache = LocalCache(InMemoryKeyValueStore(), 'owner-A');
      final first = SyncOp.mealInsert(_meal('meal-1'), trackDay: true);
      final second = SyncOp.mealInsert(_meal('meal-2'), trackDay: true);
      await cache.commitSyncOperations([first, second]);
      await cache.startSyncOperation(first.operationId);
      // The server accepted first. Its ACK could not commit locally, so both
      // intents still exist while a fresh server load reports one meal.
      final versions = (await cache.readMutationSnapshot()).snapshot.versions;
      await cache.commitStoreSnapshot(
        expectedVersions: versions,
        stats: LifetimeStats(mealsLogged: 1),
      );
      expect((await cache.readLifetimeStats())!.mealsLogged, 2);
      await cache.acknowledgeSyncOperation(
        first.operationId,
        LocalSyncResult(stats: LifetimeStats(mealsLogged: 1)),
      );
      expect((await cache.readLifetimeStats())!.mealsLogged, 2);
      await cache.startSyncOperation(second.operationId);
      await cache.acknowledgeSyncOperation(
        second.operationId,
        LocalSyncResult(stats: LifetimeStats(mealsLogged: 2)),
      );
      expect((await cache.readLifetimeStats())!.mealsLogged, 2);
      cache.close();
    });
  });

  test('terminally rejected intent stops flooring the server count', () async {
    await withClock(Clock.fixed(_day), () async {
      final cache = LocalCache(InMemoryKeyValueStore(), 'owner-A');
      final first = SyncOp.mealInsert(_meal('meal-1'), trackDay: false);
      final second = SyncOp.mealInsert(_meal('meal-2'), trackDay: false);
      await cache.commitSyncOperations([first, second]);
      await cache.recordSyncFailure(
        second.operationId,
        countAttempt: true,
        blockedReason: SyncBlockedReason.rejected,
      );
      await cache.startSyncOperation(first.operationId);
      await cache.acknowledgeSyncOperation(
        first.operationId,
        LocalSyncResult(stats: LifetimeStats(mealsLogged: 1)),
      );
      expect((await cache.readLifetimeStats())!.mealsLogged, 1);
      final versions = (await cache.readMutationSnapshot()).snapshot.versions;
      await cache.commitStoreSnapshot(
        expectedVersions: versions,
        stats: LifetimeStats(mealsLogged: 1),
      );
      expect((await cache.readLifetimeStats())!.mealsLogged, 1);
      expect((await cache.readSyncOperations()).single.blockedReason,
          SyncBlockedReason.rejected);
      cache.close();
    });
  });

  test('a larger cross-device server count wins over the local floor', () async {
    await withClock(Clock.fixed(_day), () async {
      final cache = LocalCache(InMemoryKeyValueStore(), 'owner-A');
      await cache.writeLifetimeStats(LifetimeStats(mealsLogged: 10));
      final first = SyncOp.mealInsert(_meal('meal-1'), trackDay: false);
      final second = SyncOp.mealInsert(_meal('meal-2'), trackDay: false);
      await cache.commitSyncOperations([first, second]);
      expect((await cache.readLifetimeStats())!.mealsLogged, 12);
      await cache.startSyncOperation(first.operationId);
      await cache.acknowledgeSyncOperation(
        first.operationId,
        LocalSyncResult(stats: LifetimeStats(mealsLogged: 16)),
      );
      expect((await cache.readLifetimeStats())!.mealsLogged, 16);
      expect((await cache.readSyncOperations()).single.operationId,
          second.operationId);
      cache.close();
    });
  });

  test('a stale local count cannot exceed server plus pending intent budget',
      () async {
    await withClock(Clock.fixed(_day), () async {
      final cache = LocalCache(InMemoryKeyValueStore(), 'owner-A');
      await cache.writeLifetimeStats(LifetimeStats(mealsLogged: 1000));
      final first = SyncOp.mealInsert(_meal('meal-1'), trackDay: false);
      final second = SyncOp.mealInsert(_meal('meal-2'), trackDay: false);
      await cache.commitSyncOperations([first, second]);
      await cache.startSyncOperation(first.operationId);
      await cache.acknowledgeSyncOperation(
        first.operationId,
        LocalSyncResult(stats: LifetimeStats(mealsLogged: 1)),
      );
      expect((await cache.readLifetimeStats())!.mealsLogged, 2);
      cache.close();
    });
  });

  test('pending weight and tracked day survive a partial ACK', () async {
    await withClock(Clock.fixed(_day), () async {
      final cache = LocalCache(InMemoryKeyValueStore(), 'owner-A');
      final yesterday = _day.subtract(const Duration(days: 1));
      final first = SyncOp.mealInsert(
        LoggedMeal(
          id: 'meal-yesterday',
          result: mealResult('Yesterday'),
          loggedAt: yesterday,
        ),
        trackDay: true,
      );
      final second = SyncOp.mealInsert(_meal('meal-today'), trackDay: true);
      final weight = SyncOp.weightInsert(
        id: '87000000-0000-4000-8000-000000000001',
        weightKg: 81,
        recordedAt: _day,
      );
      await cache.commitSyncOperations([first, second, weight]);
      await cache.startSyncOperation(first.operationId);
      await cache.acknowledgeSyncOperation(
        first.operationId,
        LocalSyncResult(
          stats: LifetimeStats(
            mealsLogged: 1,
            currentStreak: 1,
            longestStreak: 1,
            lastTrackedDate: yesterday,
          ),
        ),
      );
      final stats = (await cache.readLifetimeStats())!;
      expect(stats.mealsLogged, 2);
      expect(stats.weightLogs, 1);
      expect(stats.currentStreak, 2);
      expect(stats.lastTrackedDate, DateTime(2026, 9, 24));
      cache.close();
    });
  });

  test('atomic offline weight projection caps history without losing intents',
      () async {
    await withClock(Clock.fixed(_day), () async {
      final cache = LocalCache(InMemoryKeyValueStore(), 'owner-A');
      final operations = [
        for (var i = 0; i <= WeightLog.maxEntries; i++)
          SyncOp.weightInsert(
            id: '88000000-0000-4000-8000-${i.toString().padLeft(12, '0')}',
            weightKg: 80 + i / 100,
            recordedAt: _day.add(Duration(minutes: i)),
          ),
      ];
      await cache.commitSyncOperations(operations);
      final log = (await cache.readWeightLog())!;
      expect(log.entries, hasLength(WeightLog.maxEntries));
      expect(log.baseline!.timestamp.isAtSameMomentAs(
          _day.add(const Duration(minutes: 1))), isTrue);
      expect(log.latest!.timestamp.isAtSameMomentAs(
          _day.add(const Duration(minutes: WeightLog.maxEntries))), isTrue);
      expect(await cache.readSyncOperations(), hasLength(operations.length));
      cache.close();
    });
  });
}
