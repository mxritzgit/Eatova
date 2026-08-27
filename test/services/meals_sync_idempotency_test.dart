import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/meals_sync.dart';

// INT-1 / DATA-4: insertLoggedMeal is an idempotent upsert(onConflict:'id'),
// so a retry after a timeout or a delete->undo rewrites the same row instead
// of failing on a duplicate. Verified through the public API:
//   1. upsert semantics (Prefer: resolution=merge-duplicates), not raw insert.
//   2. inserting the same id twice does not throw.
//   3. the body carries the client UUID as id (the conflict key).

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

LoggedMeal _meal(String id) => LoggedMeal(
      id: id,
      loggedAt: DateTime(2026, 6, 4, 12, 30),
      result: const MealAnalysisResult(
        mealName: 'Testmahlzeit',
        caloriesKcal: 500,
        estimatedGrams: 300,
        kcalPer100G: 166.7,
        protein: '30 g',
        carbs: '50 g',
        fat: '20 g',
        confidence: 'Hoch',
        portionNotes: 'Notiz',
      ),
    );

void main() {
  group('MealsSync.insertLoggedMeal Idempotenz (upsert onConflict:id)', () {
    test('nutzt Upsert-Semantik (resolution=merge-duplicates) statt rohem insert',
        () async {
      String? prefer;
      Map<String, dynamic>? body;
      final sync = _sync((req) async {
        prefer = req.headers['Prefer'];
        // PostgREST upsert sends an array of rows.
        final decoded = jsonDecode(req.body);
        body = (decoded is List ? decoded.first : decoded) as Map<String, dynamic>;
        return http.Response('', 201, request: req);
      });

      await sync.insertLoggedMeal(_meal('meal-abc'));

      expect(prefer, contains('resolution=merge-duplicates'));
      expect(body, containsPair('id', 'meal-abc'));
      expect(body, containsPair('user_id', 'user-123'));
    });

    test('zweimaliges Inserten derselben id wirft NICHT (Retry/Undo idempotent)',
        () async {
      var calls = 0;
      final sync = _sync((req) async {
        calls++;
        // The server resolves the conflict and succeeds: no 409, because of
        // onConflict:'id' + merge-duplicates.
        return http.Response('', 201, request: req);
      });

      final meal = _meal('meal-dup');
      await sync.insertLoggedMeal(meal); // first insert
      // Second insert of the same id (delete->undo or a retry) must not throw.
      await expectLater(sync.insertLoggedMeal(meal), completes);
      expect(calls, 2);
    });

    test('echter Server-Fehler (500) wird weiterhin durchgereicht', () async {
      // `request: req` is mandatory: postgrest dereferences
      // `response.request!` while building its exception, so a fake without it
      // throws a TypeError and the assertion below would test the mock.
      final sync = _sync((req) async => http.Response(
            jsonEncode({'message': 'permission denied'}),
            500,
            headers: const {'Content-Type': 'application/json'},
            request: req,
          ));

      // Narrow on purpose: `isA<Object>()` would also pass on a broken mock
      // (a TypeError from the handler), so it could not turn red for the
      // claim in the test name.
      await expectLater(
        sync.insertLoggedMeal(_meal('meal-fail')),
        throwsA(isA<PostgrestException>()),
      );
    });
  });
}
