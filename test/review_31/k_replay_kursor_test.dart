import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/sync_operation_sync.dart';
import 'package:eatova/src/services/sync_outbox.dart';

import '../outbox/outbox_test_helpers.dart';
import '../support/sync_replay_interleaving_fake.dart';

// Queue positions are not operation identities. These controlled database
// interleavings retain the old cursor regressions without the removed
// fire-and-forget tracking RPC or counter follow-up path.
const _day = '2026-05-14';
LoggedMeal _meal(String id) => LoggedMeal(
  id: id,
  result: mealResult(id),
  loggedAt: DateTime(2026, 5, 14, 12),
  localDay: _day,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Future<void> onDay(Future<void> Function() body) =>
      withClock(Clock.fixed(DateTime(2026, 5, 14, 12, 30)), body);

  test(
    'K1: Ack der laufenden UUID ueberspringt den nachrueckenden Auftrag nicht',
    () => onDay(() async {
      final server = ReplayInterleavingServer();
      final kv = InMemoryKeyValueStore();
      final first = SyncOp.mealInsert(
        _meal('11111111-2222-4333-8444-555555555555'),
        trackDay: true,
      );
      final tail = SyncOp.mealDelete('22222222-2222-4333-8444-555555555555');
      await seedRawOutbox(kv, [first.toJson(), tail.toJson()]);
      final s = setup(kv: kv, geteilterServer: server);
      await s.cache.writeProfile(testProfile());
      var removedDuringOwnAwait = false;
      server.beforeReceipt = (params, json) async {
        if (params['p_operation_id'] != first.operationId ||
            removedDuringOwnAwait) {
          return;
        }
        // Simulate an independent receipt consumer at the atomic-cache boundary.
        // Production worker exclusion is verified separately by the lease tests.
        final receipt = SyncOperationReceipt.fromJson(json);
        await s.cache.acknowledgeSyncOperation(
          first.operationId,
          LocalSyncResult(stats: receipt.lifetimeStats),
        );
        final durable = await s.cache.readSyncOperations();
        removedDuringOwnAwait = !durable.any(
          (op) => op.operationId == first.operationId,
        );
        expect(durable.map((op) => op.operationId), [tail.operationId]);
      };
      await bootUntilIdle(s.store);
      expect(
        removedDuringOwnAwait,
        isTrue,
        reason: 'das Ack muss im await des gerade laufenden RPC erfolgen',
      );
      expect(server.operations('mealInsert'), hasLength(1));
      expect(server.operations('mealDelete'), hasLength(1));
      expect(server.mealsCounted, 1);
      expect(s.store.pendingOutbox, isEmpty);
      expect(await s.cache.readOutbox(), isEmpty);
    }),
  );

  test(
    'K1: waehrend des Replays atomar angehaengter Auftrag laeuft im selben Pass',
    () => onDay(() async {
      final server = ReplayInterleavingServer();
      final kv = InMemoryKeyValueStore();
      final first = SyncOp.mealInsert(
        _meal('11111111-2222-4333-8444-555555555555'),
        trackDay: false,
      );
      final tail = SyncOp.mealDelete('22222222-2222-4333-8444-555555555555');
      await seedRawOutbox(kv, [first.toJson()]);
      final s = setup(kv: kv, geteilterServer: server);
      await s.cache.writeProfile(testProfile());
      var appendedDuringAwait = false;
      server.beforeReceipt = (params, _) async {
        if (params['p_operation_id'] != first.operationId ||
            appendedDuringAwait) {
          return;
        }
        await s.cache.commitSyncOperations([tail]);
        final durable = await s.cache.readSyncOperations();
        expect(durable.map((op) => op.operationId), [
          first.operationId,
          tail.operationId,
        ]);
        appendedDuringAwait = true;
      };
      await bootUntilIdle(s.store);
      expect(appendedDuringAwait, isTrue);
      expect(
        server.operations('mealDelete'),
        hasLength(1),
        reason: 'der Pass darf keinen veralteten Queue-Snapshot durchlaufen',
      );
      expect(server.mealsCounted, 1);
      expect(
        server.operations('statsIncrement'),
        isEmpty,
        reason: 'der Meal-Zaehler ist Teil desselben atomaren RPC',
      );
      expect(s.store.pendingOutbox, isEmpty);
    }),
  );

  test(
    'K1: retryCounted versucht jede UUID hoechstens einmal pro Pass',
    () => onDay(() async {
      final kv = InMemoryKeyValueStore();
      final first = SyncOp.mealInsert(
        _meal('11111111-2222-4333-8444-555555555555'),
        trackDay: false,
      );
      await seedRawOutbox(kv, [
        first.toJson(),
        SyncOp.mealDelete('22222222-2222-4333-8444-555555555555').toJson(),
      ]);
      final s = setup(kv: kv);
      await s.cache.writeProfile(testProfile());
      s.server.rejectMealWrites = true;
      await bootUntilIdle(s.store);
      expect(s.server.operations('mealInsert'), hasLength(1));
      expect(
        s.server.operations('mealDelete'),
        hasLength(1),
        reason:
            'die blockierte Entitaet darf andere Entitaeten nicht blockieren',
      );
      expect(s.store.pendingOutbox, hasLength(1));
      expect(s.store.pendingOutbox.single.operationId, first.operationId);
      expect(s.store.pendingOutbox.single.attempts, 1);
    }),
  );
}
