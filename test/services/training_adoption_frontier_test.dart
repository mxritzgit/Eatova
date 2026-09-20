import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:eatova/src/models/training_plan.dart';
import 'package:eatova/src/models/training_session.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/sync_outbox.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/atomic_store_faults.dart';
import 'training_incarnation_atomic_test.dart' show plan, head;

TrainingPlan draft(String title) => TrainingPlan.fromRow({
  ...plan().toRow(),
  'plan': {...plan().proposal.toJson(), 'title': title},
});

TrainingSessionSnapshot checkpoint({bool completion = false}) =>
    TrainingSessionSnapshot(
      plan: plan(),
      workoutIndex: 0,
      exerciseIndex: completion ? 1 : 0,
      setIndex: completion ? 1 : 0,
      phase: completion
          ? TrainingSessionPhase.review
          : TrainingSessionPhase.exercise,
      remainingMilliseconds: 0,
      skippedSets: completion
          ? [
              for (var exercise = 0; exercise < 2; exercise++)
                for (var set = 0; set < 2; set++)
                  TrainingSetReference(exerciseIndex: exercise, setIndex: set),
            ]
          : const [],
      pendingCompletionAt: completion ? clock.now() : null,
      pendingCompletionNote: completion ? '' : null,
    );

Future<void> conflict(LocalCache cache, SyncOp op) async {
  await cache.acknowledgeSyncOperation(
    op.operationId,
    LocalSyncResult(trainingHead: head(3), trainingHeadConflict: true),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a head change after checkpoint validation invalidates the database commit',
    () async {
      await withClock(Clock.fixed(DateTime.utc(2026, 9, 20, 12)), () async {
        final memory = InMemoryKeyValueStore();
        final faults = AtomicStoreFaults(memory);
        final cache = LocalCache(faults, 'A');
        final a = SyncOp.trainingPlanUpsert(plan());
        await cache.commitSyncOperations([a]);
        await cache.acknowledgeSyncOperation(
          a.operationId,
          LocalSyncResult(trainingHead: head(0), trainingPlan: plan()),
        );
        faults.beforeWrite = (changes) async {
          if (!changes.containsKey('eatova.v1.training_session.A')) return;
          faults.beforeWrite = null;
          await memory.writeBatch({
            'eatova.v1.training_heads.A': jsonEncode({
              plan().id: {
                'source_id': plan().coachSourceId,
                'incarnation': 3,
                'deleted': false,
              },
            }),
          });
        };
        await expectLater(
          cache.commitTrainingCheckpoint(checkpoint(), expectedSnapshot: null),
          throwsA(isA<KeyValueConflict>()),
        );
        expect(await cache.readTrainingSession(), isNull);
      });
    },
  );

  test(
    'explicit review commits B with one new UUID and removes only its reviewed frontier',
    () async {
      final memory = InMemoryKeyValueStore();
      final faults = AtomicStoreFaults(memory);
      final cache = LocalCache(faults, 'A');
      final a = SyncOp.trainingPlanUpsert(draft('A'), adoption: true);
      final b = SyncOp.trainingPlanUpsert(draft('B'));
      final other = SyncOp.trainingPlanUpsert(
        TrainingPlan(id: 'other', proposal: plan().proposal),
      );
      await cache.commitSyncOperations([a]);
      await cache.startSyncOperation(a.operationId);
      await cache.commitSyncOperations([other, b]);
      await conflict(cache, a);
      final before = await cache.readMutationSnapshot();
      final review = trainingAdoptionReviewOps(
        before.operations,
        a.operationId,
      );
      expect(review.last.operationId, b.operationId);
      expect(review.last.trainingPlan!.proposal.title, 'B');
      final replacement = SyncOp.trainingPlanUpsert(
        draft('Reviewed B').copyWith(incarnation: 3),
        adoption: true,
      );
      Future<LocalMutationReceipt> resolve() => cache.commitSyncOperations(
        [replacement],
        replacingTrainingAdoption: a.operationId,
        expectedTrainingDraftOperationId: b.operationId,
        resolvedTrainingHead: head(3),
      );
      faults.beforeWrite = (_) async => throw StateError('Commit failed');
      await expectLater(resolve(), throwsStateError);
      faults.beforeWrite = null;
      expect(
        (await cache.readMutationSnapshot()).snapshot.values,
        before.snapshot.values,
      );
      final committed = await resolve();
      expect(committed.operations.map((op) => op.operationId), [
        other.operationId,
        replacement.operationId,
      ]);
      expect(committed.operations.last.wirePayload, isNull);
      expect(
        (await cache.readTrainingPlans())!
            .firstWhere((entry) => entry.id == plan().id)
            .proposal
            .title,
        'Reviewed B',
      );
      expect(
        committed.operations.first.toJson(),
        before.operations[1].toJson(),
      );
    },
  );

  test(
    'C confirmed after review makes the whole B resolution fail without a write',
    () async {
      final cache = LocalCache(InMemoryKeyValueStore(), 'A');
      final a = SyncOp.trainingPlanUpsert(draft('A'), adoption: true);
      final b = SyncOp.trainingPlanUpsert(draft('B'));
      await cache.commitSyncOperations([a]);
      await cache.startSyncOperation(a.operationId);
      await cache.commitSyncOperations([b]);
      await conflict(cache, a);
      final c = SyncOp.trainingPlanUpsert(draft('C'));
      await cache.commitSyncOperations([c]);
      final before = await cache.readMutationSnapshot();
      await expectLater(
        cache.commitSyncOperations(
          [
            SyncOp.trainingPlanUpsert(
              draft('Reviewed B').copyWith(incarnation: 3),
              adoption: true,
            ),
          ],
          replacingTrainingAdoption: a.operationId,
          expectedTrainingDraftOperationId: b.operationId,
          resolvedTrainingHead: head(3),
        ),
        throwsStateError,
      );
      expect(
        (await cache.readMutationSnapshot()).snapshot.values,
        before.snapshot.values,
      );
      expect((await cache.readTrainingPlans())!.single.proposal.title, 'C');
    },
  );

  for (final tail in ['frozen', 'other generation', 'delete']) {
    test('resolve never consumes a $tail successor', () async {
      final cache = LocalCache(InMemoryKeyValueStore(), 'A');
      final a = SyncOp.trainingPlanUpsert(draft('A'), adoption: true);
      final b = SyncOp.trainingPlanUpsert(draft('B'));
      final separate = switch (tail) {
        'frozen' => SyncOp.trainingPlanUpsert(
          draft('Frozen'),
        ).freezeWirePayload({'immutable': 'wire'}),
        'delete' => SyncOp.trainingPlanDelete(plan().id),
        _ => SyncOp.trainingPlanUpsert(plan(4)),
      };
      await cache.commitSyncOperations([a]);
      await cache.startSyncOperation(a.operationId);
      await cache.commitSyncOperations([b, separate]);
      await conflict(cache, a);
      final before = await cache.readMutationSnapshot();
      expect(
        trainingAdoptionReviewOps(
          before.operations,
          a.operationId,
          requireResolvable: false,
        ).last.operationId,
        b.operationId,
      );
      await expectLater(
        cache.commitSyncOperations(
          [
            SyncOp.trainingPlanUpsert(
              draft('Reviewed B').copyWith(incarnation: 3),
              adoption: true,
            ),
          ],
          replacingTrainingAdoption: a.operationId,
          expectedTrainingDraftOperationId: b.operationId,
          resolvedTrainingHead: head(3),
        ),
        throwsStateError,
      );
      expect(
        (await cache.readMutationSnapshot()).snapshot.values,
        before.snapshot.values,
      );
    });
  }

  test('hydration preserves confirmed B behind rejected in-flight A', () async {
    final memory = InMemoryKeyValueStore();
    final cache = LocalCache(memory, 'A');
    final a = SyncOp.trainingPlanUpsert(draft('A'), adoption: true);
    final b = SyncOp.trainingPlanUpsert(draft('B'));
    await cache.commitSyncOperations([a]);
    await cache.startSyncOperation(a.operationId);
    await cache.commitSyncOperations([b]);
    await conflict(cache, a);
    final snapshot = await cache.readMutationSnapshot();
    await cache.commitStoreSnapshot(
      expectedVersions: snapshot.snapshot.versions,
      trainingPlans: [head(3).plan!],
    );
    final reboot = LocalCache(memory, 'A');
    expect((await reboot.readTrainingPlans())!.single.proposal.title, 'B');
    final pending = await reboot.readSyncOperations();
    expect(pending.map((op) => op.operationId), [a.operationId, b.operationId]);
    expect(pending.first.wirePayload, isNotNull);
    expect(pending.last.blockedReason, isNull);
  });

  for (final existing in [false, true]) {
    test(
      'head conflict rejects ${existing ? 'continued' : 'new'} checkpoint',
      () async {
        await withClock(Clock.fixed(DateTime.utc(2026, 9, 20, 12)), () async {
          final cache = LocalCache(InMemoryKeyValueStore(), 'A');
          final a = SyncOp.trainingPlanUpsert(plan(), adoption: true);
          await cache.commitSyncOperations([a]);
          final saved = existing ? checkpoint() : null;
          if (saved != null) {
            await cache.commitTrainingCheckpoint(saved, expectedSnapshot: null);
          }
          await cache.startSyncOperation(a.operationId);
          await conflict(cache, a);
          await expectLater(
            cache.commitTrainingCheckpoint(
              saved ?? checkpoint(),
              expectedSnapshot: saved,
            ),
            throwsStateError,
          );
          expect(
            (await cache.readTrainingSession())?.toJson(),
            saved?.toJson(),
          );
        });
      },
    );
  }

  test(
    'already durable completion remains retryable after head conflict',
    () async {
      await withClock(Clock.fixed(DateTime.utc(2026, 9, 20, 12)), () async {
        final cache = LocalCache(InMemoryKeyValueStore(), 'A');
        final a = SyncOp.trainingPlanUpsert(plan(), adoption: true);
        await cache.commitSyncOperations([a]);
        final saved = checkpoint(completion: true);
        await cache.commitTrainingCheckpoint(saved, expectedSnapshot: null);
        await cache.startSyncOperation(a.operationId);
        await conflict(cache, a);
        await cache.commitTrainingCheckpoint(saved, expectedSnapshot: saved);
        expect((await cache.readTrainingSession())!.toJson(), saved.toJson());
      });
    },
  );

  test('a new completion flag cannot bypass a known head conflict', () async {
    await withClock(Clock.fixed(DateTime.utc(2026, 9, 20, 12)), () async {
      final cache = LocalCache(InMemoryKeyValueStore(), 'A');
      final a = SyncOp.trainingPlanUpsert(plan(), adoption: true);
      await cache.commitSyncOperations([a]);
      await cache.startSyncOperation(a.operationId);
      await conflict(cache, a);
      await expectLater(
        cache.commitTrainingCheckpoint(
          checkpoint(completion: true),
          expectedSnapshot: null,
        ),
        throwsStateError,
      );
      expect(await cache.readTrainingSession(), isNull);
    });
  });
}
