import 'dart:convert';

import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/planned_meal.dart';
import 'package:eatova/src/services/meal_plans_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import '../services/user_rpc_test.dart' show signIn;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'authenticated conversion sends one stable atomic intent, then pins account',
    () async {
      final requests = <http.Request>[];
      final client = SupabaseClient(
        'https://ci.invalid',
        'ci-dummy-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          requests.add(request);
          final payload = jsonDecode(request.body) as Map;
          return http.Response(
            jsonEncode({
              'plan': payload['p_plan'],
              'meal': payload['p_meal'],
              'stats': {},
              'created': true,
            }),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }),
      );
      addTearDown(client.dispose);
      await signIn(client, 'account-A');
      final service = MealPlansSync(client, 'account-A');
      final plan = PlannedMeal.create(
        recipe: fitnessRecipes.first,
        day: DateTime(2026, 9, 12),
        slot: MealSlot.dinner,
        servings: 1.5,
      ).copyWith(eatenAt: DateTime(2026, 9, 10, 12));
      final meal = LoggedMeal(
        id: plan.id,
        result: plan.recipe.toMealResultForServings(1.5),
        loggedAt: DateTime(2026, 9, 10, 12),
        localDay: '2026-09-10',
        forcedSlot: plan.slot,
      );
      await service.convert(plan, meal, trackDay: true);
      expect(requests, hasLength(1));
      expect(requests.single.url.path, '/rest/v1/rpc/eat_planned_meal');
      expect(
        requests.single.headers['Authorization'],
        'Bearer fixture-account-A',
      );
      final payload = jsonDecode(requests.single.body) as Map;
      expect(payload['p_plan']['id'], meal.id);
      expect(payload['p_plan']['day'], '2026-09-12');
      expect(payload['p_meal']['local_day'], '2026-09-10');
      expect(payload['p_meal']['calories_kcal'], meal.result.caloriesKcal);
      expect(payload['p_track_day'], isTrue);
      await service.convert(plan, meal, trackDay: true);
      expect(requests[1].body, requests.first.body);
      await signIn(client, 'account-B');
      await expectLater(
        service.convert(plan, meal, trackDay: true),
        throwsA(isA<AuthException>()),
      );
      await expectLater(
        service.save(plan.copyWith()),
        throwsA(isA<AuthException>()),
      );
      await expectLater(
        service.check(
          ShoppingCheck(id: '2026-09-07:${'a' * 64}', checked: true),
        ),
        throwsA(isA<AuthException>()),
      );
      expect(requests, hasLength(2));
    },
  );

  test(
    'conversion rejects a mismatched diary identity before network IO',
    () async {
      final client = SupabaseClient(
        'https://ci.invalid',
        'ci-dummy-key',
        httpClient: MockClient(
          (_) async => throw StateError('Unexpected network'),
        ),
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      addTearDown(client.dispose);
      final plan = PlannedMeal.create(
        recipe: fitnessRecipes.first,
        day: DateTime(2026, 9, 12),
        slot: MealSlot.dinner,
      ).copyWith(eatenAt: DateTime(2026, 9, 10));
      final wrong = LoggedMeal(
        id: '00000000-0000-4000-8000-000000000001',
        result: fitnessRecipes.first.toMealResult(),
        loggedAt: DateTime(2026, 9, 10),
      );
      await expectLater(
        MealPlansSync(client, 'A').convert(plan, wrong, trackDay: true),
        throwsFormatException,
      );
    },
  );
}
