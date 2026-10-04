import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:supabase/supabase.dart';

import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/services/user_recipes_sync.dart';

import '../outbox/outbox_test_helpers.dart' as h;

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
      await expectLater(env.sync.load(), throwsA(isA<AuthException>()));
      expect(server.requests, isEmpty);
    },
  );
}
