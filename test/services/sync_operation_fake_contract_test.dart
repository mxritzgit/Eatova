import 'package:flutter_test/flutter_test.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/services/sync_operation_sync.dart';
import 'package:eatova/src/models/planned_meal.dart';
import 'package:eatova/src/models/logged_meal.dart';

import '../outbox/outbox_test_helpers.dart';

const _one = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _two = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const _three = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const _four = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
Map<String, dynamic> _request(
  String id,
  String kind,
  String entity,
  Map<String, dynamic> payload,
) => {
  'p_operation_id': id,
  'p_kind': kind,
  'p_entity_id': entity,
  'p_payload': payload,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'fixture keeps receipts immutable while replay exposes current entity deletion',
    () {
      final server = FakeServer();
      final insert = _request(_one, 'mealInsert', _three, {
        'row': {'id': _three, 'local_day': '2026-09-20'},
        'track_day': true,
      });
      final first = server.syncOperations.apply(insert);
      final originalEffect = first['result'];
      expect(SyncOperationReceipt.fromJson(first).entityDeleted, isFalse);
      server.syncOperations.apply(_request(_two, 'mealDelete', _three, {}));
      final replay = server.syncOperations.apply(insert);
      expect(replay['result'], originalEffect);
      expect(SyncOperationReceipt.fromJson(replay).entityDeleted, isTrue);
      expect(server.mealsCounted, 1);
      expect(server.mealRows, isEmpty);
      expect(
        server.syncOperations.receipts[_one]!.containsKey('current_state'),
        isFalse,
      );
    },
  );

  test(
    'fixture refuses reusing an operation identity with changed content',
    () {
      final server = FakeServer();
      final request = _request(_one, 'profileUpsert', 'self', {
        'row': {'weight_kg': 80},
      });
      server.syncOperations.apply(request);
      expect(
        () => server.syncOperations.apply(
          _request(_one, 'profileUpsert', 'self', {
            'row': {'weight_kg': 90},
          }),
        ),
        throwsA(
          isA<PostgrestException>().having(
            (error) => error.code,
            'SQLSTATE',
            '22023',
          ),
        ),
      );
      expect(server.profileRow!['weight_kg'], 80);
    },
  );

  test(
    'fixture recipe conflict preserves original revision and keeps current tombstones distinct',
    () {
      final server = FakeServer();
      final row = userRecipe('user_recipe').toRow();
      server.syncOperations.apply(
        _request(_one, 'recipeUpsert', 'user_recipe', {
          'recipe': row,
          'expected_revision': 0,
        }),
      );
      server.syncOperations.apply(
        _request(_two, 'recipeUpsert', 'user_recipe', {
          'recipe': {...row, 'title': 'Other device'},
          'expected_revision': 1,
        }),
      );
      final stale = _request(_three, 'recipeUpsert', 'user_recipe', {
        'recipe': {...row, 'title': 'Offline edit'},
        'expected_revision': 1,
      });
      final first = server.syncOperations.apply(stale);
      final outcome = SyncOperationReceipt.fromJson(first);
      expect(
        outcome.recipeMutation!.outcome,
        RecipeMutationOutcome.conflictSaved,
      );
      expect(outcome.currentRecipeState!.recipe!.title, 'Other device');
      expect(outcome.currentSavedRecipeState!.recipe!.title, 'Offline edit');
      server.syncOperations.apply(
        _request(_four, 'recipeDelete', 'user_recipe', {
          'expected_revision': 2,
        }),
      );
      final replay = server.syncOperations.apply(stale);
      expect(replay['result'], first['result']);
      expect(
        SyncOperationReceipt.fromJson(replay).currentRecipeState!.deleted,
        isTrue,
      );
      expect(
        SyncOperationReceipt.fromJson(
          replay,
        ).currentSavedRecipeState!.recipe!.title,
        'Offline edit',
      );
    },
  );

  test(
    'fixture uses current row existence for legacy direct deletes without fake tombstones',
    () {
      final server = FakeServer();
      final request = _request(_one, 'trainingHistoryInsert', _three, {
        'row': {'id': _three},
      });
      final first = server.syncOperations.apply(request);
      expect(SyncOperationReceipt.fromJson(first).entityDeleted, isFalse);
      server.syncOperations.trainingHistory.remove(_three);
      expect(
        SyncOperationReceipt.fromJson(
          server.syncOperations.apply(request),
        ).entityDeleted,
        isTrue,
      );
    },
  );

  test(
    'delete before first meal-plan conversion is terminal with no counter effect',
    () {
      final server = FakeServer();
      server.syncOperations.apply(_request(_one, 'mealDelete', _three, {}));
      final now = DateTime(2026, 9, 20, 12);
      final plan = PlannedMeal.create(
        recipe: userRecipe('user_plan'),
        day: now,
        slot: MealSlot.lunch,
        id: _three,
      ).copyWith(eatenAt: now);
      final response = server.syncOperations.apply(
        _request(_two, 'mealPlanConvert', _three, {
          'plan': plan.toJson(),
          'meal': serverMealRow(_three),
          'track_day': true,
        }),
      );
      final receipt = SyncOperationReceipt.fromJson(response);
      expect(receipt.mealPlanConversion!.created, isFalse);
      expect(receipt.mealPlanConversion!.meal, isNull);
      expect(receipt.convertedMealDeleted, isTrue);
      expect(receipt.plannedMeal!.isEaten, isTrue);
      expect(server.mealRows, isEmpty);
      expect(server.mealsCounted, 0);
      expect(server.trackedDay, isNull);
    },
  );

  test('unrelated receipt does not pretend to be a fresh stats response', () {
    final server = FakeServer();
    final response = server.syncOperations.apply(
      _request(_one, 'profileUpsert', 'self', {
        'row': {'weight_kg': 80},
      }),
    );
    expect(SyncOperationReceipt.fromJson(response).lifetimeStats, isNull);
  });
}
