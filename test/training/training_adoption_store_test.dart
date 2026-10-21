import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:eatova/src/models/training_plan.dart';
import 'package:eatova/src/models/training_plan_head.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/sync_error_messages.dart';
import 'package:eatova/src/services/sync_outbox.dart';
import 'package:flutter_test/flutter_test.dart';

import '../outbox/outbox_test_helpers.dart' as h;
import '../services/training_adoption_frontier_test.dart'
    show draft, checkpoint, conflict;
import '../services/training_incarnation_atomic_test.dart' show plan, head;
import '../support/atomic_store_faults.dart';
import 'training_timer_fixtures.dart';

TrainingPlan _plan([int incarnation = 0]) => TrainingPlan(
  id: trainingPlanIdForMessage('store-adoption'),
  sourceId: 'store-adoption',
  incarnation: incarnation,
  proposal: timerPlan().proposal,
);
TrainingPlanHead _head(int incarnation, {bool deleted = false}) =>
    TrainingPlanHead(
      sourceId: 'store-adoption',
      planId: _plan().id,
      incarnation: incarnation,
      deleted: deleted,
      plan: deleted ? null : _plan(incarnation),
    );

Future<SyncOp> _seedConflict(LocalCache cache) async {
  final old = SyncOp.trainingPlanUpsert(_plan(), adoption: true);
  await cache.commitSyncOperations([old]);
  await cache.startSyncOperation(old.operationId);
  await cache.acknowledgeSyncOperation(
    old.operationId,
    LocalSyncResult(
      trainingHead: _head(3, deleted: true),
      trainingHeadConflict: true,
    ),
  );
  return old;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'protocol receipts deliver a confirmed re-adoption once at its new generation',
    () async {
      final env = h.setup();
      await h.bootUntilIdle(env.store);
      expect(
        await env.store.adoptTrainingPlan(_plan()),
        SyncDelivery.delivered,
      );
      expect(
        await env.store.deleteTrainingPlan(_plan().id),
        SyncDelivery.delivered,
      );
      expect(
        await env.store.adoptTrainingPlan(_plan()),
        SyncDelivery.delivered,
      );
      expect(env.store.trainingPlans.single.incarnation, 1);
      expect(env.store.pendingOutbox, isEmpty);
      expect(
        env.server.syncOperations.trainingPlans[_plan().id]!['incarnation'],
        1,
      );
      final writes = env.server.operations('trainingPlanUpsert');
      expect(writes, hasLength(2));
      for (final request in writes) {
        final params = jsonDecode(request.body) as Map;
        expect(params['p_training_protocol'], 2);
        expect((params['p_payload'] as Map)['adoption'], isTrue);
      }
    },
  );

  test(
    'real receipt blocks an unknown-head draft then fresh review resolves it',
    () async {
      final env = h.setup();
      env.server.syncOperations.trainingHeads['store-adoption'] = _head(
        3,
        deleted: true,
      ).toJson();
      await h.bootUntilIdle(env.store);
      expect(
        await env.store.adoptTrainingPlan(_plan()),
        SyncDelivery.queuedRetry,
      );
      final rejected = env.store.pendingTrainingAdoptions.single;
      expect(env.store.trainingPlans.single.incarnation, 0);
      expect(
        env.store.syncBlockedReason,
        SyncBlockedReason.trainingHeadConflict,
      );
      final requests = env.server.operations('trainingPlanUpsert').length;
      await env.store.syncPendingWrites(retryBlocked: true);
      expect(env.server.operations('trainingPlanUpsert'), hasLength(requests));
      final fresh = await env.store.loadTrainingPlanHead('store-adoption');
      expect(fresh!.incarnation, 3);
      expect(
        await env.store.resolveTrainingAdoption(
          rejected.operationId,
          expectedHead: fresh,
          reviewedDraft: env.store.trainingPlans.single,
        ),
        SyncDelivery.delivered,
      );
      expect(env.store.trainingPlans.single.incarnation, 4);
      expect(env.store.pendingOutbox, isEmpty);
      final writes = env.server.operations('trainingPlanUpsert');
      expect(writes, hasLength(2));
      expect(
        (jsonDecode(writes.last.body) as Map)['p_operation_id'],
        isNot(rejected.operationId),
      );
      expect(
        env.server.syncOperations.trainingPlans[_plan().id]!['incarnation'],
        4,
      );
    },
  );

  test(
    'offline delete then explicit re-adoption publishes its committed generation',
    () async {
      final env = h.setup();
      env.server.offline = true;
      await env.cache.writeProfile(h.testProfile());
      await h.bootUntilIdle(env.store);
      expect(
        await env.store.adoptTrainingPlan(_plan()),
        SyncDelivery.queuedOffline,
      );
      await env.store.deleteTrainingPlan(_plan().id);
      expect(env.store.trainingPlans, isEmpty);
      expect(
        await env.store.adoptTrainingPlan(_plan()),
        SyncDelivery.queuedOffline,
      );
      expect(env.store.trainingPlans.single.incarnation, 1);
      expect((await env.cache.readTrainingPlans())!.single.incarnation, 1);
      expect(
        env.store.pendingOutbox
            .where((op) => op.kind == SyncOpKind.trainingPlanUpsert)
            .last
            .trainingIncarnation,
        1,
      );
    },
  );

  test('failed adoption commit never publishes a plan or sends HTTP', () async {
    final faults = AtomicStoreFaults(InMemoryKeyValueStore());
    final env = h.setup(injizierterCache: LocalCache(faults, 'user-outbox'));
    env.server.offline = true;
    await env.cache.writeProfile(h.testProfile());
    await h.bootUntilIdle(env.store);
    final entered = Completer<void>();
    final release = Completer<void>();
    faults.beforeWrite = (changes) async {
      if (changes.containsKey('eatova.v1.training_heads.user-outbox')) {
        entered.complete();
        await release.future;
        throw StateError('No commit');
      }
    };
    final saving = env.store.adoptTrainingPlan(_plan());
    final failed = expectLater(saving, throwsStateError);
    await entered.future;
    expect(env.store.trainingPlans, isEmpty);
    expect(env.store.pendingOutbox, isEmpty);
    release.complete();
    await failed;
    expect(await env.cache.readTrainingPlans(), isNull);
  });

  test(
    'a hydrated conflict stays visible through retry and rejects a hidden FIFO delete',
    () async {
      final env = h.setup();
      env.server.offline = true;
      await env.cache.writeProfile(h.testProfile());
      final old = await _seedConflict(env.cache);
      await h.bootUntilIdle(env.store);
      final wire = jsonEncode(env.store.pendingOutbox.single.toJson());
      expect(
        env.store.pendingTrainingAdoptions.single.operationId,
        old.operationId,
      );
      await env.store.syncPendingWrites(retryBlocked: true);
      expect(jsonEncode(env.store.pendingOutbox.single.toJson()), wire);
      expect(() => env.store.deleteTrainingPlan(_plan().id), throwsStateError);
      expect(env.store.trainingPlans.single.incarnation, 0);
      expect(env.store.pendingOutbox, hasLength(1));
      await env.store.discardTrainingAdoption(old.operationId);
      expect(env.store.trainingPlans, isEmpty);
      expect(env.store.pendingTrainingAdoptions, isEmpty);
      expect(await env.cache.readSyncOperations(), isEmpty);
    },
  );

  test(
    'explicit conflict resolution commits one new UUID and the reviewed generation',
    () async {
      final env = h.setup();
      env.server.offline = true;
      await env.cache.writeProfile(h.testProfile());
      final old = await _seedConflict(env.cache);
      await h.bootUntilIdle(env.store);
      final delivery = await env.store.resolveTrainingAdoption(
        old.operationId,
        expectedHead: _head(3, deleted: true),
        reviewedDraft: _plan(),
      );
      expect(delivery, SyncDelivery.queuedOffline);
      expect(env.store.pendingTrainingAdoptions, isEmpty);
      expect(
        env.store.pendingOutbox.single.operationId,
        isNot(old.operationId),
      );
      expect(env.store.pendingOutbox.single.trainingIncarnation, 4);
      expect(env.store.trainingPlans.single.incarnation, 4);
      expect((await env.cache.readTrainingPlans())!.single.incarnation, 4);
    },
  );

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
            // The route can still store it, so Retry can finish the workout.
            expect(
              await env.store.saveTrainingSession(
                saved,
                generation: generation,
                sourcePlanId: plan().id,
              ),
              isTrue,
            );
            expect(
              (await cache.readTrainingSession())?.toJson(),
              saved.toJson(),
            );
          } else {
            expect(env.store.trainingSession, isNull);
            final durable = (await cache.readTrainingSession())?.toJson();
            expect(
              await env.store.saveTrainingSession(
                saved,
                generation: generation,
                sourcePlanId: plan().id,
              ),
              isFalse,
            );
            expect(await env.store.saveTrainingSession(checkpoint()), isFalse);
            expect(
              await env.store.saveTrainingSession(checkpoint(completion: true)),
              isFalse,
            );
            expect((await cache.readTrainingSession())?.toJson(), durable);
          }
        });
      },
    );
  }
}
