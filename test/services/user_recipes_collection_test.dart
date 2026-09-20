import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';
import 'package:eatova/src/services/user_recipes_sync.dart';

import '../support/recipe_read_fake.dart';

void main() {
  test(
    'public recipe loader returns the entire library beyond 200 rows',
    () async {
      final rows = List.generate(
        451,
        (i) => <String, dynamic>{
          'slug': 'user_${i.toString().padLeft(4, '0')}',
          'title': 'Recipe $i',
          'calories_kcal': 500,
          'created_at': '2026-09-20T12:00:00Z',
        },
      );
      final snapshots = RecipeReadFake();
      final client = SupabaseClient(
        'https://fixture.invalid',
        'fixture-anon',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          final Object response;
          if (request.url.path.endsWith('/rpc/load_recipe_page')) {
            response = snapshots.page(request, rows);
          } else {
            expect(request.url.path, endsWith('/user_recipes'));
            expect(request.url.queryParameters['user_id'], 'eq.user-a');
            response = rows
                .take(int.parse(request.url.queryParameters['limit']!))
                .toList();
          }
          return http.Response(
            jsonEncode(response),
            200,
            request: request,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      addTearDown(client.dispose);
      final loaded = await UserRecipesSync(client, 'user-a').load();
      expect(loaded, hasLength(451));
      expect(loaded.map((recipe) => recipe.slug).toSet(), hasLength(451));
      expect(loaded.last.title, 'Recipe 450');
      expect(snapshots.pageCalls, 3);
    },
  );
}
