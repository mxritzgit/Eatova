import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/planned_meal.dart';
import 'package:eatova/src/models/shopping_list.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/recipes/meal_plan_screen.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/services/sync_outbox.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import '../outbox/outbox_test_helpers.dart' as h;
import '../support/harness.dart';

final today = DateTime(2026, 9, 10, 12);
FitnessRecipe recipe({
  List<RecipeIngredient> ingredients = const [],
  double batch = 1,
}) => fitnessRecipes.first.copyWith(
  title: 'Oats',
  ingredients: ingredients.isEmpty ? '100 g oats\nMilk to taste' : '',
  structuredIngredients: ingredients,
  batchServings: batch,
);
RecipeIngredient oats(
  double grams, {
  IngredientSource source = IngredientSource.manual,
}) => RecipeIngredient(
  name: 'Oats',
  grams: grams,
  source: source,
  per100g: const RecipeNutrition(
    caloriesKcal: 100,
    proteinG: 10,
    carbsG: 15,
    fatG: 2,
  ),
);
PlannedMeal plan({FitnessRecipe? value, double servings = 1, String? id}) =>
    PlannedMeal.create(
      recipe: value ?? recipe(),
      day: DateTime(2026, 9, 12),
      slot: MealSlot.dinner,
      servings: servings,
      id: id,
    );

class _Fixture {
  _Fixture({InMemoryKeyValueStore? raw, String user = 'A', LocalCache? cache}) {
    this.cache = cache ?? LocalCache(raw ?? InMemoryKeyValueStore(), user);
    client = SupabaseClient(
      'https://ci.invalid',
      'ci-dummy-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        if (offline) throw http.ClientException('offline');
        if (request.url.path.endsWith('/rpc/load_meal_plan')) {
          return http.Response(
            jsonEncode({'plans': [], 'checks': []}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(
          request.url.path.endsWith('/profiles')
              ? 'null'
              : request.url.path.endsWith('/lifetime_stats')
              ? '{}'
              : '[]',
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    store = HomeStore(
      sync: EatovaSync.forUser(client, user),
      debugCache: this.cache,
      health: const NoopHealthService(),
      notificationService: const NoopNotificationService(),
      initialUserName: 'Fixture',
      emitSnack: h.SnackCapture().call,
    );
    addTearDown(() async {
      dispose();
      await client.dispose();
    });
  }
  late final HomeStore store;
  late final SupabaseClient client;
  late final LocalCache cache;
  bool offline = true;
  bool _disposed = false;
  void dispose() {
    if (!_disposed) {
      _disposed = true;
      store.dispose();
    }
  }

  Future<void> boot() async {
    await cache.writeProfile(const UserProfile(onboardingCompleted: true));
    await h.bootUntilIdle(store);
  }

  Future<void> settle() async {
    await cache.flush();
    await cache.settle();
    await h.settle();
  }
}

class _BrokenCache extends LocalCache {
  _BrokenCache() : super(InMemoryKeyValueStore(), 'A');
  @override
  Future<bool> writeOutbox(List<SyncOp> ops) async => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('snapshot preserves original recipe and rejects malformed plans', () {
    final source = recipe();
    final saved = plan(value: source);
    expect(saved.recipe.title, 'Oats');
    final longRecipe = source.copyWith(
      description: 'a' * 4000,
      portion: 'a' * 1000,
      ingredients: 'a' * 20000,
      preparation: 'a' * 20000,
      imageAsset: 'a' * 2048,
    );
    expect(plan(value: longRecipe).recipe.ingredients.length, 20000);

    expect(source.copyWith(title: 'Edited').title, 'Edited');
    expect(saved.recipe.title, 'Oats');
    final json = saved.toJson();
    (json['recipe'] as Map)['title'] = 'Mutated';
    expect(saved.recipe.title, 'Oats');
    for (final invalid in [
      0,
      .01,
      101,
      double.infinity,
      double.nan,
      '1.5',
      null,
    ]) {
      expect(
        () => PlannedMeal.fromJson({...saved.toJson(), 'servings': invalid}),
        throwsFormatException,
      );
    }
    for (final invalid in [
      '2026-02-31',
      '2026-01-00',
      '1999-12-31',
      '2026-1-1',
    ]) {
      expect(
        () => PlannedMeal.fromJson({...saved.toJson(), 'day': invalid}),
        throwsFormatException,
      );
    }
    expect(
      () => PlannedMeal.fromJson({...saved.toJson(), 'id': 'other'}),
      throwsFormatException,
    );
  });

  test(
    'shopping aggregates exact structured weights and leaves freetext honest',
    () {
      final first = plan(
        value: recipe(ingredients: [oats(200)], batch: 2),
        servings: 1.5,
      );
      final second = plan(
        value: recipe(ingredients: [oats(100)]),
        servings: .5,
      );
      final legacy = plan();
      final list = buildShoppingList([first, second, legacy], today);
      expect(list.where((i) => i.grams != null).single.grams, 200);
      expect(
        list.where((i) => i.grams == null).single.name,
        '100 g oats\nMilk to taste',
      );
      final reordered = buildShoppingList([legacy, second, first], today);
      expect(reordered.first.id, list.first.id);
      expect(
        buildShoppingList([
          first.copyWith(servings: 2),
          second,
        ], today).first.id,
        isNot(list.first.id),
      );
      expect(
        buildShoppingList([first.copyWith(day: DateTime(2026, 10, 1))], today),
        isEmpty,
      );
      expect(
        buildShoppingList([first.copyWith(eatenAt: today)], today),
        isEmpty,
      );
      expect(
        buildShoppingList([first.copyWith(removed: true)], today),
        isEmpty,
      );
      final different = plan(
        value: recipe(
          ingredients: [oats(100, source: IngredientSource.openFoodFacts)],
        ),
      );
      expect(buildShoppingList([first, different], today), hasLength(2));
    },
  );

  test('outbox conversion cannot coalesce or be lost to capacity', () {
    final p = plan().copyWith(eatenAt: today);
    final meal = LoggedMeal(
      id: p.id,
      result: p.recipe.toMealResultForServings(1),
      loggedAt: today,
    );
    final conversion = SyncOp.mealPlanConvert(p, meal, trackDay: true);
    final queue = enqueueCoalesced([conversion], SyncOp.mealUpsert(meal));
    expect(queue, hasLength(2));
    expect(queue.first.kind, SyncOpKind.mealPlanConvert);
    final capped = capOutbox(queue, maxOps: 1);
    expect(capped.queue.single.kind, SyncOpKind.mealPlanConvert);
    final restored = SyncOp.tryFromJson(
      jsonDecode(jsonEncode(conversion.toJson())),
    );
    expect(restored!.plannedMeal!.isEaten, isTrue);
    expect(restored.meal!.id, p.id);
  });

  test(
    'mixed recipe shopping keeps supplementary text and its check identity',
    () {
      final mixedRecipe = recipe(
        ingredients: [oats(200)],
        batch: 2,
      ).copyWith(ingredients: 'Salt to taste');
      final mixed = plan(value: mixedRecipe, servings: 1.5);
      final items = buildShoppingList([mixed], today);
      expect(items.where((i) => i.grams != null).single.grams, 150);
      final text = items.where((i) => i.grams == null).single;
      expect(text.name, 'Salt to taste');
      expect(text.recipeTitle, 'Oats');
      expect(text.servings, 1.5);
      expect(
        buildShoppingList([
          mixed.copyWith(slot: MealSlot.lunch),
        ], today).where((i) => i.grams == null).single.id,
        text.id,
      );
      expect(
        buildShoppingList([
          mixed.copyWith(servings: 2),
        ], today).where((i) => i.grams == null).single.id,
        isNot(text.id),
      );
      final changed = plan(
        value: mixedRecipe.copyWith(ingredients: 'Pepper to taste'),
        servings: 1.5,
        id: mixed.id,
      );
      expect(
        buildShoppingList([
          changed,
        ], today).where((i) => i.grams == null).single.id,
        isNot(text.id),
      );
      for (final empty in ['', '  \n ']) {
        expect(
          buildShoppingList([
            plan(value: mixedRecipe.copyWith(ingredients: empty)),
          ], today).where((i) => i.grams == null),
          isEmpty,
        );
      }
      // A recipe with no ingredient information retains its honest reminder.
      expect(
        buildShoppingList([
          plan(value: recipe().copyWith(ingredients: '')),
        ], today).single.grams,
        isNull,
      );
    },
  );

  test(
    'offline plan/check/edit/eaten survives cold restart without duplicate or future log',
    () async {
      await withClock(Clock.fixed(today), () async {
        final raw = InMemoryKeyValueStore();
        final first = _Fixture(raw: raw);
        await first.boot();
        final p = plan(
          value: recipe(ingredients: [oats(200)], batch: 2),
          servings: 1.5,
        );
        await first.store.savePlannedMeal(p);
        expect(first.store.loggedMeals, isEmpty);
        expect(first.store.dailyConsumedKcal, 0);
        final key = buildShoppingList(
          first.store.plannedMeals,
          today,
        ).single.id;
        await first.store.setShoppingChecked(
          ShoppingCheck(id: key, checked: true),
        );
        await first.settle();
        first.dispose();
        final second = _Fixture(raw: raw);
        await second.boot();
        expect(second.store.plannedMeals.single.recipe.title, 'Oats');
        expect(second.store.shoppingChecks[key], isTrue);
        await Future.wait([
          second.store.eatPlannedMeal(p.id),
          second.store.eatPlannedMeal(p.id),
        ]);
        expect(second.store.loggedMeals, hasLength(1));
        expect(second.store.loggedMeals.single.effectiveLocalDay, '2026-09-10');
        expect(second.store.plannedMeals.single.day, '2026-09-12');
        expect(second.store.dailyConsumedKcal, 150);
        expect(
          second.store.pendingOutbox.where(
            (o) => o.kind == SyncOpKind.mealPlanConvert,
          ),
          hasLength(1),
        );
        await second.settle();
        second.dispose();
        final third = _Fixture(raw: raw);
        await third.boot();
        await third.store.eatPlannedMeal(p.id);
        expect(third.store.loggedMeals, hasLength(1));
        expect(third.store.dailyConsumedKcal, 150);
        expect(third.store.plannedMeals.single.isEaten, isTrue);
        final other = _Fixture(raw: raw, user: 'B');
        await other.boot();
        expect(other.store.plannedMeals, isEmpty);
        expect(other.store.loggedMeals, isEmpty);
        expect(other.store.shoppingChecks, isEmpty);
      });
    },
  );

  test('storage failure does not publish an unacknowledged plan', () async {
    final f = _Fixture(cache: _BrokenCache());
    await f.boot();
    await expectLater(f.store.savePlannedMeal(plan()), throwsStateError);
    expect(f.store.plannedMeals, isEmpty);
    expect(f.store.pendingOutbox, isEmpty);
  });

  test(
    'historical cached plans do not exhaust the active planning limit',
    () async {
      await withClock(Clock.fixed(today), () async {
        final store = HomeStore(
          sync: null,
          health: const NoopHealthService(),
          notificationService: const NoopNotificationService(),
          initialUserName: 'Fixture',
          emitSnack: h.SnackCapture().call,
        );
        addTearDown(store.dispose);
        for (var i = 0; i < 500; i++) {
          await store.savePlannedMeal(
            plan().copyWith(day: today.subtract(const Duration(days: 36))),
          );
        }
        final fresh = plan();
        await store.savePlannedMeal(fresh);
        expect(store.plannedMeals.any((p) => p.id == fresh.id), isTrue);
      });
    },
  );

  test(
    'remove stays removed after restart and account cleanup purges planner mirror',
    () async {
      final raw = InMemoryKeyValueStore();
      final f = _Fixture(raw: raw);
      await f.boot();
      final p = plan();
      await f.store.savePlannedMeal(p);
      await f.store.removePlannedMeal(p);
      await f.settle();
      f.dispose();
      final next = _Fixture(raw: raw);
      await next.boot();
      expect(next.store.plannedMeals, isEmpty);
      await next.cache.clear();
      expect(raw.snapshot.keys.where((k) => k.endsWith('.A')), isEmpty);
    },
  );

  testWidgets('choose recipe, fractional servings and explicit eaten action', (
    tester,
  ) async {
    final store = HomeStore(
      sync: null,
      health: const NoopHealthService(),
      notificationService: const NoopNotificationService(),
      initialUserName: 'Fixture',
      emitSnack: h.SnackCapture().call,
    );
    addTearDown(store.dispose);
    await withClock(Clock.fixed(today), () async {
      await pumpLocalized(
        tester,
        MealPlanScreen(store: store),
        locale: const Locale('en'),
        surfaceSize: const Size(390, 850),
      );
      await tester.tap(find.text('Plan a meal').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text(recipeCatalogEn.first.title));
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('meal-plan-servings'));
      await tester.ensureVisible(field);
      await tester.enterText(field, '1,5');
      await tester.pumpAndSettle();
      final save = find.byKey(const ValueKey('meal-plan-save'));
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(store.plannedMeals.single.servings, 1.5);
      expect(store.loggedMeals, isEmpty);
      final eat = find.byKey(
        ValueKey('meal-plan-eat-${store.plannedMeals.single.id}'),
      );
      await tester.scrollUntilVisible(eat, 100);
      await tester.tap(eat);
      await tester.pumpAndSettle();
      expect(store.plannedMeals.single.isEaten, isTrue);
      expect(store.loggedMeals, hasLength(1));
      expect(store.loggedMeals.single.effectiveLocalDay, '2026-09-10');
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('full recipe selector stays below the top system inset', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 72);
    tester.view.viewPadding = const FakeViewPadding(top: 72);
    addTearDown(tester.view.reset);
    final store = HomeStore(
      sync: null,
      health: const NoopHealthService(),
      notificationService: const NoopNotificationService(),
      initialUserName: 'Fixture',
      emitSnack: h.SnackCapture().call,
    );
    addTearDown(store.dispose);
    await pumpLocalized(
      tester,
      MealPlanScreen(store: store),
      locale: const Locale('en'),
      surfaceSize: const Size(390, 800),
      safeArea: false,
      scaffold: false,
    );
    await tester.tap(find.text('Plan a meal').first);
    await tester.pumpAndSettle();
    final title = find.descendant(
      of: find.byType(BottomSheet),
      matching: find.text('Plan a meal'),
    );
    expect(tester.getTopLeft(title).dy, greaterThanOrEqualTo(72));
    expect(tester.takeException(), isNull);
  });

  for (final locale in ['de', 'en']) {
    testWidgets('planner works at 320px and 2x text $locale', (tester) async {
      final store = HomeStore(
        sync: null,
        health: const NoopHealthService(),
        notificationService: const NoopNotificationService(),
        initialUserName: 'Fixture',
        emitSnack: h.SnackCapture().call,
      );
      addTearDown(store.dispose);
      await withClock(Clock.fixed(today), () async {
        await store.savePlannedMeal(plan());
        await pumpLocalized(
          tester,
          MealPlanScreen(store: store),
          locale: Locale(locale),
          surfaceSize: const Size(320, 850),
          textScale: 2,
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(
          find.text(locale == 'de' ? 'Einkaufsliste' : 'Shopping list'),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.scrollUntilVisible(find.text('Oats'), 150);
        expect(find.text('Oats'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    });
  }
}
