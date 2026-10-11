import 'dart:convert';

import 'package:clock/clock.dart';
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
final _today = DateTime(2026, 9, 28, 12);

/// A valid check id of the week starting [week], unique per [index].
String _weekCheck(String week, int index) =>
    '$week:${index.toRadixString(16).padLeft(64, '0')}';

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
      // Checks are retained by week, so the date is frozen.
      await withClock(Clock.fixed(_today), () async {
        final cache = LocalCache(InMemoryKeyValueStore(), _owner);
        await cache.commitSyncOperations([
          SyncOp.shoppingCheck(ShoppingCheck(id: _checkId, checked: true)),
        ]);

        final read = await cache.readMealPlans();
        expect(read, isNotNull);
        expect(read!.plans, isEmpty);
        expect(read.checks, {_checkId: true});
      });
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
    await withClock(Clock.fixed(_today), () async {
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
  });

  test(
    'more checks than the server cap keep the plans and the pending tick',
    () async {
      await withClock(Clock.fixed(_today), () async {
        final cache = LocalCache(InMemoryKeyValueStore(), _owner);
        // 2000 server rows plus one tick still waiting in the outbox.
        await cache.commitStoreSnapshot(
          expectedVersions: const {},
          mealPlans: [_plan()],
          shoppingChecks: {
            for (var i = 0; i < 2000; i++) _weekCheck('2026-09-28', i): true,
          },
        );
        final pending = _weekCheck('2026-09-28', 2000);
        await cache.commitSyncOperations([
          SyncOp.shoppingCheck(ShoppingCheck(id: pending, checked: true)),
        ]);

        final read = await cache.readMealPlans();
        expect(read, isNotNull);
        expect(read!.plans.map((plan) => plan.id), [_planId]);
        expect(read.checks, hasLength(2001));
        expect(read.checks[pending], isTrue);
      });
    },
  );

  test('checks of weeks the server no longer keeps are pruned', () async {
    await withClock(Clock.fixed(_today), () async {
      final kv = InMemoryKeyValueStore();
      final cache = LocalCache(kv, _owner);
      // Six weeks back is the oldest week kept; the server keeps five.
      final kept = _weekCheck('2026-08-17', 1);
      final stale = _weekCheck('2026-08-10', 2);
      await cache.commitStoreSnapshot(
        expectedVersions: const {},
        mealPlans: [_plan()],
        shoppingChecks: {kept: true, stale: true, _checkId: false},
      );
      expect(await kv.getString(_slot), isNot(contains(stale)));
      expect((await cache.readMealPlans())!.checks, {
        kept: true,
        _checkId: false,
      });

      // A slot written before the pruning is cleaned on read.
      await kv.setString(
        _slot,
        jsonEncode({
          'plans': [_plan().toJson()],
          'checks': [
            {'id': stale, 'checked': true},
            {'id': kept, 'checked': true},
          ],
        }),
      );
      expect((await cache.readMealPlans())!.checks, {kept: true});
    });
  });

  test('an oversized check list keeps plans and the newest weeks', () async {
    await withClock(Clock.fixed(_today), () async {
      final kv = InMemoryKeyValueStore();
      final cache = LocalCache(kv, _owner);
      await kv.setString(
        _slot,
        jsonEncode({
          'plans': [_plan().toJson()],
          'checks': [
            for (var i = 0; i < 2400; i++)
              {'id': _weekCheck('2026-09-21', i), 'checked': true},
            for (var i = 0; i < 200; i++)
              {'id': _weekCheck('2026-09-28', i), 'checked': true},
          ],
        }),
      );

      final read = await cache.readMealPlans();
      expect(read, isNotNull);
      expect(read!.plans.map((plan) => plan.id), [_planId]);
      expect(read.checks, hasLength(2000 + kOutboxMaxOps));
      expect(
        read.checks.keys.where((id) => id.startsWith('2026-09-28')),
        hasLength(200),
      );
    });
  });
}
