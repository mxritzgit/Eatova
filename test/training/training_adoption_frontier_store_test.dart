import 'package:clock/clock.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/sync_outbox.dart';
import 'package:flutter_test/flutter_test.dart';

import '../outbox/outbox_test_helpers.dart' as h;
import '../services/training_adoption_frontier_test.dart'
    show draft, checkpoint, conflict;
import '../services/training_incarnation_atomic_test.dart' show plan, head;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'boot and explicit review use confirmed B and send no stale B request',
    () async {
      final cache = LocalCache(InMemoryKeyValueStore(), 'user-outbox');
      final a = SyncOp.trainingPlanUpsert(draft('A'), adoption: true);
      final b = SyncOp.trainingPlanUpsert(draft('B'));
      await cache.commitSyncOperations([a]);
      await cache.startSyncOperation(a.operationId);
      await cache.commitSyncOperations([b]);
      await conflict(cache, a);
      final env = h.setup(injizierterCache: cache);
      env.server.offline = true;
      await h.bootUntilIdle(env.store);
      expect(env.store.trainingPlans.single.proposal.title, 'B');
      final reviewed = env.store.trainingAdoptionDraft(a.operationId);
      expect(reviewed.operationId, b.operationId);
      env.server.offline = false;
      env.server.syncOperations.trainingHeads[plan().coachSourceId!] = head(
        3,
      ).toJson();
      await env.store.resolveTrainingAdoption(
        a.operationId,
        expectedDraftOperationId: reviewed.operationId,
        expectedHead: head(3),
        reviewedDraft: reviewed.trainingPlan!,
      );
      expect(env.store.trainingPlans.single.proposal.title, 'B');
      expect(env.store.trainingPlans.single.incarnation, 3);
      expect(env.store.pendingOutbox, isEmpty);
      expect(env.server.operations('trainingPlanUpsert'), hasLength(1));
    },
  );

  for (final durableCompletion in [false, true]) {
    test(
      'a live head-conflict receipt ${durableCompletion ? 'protects durable completion' : 'retires the open workout'}',
      () async {
        await withClock(Clock.fixed(DateTime.utc(2026, 9, 20, 12)), () async {
          final cache = LocalCache(InMemoryKeyValueStore(), 'user-outbox');
          final a = SyncOp.trainingPlanUpsert(plan(), adoption: true);
          await cache.commitSyncOperations([a]);
          final saved = checkpoint(completion: durableCompletion);
          await cache.commitTrainingCheckpoint(saved, expectedSnapshot: null);
          final env = h.setup(injizierterCache: cache);
          env.server.offline = true;
          await h.bootUntilIdle(env.store);
          expect(env.store.trainingSession?.sessionId, saved.sessionId);
          final generation = env.store.trainingSessionGeneration;
          env.server.offline = false;
          env.server.syncOperations.trainingHeads[plan().coachSourceId!] = head(
            3,
          ).toJson();
          await env.store.syncPendingWrites();
          expect(
            env.store.pendingTrainingAdoptions.single.operationId,
            a.operationId,
          );
          if (durableCompletion) {
            expect(env.store.trainingSession?.toJson(), saved.toJson());
            await env.store.saveTrainingSession(
              saved,
              generation: generation,
              sourcePlanId: plan().id,
            );
          } else {
            expect(env.store.trainingSession, isNull);
            await expectLater(
              env.store.saveTrainingSession(
                saved,
                generation: generation,
                sourcePlanId: plan().id,
              ),
              throwsStateError,
            );
            await expectLater(
              env.store.saveTrainingSession(checkpoint()),
              throwsStateError,
            );
            await expectLater(
              env.store.saveTrainingSession(checkpoint(completion: true)),
              throwsStateError,
            );
          }
        });
      },
    );
  }
}
