import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/local_day.dart';
import 'package:eatova/src/services/sync_outbox.dart';

import 'outbox_test_helpers.dart';
import '../support/sync_replay_interleaving_fake.dart';

final _now = DateTime(2026, 5, 14, 12, 30);
const _first = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _second = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const _third = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
LoggedMeal _meal(String id) =>
    LoggedMeal(id: id, result: mealResult(id), loggedAt: _now);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'shrinking durable queue never skips the operation that shifts into its predecessor position',
    () async {
      final kv = InMemoryKeyValueStore();
      final operations = [
        SyncOp.mealInsert(_meal(_first), trackDay: false),
        SyncOp.mealDelete(_second),
        SyncOp.mealDelete(_third),
        SyncOp.mealUpsert(
          _meal(_first).copyWith(result: mealResult('Updated', kcal: 500)),
        ),
      ];
      await seedRawOutbox(kv, operations.map((op) => op.toJson()).toList());
      final s = setup(kv: kv);
      s.server.mealRows[_second] = serverMealRow(_second);
      s.server.mealRows[_third] = serverMealRow(_third);
      await bootUntilIdle(s.store);
      final requests = s.server.requests.where(
        (request) => request.url.path.endsWith('/rpc/apply_sync_operation'),
      );
      expect(
        requests.map(
          (request) => (jsonDecode(request.body) as Map)['p_operation_id'],
        ),
        operations.map((op) => op.operationId),
      );
      expect(s.server.mealRows.keys, [_first]);
      expect(s.server.mealRows[_first]!['calories_kcal'], 500);
      expect(s.server.mealsCounted, 1);
      expect(s.store.pendingOutbox, isEmpty);
      expect(await s.cache.readOutbox(), isEmpty);
    },
  );

  // Fails when a pass works off the queue it read at its start: the commit
  // here bypasses the store, so no follow-up pass can cover for it.
  test(
    'an op committed while a delivery is in flight runs in that same pass',
    () => withClock(Clock.fixed(_now), () async {
      final server = ReplayInterleavingServer();
      final kv = InMemoryKeyValueStore();
      final first = SyncOp.mealInsert(_meal(_first), trackDay: false);
      final tail = SyncOp.mealDelete(_second);
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
        appendedDuringAwait = true;
      };
      await bootUntilIdle(s.store);
      expect(appendedDuringAwait, isTrue);
      expect(server.operations('mealDelete'), hasLength(1));
      expect(server.mealsCounted, 1);
      expect(
        server.operations('statsIncrement'),
        isEmpty,
        reason: 'the meal counter is part of the same atomic RPC',
      );
      expect(s.store.pendingOutbox, isEmpty);
    }),
  );

  test(
    'rejected predecessor blocks only its entity while day proof and tail witness still finish',
    () => withClock(Clock.fixed(_now), () async {
      final kv = InMemoryKeyValueStore();
      final recipe = SyncOp.recipeUpsert(
        userRecipe('user_blocked'),
        expectedRevision: 0,
      );
      final deletion = SyncOp.recipeDelete('user_blocked', expectedRevision: 1);
      final day = localDayKey(_now);
      await seedRawOutbox(kv, [
        recipe.toJson(),
        deletion.toJson(),
        SyncOp.mealInsert(_meal(_first), trackDay: false).toJson(),
        SyncOp.trackingDay(day).toJson(),
        SyncOp.weightInsert(
          id: _second,
          weightKg: 81,
          recordedAt: _now,
        ).toJson(),
      ]);
      final s = setup(kv: kv);
      s.server.rejectRecipeWrites = true;
      s.server.enforceTrackingDaySourceProof = true;
      await bootUntilIdle(s.store);
      expect(s.server.weightRows.keys, [_second]);
      expect(s.server.mealRows.keys, [_first]);
      expect(s.server.trackedDay, day);
      expect(s.server.trackingDayRejections, isEmpty);
      expect(s.server.operations('recipeDelete'), isEmpty);
      expect(s.store.pendingOutbox.map((op) => op.operationId), [
        recipe.operationId,
        deletion.operationId,
      ]);
      expect(s.store.pendingOutbox.map((op) => op.attempts), [1, 0]);
      expect(s.server.mealsCounted, 1);
      expect(s.server.weightLogsCounted, 1);
      s.server.rejectRecipeWrites = false;
      await s.store.syncPendingWrites();
      expect(s.store.pendingOutbox, isEmpty);
      expect(s.server.recipeRows, isEmpty);
    }),
  );
}
