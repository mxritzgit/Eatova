import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/local_day.dart';
import 'package:eatova/src/services/sync_outbox.dart';

import 'outbox_test_helpers.dart';

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

  test(
    'new entity appended during an in-flight pass is delivered in that same pass',
    () async {
      final s = setup();
      await bootUntilIdle(s.store);
      s.server.holdMealWrites();
      final mealSave = s.store.addResultToDailyTotal(mealResult('Held'));
      await pumpUntil(() => s.server.operations('mealInsert').isNotEmpty);
      final weightSave = s.store.logWeight(81);
      await pumpUntil(
        () => s.store.pendingOutbox.any(
          (op) => op.kind == SyncOpKind.weightInsert,
        ),
      );
      expect(
        s.store.pendingOutbox.any((op) => op.kind == SyncOpKind.weightInsert),
        isTrue,
        reason:
            'The witness must actually be appended after the initial pass snapshot',
      );
      expect(s.server.operations('weightInsert'), isEmpty);
      s.server.releaseMealWrites();
      await Future.wait([mealSave, weightSave]);
      expect(s.server.weightRows, hasLength(1));
      expect(s.server.weightLogsCounted, 1);
      expect(s.server.mealsCounted, 1);
      expect(
        s.store.pendingOutbox,
        isEmpty,
        reason:
            'No new timer, lifecycle event or manual replay started after releasing the held request',
      );
    },
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
