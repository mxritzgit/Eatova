import 'package:clock/clock.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/planned_meal.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/sync_outbox.dart';
import 'package:flutter_test/flutter_test.dart';

import '../outbox/outbox_test_helpers.dart' show mealResult;

const _owner = 'capacity-user';
final _now = DateTime.utc(2026, 9, 28, 12);

/// The oldest intents a head-dropping cap once had to protect or dropped
/// last: a meal-plan conversion, plan and check intents and the deletions.
List<SyncOp> _oldestIntents() {
  final plan = PlannedMeal.create(
    id: '7d000000-0000-4000-8000-000000000001',
    recipe: recipeCatalogDe.first,
    day: _now,
    slot: MealSlot.lunch,
  );
  final eaten = plan.copyWith(eatenAt: _now);
  final meal = LoggedMeal(
    id: plan.id,
    result: eaten.recipe.toMealResultForServings(1),
    loggedAt: _now,
  );
  return [
    SyncOp.mealPlanConvert(eaten, meal, trackDay: true),
    SyncOp.mealPlanUpsert(
      PlannedMeal.create(
        id: '7d000000-0000-4000-8000-000000000002',
        recipe: recipeCatalogDe.last,
        day: _now,
        slot: MealSlot.dinner,
      ),
    ),
    SyncOp.shoppingCheck(
      ShoppingCheck(id: '2026-09-28:${'b' * 64}', checked: true),
    ),
    SyncOp.trainingHistoryDelete('7d000000-0000-4000-8000-000000000003'),
    SyncOp.mealDelete('deleted-meal'),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a full queue rejects new saves and keeps its oldest intents intact',
    () async {
      await withClock(Clock.fixed(_now), () async {
        final cache = LocalCache(InMemoryKeyValueStore(), _owner);
        final oldest = _oldestIntents();
        await cache.commitSyncOperations(oldest);
        await cache.commitSyncOperations([
          for (var i = oldest.length; i < kOutboxMaxOps; i++)
            SyncOp.favoriteDelete('favorite-$i'),
        ]);
        final before = await cache.readSyncOperations();
        expect(before, hasLength(kOutboxMaxOps));

        await expectLater(
          cache.commitSyncOperations([
            SyncOp.mealInsert(
              LoggedMeal(
                id: 'one-too-many',
                result: mealResult('Too many'),
                loggedAt: _now,
              ),
              trackDay: false,
            ),
          ]),
          throwsStateError,
        );

        final after = await cache.readSyncOperations();
        expect(
          after.map((op) => op.operationId),
          before.map((op) => op.operationId),
        );
        expect(
          after.take(oldest.length).map((op) => op.kind),
          oldest.map((op) => op.kind),
        );
        final conversion = after.first;
        expect(conversion.plannedMeal!.isEaten, isTrue);
        expect(conversion.meal!.id, conversion.plannedMeal!.id);
        expect(
          (await cache.readLoggedMeals())!.map((meal) => meal.id),
          isNot(contains('one-too-many')),
        );
      });
    },
  );
}
