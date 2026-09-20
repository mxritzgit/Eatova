import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/sync_outbox.dart';
import 'outbox/outbox_test_helpers.dart';
import 'support/failing_snapshot_store.dart';

const uid = 'user-outbox';
const outboxSlot = 'eatova.v1.outbox.$uid';
const deltaSlot = 'eatova.v1.pending_stats.$uid';
final now = DateTime(2026, 9, 20, 12);
LoggedMeal oldMeal() =>
    LoggedMeal(id: 'old-meal', result: mealResult('Old bowl'), loggedAt: now);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'unreadable outbox rejects saves atomically, then recovers meals and totals',
    () async {
      await withClock(Clock.fixed(now), () async {
        final storage = FailingSnapshotStore();
        final cache = LocalCache(storage, uid);
        final old = SyncOp.mealInsert(oldMeal(), trackDay: false);
        await cache.writeOutbox([old]);
        final bytes = storage.snapshot[outboxSlot];
        storage.blockedKeys.add(outboxSlot);
        final s = setup(injizierterCache: cache)..server.offline = true;
        await boot(s.store);
        expect(s.store.pendingOutbox, isEmpty);
        expect(s.store.syncStatusReadable, isFalse);
        expect(s.store.dailyConsumedKcal, 0);
        await expectLater(
          s.store.addResultToDailyTotal(mealResult('New bowl')),
          throwsA(isA<StateError>()),
        );
        expect(s.store.loggedMeals, isEmpty);
        expect(s.store.dailyConsumedKcal, 0);
        expect(storage.snapshot[outboxSlot], bytes);
        expect(s.server.requests, isEmpty);
        storage.blockedKeys.clear();
        final id = await s.store.addResultToDailyTotal(mealResult('New bowl'));
        await s.store.syncPendingWrites();
        expect(s.store.syncStatusReadable, isTrue);
        expect(
          (await cache.readOutbox())!.map((op) => op.entityId),
          containsAll(['old-meal', id]),
        );
        expect(
          s.store.loggedMeals.map((meal) => meal.id),
          containsAll(['old-meal', id]),
        );
        expect(s.store.dailyConsumedKcal, 600);
        expect(s.store.macroProgress.proteinG, 60);
        expect(s.store.pendingOutbox.first.operationId, old.operationId);
      });
    },
  );
  test(
    'malformed outbox is preserved and never treated as an empty transaction',
    () async {
      final storage = FailingSnapshotStore({
        outboxSlot: '{"items": [ broken json',
      });
      final s = setup(kv: storage)..server.offline = true;
      await boot(s.store);
      final bytes = storage.snapshot[outboxSlot];
      await expectLater(
        s.store.addResultToDailyTotal(mealResult('New bowl')),
        throwsA(isA<Object>()),
      );
      expect(storage.snapshot[outboxSlot], bytes);
      expect(s.store.loggedMeals, isEmpty);
      expect(s.store.favorites, isEmpty);
      expect(s.store.lifetimeStats.mealsLogged, 0);
      expect(s.server.requests, isEmpty);
    },
  );
  test(
    'logout preserves unreadable legacy statistics and replay identity',
    () async {
      final storage = FailingSnapshotStore();
      final cache = LocalCache(storage, uid);
      await cache.writePendingStatsDeltas(
        meals: 3,
        weightLogs: 0,
        requestId: 'legacy-request',
      );
      final bytes = storage.snapshot[deltaSlot];
      storage.blockedKeys.add(deltaSlot);
      final s = setup(injizierterCache: cache)..server.offline = true;
      await boot(s.store);
      await s.store.signOutCleanup();
      expect(storage.snapshot[deltaSlot], bytes);
    },
  );
  test(
    'healthy snapshot adopts pending data and merges the next save',
    () async {
      await withClock(Clock.fixed(now), () async {
        final storage = FailingSnapshotStore();
        final cache = LocalCache(storage, uid);
        await cache.writeOutbox([
          SyncOp.mealInsert(oldMeal(), trackDay: false),
        ]);
        final s = setup(injizierterCache: cache)..server.offline = true;
        await boot(s.store);
        expect(
          s.store.pendingOutbox.map((op) => op.entityId),
          contains('old-meal'),
        );
        final id = await s.store.addResultToDailyTotal(mealResult('New bowl'));
        await s.store.syncPendingWrites();
        expect(storage.reads[outboxSlot], greaterThan(0));
        expect(
          (await cache.readOutbox())!.map((op) => op.entityId),
          containsAll(['old-meal', id]),
        );
        expect(s.store.dailyConsumedKcal, 600);
      });
    },
  );
}
