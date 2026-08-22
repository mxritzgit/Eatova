import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/models/favorite_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/meals_sync.dart';

// INT-2 / PROD-4: favorite_meals separates pinned favorites from auto-recents
// (pinned=false). These tests verify through the PUBLIC API that the pinned
// flag round-trips: upsertFavorite writes it, loadFavorites reads it back
// (missing column/null -> false).

MealsSync _sync(
  Future<http.Response> Function(http.Request request) handler,
) {
  final client = SupabaseClient(
    'https://example.supabase.co',
    'test-anon-key',
    httpClient: MockClient((req) => handler(req)),
  );
  addTearDown(client.dispose);
  return MealsSync(client, 'user-123');
}

const _result = MealAnalysisResult(
  mealName: 'Protein-Bowl',
  caloriesKcal: 420,
  estimatedGrams: 300,
  kcalPer100G: 140,
  protein: '35 g',
  carbs: '40 g',
  fat: '12 g',
  confidence: 'Hoch',
  portionNotes: 'Notiz',
);

void main() {
  group('MealsSync favorite pinned round-trip', () {
    test('upsertFavorite schreibt pinned=true mit', () async {
      Map<String, dynamic>? body;
      final sync = _sync((req) async {
        final decoded = jsonDecode(req.body);
        body = (decoded is List ? decoded.first : decoded)
            as Map<String, dynamic>;
        return http.Response('', 201, request: req);
      });

      await sync.upsertFavorite(FavoriteMeal(
        id: 'name:protein-bowl',
        result: _result,
        addedAt: DateTime(2026, 6, 4, 12, 0),
        pinned: true,
      ));

      expect(body, containsPair('favorite_key', 'name:protein-bowl'));
      expect(body, containsPair('pinned', true));
    });

    test('upsertFavorite schreibt pinned=false fuer Auto-Recents', () async {
      Map<String, dynamic>? body;
      final sync = _sync((req) async {
        final decoded = jsonDecode(req.body);
        body = (decoded is List ? decoded.first : decoded)
            as Map<String, dynamic>;
        return http.Response('', 201, request: req);
      });

      await sync.upsertFavorite(FavoriteMeal(
        id: 'name:protein-bowl',
        result: _result,
        addedAt: DateTime(2026, 6, 4, 12, 0),
      ));

      expect(body, containsPair('pinned', false));
    });

    test('loadFavorites liest pinned zurueck (true und fehlend->false)',
        () async {
      final sync = _sync((req) async {
        final rows = [
          {
            'favorite_key': 'name:pinned-one',
            'added_at': '2026-06-04T12:00:00Z',
            'pinned': true,
            'payload': mealResultToJson(_result),
          },
          {
            'favorite_key': 'name:recent-one',
            'added_at': '2026-06-03T12:00:00Z',
            'pinned': false,
            'payload': mealResultToJson(_result),
          },
        ];
        return http.Response(
          jsonEncode(rows),
          200,
          headers: const {'Content-Type': 'application/json'},
          request: req,
        );
      });

      final favorites = await sync.loadFavorites();
      expect(favorites.length, 2);
      expect(favorites.firstWhere((f) => f.id == 'name:pinned-one').pinned,
          isTrue);
      expect(favorites.firstWhere((f) => f.id == 'name:recent-one').pinned,
          isFalse);
    });
  });
}
