import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:eatova/src/models/training_plan.dart';
import 'package:eatova/src/models/training_plan_head.dart';
import 'package:eatova/src/models/training_session.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/sync_outbox.dart';
import 'package:eatova/src/services/training_session_source.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/atomic_store_faults.dart';
import '../training/training_timer_fixtures.dart';

const source = 'generation-proposal';
final planId = trainingPlanIdForMessage(source);
TrainingPlan plan([int generation = 0]) => TrainingPlan(
  id: planId,
  sourceId: source,
  incarnation: generation,
  proposal: timerPlan().proposal,
);
TrainingPlanHead head(int generation, {bool deleted = false}) =>
    TrainingPlanHead(
      sourceId: source,
      planId: planId,
      incarnation: generation,
      deleted: deleted,
      plan: deleted ? null : plan(generation),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'an offline deletion of an unloaded coach plan records the known tombstone',
    () async {
      final cache = LocalCache(InMemoryKeyValueStore(), 'A');
      await cache.commitSyncOperations([SyncOp.trainingPlanDelete(planId)]);
      final adoption = SyncOp.trainingPlanUpsert(plan(), adoption: true);
      final committed = await cache.commitSyncOperations([adoption]);
      expect(committed.operations.last.trainingIncarnation, 1);
      expect((await cache.readTrainingPlans())!.single.incarnation, 1);
    },
  );

  for (final deleting in [false, true]) {
    test(
      'old pending ${deleting ? 'delete' : 'edit'} does not block a current-generation checkpoint',
      () async {
        await withClock(Clock.fixed(DateTime.utc(2026, 9, 20, 12)), () async {
          final cache = LocalCache(InMemoryKeyValueStore(), 'A');
          final current = SyncOp.trainingPlanUpsert(plan(1));
          await cache.commitSyncOperations([current]);
          await cache.acknowledgeSyncOperation(
            current.operationId,
            LocalSyncResult(trainingHead: head(1), trainingPlan: plan(1)),
          );
          await cache.commitSyncOperations([
            deleting
                ? SyncOp.trainingPlanDelete(planId)
                : SyncOp.trainingPlanUpsert(plan()),
          ]);
          final checkpoint = TrainingSessionSnapshot(
            plan: plan(1),
            workoutIndex: 0,
            exerciseIndex: 0,
            setIndex: 0,
            phase: TrainingSessionPhase.exercise,
            remainingMilliseconds: 0,
          );
          await cache.commitTrainingCheckpoint(
            checkpoint,
            expectedSnapshot: null,
          );
          expect(
            (await cache.readTrainingSession())!.toJson(),
            checkpoint.toJson(),
          );
          expect(
            (await cache.readSyncOperations()).single.trainingIncarnation,
            0,
          );
        });
      },
    );
  }

  test(
    'confirmed delete and re-adoption advance a durable head in the entity transaction',
    () async {
      final memory = InMemoryKeyValueStore();
      final faults = AtomicStoreFaults(memory);
      final cache = LocalCache(faults, 'A');
      final first = SyncOp.trainingPlanUpsert(plan(), adoption: true);
      await cache.commitSyncOperations([first]);
      await cache.acknowledgeSyncOperation(
        first.operationId,
        LocalSyncResult(trainingHead: head(0), trainingPlan: plan()),
      );
      final deletion = SyncOp.trainingPlanDelete(planId);
      await cache.commitSyncOperations([deletion]);
      await cache.acknowledgeSyncOperation(
        deletion.operationId,
        LocalSyncResult(
          trainingHead: head(0, deleted: true),
          entityDeleted: true,
        ),
      );
      final adoption = SyncOp.trainingPlanUpsert(plan(), adoption: true);
      Map<String, String?>? attempted;
      faults.beforeWrite = (changes) async {
        if (changes.containsKey('eatova.v1.training_plans.A')) {
          attempted = Map.of(changes);
          throw StateError('Commit failed');
        }
      };
      await expectLater(
        cache.commitSyncOperations([adoption]),
        throwsStateError,
      );
      expect(
        attempted!.keys,
        containsAll([
          'eatova.v1.training_heads.A',
          'eatova.v1.training_plans.A',
          'eatova.v1.outbox.A',
        ]),
      );
      expect(await cache.readTrainingPlans(), isEmpty);
      expect(await cache.readSyncOperations(), isEmpty);
      faults.beforeWrite = null;
      final committed = await cache.commitSyncOperations([adoption]);
      expect(committed.operations.single.operationId, adoption.operationId);
      expect(committed.operations.single.trainingIncarnation, 1);
      expect((await cache.readTrainingPlans())!.single.incarnation, 1);
      final reboot = LocalCache(memory, 'A');
      expect((await reboot.readSyncOperations()).single.trainingIncarnation, 1);
      expect((await reboot.readTrainingPlans())!.single.incarnation, 1);
    },
  );

  test(
    'late frozen generation-zero deletes cannot remove generation one or its checkpoint',
    () async {
      await withClock(Clock.fixed(DateTime.utc(2026, 9, 20, 12)), () async {
        final cache = LocalCache(InMemoryKeyValueStore(), 'A');
        final first = SyncOp.trainingPlanUpsert(plan(), adoption: true);
        await cache.commitSyncOperations([first]);
        await cache.acknowledgeSyncOperation(
          first.operationId,
          LocalSyncResult(trainingHead: head(0), trainingPlan: plan()),
        );
        final old = SyncOp.trainingPlanDelete(planId);
        await cache.commitSyncOperations([old]);
        final started = (await cache.startSyncOperation(old.operationId))!;
        final wire = jsonEncode(started.wirePayload);
        final renewed = SyncOp.trainingPlanUpsert(plan(), adoption: true);
        await cache.commitSyncOperations([renewed]);
        final snapshot = TrainingSessionSnapshot(
          plan: plan(1),
          workoutIndex: 0,
          exerciseIndex: 0,
          setIndex: 0,
          phase: TrainingSessionPhase.exercise,
          remainingMilliseconds: 0,
        );
        await cache.commitTrainingCheckpoint(snapshot, expectedSnapshot: null);
        await cache.acknowledgeSyncOperation(
          old.operationId,
          LocalSyncResult(
            trainingHead: head(0, deleted: true),
            entityDeleted: true,
          ),
        );
        expect(await cache.readTrainingPlans(), hasLength(1));
        expect((await cache.readTrainingPlans())!.single.incarnation, 1);
        expect((await cache.readTrainingSession())!.plan.incarnation, 1);
        expect(
          (await cache.readSyncOperations()).single.trainingIncarnation,
          1,
        );
        expect(
          jsonEncode(SyncOp.tryFromJson(started.toJson())!.wirePayload),
          wire,
        );
        expect(started.trainingIncarnation, 0);
      });
    },
  );

  for (final deleted in [false, true]) {
    test(
      'unknown-head intent remains exact and visible until explicit ${deleted ? 'new generation' : 'active generation'} resolution',
      () async {
        final memory = InMemoryKeyValueStore();
        final faults = AtomicStoreFaults(memory);
        final cache = LocalCache(faults, 'A');
        final old = SyncOp.trainingPlanUpsert(plan(), adoption: true);
        await cache.commitSyncOperations([old]);
        final started = (await cache.startSyncOperation(old.operationId))!;
        final wire = jsonEncode(started.wirePayload);
        await cache.acknowledgeSyncOperation(
          old.operationId,
          LocalSyncResult(
            trainingHead: head(3, deleted: deleted),
            trainingHeadConflict: true,
            trainingPlan: deleted ? null : plan(3),
            entityDeleted: deleted,
          ),
        );
        await cache.retryBlockedSyncOperations();
        var queue = await cache.readSyncOperations();
        expect(queue.single.operationId, old.operationId);
        expect(
          queue.single.blockedReason,
          SyncBlockedReason.trainingHeadConflict,
        );
        expect(jsonEncode(queue.single.wirePayload), wire);
        expect((await cache.readTrainingPlans())!.single.incarnation, 0);
        expect(await cache.startSyncOperation(old.operationId), isNull);
        await expectLater(
          cache.commitSyncOperations([SyncOp.trainingPlanDelete(planId)]),
          throwsStateError,
        );
        expect(
          (await cache.readSyncOperations()).single.operationId,
          old.operationId,
        );
        expect((await cache.readTrainingPlans())!.single.incarnation, 0);
        final next = SyncOp.trainingPlanUpsert(
          plan(deleted ? 4 : 3),
          adoption: true,
        );
        faults.beforeWrite = (changes) async {
          if (changes.containsKey('eatova.v1.training_plans.A')) {
            throw StateError('Disk unavailable');
          }
        };
        await expectLater(
          cache.commitSyncOperations(
            [next],
            replacingTrainingAdoption: old.operationId,
            resolvedTrainingHead: head(3, deleted: deleted),
          ),
          throwsStateError,
        );
        queue = await cache.readSyncOperations();
        expect(queue.single.operationId, old.operationId);
        expect(jsonEncode(queue.single.wirePayload), wire);
        faults.beforeWrite = null;
        await cache.commitSyncOperations(
          [next],
          replacingTrainingAdoption: old.operationId,
          resolvedTrainingHead: head(3, deleted: deleted),
        );
        queue = await cache.readSyncOperations();
        expect(queue.single.operationId, next.operationId);
        expect(queue.single.operationId, isNot(old.operationId));
        expect(queue.single.trainingIncarnation, deleted ? 4 : 3);
        expect(
          (await cache.readTrainingPlans())!.single.incarnation,
          deleted ? 4 : 3,
        );
      },
    );
  }

  test(
    'stale old upsert and deleted receipt do not overlay a newer canonical generation',
    () async {
      final cache = LocalCache(InMemoryKeyValueStore(), 'A');
      final first = SyncOp.trainingPlanUpsert(plan(1));
      await cache.commitSyncOperations([first]);
      await cache.acknowledgeSyncOperation(
        first.operationId,
        LocalSyncResult(trainingHead: head(1), trainingPlan: plan(1)),
      );
      final old = SyncOp.trainingPlanUpsert(plan());
      await cache.commitSyncOperations([old]);
      expect((await cache.readTrainingPlans())!.single.incarnation, 1);
      await cache.acknowledgeSyncOperation(
        old.operationId,
        LocalSyncResult(
          trainingHead: head(1),
          trainingPlan: plan(1),
          entityDeleted: true,
        ),
      );
      expect((await cache.readTrainingPlans())!.single.incarnation, 1);
      expect(await cache.readSyncOperations(), isEmpty);
    },
  );

  test(
    'a late captured delete receipt preserves a separately observed newer generation',
    () async {
      final cache = LocalCache(InMemoryKeyValueStore(), 'A');
      final old = SyncOp.trainingPlanDelete(planId);
      await cache.commitSyncOperations([old]);
      await cache.startSyncOperation(old.operationId);
      final before = await cache.readMutationSnapshot();
      await cache.commitStoreSnapshot(
        trainingPlans: [plan(1)],
        expectedVersions: before.snapshot.versions,
      );
      expect((await cache.readTrainingPlans())!.single.incarnation, 1);
      await cache.acknowledgeSyncOperation(
        old.operationId,
        LocalSyncResult(
          trainingHead: head(0, deleted: true),
          entityDeleted: true,
        ),
      );
      expect((await cache.readTrainingPlans())!.single.incarnation, 1);
      expect(await cache.readSyncOperations(), isEmpty);
    },
  );

  test(
    'an old workout cannot match a new incarnation even with identical exercises',
    () {
      withClock(Clock.fixed(DateTime.utc(2026, 9, 20, 12)), () {
        final old = TrainingSessionSnapshot(
          plan: plan(),
          workoutIndex: 0,
          exerciseIndex: 0,
          setIndex: 0,
          phase: TrainingSessionPhase.exercise,
          remainingMilliseconds: 0,
        );
        expect(trainingSessionMatchesPlan(old, plan()), isTrue);
        expect(trainingSessionMatchesPlan(old, plan(1)), isFalse);
      });
    },
  );

  test(
    'offline discard is atomic, rejects foreign operation IDs, and issues no delete intent',
    () async {
      final faults = AtomicStoreFaults(InMemoryKeyValueStore());
      final cache = LocalCache(faults, 'A');
      final op = SyncOp.trainingPlanUpsert(plan(), adoption: true);
      await cache.commitSyncOperations([op]);
      await cache.startSyncOperation(op.operationId);
      await cache.acknowledgeSyncOperation(
        op.operationId,
        LocalSyncResult(
          trainingHead: head(3, deleted: true),
          trainingHeadConflict: true,
        ),
      );
      final edit = SyncOp.trainingPlanUpsert(plan());
      await cache.commitSyncOperations([edit]);
      await expectLater(
        cache.discardTrainingAdoption('other'),
        throwsStateError,
      );
      faults.beforeWrite = (changes) async {
        if (changes.containsKey('eatova.v1.training_plans.A')) {
          throw StateError('Disk full');
        }
      };
      await expectLater(
        cache.discardTrainingAdoption(op.operationId),
        throwsStateError,
      );
      expect((await cache.readSyncOperations()).map((op) => op.operationId), [
        op.operationId,
        edit.operationId,
      ]);
      expect(await cache.readTrainingPlans(), hasLength(1));
      faults.beforeWrite = null;
      await cache.discardTrainingAdoption(op.operationId);
      expect(await cache.readSyncOperations(), isEmpty);
      expect(await cache.readTrainingPlans(), isEmpty);
    },
  );

  test(
    'discard preserves frozen successors and unrelated generations byte for byte',
    () async {
      final cache = LocalCache(InMemoryKeyValueStore(), 'A');
      final op = SyncOp.trainingPlanUpsert(plan(), adoption: true);
      await cache.commitSyncOperations([op]);
      await cache.acknowledgeSyncOperation(
        op.operationId,
        LocalSyncResult(
          trainingHead: head(3, deleted: true),
          trainingHeadConflict: true,
        ),
      );
      final frozen = SyncOp.trainingPlanUpsert(
        plan(),
      ).freezeWirePayload({'row': plan().toRow()});
      final newer = SyncOp.trainingPlanUpsert(plan(4));
      await cache.commitSyncOperations([frozen, newer]);
      final wire = jsonEncode(frozen.toJson());
      await cache.discardTrainingAdoption(op.operationId);
      final pending = await cache.readSyncOperations();
      expect(pending.map((op) => op.operationId), [
        frozen.operationId,
        newer.operationId,
      ]);
      expect(jsonEncode(pending.first.toJson()), wire);
      expect((await cache.readTrainingPlans())!.single.incarnation, 4);
    },
  );

  test(
    'explicit discard can restore an already verified current server plan',
    () async {
      final cache = LocalCache(InMemoryKeyValueStore(), 'A');
      final op = SyncOp.trainingPlanUpsert(plan(), adoption: true);
      await cache.commitSyncOperations([op]);
      await cache.acknowledgeSyncOperation(
        op.operationId,
        LocalSyncResult(
          trainingHead: head(3),
          trainingHeadConflict: true,
          trainingPlan: plan(3),
        ),
      );
      await cache.discardTrainingAdoption(
        op.operationId,
        verifiedHead: head(3),
      );
      expect(await cache.readSyncOperations(), isEmpty);
      expect((await cache.readTrainingPlans())!.single.incarnation, 3);
    },
  );
}
