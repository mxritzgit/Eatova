import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/services/user_recipes_sync.dart';

import '../outbox/outbox_test_helpers.dart' as h;

const _operation = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _deletion = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

({UserRecipesSync sync, SupabaseClient client}) _sync(http.Client transport) {
  final client = SupabaseClient(
    'https://ci.invalid',
    'ci-dummy-key',
    httpClient: transport,
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  addTearDown(client.dispose);
  return (sync: UserRecipesSync(client, 'user-outbox'), client: client);
}

const _recipe = FitnessRecipe(
  slug: 'user_1717500000000',
  title: 'Eigene Protein-Bowl',
  description: 'Eigenes Rezept',
  portion: '1 Teller',
  ingredients: 'Reis\nHaehnchen',
  preparation: 'Eigenes Rezept — keine Zubereitung hinterlegt.',
  professionalHint: 'Selbst angelegt. Werte beruhen auf deinen Angaben.',
  imageAsset: '',
  caloriesKcal: 600,
  proteinG: 50,
  carbsG: 60,
  fatG: 15,
  estimatedGrams: 400,
  categories: <String>['Eigene'],
  userCreated: true,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'upsert sends exact intent, immutable UUID and observed revision to owner RPC',
    () async {
      final server = h.FakeServer();
      final env = _sync(server.client());
      final result = await env.sync.upsert(
        _recipe,
        operationId: _operation,
        expectedRevision: 0,
      );
      final request = server.operations('recipeUpsert').single;
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(request.method, 'POST');
      expect(request.url.path, '/rest/v1/rpc/apply_sync_operation');
      expect(body['p_operation_id'], _operation);
      expect(body['p_entity_id'], _recipe.slug);
      expect(body['p_payload']['expected_revision'], 0);
      expect(body['p_payload']['recipe'], containsPair('title', _recipe.title));
      expect(body['p_payload']['recipe'], containsPair('calories_kcal', 600));
      expect(
        body['p_payload']['recipe'].containsKey('user_id'),
        isFalse,
        reason: 'The server derives owner from its authenticated JWT.',
      );
      expect(result.outcome, RecipeMutationOutcome.applied);
      expect(result.savedRecipe?.serverRevision, 1);
      await env.sync.upsert(
        _recipe,
        operationId: _operation,
        expectedRevision: 0,
      );
      expect(server.recipeRows, hasLength(1));
      expect(server.syncOperations.recipeHeads[_recipe.slug], 1);
    },
  );

  test('load uses a bounded snapshot and parses own recipe revision', () async {
    final server = h.FakeServer()
      ..recipeRows[_recipe.slug] = {..._recipe.toRow(), 'server_revision': 7};
    final env = _sync(server.client());
    final recipes = await env.sync.load();
    expect(recipes, hasLength(1));
    expect(recipes.single.slug, _recipe.slug);
    expect(recipes.single.title, _recipe.title);
    expect(recipes.single.caloriesKcal, 600);
    expect(recipes.single.userCreated, isTrue);
    expect(recipes.single.serverRevision, 7);
    final read = server.requests.single;
    expect(read.url.path, '/rest/v1/rpc/load_recipe_page');
    expect(jsonDecode(read.body), {
      'p_watermark': null,
      'p_after_slug': null,
      'p_limit': 200,
    });
  });

  test(
    'delete sends observed revision and receives a committed tombstone',
    () async {
      final server = h.FakeServer();
      final env = _sync(server.client());
      final saved = await env.sync.upsert(
        _recipe,
        operationId: _operation,
        expectedRevision: 0,
      );
      final result = await env.sync.delete(
        _recipe.slug,
        operationId: _deletion,
        expectedRevision: saved.currentRevision,
      );
      final body = jsonDecode(server.operations('recipeDelete').single.body);
      expect(body, {
        'p_operation_id': _deletion,
        'p_kind': 'recipeDelete',
        'p_entity_id': _recipe.slug,
        'p_payload': {'expected_revision': 1},
      });
      expect(result.outcome, RecipeMutationOutcome.applied);
      expect(result.currentDeleted, isTrue);
      expect(result.currentRevision, 2);
      expect(server.recipeRows, isEmpty);
    },
  );

  test(
    'missing revision RPC fails without falling back to unversioned table writes',
    () async {
      final requests = <http.Request>[];
      final env = _sync(
        MockClient((request) async {
          requests.add(request);
          return http.Response(
            jsonEncode({'code': 'PGRST202', 'message': 'Function missing'}),
            404,
            request: request,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      await expectLater(
        env.sync.upsert(_recipe, operationId: _operation, expectedRevision: 0),
        throwsA(isA<Exception>()),
      );
      expect(requests, hasLength(1));
      expect(requests.single.url.path, '/rest/v1/rpc/apply_sync_operation');
    },
  );

  test(
    'stale writer returns a recoverable conflict instead of overwriting',
    () async {
      final server = h.FakeServer();
      final env = _sync(server.client());
      await env.sync.upsert(
        _recipe,
        operationId: _operation,
        expectedRevision: 0,
      );
      final result = await env.sync.upsert(
        _recipe.copyWith(title: 'Other device'),
        operationId: _deletion,
        expectedRevision: 0,
      );
      expect(result.outcome, RecipeMutationOutcome.conflictSaved);
      expect(result.currentRecipe?.title, _recipe.title);
      expect(result.savedRecipe?.title, 'Other device');
      expect(result.savedRecipe?.conflictOf, _recipe.slug);
      expect(server.recipeRows, hasLength(2));
    },
  );

  test('mismatched receipt identity cannot acknowledge a write', () async {
    final server = h.FakeServer();
    final env = _sync(
      MockClient((request) async {
        final response = server.syncOperations.apply(jsonDecode(request.body));
        response['operation_id'] = _deletion;
        return http.Response(
          jsonEncode(response),
          200,
          request: request,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    await expectLater(
      env.sync.upsert(_recipe, operationId: _operation, expectedRevision: 0),
      throwsFormatException,
    );
  });

  test(
    'another signed-in owner is rejected before any recipe request',
    () async {
      final server = h.FakeServer();
      final env = _sync(server.client());
      await env.client.auth.setInitialSession(
        jsonEncode({
          'access_token': 'synthetic-other',
          'refresh_token': 'synthetic-refresh',
          'token_type': 'bearer',
          'expires_in': 3600,
          'user': {
            'id': 'other',
            'aud': 'authenticated',
            'created_at': '2026-09-20T00:00:00Z',
            'app_metadata': <String, dynamic>{},
            'user_metadata': <String, dynamic>{},
          },
        }),
      );
      await expectLater(
        env.sync.upsert(_recipe, operationId: _operation, expectedRevision: 0),
        throwsA(isA<AuthException>()),
      );
      await expectLater(env.sync.load(), throwsA(isA<AuthException>()));
      await expectLater(
        env.sync.delete(
          _recipe.slug,
          operationId: _deletion,
          expectedRevision: 1,
        ),
        throwsA(isA<AuthException>()),
      );
      expect(server.requests, isEmpty);
    },
  );
}
