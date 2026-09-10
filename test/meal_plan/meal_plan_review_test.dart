import 'dart:async';
import 'dart:convert';
import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/planned_meal.dart';
import 'package:eatova/src/models/shopping_list.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/notification_service.dart';
import '../outbox/outbox_test_helpers.dart' as h;
import 'package:eatova/src/services/meals_sync.dart';

final now = DateTime(2026, 9, 10, 12);
PlannedMeal plan() => PlannedMeal.create(
  recipe: fitnessRecipes.first,
  day: now,
  slot: MealSlot.dinner,
);

Future<HomeStore> fixture(
  Future<http.Response> Function(http.Request) handler,
) async {
  final cache = LocalCache(InMemoryKeyValueStore(), 'A');
  await cache.writeProfile(const UserProfile(onboardingCompleted: true));
  final client = SupabaseClient(
    'https://ci.invalid',
    'ci-dummy-key',
    authOptions: const AuthClientOptions(autoRefreshToken: false),
    httpClient: MockClient(handler),
  );
  final store = HomeStore(
    sync: EatovaSync.forUser(client, 'A'),
    debugCache: cache,
    health: const NoopHealthService(),
    notificationService: const NoopNotificationService(),
    initialUserName: 'Fixture',
    emitSnack: h.SnackCapture().call,
  );
  addTearDown(() async {
    store.dispose();
    await client.dispose();
  });
  return store;
}

http.Response respond(http.Request req, Object? body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
  request: req,
);
http.Response defaults(http.Request req) => respond(
  req,
  req.url.path.endsWith('/profiles')
      ? null
      : req.url.path.endsWith('/lifetime_stats')
      ? {}
      : [],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'server-only plans must survive a save during the initial load',
    () async {
      await withClock(Clock.fixed(now), () async {
        final old = plan(), fresh = plan();
        final started = Completer<void>(), release = Completer<void>();
        final store = await fixture((req) async {
          if (req.url.path.endsWith('/rpc/load_meal_plan')) {
            started.complete();
            await release.future;
            return respond(req, {
              'plans': [old.toJson()],
              'checks': [],
            });
          }
          return defaults(req);
        });
        store.start();
        await started.future;
        await store.savePlannedMeal(fresh);
        release.complete();
        await h.pumpUntil(() => !store.mealPlansLoading);
        expect(store.mealPlansLoadFailed, isFalse);
        expect(store.plannedMeals.map((p) => p.id).toSet(), {old.id, fresh.id});
      });
    },
  );
  test(
    'eaten checked quantities must not check a new meal with the same amount',
    () {
      final recipe = fitnessRecipes.first.copyWith(
        ingredients: '',
        structuredIngredients: [
          RecipeIngredient(
            name: 'Oats',
            grams: 100,
            source: IngredientSource.manual,
            per100g: const RecipeNutrition(
              caloriesKcal: 100,
              proteinG: 10,
              carbsG: 15,
              fatG: 2,
            ),
          ),
        ],
      );
      final old = PlannedMeal.create(
        recipe: recipe,
        day: now,
        slot: MealSlot.lunch,
      );
      final fresh = PlannedMeal.create(
        recipe: recipe,
        day: now,
        slot: MealSlot.dinner,
      );
      final week = DateTime(2026, 9, 7);
      final checkedId = buildShoppingList([old], week).single.id;
      final freshId = buildShoppingList([
        old.copyWith(eatenAt: now),
        fresh,
      ], week).single.id;
      expect(freshId, isNot(checkedId));
    },
  );
  test(
    'a remote conversion receipt must replace a stale locally logged date',
    () async {
      await withClock(Clock.fixed(now), () async {
        final p = plan();
        final remoteReceipt = p.copyWith(eatenAt: DateTime(2026, 9, 9, 12));
        var reads = 0;
        final store = await fixture((req) async {
          if (req.url.path.endsWith('/rpc/load_meal_plan')) {
            return respond(req, {
              'plans': [(reads++ == 0 ? p : remoteReceipt).toJson()],
              'checks': [],
            });
          }
          if (req.url.path.endsWith('/rpc/eat_planned_meal')) {
            return respond(req, {
              'plan': remoteReceipt.toJson(),
              'created': false,
              'stats': {
                'meals_logged': 1,
                'current_streak': 3,
                'last_workout_date': '2026-09-09',
              },
              'meal': {
                'id': p.id,
                'logged_at': '2026-09-09T12:00:00',
                'local_day': '2026-09-09',
                'forced_slot': 'dinner',
                'payload': mealResultToJson(p.recipe.toMealResult()),
              },
            });
          }
          return defaults(req);
        });
        await h.bootUntilIdle(store);
        await h.pumpUntil(() => store.plannedMeals.isNotEmpty);
        await store.eatPlannedMeal(p.id);
        await store.retryMealPlans();
        expect(store.plannedMeals.single.eatenAt, remoteReceipt.eatenAt);
        expect(store.loggedMeals.single.effectiveLocalDay, '2026-09-09');
        expect(store.lifetimeStats.mealsLogged, 1);
        expect(store.lifetimeStats.currentStreak, 3);
      });
    },
  );
}
