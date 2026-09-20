import 'dart:convert';

import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/sync_operation_sync.dart';
import 'package:eatova/src/services/sync_outbox.dart';
import 'package:eatova/src/services/user_recipes_sync.dart';
import 'package:eatova/src/services/uuid.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const owner = '71000000-0000-4000-8000-000000000001';
const mealId = '72000000-0000-4000-8000-000000000001';
const recipe = FitnessRecipe(
  slug: 'user_example',
  title: 'Recipe',
  description: '',
  portion: '',
  ingredients: '',
  preparation: '',
  professionalHint: '',
  imageAsset: '',
  caloriesKcal: 100,
  proteinG: 10,
  carbsG: 10,
  fatG: 2,
  estimatedGrams: 100,
  categories: ['Eigene'],
  userCreated: true,
  serverRevision: 8,
);

SupabaseClient client(Future<http.Response> Function(http.Request) handler) {
  final value = SupabaseClient(
    'https://ci.invalid',
    'ci-dummy-key',
    httpClient: MockClient(handler),
  );
  addTearDown(value.dispose);
  return value;
}

Map<String, dynamic> mutation({
  String outcome = 'applied',
  String? savedSlug,
  bool deleted = false,
}) => {
  'outcome': outcome,
  'current_revision': 9,
  'current_deleted': deleted,
  'current_recipe': deleted ? null : recipe.copyWith(serverRevision: 9).toRow(),
  'saved_recipe': deleted
      ? null
      : recipe.copyWith(slug: savedSlug, serverRevision: 9).toRow(),
};

http.Response response(
  http.Request request,
  Map<String, dynamic> result, {
  String? operationId,
  String? entityId,
  Map<String, dynamic>? currentState,
}) {
  final body = jsonDecode(request.body) as Map<String, dynamic>;
  final mutation = result['recipe_mutation'] as Map?;
  final saved = mutation?['saved_recipe'] as Map?;
  final state =
      currentState ??
      {
        if (result['lifetime_stats'] != null)
          'lifetime_stats': result['lifetime_stats'],
        if (mutation != null)
          'recipe': {
            'slug': body['p_entity_id'],
            'revision': mutation['current_revision'],
            'deleted': mutation['current_deleted'],
            'recipe': mutation['current_recipe'],
          },
        if (saved != null)
          'saved_recipe': {
            'slug': saved['slug'],
            'revision': saved['server_revision'],
            'deleted': false,
            'recipe': saved,
          },
      };
  return http.Response(
    jsonEncode({
      'operation_id': operationId ?? body['p_operation_id'],
      'kind': body['p_kind'],
      'entity_id': entityId ?? body['p_entity_id'],
      'result': result,
      'current_state': state,
    }),
    200,
    headers: {'content-type': 'application/json'},
    request: request,
  );
}

void main() {
  test('recipe base revision survives cache roundtrip and editor copy', () {
    final edited = FitnessRecipe.fromRow(
      recipe.toRow(),
    ).copyWith(title: 'Edited');
    expect(edited.serverRevision, 8);
    final legacy = Map<String, dynamic>.of(recipe.toRow())
      ..remove('server_revision');
    expect(FitnessRecipe.fromRow(legacy).serverRevision, isNull);
    expect(
      FitnessRecipe.fromRow({...legacy, 'server_revision': 0}).serverRevision,
      0,
    );
    for (final invalid in [-1, 2.5, '8']) {
      expect(
        () => FitnessRecipe.fromRow({...legacy, 'server_revision': invalid}),
        throwsFormatException,
      );
    }
  });

  test('new recipe slugs use independent UUID identities', () {
    final slugs = {
      for (var i = 0; i < 100; i++) FitnessRecipe.userRecipeSlug(),
    };
    expect(slugs, hasLength(100));
    expect(
      slugs.every(
        (slug) => slug.startsWith('user_') && isUuidShape(slug.substring(5)),
      ),
      isTrue,
    );
  });

  test(
    'recipe request pins immutable operation identity and expected revision',
    () async {
      final operation = SyncOp.recipeUpsert(recipe, expectedRevision: 8);
      final requests = <Map<String, dynamic>>[];
      final service = SyncOperationSync(
        client((request) async {
          expect(request.url.path, '/rest/v1/rpc/apply_sync_operation');
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          requests.add(body);
          expect(body['p_payload'], {
            'recipe': recipe.toRow(),
            'expected_revision': 8,
          });
          expect(body, isNot(contains('user_id')));
          return response(request, {'recipe_mutation': mutation()});
        }),
        owner,
      );
      final first = await service.apply(operation);
      final second = await service.apply(operation);
      expect(requests[0], requests[1]);
      expect(first.operationId, operation.operationId);
      expect(second.recipeMutation!.savedRecipe!.serverRevision, 9);
    },
  );

  test(
    'restarted retry sends the frozen wire body despite changed model encoding',
    () async {
      final operation = SyncOp.recipeUpsert(recipe, expectedRevision: 8);
      final frozen = <String, dynamic>{
        'recipe': recipe.copyWith(title: 'Encoded before restart').toRow(),
        'expected_revision': 8,
      };
      final persisted = operation.freezeWirePayload(frozen);
      // Cache roundtrip and a retry must preserve the original fingerprint.
      final restarted = SyncOp.tryFromJson(
        jsonDecode(jsonEncode(persisted.incrementAttempt().toJson()))
            as Map<String, dynamic>,
      )!;
      expect(restarted.operationId, operation.operationId);
      expect(restarted.wireSchema, 1);
      expect(restarted.payload, operation.payload);
      var requests = 0;
      final service = SyncOperationSync(
        client((request) async {
          requests++;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['p_operation_id'], operation.operationId);
          expect(body['p_payload'], frozen);
          return response(request, {'recipe_mutation': mutation()});
        }),
        owner,
      );
      await service.apply(restarted);
      await service.apply(restarted.incrementAttempt());
      expect(requests, 2);
    },
  );

  test(
    'typed conflict receipt preserves deterministic copy and canonical recipe',
    () async {
      final operation = SyncOp.recipeUpsert(recipe, expectedRevision: 8);
      final slug = 'user_conflict_${operation.operationId}';
      final service = SyncOperationSync(
        client(
          (request) async => response(request, {
            'recipe_mutation': mutation(
              outcome: 'conflictSaved',
              savedSlug: slug,
            ),
          }),
        ),
        owner,
      );
      final receipt = await service.apply(operation);
      expect(
        receipt.recipeMutation!.outcome,
        RecipeMutationOutcome.conflictSaved,
      );
      expect(receipt.recipeMutation!.savedRecipe!.slug, slug);
      expect(receipt.recipeMutation!.currentRecipe!.slug, recipe.slug);
    },
  );

  test(
    'old effect preserves rebase revision while current tombstone prevents resurrection',
    () async {
      final operation = SyncOp.recipeUpsert(recipe, expectedRevision: 8);
      final service = SyncOperationSync(
        client(
          (request) async => response(
            request,
            {'recipe_mutation': mutation()},
            currentState: {
              'recipe': {
                'slug': recipe.slug,
                'revision': 12,
                'deleted': true,
                'recipe': null,
              },
              'saved_recipe': {
                'slug': recipe.slug,
                'revision': 12,
                'deleted': true,
                'recipe': null,
              },
            },
          ),
        ),
        owner,
      );
      final receipt = await service.apply(operation);
      expect(receipt.recipeMutation!.savedRecipe!.serverRevision, 9);
      expect(receipt.currentRecipeState!.revision, 12);
      expect(receipt.currentSavedRecipeState!.deleted, isTrue);
      expect(receipt.currentSavedRecipeState!.recipe, isNull);
    },
  );

  test('wrong operation or recipe identities are never acknowledged', () async {
    final operation = SyncOp.recipeUpsert(recipe, expectedRevision: 8);
    for (final wrong in ['operation', 'entity', 'saved']) {
      final service = SyncOperationSync(
        client(
          (request) async => response(
            request,
            {
              'recipe_mutation': mutation(
                savedSlug: wrong == 'saved' ? 'user_foreign' : null,
              ),
            },
            operationId: wrong == 'operation' ? uuidV4() : null,
            entityId: wrong == 'entity' ? 'user_foreign' : null,
          ),
        ),
        owner,
      );
      await expectLater(service.apply(operation), throwsFormatException);
    }
  });

  test(
    'missing RPC produces one failure without an unversioned fallback',
    () async {
      var count = 0;
      final operation = SyncOp.recipeUpsert(recipe, expectedRevision: 8);
      final service = SyncOperationSync(
        client((request) async {
          count++;
          expect(request.url.path, '/rest/v1/rpc/apply_sync_operation');
          return http.Response(
            jsonEncode({'code': 'PGRST202', 'message': 'RPC unavailable'}),
            404,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }),
        owner,
      );
      await expectLater(
        service.apply(operation),
        throwsA(isA<PostgrestException>()),
      );
      expect(count, 1);
    },
  );

  test('capacity failures expose a sanitized typed blocked reason', () async {
    for (final capacity in {
      'EX_RECIPE_HISTORY_CAPACITY': SyncCapacityKind.recipeHistory,
      'EX_SYNC_RECEIPT_CAPACITY': SyncCapacityKind.operationReceipts,
    }.entries) {
      final service = SyncOperationSync(
        client(
          (request) async => http.Response(
            jsonEncode({'code': 'PT507', 'message': capacity.key}),
            507,
            headers: {'content-type': 'application/json'},
            request: request,
          ),
        ),
        owner,
      );
      await expectLater(
        service.apply(SyncOp.recipeDelete(recipe.slug, expectedRevision: 8)),
        throwsA(
          isA<SyncCapacityException>()
              .having((error) => error.kind, 'kind', capacity.value)
              .having(
                (error) => error.toString(),
                'safe diagnostic',
                'Sync storage capacity reached',
              ),
        ),
      );
    }
  });

  test(
    'meal transport sends normalized row and tracking flag in one operation',
    () async {
      final meal = LoggedMeal(
        id: mealId,
        loggedAt: DateTime(2026, 9, 19, 12),
        localDay: '2026-09-19',
        forcedSlot: MealSlot.lunch,
        result: const MealAnalysisResult(
          mealName: 'Bowl',
          caloriesKcal: 100,
          estimatedGrams: 100,
          kcalPer100G: 100,
          protein: '10,5 g',
          carbs: '12 g',
          fat: '3 g',
          confidence: '',
          portionNotes: '',
          items: [],
          sourceLabel: 'manual',
        ),
      );
      final operation = SyncOp.mealInsert(meal, trackDay: true);
      final service = SyncOperationSync(
        client((request) async {
          final body = jsonDecode(request.body) as Map;
          final payload = body['p_payload'] as Map;
          expect(payload['track_day'], isTrue);
          final row = payload['row'] as Map;
          expect(row['id'], mealId);
          expect(row['local_day'], '2026-09-19');
          expect(row['protein_g'], 10.5);
          expect(row, isNot(contains('user_id')));
          return response(request, {
            'lifetime_stats': {'meals_logged': 1, 'weight_logs': 0},
          });
        }),
        owner,
      );
      expect((await service.apply(operation)).lifetimeStats!.mealsLogged, 1);
    },
  );

  test('missing required effect receipt fails closed', () async {
    final service = SyncOperationSync(
      client((request) async => response(request, {})),
      owner,
    );
    await expectLater(
      service.apply(SyncOp.recipeUpsert(recipe, expectedRevision: 8)),
      throwsFormatException,
    );
    await expectLater(
      service.apply(SyncOp.statsIncrement(requestId: mealId, meals: 1)),
      throwsFormatException,
    );
  });

  test('recipe write convenience service shares the guarded RPC', () async {
    final id = uuidV4();
    final service = UserRecipesSync(
      client((request) async {
        final body = jsonDecode(request.body) as Map;
        expect(body['p_operation_id'], id);
        expect(body['p_payload']['expected_revision'], 8);
        return response(request, {'recipe_mutation': mutation(deleted: true)});
      }),
      owner,
    );
    final result = await service.delete(
      recipe.slug,
      operationId: id,
      expectedRevision: 8,
    );
    expect(result.currentDeleted, isTrue);
    expect(result.currentRevision, 9);
  });
}
