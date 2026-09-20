import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/sync_outbox.dart';

import 'outbox_test_helpers.dart';

// Confirmed changes are never dropped. Poison errors and exhausted budgets
// stop automatic retries while retaining the intent for explicit recovery.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'poison rejection retains the confirmed meal and blocks automatic retry',
    () async {
      final s = setup();
      await boot(s.store);
      s.server.poisonMealWrites = true;
      final id = await s.store.addResultToDailyTotal(mealResult('Retained'));
      final op = s.store.pendingOutbox.singleWhere((o) => o.entityId == id);
      expect(op.blockedReason, SyncBlockedReason.rejected);
      expect(s.store.syncBlockedReason, SyncBlockedReason.rejected);
      expect(s.store.loggedMeals.map((m) => m.id), contains(id));
      expect(
        (await s.cache.readOutbox())!.any(
          (o) => o.operationId == op.operationId,
        ),
        isTrue,
      );
      final count = s.server.operations('mealInsert').length;
      await s.store.syncPendingWrites();
      await s.store.syncPendingWrites();
      expect(s.server.operations('mealInsert'), hasLength(count));
      for (final text in s.snacks.messages) {
        expect(text, isNot(contains('23502')));
        expect(text, isNot(contains('logged_meals')));
        expect(text, isNot(contains('PostgrestException')));
      }
      s.server.poisonMealWrites = false;
      await s.store.syncPendingWrites(retryBlocked: true);
      expect(s.server.mealRows.keys, contains(id));
      expect(s.store.pendingOutbox, isEmpty);
    },
  );

  test(
    'transient rejection counts attempts but successful recovery retains one meal',
    () async {
      final s = setup();
      await boot(s.store);
      s.server.rejectMealWrites = true;
      final id = await s.store.addResultToDailyTotal(mealResult('Retry'));
      expect(
        s.store.pendingOutbox.singleWhere((o) => o.entityId == id).attempts,
        1,
      );
      for (var i = 0; i < 3; i++) {
        await s.store.syncPendingWrites();
      }
      final op = s.store.pendingOutbox.singleWhere((o) => o.entityId == id);
      expect(op.attempts, 4);
      expect(op.blockedReason, isNull);
      s.server.rejectMealWrites = false;
      await s.store.syncPendingWrites();
      expect(s.store.pendingOutbox, isEmpty);
      expect(s.server.mealRows, hasLength(1));
      expect(s.server.mealsCounted, 1);
    },
  );

  test('network outage never spends the attempt budget', () async {
    final s = setup();
    await boot(s.store);
    s.server.offline = true;
    final id = await s.store.addResultToDailyTotal(mealResult('Offline'));
    for (var i = 0; i < kOutboxMaxAttempts * 3; i++) {
      await s.store.syncPendingWrites();
    }
    final op = s.store.pendingOutbox.singleWhere((o) => o.entityId == id);
    expect(op.attempts, 0);
    expect(op.blockedReason, isNull);
    s.server.offline = false;
    await s.store.syncPendingWrites();
    expect(s.server.mealRows.keys, contains(id));
    expect(s.store.pendingOutbox, isEmpty);
  });

  test(
    'lifecycle churn exhausts retries without erasing any confirmed data',
    () async {
      final s = setup();
      await boot(s.store);
      s.server.rejectMealWrites = true;
      final id = await s.store.addResultToDailyTotal(mealResult('Outage'));
      for (var i = 0; i < kOutboxMaxAttempts * 2; i++) {
        await s.store.syncPendingWrites();
      }
      final op = s.store.pendingOutbox.singleWhere((o) => o.entityId == id);
      expect(op.blockedReason, SyncBlockedReason.rejected);
      expect(op.attempts, lessThanOrEqualTo(kOutboxMaxAttempts + 1));
      expect((await s.cache.readLoggedMeals())!.map((m) => m.id), contains(id));
      final persisted = (await s.cache.readOutbox())!.singleWhere(
        (o) => o.entityId == id,
      );
      expect(persisted.operationId, op.operationId);
      expect(persisted.blockedReason, SyncBlockedReason.rejected);
    },
  );

  for (final age in [
    const Duration(hours: 23),
    const Duration(hours: 25),
    const Duration(days: 365),
  ]) {
    test(
      'confirmed operations survive expiry age $age and process restart',
      () async {
        final now = DateTime(2030, 5, 17, 8);
        final kv = InMemoryKeyValueStore();
        const id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
        final operation = SyncOp.mealInsert(
          LoggedMeal(id: id, result: mealResult('Old'), loggedAt: now),
          trackDay: false,
        );
        await seedRawOutbox(kv, [
          operation.toJson()
            ..['queued_at'] = now.subtract(age).toIso8601String()
            ..['attempts'] = kOutboxMaxAttempts - 1,
        ]);
        await withClock(Clock.fixed(now), () async {
          final s = setup(kv: kv);
          s.server.rejectMealWrites = true;
          await bootUntilIdle(s.store);
          expect(
            s.store.pendingOutbox.single.operationId,
            operation.operationId,
          );
          expect(
            s.store.pendingOutbox.single.blockedReason,
            SyncBlockedReason.rejected,
          );
          expect(s.store.loggedMeals.map((m) => m.id), contains(id));
          final restarted = setup(kv: kv);
          await bootUntilIdle(restarted.store);
          expect(
            restarted.store.pendingOutbox.single.operationId,
            operation.operationId,
          );
          expect(restarted.server.operations('mealInsert'), isEmpty);
          await restarted.store.syncPendingWrites(retryBlocked: true);
          expect(restarted.server.mealRows.keys, contains(id));
          expect(restarted.store.pendingOutbox, isEmpty);
        });
      },
    );
  }

  test(
    'editing a blocked meal preserves FIFO and recovery sends the latest content',
    () async {
      final s = setup();
      await boot(s.store);
      s.server.poisonMealWrites = true;
      final id = await s.store.addResultToDailyTotal(mealResult('Original'));
      final identity = s.store.pendingOutbox
          .singleWhere((o) => o.entityId == id)
          .operationId;
      s.server.poisonMealWrites = false;
      await s.store.updateLoggedMealResult(id, mealResult('Edited', kcal: 500));
      expect(
        s.server.mealRows,
        isEmpty,
        reason: 'The edit may not bypass its blocked predecessor',
      );
      expect(
        s.store.pendingOutbox.firstWhere((o) => o.entityId == id).operationId,
        identity,
      );
      await s.store.syncPendingWrites(retryBlocked: true);
      expect(s.server.mealRows[id]!['calories_kcal'], 500);
      expect(s.server.mealsCounted, 1);
      expect(s.store.pendingOutbox, isEmpty);
    },
  );

  test(
    'corrupt legacy payload is retained and never reported as delivered',
    () async {
      final kv = InMemoryKeyValueStore();
      await seedRawOutbox(kv, [
        {
          'kind': 'mealInsert',
          'entity_id': 'corrupt',
          'queued_at': DateTime(2026, 1, 1).toIso8601String(),
          'payload': 'broken',
        },
      ]);
      final s = setup(kv: kv);
      await bootUntilIdle(s.store);
      expect(s.server.operations('mealInsert'), isEmpty);
      expect(kv.snapshot['eatova.v1.outbox.user-outbox'], contains('corrupt'));
      expect(
        s.store.pendingOutbox.single.blockedReason,
        SyncBlockedReason.rejected,
      );
    },
  );

  test(
    'missing backend RPC keeps a deletion durable and allows explicit retry',
    () async {
      final s = setup();
      await boot(s.store);
      final id = await s.store.addResultToDailyTotal(mealResult('Delete'));
      s.server.poisonMealWrites = true;
      s.server.poisonCode = 'PGRST202';
      await s.store.removeLoggedMeal(id);
      expect(
        s.store.pendingOutbox.single.blockedReason,
        SyncBlockedReason.backendUnavailable,
      );
      expect(s.server.mealRows.keys, contains(id));
      expect(s.store.loggedMeals, isEmpty);
      final count = s.server.operations('mealDelete').length;
      await s.store.syncPendingWrites();
      expect(s.server.operations('mealDelete'), hasLength(count));
      s.server.poisonMealWrites = false;
      await s.store.syncPendingWrites(retryBlocked: true);
      expect(s.store.pendingOutbox, isEmpty);
      expect(s.server.mealRows, isEmpty);
    },
  );

  for (final days in [0, 60]) {
    test(
      'exhausted deletion stays hidden after cold start including archive age $days',
      () async {
        final kv = InMemoryKeyValueStore();
        const id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
        final op = SyncOp.mealDelete(id);
        await seedRawOutbox(kv, [
          op.toJson()
            ..['queued_at'] = DateTime(2020).toIso8601String()
            ..['attempts'] = kOutboxDeleteMaxAttempts - 1,
        ]);
        final s = setup(kv: kv);
        s.server.mealRows[id] = serverMealRow(id)
          ..['logged_at'] = DateTime.now()
              .subtract(Duration(days: days))
              .toIso8601String();
        s.server.poisonMealWrites = true;
        await bootUntilIdle(s.store);
        expect(s.store.pendingOutbox.single.operationId, op.operationId);
        expect(
          s.store.pendingOutbox.single.blockedReason,
          SyncBlockedReason.rejected,
        );
        expect(s.store.loggedMeals, isEmpty);
        expect(s.server.mealRows.keys, contains(id));
        s.server.poisonMealWrites = false;
        await s.store.syncPendingWrites(retryBlocked: true);
        expect(s.store.pendingOutbox, isEmpty);
        expect(s.server.mealRows, isEmpty);
        expect(s.store.loggedMeals, isEmpty);
      },
    );
  }

  test(
    'rejected insert and delete remain individually recoverable in one pass',
    () async {
      final s = setup();
      await boot(s.store);
      final removed = await s.store.addResultToDailyTotal(
        mealResult('Removed'),
      );
      s.server.poisonMealWrites = true;
      await s.store.removeLoggedMeal(removed);
      final added = await s.store.addResultToDailyTotal(mealResult('Added'));
      final pending = s.store.pendingOutbox
          .where((o) => o.entityKey.startsWith('meal:'))
          .toList();
      expect(pending.map((o) => o.kind), [
        SyncOpKind.mealDelete,
        SyncOpKind.mealInsert,
      ]);
      expect(s.store.loggedMeals.map((m) => m.id), [added]);
      s.server.poisonMealWrites = false;
      await s.store.syncPendingWrites(retryBlocked: true);
      expect(s.server.mealRows.keys, [added]);
      expect(s.store.pendingOutbox, isEmpty);
    },
  );
}
