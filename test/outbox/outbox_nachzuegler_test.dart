import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/sync_dispatcher.dart';
import '../support/atomic_store_faults.dart';
import 'outbox_test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('gescheiterter Korrekturcommit erzeugt weder PATCH noch falschen Erfolg', () async {
    final raw = InMemoryKeyValueStore();
    final faults = AtomicStoreFaults(raw);
    final a = setup(kv: raw, injizierterCache: LocalCache(faults, 'user-outbox'));
    await bootUntilIdle(a.store);
    final id = await a.store.addResultToDailyTotal(mealResult('Alt'));
    final before = a.server.operations('mealUpsert').length;
    faults.beforeWrite = (changes) async {
      if (changes.keys.any((key) => key.contains('.outbox.'))) {
        throw StateError('Injected transaction failure');
      }
    };
    await expectLater(a.store.updateLoggedMealResult(id, mealResult('Neu', kcal: 600)), throwsStateError);
    expect(a.store.loggedMeals.single.result.caloriesKcal, 300);
    expect(a.server.mealRows[id]!['calories_kcal'], 300);
    expect(a.server.operations('mealUpsert'), hasLength(before));
    expect(a.server.requests.where((r) => r.method == 'PATCH'), isEmpty);
  });

  test('gesunde Korrektur verwendet einen vorher dauerhaft gespeicherten RPC-Intent', () async {
    final raw = InMemoryKeyValueStore();
    final faults = AtomicStoreFaults(raw);
    final a = setup(kv: raw, injizierterCache: LocalCache(faults, 'user-outbox'));
    await bootUntilIdle(a.store);
    final id = await a.store.addResultToDailyTotal(mealResult('Alt'));
    final persisted = <String>{};
    faults.beforeWrite = (changes) async {
      final value = changes['eatova.v1.outbox.user-outbox'];
      if (value == null) return;
      for (final row in (jsonDecode(value) as Map)['items'] as List) {
        if (row['kind'] == 'mealUpsert') persisted.add(row['operation_id'] as String);
      }
    };
    await a.store.updateLoggedMealResult(id, mealResult('Korrigiert', kcal: 400));
    final request = jsonDecode(a.server.operations('mealUpsert').single.body) as Map;
    expect(persisted, contains(request['p_operation_id']));
    expect(a.store.pendingOutbox, isEmpty);
    expect(a.server.mealRows[id]!['calories_kcal'], 400);
    expect(a.server.requests.where((r) => r.method == 'PATCH'), isEmpty);
  });

  test('Timeout laesst andere Entity durch; spaete Antwort quittiert keine alte Lease', () {
    fakeAsync((async) {
      final a = setup(disposeClient: false);
      a.store.start();
      async.flushMicrotasks();
      async.elapse(Duration.zero);
      async.flushMicrotasks();
      a.server.holdRecipeWrites();
      unawaited(a.store.createUserRecipe(userRecipe('user_waiting')));
      async.flushMicrotasks();
      unawaited(a.store.addResultToDailyTotal(mealResult('Independent')));
      async.flushMicrotasks();
      async.elapse(kSyncOperationTimeout);
      async.flushMicrotasks();
      expect(a.server.mealRows, hasLength(1));
      final old = a.store.pendingOutbox.single;
      expect(old.entityId, 'user_waiting');
      a.server.releaseRecipeWrites();
      async.flushMicrotasks();
      expect(a.store.pendingOutbox.single.operationId, old.operationId,
          reason: 'Eine nach Timeout kommende Future-Antwort ist kein aktueller Ack');
      unawaited(a.store.syncPendingWrites());
      async.flushMicrotasks();
      expect(a.store.pendingOutbox, isEmpty);
      final ids = a.server.operations('recipeUpsert').map((request) =>
          (jsonDecode(request.body) as Map)['p_operation_id']).toSet();
      expect(ids, {old.operationId});
    });
  });

  test('Timeout-Retries erreichen den Backoffdeckel ohne UUID- oder Datenverlust', () {
    fakeAsync((async) {
      final a = setup(disposeClient: false);
      a.store.start();
      async.flushMicrotasks();
      async.elapse(Duration.zero);
      async.flushMicrotasks();
      a.server.hangRecipeWrites = true;
      unawaited(a.store.createUserRecipe(userRecipe('user_waiting')));
      async.flushMicrotasks();
      final id = a.store.pendingOutbox.single.operationId;
      async.elapse(kSyncOperationTimeout);
      async.flushMicrotasks();
      for (var stage = 0; stage < 3; stage++) {
        async.elapse(Duration(seconds: 30 * (1 << stage)) + kSyncOperationTimeout);
        async.flushMicrotasks();
        expect(a.store.debugOutboxRetryStage, stage + 1);
      }
      async.elapse(const Duration(seconds: 240) + kSyncOperationTimeout);
      async.flushMicrotasks();
      expect(a.store.debugOutboxRetryStage, 3);
      expect(a.store.pendingOutbox.single.operationId, id);
      expect(a.store.pendingOutbox.single.attempts, 0,
          reason: 'Ungeklaerte Netzwerkantworten verbrauchen kein Ablehnungsbudget');
      a.server.hangRecipeWrites = false;
      unawaited(a.store.syncPendingWrites());
      async.flushMicrotasks();
      expect(a.store.pendingOutbox, isEmpty);
      expect(a.store.debugOutboxRetryStage, 0);
    });
  });
}
