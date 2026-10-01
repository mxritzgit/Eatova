import 'package:clock/clock.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/lifetime_stats.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/planned_meal.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/sync_outbox.dart';
import 'package:flutter_test/flutter_test.dart';

import '../outbox/outbox_test_helpers.dart' show mealResult;
import '../support/atomic_store_faults.dart';

// An acknowledgment only rewrites the slots its receipt changes. A logged
// meal used to decode and re-encode the whole diary twice: once for the
// insert commit and once more for its acknowledgment.

const _owner = 'ack-io-user';
const _diary = 'eatova.v1.logged_meals.$_owner';
const _weights = 'eatova.v1.weight_log.$_owner';
final _now = DateTime.utc(2026, 9, 20, 12);

LoggedMeal _meal(String id, {int minutes = 0}) => LoggedMeal(
  id: id,
  result: mealResult(id),
  loggedAt: _now.subtract(Duration(minutes: minutes)),
);

/// Counts slot reads and writes at the store seam.
class _SlotIo {
  _SlotIo() {
    store.beforeRead = (keys) async {
      for (final key in keys) {
        reads[key] = (reads[key] ?? 0) + 1;
      }
    };
    store.beforeWrite = (changes) async {
      if (failWrites) throw StateError('Injected disk failure');
      for (final key in changes.keys) {
        writes[key] = (writes[key] ?? 0) + 1;
      }
    };
  }
  final inner = InMemoryKeyValueStore();
  late final store = AtomicStoreFaults(inner);
  final reads = <String, int>{};
  final writes = <String, int>{};
  bool failWrites = false;

  void reset() {
    reads.clear();
    writes.clear();
  }
}

Future<(_SlotIo, LocalCache)> _seededDiary(int meals) async {
  final io = _SlotIo();
  final cache = LocalCache(io.store, _owner);
  await cache.commitStoreSnapshot(
    expectedVersions: const {},
    meals: [for (var i = 0; i < meals; i++) _meal('old-$i', minutes: i + 1)],
    stats: LifetimeStats(mealsLogged: meals),
  );
  io.reset();
  return (io, cache);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Mahlzeit: Insert liest/schreibt das Tagebuch einmal, ACK gar nicht',
    () async {
      await withClock(Clock.fixed(_now), () async {
        final (io, cache) = await _seededDiary(1000);
        final op = SyncOp.mealInsert(_meal('new'), trackDay: true);

        await cache.commitSyncOperations([op]);
        expect(io.reads[_diary], 1, reason: 'insert commit decodes once');
        expect(io.writes[_diary], 1, reason: 'insert commit encodes once');

        await cache.startSyncOperation(op.operationId);
        io.reset();
        final committed = await cache.acknowledgeSyncOperation(
          op.operationId,
          LocalSyncResult(stats: LifetimeStats(mealsLogged: 1001)),
        );
        expect(io.reads[_diary], isNull, reason: 'ack must not decode diary');
        expect(io.writes[_diary], isNull, reason: 'ack must not encode diary');

        // Receipt applied, intent gone, diary row untouched.
        expect(committed.operations, isEmpty);
        expect(await cache.readSyncOperations(), isEmpty);
        expect((await cache.readLifetimeStats())!.mealsLogged, 1001);
        final diary = (await cache.readLoggedMeals())!;
        expect(diary, hasLength(1001));
        expect(diary.where((meal) => meal.id == 'new'), hasLength(1));
      });
    },
  );

  test('Gewicht: ACK liest und schreibt das Gewichtslog nicht', () async {
    await withClock(Clock.fixed(_now), () async {
      final (io, cache) = await _seededDiary(10);
      final op = SyncOp.weightInsert(
        id: '7e000000-0000-4000-8000-000000000001',
        weightKg: 80,
        recordedAt: _now,
      );
      await cache.commitSyncOperations([op]);
      expect(io.writes[_weights], 1);
      await cache.startSyncOperation(op.operationId);
      io.reset();
      await cache.acknowledgeSyncOperation(
        op.operationId,
        LocalSyncResult(stats: LifetimeStats(weightLogs: 1)),
      );
      expect(io.reads[_weights], isNull);
      expect(io.writes[_weights], isNull);
      expect(await cache.readSyncOperations(), isEmpty);
      expect((await cache.readWeightLog())!.entries.single.weightKg, 80);
      expect((await cache.readLifetimeStats())!.weightLogs, 1);
    });
  });

  test(
    'Tombstone-Receipt entfernt die Mahlzeit weiterhin im selben Commit',
    () async {
      await withClock(Clock.fixed(_now), () async {
        final (io, cache) = await _seededDiary(3);
        final op = SyncOp.mealInsert(_meal('tombstoned'), trackDay: false);
        await cache.commitSyncOperations([op]);
        await cache.startSyncOperation(op.operationId);
        io.reset();
        await cache.acknowledgeSyncOperation(
          op.operationId,
          const LocalSyncResult(entityDeleted: true),
        );
        expect(io.writes[_diary], 1);
        expect(await cache.readSyncOperations(), isEmpty);
        expect(
          (await cache.readLoggedMeals())!.map((meal) => meal.id),
          isNot(contains('tombstoned')),
        );
      });
    },
  );

  test(
    'Plan-Konvertierung: ACK übernimmt Server-Mahlzeit bzw. deren Löschung',
    () async {
      await withClock(Clock.fixed(_now), () async {
        final plan = PlannedMeal.create(
          id: '7d000000-0000-4000-8000-000000000001',
          recipe: recipeCatalogDe.first,
          day: _now,
          slot: MealSlot.lunch,
        );
        final eaten = plan.copyWith(eatenAt: _now);
        final meal = LoggedMeal(
          id: plan.id,
          result: eaten.recipe.toMealResultForServings(1),
          loggedAt: _now,
        );
        final (io, cache) = await _seededDiary(3);
        final op = SyncOp.mealPlanConvert(eaten, meal, trackDay: true);
        await cache.commitSyncOperations([op]);
        await cache.startSyncOperation(op.operationId);
        await cache.acknowledgeSyncOperation(
          op.operationId,
          LocalSyncResult(
            plan: eaten,
            meal: meal.copyWith(loggedAt: _now.add(const Duration(minutes: 5))),
            stats: LifetimeStats(mealsLogged: 4),
          ),
        );
        var diary = (await cache.readLoggedMeals())!;
        expect(
          diary.singleWhere((row) => row.id == plan.id).loggedAt.toUtc(),
          _now.add(const Duration(minutes: 5)),
        );
        expect(await cache.readSyncOperations(), isEmpty);

        final again = SyncOp.mealPlanConvert(eaten, meal, trackDay: false);
        await cache.commitSyncOperations([again]);
        await cache.startSyncOperation(again.operationId);
        await cache.acknowledgeSyncOperation(
          again.operationId,
          LocalSyncResult(plan: eaten, convertedMealDeleted: true),
        );
        diary = (await cache.readLoggedMeals())!;
        expect(diary.map((row) => row.id), isNot(contains(plan.id)));
        expect(io.writes[_diary], greaterThan(0));
      });
    },
  );

  test('Absturz zwischen Zustellung und ACK: Intent und Tagebuch bleiben, '
      'Wiederholung wendet die Quittung genau einmal an', () async {
    await withClock(Clock.fixed(_now), () async {
      final (io, cache) = await _seededDiary(20);
      final op = SyncOp.mealInsert(_meal('pending'), trackDay: false);
      await cache.commitSyncOperations([op]);
      await cache.startSyncOperation(op.operationId);
      final frozen = (await cache.readSyncOperations()).single.toJson();
      final diaryBefore = await io.inner.getString(_diary);

      io.failWrites = true;
      await expectLater(
        cache.acknowledgeSyncOperation(
          op.operationId,
          LocalSyncResult(stats: LifetimeStats(mealsLogged: 21)),
        ),
        throwsStateError,
      );
      io.failWrites = false;

      // A restarted process sees the exact frozen request and the diary.
      final restarted = LocalCache(io.store, _owner);
      expect((await restarted.readSyncOperations()).single.toJson(), frozen);
      expect(await io.inner.getString(_diary), diaryBefore);
      expect((await restarted.readLifetimeStats())!.mealsLogged, 21);

      await restarted.acknowledgeSyncOperation(
        op.operationId,
        LocalSyncResult(stats: LifetimeStats(mealsLogged: 21)),
      );
      // A repeated receipt for an already removed intent changes nothing.
      await restarted.acknowledgeSyncOperation(
        op.operationId,
        LocalSyncResult(stats: LifetimeStats(mealsLogged: 99)),
      );
      expect(await restarted.readSyncOperations(), isEmpty);
      expect((await restarted.readLifetimeStats())!.mealsLogged, 21);
      expect(
        (await restarted.readLoggedMeals())!.map((meal) => meal.id),
        contains('pending'),
      );
    });
  });
}
