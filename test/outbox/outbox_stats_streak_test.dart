import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/local_day.dart';
import 'package:eatova/src/services/sync_outbox.dart';
import 'package:eatova/src/services/uuid.dart' show deriveStatsRequestId;

import '../support/atomic_store_faults.dart';
import 'outbox_test_helpers.dart';

const _queueKey = 'eatova.v1.outbox.user-outbox';
const _deltaKey = 'eatova.v1.pending_stats.user-outbox';
const _statsKey = 'eatova.v1.stats.user-outbox';
final _now = DateTime(2026, 5, 14, 12, 30);
Future<void> _today(Future<void> Function() body) =>
    withClock(Clock.fixed(_now), body);
List<Map<String, dynamic>> _ops(FakeServer server, String kind) => server
    .operations(kind)
    .map((request) => (jsonDecode(request.body) as Map).cast<String, dynamic>())
    .toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'meal and counter failure is atomic and pending intent survives restart',
    () => _today(() async {
      final kv = InMemoryKeyValueStore();
      final server = FakeServer();
      final a = setup(kv: kv, geteilterServer: server);
      await bootUntilIdle(a.store);
      server.statsOffline = true;
      final id = await a.store.addResultToDailyTotal(mealResult('Bowl'));
      expect(server.mealRows, isEmpty);
      expect(server.mealsCounted, 0);
      expect(server.trackedDay, isNull);
      expect(
        (await a.cache.readOutbox())!
            .singleWhere((op) => op.kind == SyncOpKind.mealInsert)
            .entityId,
        id,
      );
      expect((await a.cache.readPendingStatsDeltas())?.meals ?? 0, 0);
      final b = setup(kv: kv, geteilterServer: server);
      server.statsOffline = false;
      await bootUntilIdle(b.store);
      expect(server.mealRows.keys, [id]);
      expect(server.mealsCounted, 1);
      expect(server.trackedDay, localDayKey(_now));
      expect(b.store.pendingOutbox, isEmpty);
    }),
  );

  test(
    'immutable receipt identity survives retries and restart; next meal gets a new one',
    () async {
      final kv = InMemoryKeyValueStore();
      final server = FakeServer();
      final a = setup(kv: kv, geteilterServer: server);
      await bootUntilIdle(a.store);
      server.statsOffline = true;
      await a.store.addResultToDailyTotal(mealResult('First'));
      await a.store.syncPendingWrites();
      final first = _ops(server, 'mealInsert').first;
      final b = setup(kv: kv, geteilterServer: server);
      await bootUntilIdle(b.store);
      expect(
        _ops(server, 'mealInsert').map((op) => op['p_operation_id']).toSet(),
        {first['p_operation_id']},
      );
      expect(
        _ops(
          server,
          'mealInsert',
        ).every((op) => jsonEncode(op) == jsonEncode(first)),
        isTrue,
      );
      server.statsOffline = false;
      await b.store.syncPendingWrites();
      await b.store.addResultToDailyTotal(mealResult('Second'));
      expect(
        _ops(server, 'mealInsert').last['p_operation_id'],
        isNot(first['p_operation_id']),
      );
      expect(server.mealsCounted, 2);
    },
  );

  for (final legacyId in <String?>[
    null,
    'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
  ]) {
    test(
      'legacy counter bundle migrates atomically with stable identity $legacyId',
      () async {
        final kv = InMemoryKeyValueStore();
        await LocalCache(
          kv,
          'user-outbox',
        ).writePendingStatsDeltas(meals: 2, weightLogs: 1, requestId: legacyId);
        final server = FakeServer()..statsOffline = true;
        final a = setup(kv: kv, geteilterServer: server);
        await bootUntilIdle(a.store);
        final pending = a.store.pendingOutbox.singleWhere(
          (op) => op.kind == SyncOpKind.statsIncrement,
        );
        expect(pending.statsMeals, 2);
        expect(pending.statsWeightLogs, 1);
        if (legacyId != null) expect(pending.entityId, legacyId);
        expect((await a.cache.readPendingStatsDeltas())!.meals, 0);
        final b = setup(kv: kv, geteilterServer: server);
        await bootUntilIdle(b.store);
        expect(b.store.pendingOutbox.single.operationId, pending.operationId);
        server.statsOffline = false;
        await b.store.syncPendingWrites();
        expect(server.mealsCounted, 2);
        expect(server.weightLogsCounted, 1);
        expect(server.verbrauchteStatsIds, {pending.entityId});
        expect(b.store.pendingOutbox, isEmpty);
      },
    );
  }

  test(
    'server commit followed by failed local acknowledgement is exactly once after restart',
    () async {
      final kv = InMemoryKeyValueStore();
      final server = FakeServer();
      final faults = AtomicStoreFaults(kv);
      String? mealId;
      faults.beforeWrite = (changes) async {
        final body = changes[_queueKey];
        if (mealId != null &&
            server.mealRows.containsKey(mealId) &&
            body != null &&
            !body.contains(mealId)) {
          throw StateError('Power failed before ACK commit');
        }
      };
      const id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
      final op = SyncOp.mealInsert(
        LoggedMeal(id: id, result: mealResult('Crash'), loggedAt: _now),
        trackDay: false,
      );
      await seedRawOutbox(kv, [op.toJson()]);
      mealId = id;
      final a = setup(
        geteilterServer: server,
        injizierterCache: LocalCache(faults, 'user-outbox'),
      );
      await bootUntilIdle(a.store);
      expect(server.mealRows.keys, [id]);
      expect(server.mealsCounted, 1);
      expect(kv.snapshot[_queueKey], contains(op.operationId));
      final b = setup(kv: kv, geteilterServer: server);
      await bootUntilIdle(b.store);
      expect(server.mealsCounted, 1);
      expect(server.verbrauchteStatsIds, {deriveStatsRequestId(id)});
      expect(
        _ops(
          server,
          'mealInsert',
        ).map((request) => request['p_operation_id']).toSet(),
        {op.operationId},
      );
      expect(b.store.pendingOutbox, isEmpty);
    },
  );

  test(
    'already applied legacy stats increment returns success without counting twice',
    () async {
      const rid = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
      final kv = InMemoryKeyValueStore();
      await seedRawOutbox(kv, [
        SyncOp.statsIncrement(requestId: rid, meals: 1).toJson(),
      ]);
      final s = setup(kv: kv);
      s.server.verbrauchteStatsIds.add(rid);
      s.server.mealsCounted = 1;
      await bootUntilIdle(s.store);
      expect(s.server.mealsCounted, 1);
      expect(s.server.operations('statsIncrement'), hasLength(1));
      expect(s.store.pendingOutbox, isEmpty);
    },
  );

  test(
    'ambiguous weight response keeps one row and one counter through replay',
    () async {
      final s = setup();
      await bootUntilIdle(s.store);
      s.server.ambiguousWrites = true;
      await s.store.logWeight(80.5);
      final pending = s.store.pendingOutbox.singleWhere(
        (op) => op.kind == SyncOpKind.weightInsert,
      );
      expect(s.server.weightLogsCounted, 1);
      s.server.ambiguousWrites = false;
      await s.store.syncPendingWrites();
      expect(s.server.weightRows, hasLength(1));
      expect(s.server.weightLogsCounted, 1);
      expect(s.server.verbrauchteStatsIds, {
        deriveStatsRequestId(pending.entityId),
      });
      expect(
        _ops(
          s.server,
          'weightInsert',
        ).map((op) => op['p_operation_id']).toSet(),
        {pending.operationId},
      );
      expect(s.store.pendingOutbox, isEmpty);
    },
  );

  test(
    'ACK removes source and persists authoritative counter in one local transaction',
    () async {
      final kv = InMemoryKeyValueStore();
      final commits = <Map<String, String?>>[];
      final faults = AtomicStoreFaults(kv)
        ..beforeWrite = (changes) async {
          commits.add({...kv.snapshot, ...changes});
        };
      final s = setup(injizierterCache: LocalCache(faults, 'user-outbox'));
      await bootUntilIdle(s.store);
      final id = await s.store.addResultToDailyTotal(mealResult('Atomic ACK'));
      final queued = commits.indexWhere(
        (batch) => batch[_queueKey]?.contains(id) == true,
      );
      expect(queued, greaterThanOrEqualTo(0));
      final ack = commits
          .skip(queued + 1)
          .firstWhere(
            (batch) =>
                batch.containsKey(_queueKey) && !batch[_queueKey]!.contains(id),
          );
      expect(jsonDecode(ack[_statsKey]!)['meals_logged'], 1);
      expect(s.server.mealsCounted, 1);
      expect(s.store.pendingOutbox, isEmpty);
    },
  );

  test(
    'edit during an in-flight insert is appended with a distinct immutable identity',
    () async {
      final s = setup();
      await bootUntilIdle(s.store);
      s.server.holdMealWrites();
      final adding = s.store.addResultToDailyTotal(mealResult('Original'));
      await pumpUntil(() => s.server.operations('mealInsert').isNotEmpty);
      final firstRequest = _ops(s.server, 'mealInsert').single;
      final id = firstRequest['p_entity_id'] as String;
      final edit = s.store.updateLoggedMealResult(
        id,
        mealResult('Edited', kcal: 500),
      );
      await pumpUntil(
        () =>
            s.store.pendingOutbox.where((op) => op.entityId == id).length == 2,
      );
      final pending = s.store.pendingOutbox
          .where((op) => op.entityId == id)
          .toList();
      expect(pending.map((op) => op.kind), [
        SyncOpKind.mealInsert,
        SyncOpKind.mealUpsert,
      ]);
      expect(pending.first.meal!.result.caloriesKcal, 300);
      expect(pending.last.meal!.result.caloriesKcal, 500);
      expect(pending.first.operationId, isNot(pending.last.operationId));
      s.server.releaseMealWrites();
      await Future.wait([adding, edit]);
      expect(s.server.mealsCounted, 1);
      expect(s.server.mealRows[id]!['calories_kcal'], 500);
      expect(_ops(s.server, 'mealInsert').single, firstRequest);
    },
  );

  test(
    'exhausted legacy counter stays blocked and explicitly recoverable',
    () async {
      final kv = InMemoryKeyValueStore();
      final op = SyncOp.statsIncrement(
        requestId: 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
        meals: 2,
      );
      await seedRawOutbox(kv, [
        op.toJson()..['attempts'] = kOutboxMaxAttempts - 1,
      ]);
      final s = setup(kv: kv);
      s.server.statsOffline = true;
      await bootUntilIdle(s.store);
      expect(s.store.pendingOutbox.single.operationId, op.operationId);
      expect(s.store.syncBlockedReason, SyncBlockedReason.rejected);
      expect(s.server.mealsCounted, 0);
      s.server.statsOffline = false;
      await s.store.syncPendingWrites(retryBlocked: true);
      expect(s.server.mealsCounted, 2);
      expect(s.store.pendingOutbox, isEmpty);
    },
  );

  for (final failures in [1, 6]) {
    test(
      'unreadable legacy stats never get overwritten by $failures new mutations',
      () async {
        final kv = InMemoryKeyValueStore();
        await LocalCache(
          kv,
          'user-outbox',
        ).writePendingStatsDeltas(meals: 2, weightLogs: 1);
        final original = kv.snapshot[_deltaKey];
        final faults = AtomicStoreFaults(kv)
          ..beforeRead = (keys) async {
            if (keys.contains(_deltaKey)) {
              throw StateError('Keystore temporarily unavailable');
            }
          };
        final s = setup(injizierterCache: LocalCache(faults, 'user-outbox'));
        await bootUntilIdle(s.store);
        for (var i = 0; i < failures; i++) {
          await expectLater(
            s.store.addResultToDailyTotal(mealResult('Uncommitted $i')),
            throwsStateError,
          );
          expect(kv.snapshot[_deltaKey], original);
          expect(s.store.loggedMeals, isEmpty);
        }
        final recovered = setup(kv: kv);
        await bootUntilIdle(recovered.store);
        expect(recovered.server.mealsCounted, 2);
        expect(recovered.server.weightLogsCounted, 1);
        await recovered.store.addResultToDailyTotal(mealResult('Committed'));
        expect(recovered.server.mealsCounted, 3);
      },
    );
  }

  test(
    'tracking-day failure leaves the whole meal transaction pending and local streak visible',
    () => _today(() async {
      final s = setup();
      await bootUntilIdle(s.store);
      s.server.rejectTrackingDay = true;
      final id = await s.store.addResultToDailyTotal(mealResult('Streak'));
      expect(s.server.mealRows, isEmpty);
      expect(s.server.mealsCounted, 0);
      expect(s.server.trackedDay, isNull);
      expect(s.store.loggedMeals.map((meal) => meal.id), contains(id));
      expect(s.store.lifetimeStats.currentStreak, 1);
      expect(
        s.store.pendingOutbox
            .singleWhere((op) => op.kind == SyncOpKind.mealInsert)
            .trackDay,
        isTrue,
      );
      s.server.rejectTrackingDay = false;
      await s.store.syncPendingWrites();
      expect(s.server.trackedDay, localDayKey(_now));
      expect(s.store.lifetimeStats.currentStreak, 1);
    }),
  );

  test(
    'pending tracked meal preserves optimistic streak after cold start with server stats',
    () => _today(() async {
      final kv = InMemoryKeyValueStore();
      final server = FakeServer()..rejectTrackingDay = true;
      final a = setup(kv: kv, geteilterServer: server);
      await bootUntilIdle(a.store);
      await a.store.addResultToDailyTotal(mealResult('Streak'));
      final b = setup(kv: kv, geteilterServer: server);
      await bootUntilIdle(b.store);
      expect(b.store.lifetimeStats.currentStreak, 1);
      server.rejectTrackingDay = false;
      await b.store.syncPendingWrites();
      expect(server.mealsCounted, 1);
      expect(server.trackedDay, localDayKey(_now));
      expect(b.store.pendingOutbox, isEmpty);
    }),
  );

  test(
    'three offline meals retain three atomic day intents and count once each',
    () => _today(() async {
      final s = setup();
      await bootUntilIdle(s.store);
      s.server.offline = true;
      for (var i = 0; i < 3; i++) {
        await s.store.addResultToDailyTotal(mealResult('Bowl $i'));
      }
      final meals = s.store.pendingOutbox
          .where((op) => op.kind == SyncOpKind.mealInsert)
          .toList();
      expect(meals, hasLength(3));
      expect(meals.every((op) => op.trackDay), isTrue);
      expect(meals.map((op) => op.operationId).toSet(), hasLength(3));
      s.server.offline = false;
      await s.store.syncPendingWrites();
      expect(s.server.mealsCounted, 3);
      expect(s.server.trackedDay, localDayKey(_now));
      expect(s.store.lifetimeStats.currentStreak, 1);
      expect(s.store.pendingOutbox, isEmpty);
    }),
  );

  test(
    'new successful tracked meal does not erase an older undelivered meal',
    () => _today(() async {
      final s = setup();
      await bootUntilIdle(s.store);
      s.server.rejectTrackingDay = true;
      final oldId = await s.store.addResultToDailyTotal(mealResult('First'));
      s.server.rejectTrackingDay = false;
      final newId = await s.store.addResultToDailyTotal(mealResult('Second'));
      expect(s.server.mealRows.keys, containsAll([oldId, newId]));
      expect(s.server.mealsCounted, 2);
      expect(s.server.trackedDay, localDayKey(_now));
      expect(s.store.pendingOutbox, isEmpty);
    }),
  );
}
