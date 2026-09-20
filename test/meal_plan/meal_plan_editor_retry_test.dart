import '../support/recipe_read_fake.dart';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/recipes/meal_plan_screen.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/crash_reporter.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import '../outbox/outbox_test_helpers.dart' as h;
import '../support/harness.dart';
import '../support/sync_operation_fake.dart';
import '../support/sync_session_fixture.dart';

class _FailedOutboxStorage extends InMemoryKeyValueStore {
  bool fail = false;
  final draftIds = <String>[];

  @override
  Future<KeyValueCommit> writeBatch(
    Map<String, String?> changes, {
    Map<String, int> expectedVersions = const {},
  }) {
    final raw = changes['eatova.v1.outbox.A'];
    if (raw != null) {
      for (final op in (jsonDecode(raw) as Map)['items'] as List) {
        if (op['kind'] == 'mealPlanUpsert') {
          draftIds.add(op['entity_id'] as String);
        }
      }
      if (fail) return Future.error(StateError('fixture local commit failure'));
    }
    return super.writeBatch(changes, expectedVersions: expectedVersions);
  }
}

void main() {
  testWidgets(
    'editor retries a failed local commit and replays a lost receipt with the same plan',
    (tester) async {
      await withClock(Clock.fixed(DateTime(2026, 9, 10, 12)), () async {
        final failures = <String>[];
        CrashReporter.debugSentrySink = (error, stack, context) {
          failures.add('$context: $error\n$stack');
        };
        addTearDown(() => CrashReporter.debugSentrySink = null);
        final serverPlans = <String, Map<String, dynamic>>{};
        final submittedIds = <String>[];
        final storage = _FailedOutboxStorage();
        final cache = LocalCache(storage, 'A');
        final operations = SyncOperationFake(
          meals: {},
          weights: {},
          favorites: {},
          recipes: {},
          mealPlans: serverPlans,
          readProfile: () => null,
          writeProfile: (_) {},
          readStats: () => {},
          incrementStats: (_, _, _) {},
          recordDay: (_) {},
        );
        late SupabaseClient client;
        late HomeStore store;
        await tester.runAsync(() async {
          client = SupabaseClient(
            'https://ci.invalid',
            'ci-dummy-key',
            authOptions: const AuthClientOptions(autoRefreshToken: false),
            httpClient: MockClient((request) async {
              final recipeResponse = emptyRecipeReadResponse(request);
              if (recipeResponse != null) return recipeResponse;
              Object? response = [];
              if (request.url.path.endsWith('/rpc/apply_sync_operation')) {
                expect(
                  request.headers['Authorization'],
                  'Bearer ${syncFixtureToken('A')}',
                );
                final params = (jsonDecode(request.body) as Map)
                    .cast<String, dynamic>();
                response = operations.apply(params);
                if (params['p_kind'] == 'mealPlanUpsert') {
                  submittedIds.add(params['p_entity_id'] as String);
                }
                if (params['p_kind'] == 'mealPlanUpsert' &&
                    submittedIds.length == 1) {
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
                headers: {'content-type': 'application/json; charset=utf-8'},
                request: request,
              );
            }),
          );
          await signInSyncFixture(client, 'A');
          store = HomeStore(
            sync: EatovaSync.forUser(client, 'A'),
            debugCache: cache,
            health: const NoopHealthService(),
            notificationService: const NoopNotificationService(),
            initialUserName: 'Fixture',
            emitSnack: h.SnackCapture().call,
          );
          await cache.writeProfile(
            const UserProfile(onboardingCompleted: true),
          );
          await h.bootUntilIdle(store);
          await h.pumpUntil(() => !store.mealPlansLoading);
          storage.fail = true;
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
          await h.pumpUntil(() => storage.draftIds.isNotEmpty);
          await h.settle();
        });
        await tester.pumpAndSettle();
        expect(submittedIds, isEmpty);
        expect(serverPlans, isEmpty);
        expect(store.plannedMeals, isEmpty);
        expect(store.pendingOutbox, isEmpty);
        expect(find.textContaining('Not saved.'), findsOneWidget);

        // The editor remains usable; changing portions retries the same draft.
        storage.fail = false;
        await tester.ensureVisible(field);
        await tester.enterText(field, '2.5');
        await tester.ensureVisible(save);
        await tester.runAsync(() async {
          await tester.tap(save);
          await h.pumpUntil(() => store.plannedMeals.isNotEmpty);
          await h.settle();
        });
        await tester.pumpAndSettle();
        expect(submittedIds, hasLength(1));
        expect(storage.draftIds.toSet(), {submittedIds.first});
        expect(serverPlans, hasLength(1));
        expect(serverPlans.values.single['servings'], 2.5);
        expect(store.plannedMeals.single.id, submittedIds.first);
        expect(store.plannedMeals.single.servings, 2.5);
        expect(find.byKey(const ValueKey('meal-plan-save')), findsNothing);
        expect(store.pendingOutbox, hasLength(1));
        await tester.runAsync(() async {
          await store.syncPendingWrites();
          await store.retryMealPlans();
        });
        await tester.pumpAndSettle();
        expect(submittedIds.length, greaterThanOrEqualTo(2));
        expect(submittedIds.toSet(), {submittedIds.first});
        expect(serverPlans, hasLength(1));
        expect(store.plannedMeals.single.servings, 2.5);
        expect(store.pendingOutbox, isEmpty, reason: failures.join('\n'));
        expect(failures, isEmpty);
        expect(tester.takeException(), isNull);
      });
    },
  );
}
