import 'dart:convert';

import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/planned_meal.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/sync_outbox.dart';
import 'package:flutter_test/flutter_test.dart';

const _owner = 'plan-user';
const _slot = 'eatova.v1.meal_plans.$_owner';
const _planId = '7b000000-0000-4000-8000-000000000001';
final _checkId = '2026-09-28:${'a' * 64}';

PlannedMeal _plan() => PlannedMeal.create(
  id: _planId,
  recipe: recipeCatalogDe.first,
  day: DateTime(2026, 9, 28),
  slot: MealSlot.lunch,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a plan projected into an absent slot stays readable', () async {
    final kv = InMemoryKeyValueStore();
    final cache = LocalCache(kv, _owner);
    await cache.commitSyncOperations([SyncOp.mealPlanUpsert(_plan())]);
    // The projection creates the slot with only the key it touched.
    expect(
      (jsonDecode((await kv.getString(_slot))!) as Map).keys,
      ['plans'],
    );

    final read = await cache.readMealPlans();
    expect(read, isNotNull);
    expect(read!.plans.map((plan) => plan.id), [_planId]);
    expect(read.checks, isEmpty);
  });

  test(
    'a shopping check projected into an absent slot stays readable',
    () async {
      final cache = LocalCache(InMemoryKeyValueStore(), _owner);
      await cache.commitSyncOperations([
        SyncOp.shoppingCheck(ShoppingCheck(id: _checkId, checked: true)),
      ]);

      final read = await cache.readMealPlans();
      expect(read, isNotNull);
      expect(read!.plans, isEmpty);
      expect(read.checks, {_checkId: true});
    },
  );

  test(
    'an absent slot is still unknown and a mistyped one still unreadable',
    () async {
      final kv = InMemoryKeyValueStore();
      final cache = LocalCache(kv, _owner);
      expect(await cache.readMealPlans(), isNull);

      await kv.setString(
        _slot,
        jsonEncode({'plans': 'broken', 'checks': <Object?>[]}),
      );
      expect(await cache.readMealPlans(), isNull);
      await kv.setString(
        _slot,
        jsonEncode({'plans': <Object?>[], 'checks': <String, Object?>{}}),
      );
      expect(await cache.readMealPlans(), isNull);
    },
  );

  test('a complete slot round-trips unchanged', () async {
    final cache = LocalCache(InMemoryKeyValueStore(), _owner);
    await cache.commitStoreSnapshot(
      expectedVersions: const {},
      mealPlans: [_plan()],
      shoppingChecks: {_checkId: false},
    );
    final read = (await cache.readMealPlans())!;
    expect(read.plans.single.toJson(), _plan().toJson());
    expect(read.checks, {_checkId: false});
  });
}
