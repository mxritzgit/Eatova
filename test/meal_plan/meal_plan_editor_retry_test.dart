import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
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
import '../services/user_rpc_test.dart' show signIn;
import '../support/harness.dart';

class _FailedOutboxCache extends LocalCache {
  _FailedOutboxCache() : super(InMemoryKeyValueStore(), 'A');
  bool fail = true;

  @override
  Future<bool> writeOutbox(List<SyncOp> ops) async =>
      fail ? false : super.writeOutbox(ops);
}

void main() {
  testWidgets(
    'editor retry after a lost receipt updates the same server plan',
    (tester) async {
      await withClock(Clock.fixed(DateTime(2026, 9, 10, 12)), () async {
        final serverPlans = <String, Map<String, dynamic>>{};
        final submittedIds = <String>[];
        final cache = _FailedOutboxCache();
        late SupabaseClient client;
        late HomeStore store;
        await tester.runAsync(() async {
          client = SupabaseClient(
            'https://ci.invalid',
            'ci-dummy-key',
            authOptions: const AuthClientOptions(autoRefreshToken: false),
            httpClient: MockClient((request) async {
              Object? response = [];
              if (request.url.path.endsWith('/rpc/save_planned_meal')) {
                expect(request.headers['Authorization'], 'Bearer fixture-A');
                final plan = (jsonDecode(request.body)['p_plan'] as Map)
                    .cast<String, dynamic>();
                final id = plan['id'] as String;
                submittedIds.add(id);
                serverPlans[id] = plan;
                if (submittedIds.length == 1) {
                  throw http.ClientException(
                    'Response lost after server commit',
                  );
                }
              } else if (request.url.path.endsWith('/rpc/load_meal_plan')) {
                response = {'plans': serverPlans.values.toList(), 'checks': []};
              } else {
                response = request.url.path.endsWith('/profiles')
                    ? null
                    : request.url.path.endsWith('/lifetime_stats')
                    ? {}
                    : [];
              }
              return http.Response(
                jsonEncode(response),
                200,
                headers: {'content-type': 'application/json'},
              );
            }),
          );
          store = HomeStore(
            sync: EatovaSync.forUser(client, 'A'),
            debugCache: cache,
            health: const NoopHealthService(),
            notificationService: const NoopNotificationService(),
            initialUserName: 'Fixture',
            emitSnack: h.SnackCapture().call,
          );
          await signIn(client, 'A');
          await cache.writeProfile(
            const UserProfile(onboardingCompleted: true),
          );
          await h.bootUntilIdle(store);
          await h.pumpUntil(() => !store.mealPlansLoading);
        });
        addTearDown(() async {
          store.dispose();
          await client.dispose();
        });
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
        final save = find.byKey(const ValueKey('meal-plan-save'));
        await tester.ensureVisible(save);
        await tester.runAsync(() async {
          await tester.tap(save);
          await h.pumpUntil(
            () => submittedIds.length == 1 && store.pendingOutbox.isEmpty,
          );
          await h.settle();
        });
        await tester.pumpAndSettle();
        expect(submittedIds, hasLength(1));
        expect(serverPlans, hasLength(1));
        expect(store.plannedMeals, isEmpty);
        expect(store.pendingOutbox, isEmpty);
        expect(find.textContaining('Not saved.'), findsOneWidget);

        // The editor remains usable; changing portions retries the same draft.
        cache.fail = false;
        await tester.ensureVisible(field);
        await tester.enterText(field, '2.5');
        await tester.ensureVisible(save);
        await tester.runAsync(() async {
          await tester.tap(save);
          await h.pumpUntil(() => store.plannedMeals.isNotEmpty);
          await store.retryMealPlans();
          await h.settle();
        });
        await tester.pumpAndSettle();
        expect(submittedIds.length, greaterThanOrEqualTo(2));
        expect(submittedIds.toSet(), {submittedIds.first});
        expect(serverPlans, hasLength(1));
        expect(serverPlans.values.single['servings'], 2.5);
        expect(store.plannedMeals.single.id, submittedIds.first);
        expect(store.plannedMeals.single.servings, 2.5);
        expect(find.byKey(const ValueKey('meal-plan-save')), findsNothing);
        expect(tester.takeException(), isNull);
      });
    },
  );
}
