import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/services/user_recipes_sync.dart';

// INT-2 / PROD-2: UserRecipesSync wird jetzt verdrahtet (Boot-Load + Create +
// Delete). Diese Tests verifizieren ueber die PUBLIC API (echter SupabaseClient
// + Mock-Client) das beobachtbare Persistenz-Verhalten.

UserRecipesSync _sync(
  Future<http.Response> Function(http.Request request) handler,
) {
  final client = SupabaseClient(
    'https://example.supabase.co',
    'test-anon-key',
    httpClient: MockClient((req) => handler(req)),
  );
  addTearDown(client.dispose);
  return UserRecipesSync(client, 'user-123');
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
  group('UserRecipesSync', () {
    test('upsert nutzt Konflikt-Schluessel user_id,slug + sendet user_id + slug',
        () async {
      String? prefer;
      Map<String, dynamic>? body;
      final sync = _sync((req) async {
        prefer = req.headers['Prefer'];
        final decoded = jsonDecode(req.body);
        body = (decoded is List ? decoded.first : decoded)
            as Map<String, dynamic>;
        return http.Response('', 201, request: req);
      });

      await sync.upsert(_recipe);

      expect(prefer, contains('resolution=merge-duplicates'));
      expect(body, containsPair('user_id', 'user-123'));
      expect(body, containsPair('slug', 'user_1717500000000'));
      expect(body, containsPair('title', 'Eigene Protein-Bowl'));
      expect(body, containsPair('calories_kcal', 600));
    });

    test('load liest Zeilen als FitnessRecipe (userCreated=true)', () async {
      final sync = _sync((req) async {
        final rows = [
          {
            'slug': 'user_1717500000000',
            'title': 'Eigene Protein-Bowl',
            'description': 'Eigenes Rezept',
            'portion': '1 Teller',
            'ingredients': 'Reis',
            'preparation': 'x',
            'image_asset': '',
            'calories_kcal': 600,
            'protein_g': 50,
            'carbs_g': 60,
            'fat_g': 15,
            'estimated_g': 400,
            'categories': ['Eigene'],
          },
        ];
        return http.Response(
          jsonEncode(rows),
          200,
          headers: const {'Content-Type': 'application/json'},
          request: req,
        );
      });

      final recipes = await sync.load();
      expect(recipes.length, 1);
      expect(recipes.first.slug, 'user_1717500000000');
      expect(recipes.first.title, 'Eigene Protein-Bowl');
      expect(recipes.first.caloriesKcal, 600);
      expect(recipes.first.userCreated, isTrue);
    });

    test('delete filtert auf slug + user_id', () async {
      String? method;
      String? url;
      final sync = _sync((req) async {
        method = req.method;
        url = req.url.toString();
        return http.Response('', 204, request: req);
      });

      await sync.delete('user_1717500000000');

      expect(method, 'DELETE');
      expect(url, contains('slug=eq.user_1717500000000'));
      expect(url, contains('user_id=eq.user-123'));
    });
  });
}
