import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/meals_sync.dart';
import 'package:eatova/src/services/sync_outbox.dart';

// Sentinel S1: `mealResultFromJson` filled a missing/unreadable `caloriesKcal`
// with 0 WITHOUT explicitZeroKcal — indistinguishable from a measured 0, and it
// reached the daily balance, the diary and, via outbox replay, the server.
//
// New contract:
//  * `caloriesKcal` is REQUIRED in the payload; missing or unreadable =>
//    FormatException. The catchers are already honest: SyncOp.meal catches it
//    to null => replay throws _CorruptOpPayload => drop with message (A8);
//    LocalCache.readLoggedMeals catches it => slot unreadable => the server
//    boot supplies the truth.
//  * `estimatedGrams`/`kcalPer100G` keep 0 as this model's documented unknown
//    form (see meal_analysis_hardening_test).
//  * A REAL 0 with explicitZeroKcal round-trips unchanged (B7).
//  * Server rows with a broken payload are SKIPPED on load and reported: one
//    bad row must not block the whole diary.

Map<String, dynamic> _payloadOhne(String key) {
  final json = mealResultToJson(const MealAnalysisResult(
    mealName: 'Bowl',
    caloriesKcal: 500,
    estimatedGrams: 400,
    kcalPer100G: 125,
    protein: '30 g',
    carbs: '40 g',
    fat: '10 g',
    confidence: 'Hoch',
    portionNotes: 'Test.',
  ));
  json.remove(key);
  return json;
}

void main() {
  group('mealResultFromJson', () {
    test('fehlendes caloriesKcal wirft statt eine 0-kcal-Mahlzeit zu bauen',
        () {
      expect(() => mealResultFromJson(_payloadOhne('caloriesKcal')),
          throwsFormatException);
    });

    test('unlesbares caloriesKcal (String-Muell) wirft ebenfalls', () {
      final json = _payloadOhne('caloriesKcal');
      json['caloriesKcal'] = 'kaputt';
      expect(() => mealResultFromJson(json), throwsFormatException);
    });

    test('die gemessene 0 (B7) roundtrippt unveraendert', () {
      final json = mealResultToJson(const MealAnalysisResult(
        mealName: 'Wasser',
        caloriesKcal: 0,
        estimatedGrams: 500,
        kcalPer100G: 0,
        protein: '0 g',
        carbs: '0 g',
        fat: '0 g',
        confidence: 'Hoch',
        portionNotes: 'still',
        explicitZeroKcal: true,
      ));
      final back = mealResultFromJson(json);
      expect(back.caloriesKcal, 0);
      expect(back.explicitZeroKcal, isTrue);
    });

    test('fehlende Gramm/Dichte bleiben 0 = unbekannt (dokumentierte Form)',
        () {
      final json = _payloadOhne('estimatedGrams')..remove('kcalPer100G');
      final back = mealResultFromJson(json);
      expect(back.caloriesKcal, 500);
      expect(back.estimatedGrams, 0);
      expect(back.kcalPer100G, 0);
    });
  });

  test('SyncOp.meal faengt den Wurf zu null — der Replay-Drop-Pfad greift',
      () {
    final meal = LoggedMeal(
      id: 'm-1',
      result: const MealAnalysisResult(
        mealName: 'Bowl',
        caloriesKcal: 500,
        estimatedGrams: 400,
        kcalPer100G: 125,
        protein: '30 g',
        carbs: '40 g',
        fat: '10 g',
        confidence: 'Hoch',
        portionNotes: 'Test.',
      ),
      loggedAt: DateTime(2026, 8, 8, 12),
    );
    final op = SyncOp.mealInsert(meal, trackDay: false);
    final raw = op.toJson();
    ((raw['payload'] as Map)['meal'] as Map)
        .cast<String, dynamic>()['result'] = <String, dynamic>{
      'mealName': 'Bowl',
      // caloriesKcal missing -> corrupt.
    };
    final corrupt = SyncOp.tryFromJson(raw)!;

    expect(corrupt.meal, isNull,
        reason: 'null routet den Replay in _CorruptOpPayload -> Drop mit '
            'Meldung statt calories_kcal: 0 auf den Server zu schreiben');
  });

  test(
      'loadLoggedMeals ueberspringt eine kaputte Server-Zeile statt das '
      'ganze Tagebuch am Laden zu hindern', () async {
    final rows = <Map<String, dynamic>>[
      {
        'id': 'm-gut',
        'logged_at': DateTime(2026, 8, 8, 12).toUtc().toIso8601String(),
        'forced_slot': null,
        'local_day': null,
        'payload': mealResultToJson(const MealAnalysisResult(
          mealName: 'Gute Bowl',
          caloriesKcal: 400,
          estimatedGrams: 350,
          kcalPer100G: 114,
          protein: '30 g',
          carbs: '40 g',
          fat: '10 g',
          confidence: 'Hoch',
          portionNotes: 'ok',
        )),
      },
      {
        'id': 'm-kaputt',
        'logged_at': DateTime(2026, 8, 8, 13).toUtc().toIso8601String(),
        'forced_slot': null,
        'local_day': null,
        'payload': <String, dynamic>{'mealName': 'Geist'},
      },
    ];
    final client = SupabaseClient(
      'https://example.supabase.co',
      'test-anon-key',
      httpClient: MockClient((req) async => http.Response(
            jsonEncode(rows),
            200,
            headers: const {'Content-Type': 'application/json'},
            request: req,
          )),
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );

    final meals = await MealsSync(client, 'user-1').loadLoggedMeals();

    expect(meals.map((m) => m.id), ['m-gut'],
        reason: 'die kaputte Zeile faellt (und wird gemeldet), die gute '
            'bleibt — ein Voll-Fehlschlag wuerde das Tagebuch dauerhaft '
            'auf dem Cache-Stand einfrieren');
  });
}
