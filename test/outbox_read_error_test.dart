import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/sync_outbox.dart';
import 'outbox/outbox_test_helpers.dart';
import 'support/failing_snapshot_store.dart';

// An unreadable sync slot (outbox or legacy stats bundle) is never taken for
// an empty one: every save is rejected before HTTP, the persisted bytes stay
// untouched however often or however late it is retried, and the old intents
// are delivered once the slot reads again.

const uid = 'user-outbox';
const outboxSlot = 'eatova.v1.outbox.$uid';
final now = DateTime(2026, 9, 20, 12);
LoggedMeal oldMeal() =>
    LoggedMeal(id: 'old-meal', result: mealResult('Old bowl'), loggedAt: now);

/// While [failing], every read throws an error the cache does not classify.
class _FlakyReadStore extends InMemoryKeyValueStore {
  bool failing = false;

  @override
  Future<String?> getString(String key) async {
    if (failing) throw StateError('read failure: $key');
    return super.getString(key);
  }

  @override
  Future<KeyValueSnapshot> readSnapshot(Iterable<String> keys) async {
    if (failing) throw StateError('read failure');
    return super.readSnapshot(keys);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Such a failure aborts the whole hydration. Once reads work again, the next
  // save must rebuild the queue from storage, not write the empty one over it.
  test('after a failed hydration a save keeps the stored intents', () async {
    await withClock(Clock.fixed(now), () async {
      final storage = _FlakyReadStore();
      final cache = LocalCache(storage, uid);
      await cache.writeOutbox([SyncOp.mealInsert(oldMeal(), trackDay: false)]);
      storage.failing = true;
      final s = setup(injizierterCache: cache)..server.offline = true;
      await boot(s.store);
      storage.failing = false;

      final id = await s.store.addResultToDailyTotal(mealResult('New bowl'));

      expect(
        (await cache.readOutbox())!.map((op) => op.entityId),
        containsAll(['old-meal', id]),
      );
    });
  });
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

  // Neither many attempts nor a year of them may turn into a takeover.
  for (final slot in ['outbox', 'pending_stats']) {
    test(
      '$slot survives repeated failures across a year and replays after restart',
      () async {
        final start = DateTime(2026, 9, 20, 12);
        var now = start;
        await withClock(Clock(() => now), () async {
          final storage = FailingSnapshotStore();
          final cache = LocalCache(storage, uid);
          final key = 'eatova.v1.$slot.$uid';
          final old = SyncOp.mealInsert(
            LoggedMeal(
              id: '11111111-1111-4111-8111-111111111111',
              result: mealResult('Old bowl'),
              loggedAt: start,
            ),
            trackDay: false,
          );
          if (slot == 'outbox') {
            await cache.writeOutbox([old]);
          } else {
            await cache.writePendingStatsDeltas(
              meals: 3,
              weightLogs: 0,
              requestId: 'legacy-request',
            );
          }
          final original = storage.snapshot[key];
          storage.blockedKeys.add(key);
          final server = FakeServer()..offline = true;
          final first = setup(
            injizierterCache: cache,
            geteilterServer: server,
            disposeStore: false,
          );
          var disposed = false;
          addTearDown(() {
            if (!disposed) first.store.dispose();
          });
          await boot(first.store);
          for (var i = 0; i < 12; i++) {
            now = now.add(const Duration(days: 365));
            await expectLater(
              first.store.addResultToDailyTotal(mealResult('Rejected $i')),
              throwsA(isA<StateError>()),
            );
            expect(storage.snapshot[key], original);
            expect(first.store.loggedMeals, isEmpty);
            expect(first.store.favorites, isEmpty);
          }
          expect(server.requests, isEmpty);
          first.store.dispose();
          disposed = true;
          storage.blockedKeys.clear();
          server.offline = false;
          final second = setup(kv: storage, geteilterServer: server);
          await boot(second.store);
          await second.store.syncPendingWrites();
          expect(second.store.pendingOutbox, isEmpty);
          expect(server.mealsCounted, slot == 'outbox' ? 1 : 3);
          if (slot == 'outbox') {
            expect(server.mealRows.keys, [
              '11111111-1111-4111-8111-111111111111',
            ]);
            expect(
              server.syncOperations.receipts.keys,
              contains(old.operationId),
            );
          } else {
            expect(server.statsRequestIds, contains('legacy-request'));
          }
          await second.store.syncPendingWrites();
          expect(server.mealsCounted, slot == 'outbox' ? 1 : 3);
        });
      },
    );
  }
}
