// The boot snapshot guards the cache versions the store has observed, so a
// slot changed behind its back makes the snapshot conflict. A conflict
// re-hydrates the cache over the fresh server state and runs the whole
// server load a second time. Writes the store makes itself, or writes to
// slots the snapshot neither reads nor writes, must not count as such a
// change.

import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/training_plan.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/services/sync_outbox.dart';

import '../support/today_design_fixture.dart' show designPlan;
import 'outbox_test_helpers.dart';

const _mealId = '00000000-0000-4000-8000-000000000001';

class _Boot {
  _Boot(this.server, this.kv, this.cache);
  final FakeServer server;
  final InMemoryKeyValueStore kv;
  final LocalCache cache;
  late final HomeStore store;
  final Completer<void> gate = Completer<void>();
  int profileLoads = 0;
}

_Boot _setup() {
  final server = FakeServer()
    ..profileRow = serverProfileRow(
      const UserProfile(weightKg: 80, onboardingCompleted: true),
    )
    ..mealRows['m1'] = serverMealRow(_mealId);
  final kv = InMemoryKeyValueStore();
  final boot = _Boot(server, kv, LocalCache(kv, 'user-outbox'));
  final inner = server.client();
  final client = SupabaseClient(
    'https://example.supabase.co',
    'test-anon-key',
    httpClient: MockClient((request) async {
      if (request.method == 'GET' && request.url.path.endsWith('/profiles')) {
        boot.profileLoads++;
        await boot.gate.future;
      }
      final copy = http.Request(request.method, request.url)
        ..headers.addAll(request.headers)
        ..bodyBytes = request.bodyBytes;
      return http.Response.fromStream(await inner.send(copy));
    }),
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  addTearDown(client.dispose);
  boot.store = HomeStore(
    sync: EatovaSync.forUser(client, 'user-outbox'),
    health: const NoopHealthService(),
    notificationService: const NoopNotificationService(),
    initialUserName: 'Test',
    emitSnack: SnackCapture().call,
    debugCache: boot.cache,
  );
  addTearDown(boot.store.dispose);
  return boot;
}

Future<void> _finish(_Boot boot) async {
  boot.gate.complete();
  await pumpUntil(() => !boot.store.bootLoadInFlight);
  await settle();
  expect(boot.profileLoads, 1, reason: 'no second boot load');
  expect(boot.store.loggedMeals.map((meal) => meal.id), contains(_mealId));
  final cached =
      jsonDecode(boot.kv.snapshot['eatova.v1.logged_meals.user-outbox']!)
          as Map<String, dynamic>;
  expect(
    (cached['items'] as List).map((row) => (row as Map)['id']),
    contains(_mealId),
    reason: 'the server snapshot reached the cache',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final write in <String, Future<void> Function(LocalCache)>{
    'daily activity': (cache) => cache.writeDailyActivity({
      '2026-10-11': (steps: 4321, kcal: 150),
    }),
    'Health opt-in': (cache) => cache.writeHealthConnectEnabled(true),
    'reminder opt-in': (cache) => cache.writeNotificationsEnabled(true),
  }.entries) {
    test('a ${write.key} write during the boot load keeps one server load',
        () async {
      final boot = _setup();
      boot.store.start();
      await pumpUntil(() => boot.profileLoads == 1);
      expect(boot.profileLoads, 1, reason: 'precondition: the load is held');
      await write.value(boot.cache);
      await _finish(boot);
    });
  }

  test('a failed boot delivery keeps one server load', () async {
    final boot = _setup();
    // A server error is counted, so the failure rewrites the queued op.
    boot.server.rejectMealWrites = true;
    await boot.cache.commitSyncOperations([
      SyncOp.mealInsert(
        LoggedMeal(
          id: '00000000-0000-4000-8000-000000000002',
          result: mealResult('Offline'),
          loggedAt: clock.now(),
        ),
        trackDay: false,
      ),
    ]);
    boot.store.start();
    await pumpUntil(() => boot.profileLoads == 1);
    expect(boot.server.operations('mealInsert'), hasLength(1),
        reason: 'precondition: the boot replay tried and failed');
    expect(boot.store.pendingOutbox.single.attempts, 1);
    await _finish(boot);
  });

  test('a plan selection keeps the next meal plan load single', () async {
    final boot = _setup();
    boot.store.start();
    await _finish(boot);
    for (final id in ['plan-a', 'plan-b']) {
      await boot.store.saveTrainingPlan(
        TrainingPlan(id: id, proposal: designPlan().proposal),
      );
    }
    expect(boot.store.trainingPlans, hasLength(2), reason: 'precondition');
    final other = boot.store.trainingPlans
        .firstWhere((plan) => plan.id != boot.store.selectedTrainingPlanId);
    await boot.store.selectTrainingPlan(other.id);
    boot.server.serveMealPlans = true;
    int planLoads() => boot.server.requests
        .where((r) => r.url.path.endsWith('/rpc/load_meal_plan'))
        .length;
    final before = planLoads();
    await boot.store.retryMealPlans();
    await settle();
    expect(planLoads(), before + 1,
        reason: 'the own selection commit is no foreign change');
  });
}
