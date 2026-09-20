import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:eatova/src/models/favorite_meal.dart';
import 'package:eatova/src/models/lifetime_stats.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/training_history.dart';
import 'package:eatova/src/models/training_session.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/sync_outbox.dart';
import 'package:flutter_test/flutter_test.dart';

import '../outbox/outbox_test_helpers.dart' show mealResult, userRecipe;
import '../training/training_timer_fixtures.dart';

const _owner = 'atomic-user';
String _key(String slot) => 'eatova.v1.$slot.$_owner';
final _now = DateTime.utc(2026, 9, 20, 12);

class _FaultStore extends InMemoryKeyValueStore {
  bool failCommit = false;
  String? unreadable;

  @override
  Future<KeyValueSnapshot> readSnapshot(Iterable<String> keys) async {
    if (keys.contains(unreadable)) throw StateError('Injected unreadable slot');
    return super.readSnapshot(keys);
  }

  @override
  Future<KeyValueCommit> writeBatch(
    Map<String, String?> changes, {
    Map<String, int> expectedVersions = const {},
  }) async {
    if (failCommit && changes.isNotEmpty) {
      throw StateError('Injected disk failure');
    }
    return super.writeBatch(changes, expectedVersions: expectedVersions);
  }
}

LoggedMeal _meal(String id) =>
    LoggedMeal(id: id, result: mealResult(id), loggedAt: _now);

TrainingSessionSnapshot _review() => TrainingSessionSnapshot(
  plan: timerPlan(),
  workoutIndex: 0,
  exerciseIndex: 1,
  setIndex: 1,
  phase: TrainingSessionPhase.review,
  remainingMilliseconds: 0,
  startedAt: _now,
  skippedSets: const [
    TrainingSetReference(exerciseIndex: 0, setIndex: 0),
    TrainingSetReference(exerciseIndex: 0, setIndex: 1),
    TrainingSetReference(exerciseIndex: 1, setIndex: 0),
    TrainingSetReference(exerciseIndex: 1, setIndex: 1),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'failed transaction leaves meal, recent, stats and outbox unchanged',
    () async {
      await withClock(Clock.fixed(_now), () async {
        final kv = _FaultStore();
        final cache = LocalCache(kv, _owner);
        final op = SyncOp.mealInsert(_meal('meal-1'), trackDay: true);
        final favorite = FavoriteMeal(
          id: 'recent-1',
          result: mealResult('Food'),
          addedAt: _now,
        );
        kv.failCommit = true;
        await expectLater(
          cache.commitSyncOperations([op, SyncOp.favoriteUpsert(favorite)]),
          throwsStateError,
        );
        expect(await kv.getString(_key('logged_meals')), isNull);
        expect(await kv.getString(_key('favorites')), isNull);
        expect(await kv.getString(_key('stats')), isNull);
        expect(await kv.getString(_key('outbox')), isNull);
        kv.failCommit = false;
        await cache.commitSyncOperations([op, SyncOp.favoriteUpsert(favorite)]);
        final restarted = LocalCache(kv, _owner);
        expect((await restarted.readLoggedMeals())!.single.id, 'meal-1');
        expect((await restarted.readFavorites())!.single.id, 'recent-1');
        expect((await restarted.readLifetimeStats())!.mealsLogged, 1);
        expect(await restarted.readSyncOperations(), hasLength(2));
      });
    },
  );

  test(
    'concurrent cache instances keep both committed entities and UUIDs',
    () async {
      final kv = _FaultStore();
      final first = LocalCache(kv, _owner), second = LocalCache(kv, _owner);
      final a = SyncOp.mealInsert(_meal('a'), trackDay: false);
      final b = SyncOp.mealInsert(_meal('b'), trackDay: false);
      await Future.wait([
        first.commitSyncOperations([a]),
        second.commitSyncOperations([b]),
      ]);
      expect(
        (await first.readSyncOperations()).map((op) => op.operationId).toSet(),
        {a.operationId, b.operationId},
      );
      expect((await first.readLoggedMeals())!.map((meal) => meal.id).toSet(), {
        'a',
        'b',
      });
      expect((await first.readLifetimeStats())!.mealsLogged, 2);
    },
  );

  test(
    'ack failure preserves exact request and retry applies receipt once',
    () async {
      final kv = _FaultStore();
      final cache = LocalCache(kv, _owner);
      final op = SyncOp.mealInsert(_meal('one'), trackDay: false);
      await cache.commitSyncOperations([op]);
      await cache.startSyncOperation(op.operationId);
      final started = (await cache.readSyncOperations()).single.toJson();
      kv.failCommit = true;
      await expectLater(
        cache.acknowledgeSyncOperation(
          op.operationId,
          LocalSyncResult(stats: LifetimeStats(mealsLogged: 7)),
        ),
        throwsStateError,
      );
      kv.failCommit = false;
      expect((await cache.readSyncOperations()).single.toJson(), started);
      await cache.acknowledgeSyncOperation(
        op.operationId,
        LocalSyncResult(stats: LifetimeStats(mealsLogged: 7)),
      );
      await cache.acknowledgeSyncOperation(
        op.operationId,
        LocalSyncResult(stats: LifetimeStats(mealsLogged: 99)),
      );
      expect(await cache.readSyncOperations(), isEmpty);
      expect((await cache.readLifetimeStats())!.mealsLogged, 7);
    },
  );

  test(
    'same-entity successor cannot overtake ambiguous or blocked predecessor',
    () async {
      final cache = LocalCache(_FaultStore(), _owner);
      final first = SyncOp.mealInsert(_meal('shared'), trackDay: false);
      final second = SyncOp.mealDelete('shared');
      await cache.commitSyncOperations([first, second]);
      expect(await cache.startSyncOperation(first.operationId), isNotNull);
      await cache.recordSyncFailure(first.operationId, countAttempt: false);
      expect(await cache.startSyncOperation(second.operationId), isNull);
      await cache.recordSyncFailure(
        first.operationId,
        countAttempt: true,
        blockedReason: SyncBlockedReason.backendUnavailable,
      );
      expect(await cache.startSyncOperation(second.operationId), isNull);
      expect(
        (await cache.readSyncOperations()).first.blockedReason,
        SyncBlockedReason.backendUnavailable,
      );
      await cache.retryBlockedSyncOperations();
      expect(
        (await cache.startSyncOperation(first.operationId))!.operationId,
        first.operationId,
      );
      await cache.acknowledgeSyncOperation(
        first.operationId,
        const LocalSyncResult(),
      );
      expect(await cache.startSyncOperation(second.operationId), isNotNull);
    },
  );

  test(
    'old recipe receipt rebases exact successor and retains newer draft',
    () async {
      final cache = LocalCache(_FaultStore(), _owner);
      final first = SyncOp.recipeUpsert(
        userRecipe('own', title: 'First'),
        expectedRevision: 4,
      );
      final second = SyncOp.recipeUpsert(
        userRecipe('own', title: 'Second'),
        expectedRevision: 4,
      );
      final third = SyncOp.recipeUpsert(
        userRecipe('own', title: 'Third'),
        expectedRevision: 4,
      );
      await cache.commitSyncOperations([first, second, third]);
      final saved = userRecipe(
        'own',
        title: 'First',
      ).copyWith(serverRevision: 5);
      await cache.acknowledgeSyncOperation(
        first.operationId,
        LocalSyncResult(recipe: saved, currentRecipe: saved, recipeRevision: 5),
      );
      final queue = await cache.readSyncOperations();
      expect(queue[0].operationId, second.operationId);
      expect(queue[0].expectedRevision, 5);
      expect(queue[0].predecessorId, isNull);
      expect(queue[1].predecessorId, second.operationId);
      expect(queue[1].expectedRevision, 4);
      expect((await cache.readUserRecipes())!.single.title, 'Third');
    },
  );

  test(
    'conflict copy and original survive atomically with successor retarget',
    () async {
      final cache = LocalCache(_FaultStore(), _owner);
      final first = SyncOp.recipeUpsert(
        userRecipe('own', title: 'First'),
        expectedRevision: 1,
      );
      final second = SyncOp.recipeUpsert(
        userRecipe('own', title: 'Second'),
        expectedRevision: 1,
      );
      await cache.commitSyncOperations([first, second]);
      final original = userRecipe(
        'own',
        title: 'Remote',
      ).copyWith(serverRevision: 8);
      final saved = userRecipe(
        'copy',
        title: 'First',
      ).copyWith(serverRevision: 1, conflictOf: 'own');
      await cache.acknowledgeSyncOperation(
        first.operationId,
        LocalSyncResult(
          recipe: saved,
          currentRecipe: original,
          recipeRevision: 8,
          recipeOutcome: 'conflictSaved',
        ),
      );
      final next = (await cache.readSyncOperations()).single;
      expect(next.entityId, 'copy');
      expect(next.expectedRevision, 1);
      final recipes = await cache.readUserRecipes();
      expect(
        recipes!.map((recipe) => '${recipe.slug}:${recipe.title}').toSet(),
        {'own:Remote', 'copy:Second'},
      );
    },
  );

  test(
    'stale foreground snapshot cannot erase background ack or conflict copy',
    () async {
      final kv = _FaultStore();
      final foreground = LocalCache(kv, _owner),
          background = LocalCache(kv, _owner);
      final op = SyncOp.recipeUpsert(userRecipe('own'), expectedRevision: 1);
      await foreground.commitSyncOperations([op]);
      final before = await foreground.readMutationSnapshot();
      final copy = userRecipe(
        'conflict',
      ).copyWith(serverRevision: 1, conflictOf: 'own');
      await background.acknowledgeSyncOperation(
        op.operationId,
        LocalSyncResult(
          recipe: copy,
          currentRecipe: userRecipe('own').copyWith(serverRevision: 4),
          recipeRevision: 4,
          recipeOutcome: 'conflictSaved',
        ),
      );
      await expectLater(
        foreground.commitStoreSnapshot(
          expectedVersions: before.snapshot.versions,
          recipes: [userRecipe('own')],
        ),
        throwsA(isA<KeyValueConflict>()),
      );
      expect(
        (await foreground.readUserRecipes())!
            .map((recipe) => recipe.slug)
            .toSet(),
        {'own', 'conflict'},
      );
      expect(await foreground.readSyncOperations(), isEmpty);
    },
  );

  test(
    'current canonical revision never becomes the successor wire basis',
    () async {
      final cache = LocalCache(_FaultStore(), _owner);
      final first = SyncOp.recipeUpsert(
        userRecipe('own', title: 'First'),
        expectedRevision: 4,
      );
      final next = SyncOp.recipeUpsert(
        userRecipe('own', title: 'Next'),
        expectedRevision: 4,
      );
      await cache.commitSyncOperations([first, next]);
      // The receipt originally produced revision 5; a different device has
      // meanwhile produced revision 9. This edit must conflict against 9.
      final current = userRecipe(
        'own',
        title: 'Other device',
      ).copyWith(serverRevision: 9);
      await cache.acknowledgeSyncOperation(
        first.operationId,
        LocalSyncResult(
          recipe: current,
          currentRecipe: current,
          recipeRevision: 9,
          recipeBaseRevision: 5,
          recipeBaseSlug: 'own',
        ),
      );
      expect((await cache.readSyncOperations()).single.expectedRevision, 5);
      expect((await cache.readUserRecipes())!.single.title, 'Next');
    },
  );

  test(
    'session generation change fences entity commit and account purge',
    () async {
      final kv = _FaultStore();
      final cache = LocalCache(kv, _owner);
      const key = 'eatova.v1.sync_session.current';
      await kv.setString(key, 'old');
      final old = await kv.readSnapshot([key]);
      await kv.setString(key, 'new');
      await expectLater(
        cache.commitSyncOperations([
          SyncOp.mealInsert(_meal('old-account-action'), trackDay: false),
        ], guards: old.versions),
        throwsA(isA<KeyValueConflict>()),
      );
      expect(await cache.readLoggedMeals(), isNull);
      await cache.commitSyncOperations([
        SyncOp.mealInsert(_meal('new-account-action'), trackDay: false),
      ]);
      await expectLater(
        cache.clear(guards: old.versions),
        throwsA(isA<KeyValueConflict>()),
      );
      expect(
        (await LocalCache(kv, _owner).readLoggedMeals())!.single.id,
        'new-account-action',
      );
    },
  );

  test(
    'queued payload cannot be changed after operation identity is assigned',
    () {
      final op = SyncOp.mealInsert(_meal('immutable'), trackDay: false);
      expect(() => op.payload['meal'] = {}, throwsUnsupportedError);
      expect(
        () => (op.payload['meal'] as Map)['id'] = 'different',
        throwsUnsupportedError,
      );
    },
  );

  test(
    'training completion atomically replaces recovery; delete cannot resurrect it',
    () async {
      await withClock(Clock.fixed(_now), () async {
        final kv = _FaultStore();
        final cache = LocalCache(kv, _owner);
        final snapshot = _review();
        expect(await cache.writeTrainingSession(snapshot), isTrue);
        final entry = TrainingHistoryEntry(
          snapshot: snapshot,
          finishedAt: _now,
          note: 'Done',
        );
        final op = SyncOp.trainingHistoryInsert(entry);
        kv.failCommit = true;
        await expectLater(cache.commitSyncOperations([op]), throwsStateError);
        expect(
          (await cache.readTrainingSession())!.sessionId,
          snapshot.sessionId,
        );
        expect(await cache.readTrainingHistory(), isNull);
        kv.failCommit = false;
        await cache.commitSyncOperations([op]);
        expect(await cache.readTrainingSession(), isNull);
        expect(
          (await cache.readTrainingHistory())!.single.id,
          snapshot.sessionId,
        );
        await cache.commitSyncOperations([
          SyncOp.trainingHistoryDelete(entry.id),
        ]);
        await expectLater(
          cache.commitSyncOperations([SyncOp.trainingHistoryInsert(entry)]),
          throwsStateError,
        );
        expect(await cache.readTrainingHistory(), isEmpty);
        expect(await cache.readTrainingHistoryDeletions(), contains(entry.id));
      });
    },
  );

  test(
    'unreadable plan library preserves recovery and unrelated atomic writes',
    () async {
      final kv = _FaultStore();
      final cache = LocalCache(kv, _owner);
      await cache.writeTrainingPlans([timerPlan()]);
      final snapshot = _review();
      await cache.writeTrainingSession(snapshot);
      final before = await kv.getString(_key('training_plans'));
      kv.unreadable = _key('training_plans');
      final partial = await cache.readMutationSnapshot(allowPartial: true);
      expect(partial.unreadableKeys, contains(_key('training_plans')));
      expect(partial.snapshot.values[_key('training_session')], isNotNull);
      await cache.commitSyncOperations([
        SyncOp.mealInsert(_meal('independent'), trackDay: false),
      ]);
      await cache.commitSyncOperations([SyncOp.trainingPlanDelete('other')]);
      expect(await kv.getString(_key('training_plans')), before);
      expect(
        (await cache.readTrainingSession())!.sessionId,
        snapshot.sessionId,
      );
    },
  );

  test(
    'full queue rejects entire new save without discarding confirmed intents',
    () async {
      final kv = _FaultStore();
      final cache = LocalCache(kv, _owner);
      final pending = List.generate(
        kOutboxMaxOps,
        (i) => SyncOp.favoriteDelete('favorite-$i'),
      );
      await cache.commitSyncOperations(pending);
      final before = await kv.getString(_key('outbox'));
      await expectLater(
        cache.commitSyncOperations([
          SyncOp.mealInsert(_meal('too-many'), trackDay: false),
        ]),
        throwsStateError,
      );
      expect(await kv.getString(_key('outbox')), before);
      expect(await cache.readLoggedMeals(), isNull);
    },
  );

  test(
    'legacy UUID and pending stats migration is stable before first delivery',
    () async {
      final kv = _FaultStore();
      final cache = LocalCache(kv, _owner);
      final legacy = SyncOp.mealInsert(
        _meal('legacy'),
        trackDay: false,
      ).toJson()..remove('operation_id');
      await kv.setString(
        _key('outbox'),
        jsonEncode({
          'items': [legacy],
        }),
      );
      await kv.setString(
        _key('pending_stats'),
        jsonEncode({
          'meals': 2,
          'weight_logs': 1,
          'request_id': '40000000-0000-4000-8000-000000000004',
        }),
      );
      final first = await cache.readSyncOperations();
      final second = await LocalCache(kv, _owner).readSyncOperations();
      expect(
        first.map((op) => op.operationId),
        second.map((op) => op.operationId),
      );
      expect(first, hasLength(2));
      expect(first.last.entityId, '40000000-0000-4000-8000-000000000004');
      expect((await cache.readPendingStatsDeltasOrThrow())!.meals, 0);
    },
  );
}
