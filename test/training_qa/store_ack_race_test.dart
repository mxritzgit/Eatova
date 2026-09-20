import 'dart:async';
import 'dart:convert';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/coach_training_proposal.dart';
import 'package:eatova/src/models/training_plan.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/services/sync_error_messages.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import '../outbox/outbox_test_helpers.dart' as h;
import '../support/atomic_store_faults.dart';
import '../support/sync_operation_fake.dart';
import '../support/recipe_read_fake.dart';
import 'fixtures.dart';

TrainingPlan _plan(String title) => CoachTrainingProposal.fromJson(
  trainingDraft()..['title'] = title,
)!.toTrainingPlan(id: 'coach_message-1');

class _FailingDurabilityCache extends LocalCache {
  _FailingDurabilityCache()
    : this._(AtomicStoreFaults(InMemoryKeyValueStore()));
  _FailingDurabilityCache._(AtomicStoreFaults storage) : super(storage, 'A') {
    storage.beforeWrite = (changes) async {
      if (rejectNext && changes.keys.any((key) => key.contains('.outbox.'))) {
        rejectNext = false;
        throw StateError('Simulated atomic commit failure');
      }
    };
  }
  bool rejectNext = false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'newer rejected edit cannot hide an older save acknowledged by server',
    () async {
      final writeStarted = Completer<void>();
      final releaseWrite = Completer<void>();
      final savedRows = <String, Map<String, dynamic>>{};
      final calls = <String>[];
      final operations = SyncOperationFake(
        meals: {},
        weights: {},
        favorites: {},
        recipes: {},
        trainingPlans: savedRows,
        readProfile: () => null,
        writeProfile: (_) {},
        readStats: () => {},
        incrementStats: (_, _, _) {},
        recordDay: (_) {},
      );
      final client = SupabaseClient(
        'https://ci.invalid',
        'ci-dummy-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          calls.add('${request.method} ${request.url.path}');
          Object? response = [];
          final path = request.url.path;
          if (path.endsWith('/rpc/apply_sync_operation')) {
            final params = (jsonDecode(request.body) as Map)
                .cast<String, dynamic>();
            if (params['p_kind'] == 'trainingPlanUpsert') {
              if (!writeStarted.isCompleted) writeStarted.complete();
              await releaseWrite.future;
            }
            response = operations.apply(params);
          } else if (emptyRecipeReadResponse(request) case final read?) {
            return read;
          } else if (path.endsWith('/profiles')) {
            response = null;
          } else if (path.endsWith('/lifetime_stats')) {
            response = {};
          }
          return http.Response(
            jsonEncode(response),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
            request: request,
          );
        }),
      );
      final cache = _FailingDurabilityCache();
      final store = HomeStore(
        sync: EatovaSync.forUser(client, 'A'),
        health: const NoopHealthService(),
        notificationService: const NoopNotificationService(),
        initialUserName: 'QA',
        emitSnack: h.SnackCapture().call,
        debugCache: cache,
      );
      addTearDown(() async {
        store.dispose();
        await client.dispose();
      });
      await cache.writeProfile(const UserProfile(onboardingCompleted: true));
      await h.bootUntilIdle(store);

      Object? firstOutcome;
      final firstSave = store
          .saveTrainingPlan(_plan('First confirmed plan'))
          .then<Object>(
            (value) => firstOutcome = value,
            onError: (Object error) => firstOutcome = error,
          );
      await h.pumpUntil(() => writeStarted.isCompleted || firstOutcome != null);
      expect(writeStarted.isCompleted, isTrue, reason: '$calls; $firstOutcome');
      // Same entity is busy, so the second save needs durable outbox acceptance.
      cache.rejectNext = true;
      await expectLater(
        store.saveTrainingPlan(_plan('Rejected edit')),
        throwsStateError,
      );
      expect(store.trainingPlans.single.title, 'First confirmed plan');
      releaseWrite.complete();
      expect(await firstSave, SyncDelivery.queuedRetry);
      expect(savedRows, hasLength(1));
      expect(savedRows.values.single['plan']['title'], 'First confirmed plan');
      expect(store.trainingPlans.map((plan) => plan.title), [
        'First confirmed plan',
      ]);
      expect(store.selectedTrainingPlanId, 'coach_message-1');
      expect(store.pendingOutbox, hasLength(1));
      await store.syncPendingWrites();
      expect(store.pendingOutbox, isEmpty);
      expect(savedRows, hasLength(1));
    },
  );
}
