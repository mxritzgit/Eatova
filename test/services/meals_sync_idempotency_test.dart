import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/meals_sync.dart';

// INT-1 / DATA-4: insertLoggedMeal ist ein idempotenter upsert(onConflict:'id').
// Folge: ein Retry nach unklarem Netzwerk-Timeout ODER ein delete→undo
// (_restoreLoggedMeal re-insertet dieselbe id) erzeugt KEINEN Duplikat-Fehler
// mehr, sondern schreibt dieselbe Zeile erneut und kehrt still zurueck.
//
// Diese Tests verifizieren ueber die PUBLIC API (echter SupabaseClient + Mock-
// Client) das beobachtbare Verhalten:
//   1. Der Write nutzt Upsert-Semantik (Prefer: resolution=merge-duplicates),
//      nicht ein rohes insert (das bei Konflikt 409 wuerfe).
//   2. Zweimaliges Inserten derselben id wirft NICHT (idempotent).
//   3. Der Body traegt die Client-UUID als id (Konflikt-Schluessel).

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
        // PostgREST upsert sendet ein Array von Zeilen.
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
        // Der Server loest den Konflikt auf und antwortet erfolgreich — KEIN
        // 409, weil onConflict:'id' + merge-duplicates. (Ein rohes insert wuerde
        // hier 409 zurueckgeben und insertLoggedMeal wuerde rethrowen.)
        return http.Response('', 201, request: req);
      });

      final meal = _meal('meal-dup');
      await sync.insertLoggedMeal(meal); // erster Insert
      // Zweiter Insert derselben id (z.B. delete→undo via _restoreLoggedMeal
      // oder ein Retry nach Timeout) darf NICHT werfen.
      await expectLater(sync.insertLoggedMeal(meal), completes);
      expect(calls, 2);
    });

    test('echter Server-Fehler (500) wird weiterhin durchgereicht', () async {
      final sync = _sync((req) async => http.Response(
            jsonEncode({'message': 'permission denied'}),
            500,
            headers: const {'Content-Type': 'application/json'},
          ));

      await expectLater(
        sync.insertLoggedMeal(_meal('meal-fail')),
        throwsA(isA<Object>()),
      );
    });
  });
}
