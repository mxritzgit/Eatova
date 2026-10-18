// Food preferences in the store (F8, C3): saving through the outbox, offline,
// older cache snapshots, account separation, and the coach context line.

import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/services/sync_outbox.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase/supabase.dart';

import '../outbox/outbox_test_helpers.dart';

final DateTime _now = DateTime(2026, 10, 18, 19, 30);

const FoodPreferences _vegan = FoodPreferences(
  diet: DietPreference.vegan,
  avoidances: <FoodAvoidance>{FoodAvoidance.nuts, FoodAvoidance.lactose},
  dislikes: 'Koriander',
);

void _noopSnack(
  String message, {
  IconData icon = Icons.info_outline,
  SnackTone tone = SnackTone.positive,
  Duration? duration,
  SnackBarAction? action,
}) {}

/// A store without sync, for the pure context getter.
HomeStore _localStore() {
  final store = HomeStore(
    sync: null,
    health: const NoopHealthService(),
    notificationService: const NoopNotificationService(),
    initialUserName: 'Test',
    emitSnack: _noopSnack,
  );
  addTearDown(store.dispose);
  return store;
}

/// A store for another account over the SAME device storage.
HomeStore _storeFor(
  String userId,
  FakeServer server,
  InMemoryKeyValueStore kv,
) {
  final client = SupabaseClient(
    'https://example.supabase.co',
    'test-anon-key',
    httpClient: server.client(),
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  addTearDown(client.dispose);
  final store = HomeStore(
    sync: EatovaSync.forUser(client, userId),
    health: const NoopHealthService(),
    notificationService: const NoopNotificationService(),
    initialUserName: 'Test',
    emitSnack: _noopSnack,
    debugCache: LocalCache(kv, userId),
  );
  addTearDown(store.dispose);
  return store;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('coachContext', () {
    test(
      'without preferences there is no line',
      () => withClock(Clock.fixed(_now), () async {
        expect(_localStore().coachContext, isNot(contains('Laut Profil')));
      }),
    );

    test(
      'diet, avoided foods and dislikes in German, before the meal lines',
      () => withClock(Clock.fixed(_now), () async {
        final store = _localStore();
        await store.updateFoodPreferences(_vegan);
        for (var i = 0; i < 10; i++) {
          await store.addResultToDailyTotal(
            mealResult('Sehr langer Mahlzeitname Nummer $i mit Beilage'),
            slot: MealSlot.dinner,
          );
        }
        final ctx = store.coachContext;
        const line =
            'Laut Profil: Kostform Vegan; meidet Laktose, Nüsse; mag nicht: '
            'Koriander.';
        expect(ctx, contains(line));
        final prefs = ctx.indexOf(line);
        expect(prefs, greaterThan(ctx.indexOf('Makros heute noch offen')));
        expect(prefs, lessThan(ctx.indexOf('Pro Mahlzeit heute')));
        expect(prefs, lessThan(ctx.indexOf('Heute gegessene Lebensmittel')));
        expect(
          prefs + line.length,
          lessThan(kCoachContextCapChars),
          reason: 'the server cap trims the tail and must never reach it',
        );
      }),
    );

    test(
      'only what is set',
      () => withClock(Clock.fixed(_now), () async {
        final store = _localStore();
        await store.updateFoodPreferences(
          const FoodPreferences(
            avoidances: <FoodAvoidance>{FoodAvoidance.pork},
          ),
        );
        expect(
          store.coachContext,
          contains('Laut Profil: meidet Schweinefleisch.'),
        );
        expect(store.coachRecipePreferences?.avoidances, {FoodAvoidance.pork});
        await store.updateFoodPreferences(const FoodPreferences());
        expect(store.coachContext, isNot(contains('Laut Profil')));
        expect(store.coachRecipePreferences, isNull);
      }),
    );
  });

  group('saving', () {
    test(
      'one profile op carries the three fields, the rest stays',
      () => withClock(Clock.fixed(_now), () async {
        final s = setup();
        s.server.profileRow = serverProfileRow(testProfile(weightKg: 83));
        await boot(s.store);
        // The boot may already heal the live goals with a profile op of its own.
        final before = s.server.operations('profileUpsert').length;

        await s.store.updateFoodPreferences(_vegan);
        await settle();

        expect(s.store.profile.foodPreferences, _vegan);
        expect(s.store.profile.weightKg, 83);
        final ops = s.server.operations('profileUpsert');
        expect(
          ops,
          hasLength(before + 1),
          reason: 'one op per change (DATA-7)',
        );
        final row =
            (jsonDecode(ops.last.body) as Map)['p_payload']['row'] as Map;
        expect(row['diet_preference'], 'vegan');
        expect(row['food_avoidances'], <String>['lactose', 'nuts']);
        expect(row['food_dislikes'], 'Koriander');
        expect(s.server.profileRow!['food_avoidances'], <String>[
          'lactose',
          'nuts',
        ]);
        expect((await s.cache.readProfile())!.foodPreferences, _vegan);
      }),
    );

    test(
      'a goals save in flight lands first and is not overwritten',
      () => withClock(Clock.fixed(_now), () async {
        final s = setup();
        s.server.profileRow = serverProfileRow(testProfile(weightKg: 83));
        await boot(s.store);

        final goals = s.store.applySettings(
          newProfile: s.store.profile.copyWith(weightKg: 79),
          notificationsEnabled: false,
        );
        final prefs = s.store.updateFoodPreferences(_vegan);
        await Future.wait(<Future<void>>[goals, prefs]);
        await settle();

        expect(s.store.profile.weightKg, 79, reason: 'the goals edit survives');
        expect(s.store.profile.foodPreferences, _vegan);
        expect(s.server.profileRow!['weight_kg'], 79);
      }),
    );

    test(
      'offline: published at once, queued durably, delivered later',
      () => withClock(Clock.fixed(_now), () async {
        final s = setup();
        s.server.profileRow = serverProfileRow(testProfile());
        await boot(s.store);
        s.server.offline = true;

        await s.store.updateFoodPreferences(_vegan);
        await settle();

        expect(s.store.profile.foodPreferences, _vegan);
        expect(
          s.store.pendingOutbox.map((o) => o.kind),
          contains(SyncOpKind.profileUpsert),
        );
        final persisted = await s.cache.readOutbox();
        expect(
          persisted!
              .where((o) => o.kind == SyncOpKind.profileUpsert)
              .single
              .profile!
              .foodPreferences,
          _vegan,
        );
        expect(
          s.server.profileRow!['food_avoidances'],
          isNot(contains('nuts')),
          reason: 'nothing reached the server yet',
        );

        s.server.offline = false;
        await s.store.syncPendingWrites();
        await settle();
        expect(s.store.pendingOutbox, isEmpty);
        expect(s.server.profileRow!['food_avoidances'], <String>[
          'lactose',
          'nuts',
        ]);
        expect(s.server.profileRow!['food_dislikes'], 'Koriander');
      }),
    );

    test(
      'before the profile is hydrated nothing is written',
      () => withClock(Clock.fixed(_now), () async {
        final s = setup();
        s.server.offline = true;
        await boot(s.store);

        await expectLater(
          s.store.updateFoodPreferences(_vegan),
          throwsStateError,
        );
        expect(s.store.pendingOutbox, isEmpty);
      }),
    );
  });

  group('loading', () {
    test(
      'the server row brings the preferences in',
      () => withClock(Clock.fixed(_now), () async {
        final s = setup();
        s.server.profileRow = serverProfileRow(testProfile())
          ..['diet_preference'] = 'pescetarian'
          ..['food_avoidances'] = <String>['alcohol', 'insects']
          ..['food_dislikes'] = 'Rosinen';
        await boot(s.store);

        expect(s.store.profile.diet, DietPreference.pescetarian);
        expect(s.store.profile.foodAvoidances, {FoodAvoidance.alcohol});
        expect(s.store.profile.foodDislikes, 'Rosinen');
      }),
    );

    test(
      'an older cache snapshot without the fields boots cleanly',
      () => withClock(Clock.fixed(_now), () async {
        final kv = InMemoryKeyValueStore();
        final old = userProfileToJson(testProfile(weightKg: 91))
          ..remove('food_avoidances')
          ..remove('food_dislikes');
        await kv.setString('eatova.v1.profile.user-outbox', jsonEncode(old));
        final s = setup(kv: kv);
        s.server.offline = true;
        await boot(s.store);

        expect(s.store.profile.weightKg, 91, reason: 'hydrated from the cache');
        expect(s.store.profile.foodAvoidances, isEmpty);
        expect(s.store.profile.foodDislikes, '');
        await s.store.updateFoodPreferences(_vegan);
        expect(s.store.profile.foodPreferences, _vegan);
      }),
    );
  });

  test(
    'another account on the device never sees them',
    () => withClock(Clock.fixed(_now), () async {
      final kv = InMemoryKeyValueStore();
      final a = setup(kv: kv);
      a.server.profileRow = serverProfileRow(testProfile());
      await boot(a.store);
      await a.store.updateFoodPreferences(_vegan);
      await settle();

      final serverB = FakeServer()
        ..profileRow = serverProfileRow(testProfile());
      final b = _storeFor('user-b', serverB, kv);
      await boot(b);

      expect(b.profile.foodPreferences.isEmpty, isTrue);
      expect(b.coachContext, isNot(contains('Laut Profil')));
      expect(b.coachRecipePreferences, isNull);
      expect(
        (await LocalCache(kv, 'user-outbox').readProfile())!.foodPreferences,
        _vegan,
        reason: "A's snapshot stays under A's key",
      );
    }),
  );

  test(
    'the recipe pick follows the new diet at once',
    () => withClock(Clock.fixed(_now), () async {
      final store = _localStore();
      await store.updateFoodPreferences(
        const FoodPreferences(diet: DietPreference.vegan),
      );
      final pick = store.nextMealPick(localeName: 'de');
      expect(pick, isNotNull);
      expect(pick!.recipe.matchesDiet(DietPreference.vegan), isTrue);
    }),
  );
}
