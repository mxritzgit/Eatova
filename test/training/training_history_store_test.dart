import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/training_history.dart';
import 'package:eatova/src/models/training_log.dart';
import 'package:eatova/src/models/training_plan.dart';
import 'package:eatova/src/models/training_session.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/services/secure_cache_store.dart';
import 'package:eatova/src/services/sync_error_messages.dart';
import 'package:eatova/src/services/sync_outbox.dart';
import 'package:eatova/src/services/training_history_sync.dart';
import 'package:eatova/src/services/training_session_controller.dart';
import 'package:eatova/src/services/uuid.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import '../outbox/outbox_test_helpers.dart' as h;
import '../support/sync_session_fixture.dart';
import '../support/sync_operation_fake.dart';
import '../support/atomic_store_faults.dart';
import 'training_timer_fixtures.dart';

class _ScopedRows extends MapBase<String, Map<String, dynamic>> {
  _ScopedRows(this.rows, this.owner);
  final Map<String, Map<String, dynamic>> rows;
  final String owner;

  @override
  Map<String, dynamic>? operator [](Object? key) => rows['$owner:$key'];
  @override
  void operator []=(String key, Map<String, dynamic> value) {
    rows['$owner:$key'] = {...value, 'user_id': owner};
  }

  @override
  Iterable<String> get keys => rows.keys
      .where((key) => key.startsWith('$owner:'))
      .map((key) => key.substring(owner.length + 1));
  @override
  Map<String, dynamic>? remove(Object? key) => rows.remove('$owner:$key');
  @override
  void clear() {
    for (final key in keys.toList()) {
      remove(key);
    }
  }
}

class _Server {
  bool offline = false;
  bool failLoads = false;
  bool ambiguous = false;
  bool rejectHistory = false;
  bool hideHistory = false;
  bool seedPlan = false;
  Completer<void>? hold;
  final entered = Completer<void>();
  final rows = <String, Map<String, dynamic>>{};
  final requests = <http.Request>[];
  final deleted = <String>{};
  final operations = <String, SyncOperationFake>{};
  SyncOperationFake _operations(String owner) => operations.putIfAbsent(
    owner,
    () => SyncOperationFake(
      meals: {},
      weights: {},
      favorites: {},
      recipes: {},
      trainingHistory: _ScopedRows(rows, owner),
      readProfile: () => null,
      writeProfile: (_) {},
      readStats: () => {},
      incrementStats: (_, _, _) {},
      recordDay: (_) {},
    ),
  );
  Future<http.Response> handle(http.Request request) async {
    requests.add(request);
    if (failLoads && request.method == 'GET') {
      return http.Response(
        '{"code":"PGRST000","message":"fixture load unavailable"}',
        400,
        headers: {'content-type': 'application/json'},
        request: request,
      );
    }
    if (offline) throw http.ClientException('fixture offline');
    final params = request.url.path.endsWith('/rpc/apply_sync_operation')
        ? (jsonDecode(request.body) as Map).cast<String, dynamic>()
        : null;
    final kind = params?['p_kind'];
    Object? result = [];
    final isHistory = request.url.path.endsWith('/training_history');
    // History writes travel only as sync operations; lib has no direct
    // record/delete RPC any more.
    final isRecord = kind == 'trainingHistoryInsert';
    final isDelete = kind == 'trainingHistoryDelete';
    if (params != null && (isRecord || isDelete)) {
      if (offline) throw http.ClientException('fixture offline');
      if (rejectHistory) {
        return http.Response(
          '{"code":"23502","message":"fixture rejection"}',
          400,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      }
      if (!entered.isCompleted) entered.complete();
      await hold?.future;
      final bearer =
          request.headers['Authorization'] ??
          request.headers['authorization'] ??
          '';
      final token = bearer.replaceFirst('Bearer ', '').split('.');
      final owner = token.length == 3
          ? (jsonDecode(
                      utf8.decode(
                        base64Url.decode(base64Url.normalize(token[1])),
                      ),
                    )
                    as Map)['sub']
                as String
          : 'A';
      final key = '$owner:${params['p_entity_id']}';
      final sync = _operations(owner);
      for (final deletedKey in deleted.where(
        (key) => key.startsWith('$owner:'),
      )) {
        sync.deleted.add(
          'training_history:${deletedKey.substring(owner.length + 1)}',
        );
      }
      result = sync.apply(params);
      if (isDelete) deleted.add(key);
      if (isRecord && ambiguous) {
        throw http.ClientException('fixture lost response');
      }
    } else if (params != null) {
      result = _operations('A').apply(params);
    } else if (isHistory) {
      final owner = request.url.queryParameters['user_id']!.substring(3);
      result = hideHistory
          ? []
          : rows.values.where((row) => row['user_id'] == owner).toList();
    } else if (seedPlan &&
        request.method == 'GET' &&
        request.url.path.endsWith('/training_plans')) {
      result = [timerPlan().toRow()];
    } else if (request.url.path.endsWith('/profiles')) {
      result = null;
    } else if (request.url.path.endsWith('/lifetime_stats')) {
      result = {};
    }
    return http.Response(
      jsonEncode(result),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
      request: request,
    );
  }
}

class _Cache extends LocalCache {
  _Cache(KeyValueStore store, String userId)
    : this._(AtomicStoreFaults(store), userId);
  _Cache._(this.faults, String userId) : super(faults, userId) {
    faults.beforeRead = (keys) async {
      if (keys.any((key) => key.contains('.training_history_deletions.'))) {
        if (failDeletionRead) {
          throw StateError('fixture receipt read unavailable');
        }
        await holdDeletionRead?.future;
      }
      if (failSessionRead &&
          keys.any((key) => key.contains('.training_session.'))) {
        throw StateError('fixture checkpoint read unavailable');
      }
    };
    faults.beforeWrite = (changes) async {
      final outbox = changes['eatova.v1.outbox.$userId'];
      final pending = outbox == null
          ? <dynamic>[]
          : (jsonDecode(outbox) as Map)['items'] as List;
      if (pending.any(
        (op) =>
            op['kind'] == 'trainingHistoryInsert' ||
            op['kind'] == 'trainingHistoryDelete',
      )) {
        if (!entered.isCompleted) entered.complete();
        await holdOutbox?.future;
        if (failOutbox) throw StateError('fixture transaction unavailable');
      }
      if (failDeletionReceipt &&
          changes.containsKey('eatova.v1.training_history_deletions.$userId')) {
        throw StateError('fixture deletion receipt unavailable');
      }
      if (failClear &&
          changes.containsKey('eatova.v1.training_session.$userId') &&
          (changes['eatova.v1.training_session.$userId'] == null ||
              (jsonDecode(changes['eatova.v1.training_session.$userId']!)
                      as Map)['snapshot'] ==
                  null)) {
        throw StateError('fixture checkpoint retirement unavailable');
      }
    };
  }
  final AtomicStoreFaults faults;
  bool failOutbox = false;
  bool failClear = false;
  bool failDeletionReceipt = false;
  bool failDeletionRead = false;
  bool failSessionRead = false;
  Completer<void>? holdDeletionRead;

  @override
  Future<Set<String>> readTrainingHistoryDeletions() async {
    if (failDeletionRead) throw StateError('fixture receipt read unavailable');
    await holdDeletionRead?.future;
    return super.readTrainingHistoryDeletions();
  }

  @override
  Future<TrainingSessionSnapshot?> readTrainingSession({
    bool requireReadable = false,
  }) async {
    if (failSessionRead) {
      throw StateError('fixture checkpoint read unavailable');
    }
    return super.readTrainingSession(requireReadable: requireReadable);
  }

  Completer<void>? holdOutbox;
  final entered = Completer<void>();
}

class _Harness {
  _Harness(
    this.server, {
    required KeyValueStore storage,
    this.owner = 'A',
    SupabaseClient? clientOverride,
  }) {
    cache = _Cache(storage, owner);
    client =
        clientOverride ??
        SupabaseClient(
          'https://ci.invalid',
          'ci-dummy-key',
          httpClient: MockClient(server.handle),
          authOptions: const AuthClientOptions(autoRefreshToken: false),
        );
    store = HomeStore(
      sync: EatovaSync.forUser(client, owner),
      health: const NoopHealthService(),
      notificationService: const NoopNotificationService(),
      initialUserName: 'Fixture',
      emitSnack: h.SnackCapture().call,
      debugCache: cache,
    );
    addTearDown(() async {
      dispose();
      await client.dispose();
    });
  }
  final _Server server;
  final String owner;
  late final _Cache cache;
  late final SupabaseClient client;
  late final HomeStore store;
  bool _disposed = false;
  int generation = 0;
  void dispose() {
    if (!_disposed) {
      _disposed = true;
      store.dispose();
    }
  }

  Future<void> boot() async {
    await cache.writeProfile(const UserProfile(onboardingCompleted: true));
    await h.bootUntilIdle(store);
    await store.saveTrainingPlan(timerPlan());
    generation = store.trainingSessionGeneration;
  }

  Future<void> settle() async {
    await h.settle();
    await cache.settle();
  }
}

TrainingHistoryEntry _entry() =>
    withClock(Clock.fixed(DateTime.utc(2026, 9, 10, 12)), () {
      final controller = TrainingSessionController(
        plan: timerPlan(),
        workoutIndex: 1,
        autoTick: false,
      );
      controller.setCurrentActual(reps: 6, weightKg: 14.5);
      controller.start();
      controller.completeCurrentSet();
      final entry = controller.completion();
      controller.dispose();
      return entry;
    });

TrainingSessionSnapshot _unfinished() {
  final controller = TrainingSessionController(
    plan: timerPlan(),
    workoutIndex: 1,
    autoTick: false,
  );
  controller.setCurrentActual(reps: 4, weightKg: 7.5);
  final snapshot = controller.snapshot();
  controller.dispose();
  return snapshot;
}

Future<void> _seedRecovery(
  _Harness env,
  TrainingSessionSnapshot snapshot,
) async {
  await env.cache.writeProfile(const UserProfile(onboardingCompleted: true));
  await env.cache.writeTrainingPlans([snapshot.plan]);
  await env.cache.writeTrainingSession(snapshot);
}

/// A free log (spec B), built for a frozen 2026-09-10 evening.
TrainingHistoryEntry _log([String? id]) => buildLoggedWorkout(
  historyId: id ?? uuidV4(),
  draft: LoggedWorkoutDraft(
    title: 'Garage session',
    performedOn: DateTime(2026, 9, 10),
    exercises: const [
      LoggedExercise(
        name: 'Bench press',
        timed: false,
        sets: [LoggedSet(reps: 8, weightKg: 60)],
      ),
    ],
  ),
  now: DateTime(2026, 9, 10, 18),
  fallbackTitle: 'Workout',
);

/// Workout 1 of [timerPlan] logged as done without the player.
TrainingHistoryEntry _planAttached() => buildPlanAttachedLog(
  historyId: uuidV4(),
  plan: timerPlan(),
  workoutIndex: 1,
  sets: const [
    [PlanAttachedSet(done: true, reps: 8)],
  ],
  performedOn: DateTime(2026, 9, 10),
  now: DateTime(2026, 9, 10, 18),
);

/// [timerPlan] with its workout 1 changed, which retires a session of it.
TrainingPlan _editedPlan() {
  final plan = timerPlan();
  return plan.copyWith(
    proposal: plan.proposal.copyWith(
      workouts: [
        plan.workouts[0],
        plan.workouts[1].copyWith(title: 'Mobility, edited'),
      ],
    ),
  );
}

Iterable<SyncOp> _historyInserts(List<SyncOp>? ops) => (ops ?? const <SyncOp>[])
    .where((op) => op.kind == SyncOpKind.trainingHistoryInsert);

int _historyInsertRequests(_Server server) => server.requests
    .where(
      (r) =>
          r.url.path.endsWith('/rpc/apply_sync_operation') &&
          (jsonDecode(r.body) as Map)['p_kind'] == 'trainingHistoryInsert',
    )
    .length;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'encrypted offline completion survives restart, replay and lost-response retry exactly once',
    () async {
      final raw = InMemoryKeyValueStore();
      final storage = EncryptedKeyValueStore(
        raw,
        AesGcmCacheCipher(Uint8List(32)),
      );
      final server = _Server()
        ..offline = true
        ..seedPlan = true;
      final first = _Harness(server, storage: storage);
      await first.boot();
      final entry = _entry();
      final delivery = await first.store.completeTrainingSession(
        entry,
        generation: first.generation,
      );
      expect(delivery, isNot(SyncDelivery.delivered));
      expect(first.store.trainingHistory.single.id, entry.id);
      expect(first.store.trainingSession, isNull);
      await first.settle();
      expect(
        await raw.getString('eatova.v1.outbox.A'),
        startsWith(cacheCipherMagic),
      );
      expect(
        await raw.getString('eatova.v1.training_history.A'),
        startsWith(cacheCipherMagic),
      );
      first.dispose();
      final reboot = _Harness(server, storage: storage);
      await reboot.boot();
      expect(reboot.store.trainingHistory.single.toRow(), entry.toRow());
      expect(reboot.store.trainingSession, isNull);
      server.offline = false;
      server.ambiguous = true;
      await reboot.store.syncPendingWrites();
      await reboot.settle();
      expect(server.rows.length, 1);
      server.ambiguous = false;
      await reboot.store.syncPendingWrites();
      await reboot.settle();
      expect(server.rows.length, 1);
      expect(reboot.store.trainingHistory.length, 1);
      final b = _Harness(server, storage: storage, owner: 'B');
      await b.boot();
      expect(b.store.trainingHistory, isEmpty);
      expect(b.store.trainingSession, isNull);
    },
  );

  test(
    'ambiguous completion preserves its full candidate across restart and source deletion',
    () async {
      final raw = InMemoryKeyValueStore();
      final server = _Server()
        ..ambiguous = true
        ..hideHistory = true;
      final env = _Harness(server, storage: raw);
      await env.boot();
      final original = _entry();
      final entry = TrainingHistoryEntry(
        snapshot: original.snapshot,
        finishedAt: original.finishedAt,
        note: 'Keep these exact values',
      );
      final delivery = await env.store.completeTrainingSession(
        entry,
        generation: env.generation,
      );
      expect(delivery, isNot(SyncDelivery.delivered));
      expect(
        (await env.cache.readTrainingHistory())!.single.toRow(),
        entry.toRow(),
      );
      final pending = (await env.cache.readOutbox())!.singleWhere(
        (op) => op.kind == SyncOpKind.trainingHistoryInsert,
      );
      expect(pending.trainingHistory!.toRow(), entry.toRow());
      expect(server.rows.values.single['session'], entry.toRow()['session']);
      await env.store.saveTrainingSession(null);
      await env.store.deleteTrainingPlan(entry.snapshot.plan.id);
      expect(env.store.trainingSession, isNull);
      await env.settle();
      env.dispose();
      final reboot = _Harness(server, storage: raw);
      await reboot.boot();
      final restored = reboot.store.trainingHistory.single;
      expect(restored.toRow(), entry.toRow());
      final changed = TrainingHistoryEntry(
        snapshot: original.snapshot,
        finishedAt: original.finishedAt,
        note: 'Changed after request',
      );
      await reboot.store.completeTrainingSession(
        changed,
        generation: reboot.generation,
      );
      expect(reboot.store.trainingHistory.single.toRow(), entry.toRow());
      server.ambiguous = false;
      await reboot.store.syncPendingWrites();
      expect(reboot.store.trainingHistory.single.toRow(), entry.toRow());
      expect(server.rows.length, 1);
      expect(await reboot.cache.readTrainingSession(), isNull);
    },
  );

  test(
    'completion atomically retires recovery and permits the next workout',
    () async {
      final env = _Harness(_Server(), storage: InMemoryKeyValueStore());
      await env.boot();
      final first = _entry();
      await env.store.saveTrainingSession(first.snapshot);
      await env.store.completeTrainingSession(
        first,
        generation: env.generation,
      );
      expect(await env.cache.readTrainingSession(), isNull);
      final next = _entry();
      await env.store.saveTrainingSession(next.snapshot);
      expect(env.store.trainingSession?.sessionId, next.id);
      await env.store.completeTrainingSession(
        next,
        generation: env.store.trainingSessionGeneration,
      );
      expect(env.store.trainingHistory.length, 2);
    },
  );

  test(
    'two devices cannot resurrect a deletion after an ambiguous durable completion',
    () async {
      final server = _Server()..ambiguous = true;
      final storageA = InMemoryKeyValueStore();
      final deviceA = _Harness(server, storage: storageA);
      await deviceA.boot();
      final entry = _entry();
      await deviceA.store.completeTrainingSession(
        entry,
        generation: deviceA.generation,
      );
      expect(
        (await deviceA.cache.readOutbox())!.where(
          (op) => op.kind == SyncOpKind.trainingHistoryInsert,
        ),
        hasLength(1),
      );
      server.ambiguous = false;
      final deviceB = _Harness(server, storage: InMemoryKeyValueStore());
      await deviceB.boot();
      expect(deviceB.store.trainingHistory.single.id, entry.id);
      await deviceB.store.deleteTrainingHistory(entry.id);
      await deviceB.store.deleteTrainingHistory(entry.id);
      expect(server.rows, isEmpty);
      expect(server.deleted, {'A:${entry.id}'});
      await deviceA.store.syncPendingWrites();
      await deviceA.settle();
      expect(server.rows, isEmpty);
      expect(deviceA.store.trainingHistory, isEmpty);
      expect(await deviceA.cache.readOutbox(), isEmpty);
      deviceA.dispose();
      server.offline = true;
      final reboot = _Harness(server, storage: storageA);
      await reboot.boot();
      expect(reboot.store.trainingHistory, isEmpty);
      expect(reboot.store.trainingSession, isNull);
    },
  );

  test(
    'deletion receipt fences stale encrypted recovery and history across offline restart',
    () async {
      final raw = InMemoryKeyValueStore();
      final storage = EncryptedKeyValueStore(
        raw,
        AesGcmCacheCipher(Uint8List(32)),
      );
      final server = _Server()
        ..ambiguous = true
        ..seedPlan = true;
      final a = _Harness(server, storage: storage);
      await a.boot();
      final entry = _entry();
      await a.store.completeTrainingSession(entry, generation: a.generation);
      await a.settle();
      // Imported legacy mirrors can still contain an already completed player.
      await a.cache.writeTrainingSession(entry.recoverySnapshot());
      expect((await a.cache.readTrainingSession())?.sessionId, entry.id);
      expect((await a.cache.readTrainingHistory())!.single.id, entry.id);
      server.ambiguous = false;
      final b = _Harness(server, storage: InMemoryKeyValueStore());
      await b.boot();
      await b.store.deleteTrainingHistory(entry.id);
      await a.store.syncPendingWrites();
      await a.settle();
      expect(await a.cache.readOutbox(), isEmpty);
      // Simulate stale pre-migration payloads next to the durable deletion fence.
      await a.cache.writeTrainingSession(entry.recoverySnapshot());
      await a.cache.writeTrainingHistory([entry]);
      expect((await a.cache.readTrainingSession())?.sessionId, entry.id);
      expect((await a.cache.readTrainingHistory())!.single.id, entry.id);
      a.dispose();
      server.offline = true;
      final reboot = _Harness(server, storage: storage);
      await h.bootUntilIdle(reboot.store);
      expect(reboot.store.trainingSession, isNull);
      expect(reboot.store.trainingHistory, isEmpty);
      expect(
        await raw.getString('eatova.v1.training_history_deletions.A'),
        startsWith(cacheCipherMagic),
      );

      await expectLater(
        reboot.store.completeTrainingSession(
          entry,
          generation: reboot.generation,
        ),
        throwsA(isA<TrainingCompletionDeleted>()),
      );
      await expectLater(
        reboot.store.saveTrainingSession(entry.recoverySnapshot()),
        throwsA(isA<TrainingCompletionDeleted>()),
      );
      expect(reboot.store.trainingHistory, isEmpty);
      expect(await reboot.cache.readOutbox(), isEmpty);
      final other = _Harness(server, storage: storage, owner: 'B');
      await other.boot();
      expect(await other.cache.readTrainingHistoryDeletions(), isEmpty);
      await other.store.completeTrainingSession(
        entry,
        generation: other.generation,
      );
      expect(other.store.trainingHistory.single.id, entry.id);
    },
  );

  test(
    'failed deletion receipt retains replay until durable local retirement',
    () async {
      final storage = InMemoryKeyValueStore();
      final server = _Server()
        ..ambiguous = true
        ..seedPlan = true;
      final a = _Harness(server, storage: storage);
      await a.boot();
      final entry = _entry();
      await a.store.completeTrainingSession(entry, generation: a.generation);
      await a.cache.writeTrainingSession(entry.recoverySnapshot());
      server.ambiguous = false;
      final b = _Harness(server, storage: InMemoryKeyValueStore());
      await b.boot();
      await b.store.deleteTrainingHistory(entry.id);
      a.cache.failDeletionReceipt = true;
      await a.store.syncPendingWrites();
      await a.settle();
      expect(server.rows, isEmpty);
      expect(
        (await a.cache.readOutbox())!.where(
          (op) => op.kind == SyncOpKind.trainingHistoryInsert,
        ),
        hasLength(1),
      );
      expect(await a.cache.readTrainingHistoryDeletions(), isEmpty);
      expect((await a.cache.readTrainingSession())?.sessionId, entry.id);
      a.cache.failDeletionReceipt = false;
      await a.store.syncPendingWrites();
      await a.settle();
      expect(await a.cache.readOutbox(), isEmpty);
      expect(await a.cache.readTrainingHistoryDeletions(), {entry.id});
      a.dispose();
      server.offline = true;
      final reboot = _Harness(server, storage: storage);
      await h.bootUntilIdle(reboot.store);
      expect(reboot.store.trainingSession, isNull);
      expect(reboot.store.trainingHistory, isEmpty);
    },
  );

  test(
    'live false receipt cannot acknowledge completion when its local deletion fence fails',
    () async {
      final server = _Server();
      final env = _Harness(server, storage: InMemoryKeyValueStore());
      await env.boot();
      final entry = _entry();
      server.deleted.add('A:${entry.id}');
      env.cache.failDeletionReceipt = true;
      expect(
        await env.store.completeTrainingSession(
          entry,
          generation: env.generation,
        ),
        SyncDelivery.queuedRetry,
      );
      // Local intent remains durable until the tombstone and ack commit together.
      expect(env.store.trainingHistory.single.id, entry.id);
      expect(await env.cache.readTrainingSession(), isNull);
      expect(
        (await env.cache.readOutbox())!.where(
          (op) => op.kind == SyncOpKind.trainingHistoryInsert,
        ),
        hasLength(1),
      );
      env.cache.failDeletionReceipt = false;
      await env.store.syncPendingWrites();
      await env.settle();
      expect(await env.cache.readTrainingHistoryDeletions(), {entry.id});
      expect(await env.cache.readOutbox(), isEmpty);
      expect(env.store.trainingSession, isNull);
    },
  );

  test(
    'unreadable deletion receipts fail closed without overwriting recovery',
    () async {
      final storage = InMemoryKeyValueStore();
      final server = _Server()..offline = true;
      final env = _Harness(server, storage: storage);
      final entry = _entry();
      await env.cache.writeTrainingSession(entry.recoverySnapshot());
      await env.cache.writeTrainingHistory([entry]);
      await storage.setString(
        'eatova.v1.training_history_deletions.A',
        '{broken',
      );
      await h.bootUntilIdle(env.store);
      expect(env.store.trainingSession, isNull);
      expect(env.store.trainingHistory, isEmpty);
      await expectLater(
        env.store.completeTrainingSession(entry, generation: env.generation),
        throwsStateError,
      );
      expect(
        (await env.cache.readTrainingSession())?.toJson(),
        entry.recoverySnapshot().toJson(),
      );
      expect(
        await storage.getString('eatova.v1.training_history_deletions.A'),
        '{broken',
      );
      await storage.setString(
        'eatova.v1.training_history_deletions.A',
        jsonEncode({
          'ids': [entry.id],
        }),
      );
      await expectLater(
        env.store.completeTrainingSession(entry, generation: env.generation),
        throwsA(isA<TrainingCompletionDeleted>()),
      );
    },
  );

  test(
    'receipt read failure preserves valid history through complete boot cache snapshots',
    () async {
      final storage = InMemoryKeyValueStore();
      final env = _Harness(_Server()..failLoads = true, storage: storage);
      final entry = _entry();
      await env.cache.writeProfile(
        const UserProfile(onboardingCompleted: true),
      );
      await env.cache.writeTrainingHistory([entry]);
      env.cache.failDeletionRead = true;
      await h.bootUntilIdle(env.store);
      expect(env.store.bootLoadInFlight, isFalse);
      await env.settle();
      expect(env.store.trainingHistory, isEmpty);
      expect(env.store.trainingHistoryLoadFailed, isTrue);
      expect(
        (await env.cache.readTrainingHistory())!.single.toRow(),
        entry.toRow(),
      );
      env.dispose();
      final reboot = _Harness(_Server()..failLoads = true, storage: storage);
      await h.bootUntilIdle(reboot.store);
      expect(reboot.store.bootLoadInFlight, isFalse);
      expect(reboot.store.trainingHistory.single.toRow(), entry.toRow());
    },
  );

  test(
    'history retry repairs receipt reads during failed loads and retains hidden pending overlays and recovery',
    () async {
      final server = _Server()
        ..failLoads = true
        ..rejectHistory = true;
      final env = _Harness(server, storage: InMemoryKeyValueStore());
      final snapshot = _unfinished();
      final synced = _entry();
      final queued = _entry();
      await _seedRecovery(env, snapshot);
      await env.cache.writeTrainingHistory([synced]);
      await env.cache.writeOutbox([SyncOp.trainingHistoryInsert(queued)]);
      env.cache.failDeletionRead = true;
      await h.bootUntilIdle(env.store);
      expect(env.store.bootLoadInFlight, isFalse);
      expect(env.store.trainingHistory, isEmpty);
      expect(env.store.trainingSession, isNull);
      await env.store.retryTrainingHistory();
      expect(env.store.trainingHistory, isEmpty);
      expect(env.store.trainingSession, isNull);
      env.cache.failDeletionRead = false;
      await env.store.retryTrainingHistory();
      expect(env.store.trainingHistory.map((entry) => entry.id).toSet(), {
        synced.id,
        queued.id,
      });
      expect(env.store.trainingSession!.toJson(), snapshot.toJson());
      expect(
        env.store.trainingHistoryLoadFailed,
        isTrue,
      ); // Network still offline.
      server.failLoads = false;
      server.rejectHistory = false;
      server.seedPlan = true;
      server.rows['A:${synced.id}'] = {'user_id': 'A', ...synced.toRow()};
      await env.store.retryTrainingHistory();
      expect(env.store.trainingHistoryLoadFailed, isFalse);
      expect(env.store.trainingHistory.map((entry) => entry.id).toSet(), {
        synced.id,
        queued.id,
      });
      expect(env.store.trainingSession!.sessionId, snapshot.sessionId);
    },
  );

  for (final prepareFirst in [false, true]) {
    test(
      'repaired unfinished recovery rejects an unrelated session until explicitly cleared (prepare=$prepareFirst)',
      () async {
        final env = _Harness(
          _Server()..failLoads = true,
          storage: InMemoryKeyValueStore(),
        );
        final snapshot = _unfinished();
        await _seedRecovery(env, snapshot);
        env.cache.failDeletionRead = true;
        await h.bootUntilIdle(env.store);
        expect(env.store.bootLoadInFlight, isFalse);
        expect(env.store.trainingSession, isNull);
        await expectLater(
          env.store.prepareTrainingSessionRecovery(),
          throwsStateError,
        );
        env.cache.failDeletionRead = false;
        if (prepareFirst) {
          expect(
            (await env.store.prepareTrainingSessionRecovery())!.toJson(),
            snapshot.toJson(),
          );
        }
        final fresh = _unfinished();
        expect(fresh.sessionId, isNot(snapshot.sessionId));
        await expectLater(
          env.store.saveTrainingSession(fresh),
          throwsStateError,
        );
        await expectLater(
          env.store.completeTrainingSession(
            _entry(),
            generation: env.store.trainingSessionGeneration,
          ),
          throwsStateError,
        );
        expect(
          (await env.cache.readTrainingSession())!.toJson(),
          snapshot.toJson(),
        );
        expect(env.store.trainingSession!.sessionId, snapshot.sessionId);
        await env.store.saveTrainingSession(snapshot);
        await env.store.saveTrainingSession(null);
        await env.store.saveTrainingSession(fresh);
        expect(env.store.trainingSession!.sessionId, fresh.sessionId);
      },
    );
  }

  test(
    'prepared unfinished recovery can complete its matching session',
    () async {
      final env = _Harness(
        _Server()..failLoads = true,
        storage: InMemoryKeyValueStore(),
      );
      final snapshot = _unfinished();
      await _seedRecovery(env, snapshot);
      await h.bootUntilIdle(env.store);
      final recovered = await env.store.prepareTrainingSessionRecovery();
      final controller = TrainingSessionController.fromSnapshot(
        recovered!,
        autoTick: false,
      );
      controller.start();
      controller.completeCurrentSet();
      final completed = controller.completion();
      controller.dispose();
      await env.store.completeTrainingSession(
        completed,
        generation: env.store.trainingSessionGeneration,
      );
      expect(env.store.trainingHistory.single.id, snapshot.sessionId);
      expect(env.store.trainingSession, isNull);
    },
  );

  test(
    'prepare repairs checkpoint reads and cannot publish after an account switch',
    () async {
      final env = _Harness(
        _Server()..failLoads = true,
        storage: InMemoryKeyValueStore(),
      );
      final snapshot = _unfinished();
      await _seedRecovery(env, snapshot);
      env.cache.failDeletionRead = true;
      env.cache.failSessionRead = true;
      await h.bootUntilIdle(env.store);
      expect(env.store.bootLoadInFlight, isFalse);
      env.cache.failDeletionRead = false;
      await expectLater(
        env.store.prepareTrainingSessionRecovery(),
        throwsStateError,
      );
      env.cache.failSessionRead = false;
      expect(
        (await env.store.prepareTrainingSessionRecovery())!.toJson(),
        snapshot.toJson(),
      );
      await signInSyncFixture(env.client, 'B');
      await expectLater(
        env.store.prepareTrainingSessionRecovery(),
        throwsStateError,
      );
      expect(
        (await env.cache.readTrainingSession())!.toJson(),
        snapshot.toJson(),
      );
    },
  );

  test(
    'prepare rejects a late receipt read after its pinned account changes',
    () async {
      final env = _Harness(
        _Server()..failLoads = true,
        storage: InMemoryKeyValueStore(),
      );
      final snapshot = _unfinished();
      await _seedRecovery(env, snapshot);
      env.cache.failDeletionRead = true;
      await h.bootUntilIdle(env.store);
      expect(env.store.bootLoadInFlight, isFalse);
      env.cache.failDeletionRead = false;
      final gate = Completer<void>();
      env.cache.holdDeletionRead = gate;
      final preparing = env.store.prepareTrainingSessionRecovery();
      await h.settle();
      await signInSyncFixture(env.client, 'B');
      final rejected = expectLater(preparing, throwsStateError);
      gate.complete();
      await rejected;
      expect(env.store.trainingSession, isNull);
      expect(
        (await env.cache.readTrainingSession())!.toJson(),
        snapshot.toJson(),
      );
    },
  );

  test(
    'deleted pending completion ends without publishing or keeping recovery',
    () async {
      final server = _Server();
      final env = _Harness(server, storage: InMemoryKeyValueStore());
      await env.boot();
      final entry = _entry();
      server.deleted.add('A:${entry.id}');
      await expectLater(
        env.store.completeTrainingSession(entry, generation: env.generation),
        throwsA(isA<TrainingCompletionDeleted>()),
      );
      expect(env.store.trainingHistory, isEmpty);
      expect(await env.cache.readTrainingSession(), isNull);
      expect(await env.cache.readOutbox() ?? [], isEmpty);
    },
  );

  test(
    'failed outbox receipt retains recovery and reports no completion',
    () async {
      final env = _Harness(
        _Server()..offline = true,
        storage: InMemoryKeyValueStore(),
      );
      await env.boot();
      env.cache.failOutbox = true;
      final entry = _entry();
      await env.store.saveTrainingSession(entry.snapshot);
      await expectLater(
        env.store.completeTrainingSession(entry, generation: env.generation),
        throwsStateError,
      );
      expect(env.store.trainingHistory, isEmpty);
      expect((await env.cache.readTrainingSession())?.sessionId, entry.id);
      expect(env.store.trainingSession?.sessionId, entry.id);
      env.cache.failOutbox = false;
      await env.store.completeTrainingSession(
        entry,
        generation: env.generation,
      );
      expect(env.store.trainingHistory.single.id, entry.id);
    },
  );

  test(
    'history stays unpublished and recovery present until held durable receipt settles',
    () async {
      final env = _Harness(
        _Server()..offline = true,
        storage: InMemoryKeyValueStore(),
      );
      await env.boot();
      env.cache.holdOutbox = Completer<void>();
      final entry = _entry();
      await env.store.saveTrainingSession(entry.snapshot);
      var done = false;
      final save = env.store
          .completeTrainingSession(entry, generation: env.generation)
          .then((_) => done = true);
      await env.cache.entered.future;
      expect(done, isFalse);
      expect(env.store.trainingHistory, isEmpty);
      expect((await env.cache.readTrainingSession())?.sessionId, entry.id);
      env.cache.holdOutbox!.complete();
      await save;
      expect(env.store.trainingHistory.single.id, entry.id);
      expect(await env.cache.readTrainingSession(), isNull);
    },
  );

  test(
    'late server callback after A to B cannot ack A durable intent into B',
    () async {
      final server = _Server()..hold = Completer<void>();
      final raw = InMemoryKeyValueStore();
      final client = SupabaseClient(
        'https://ci.invalid',
        'ci-dummy-key',
        httpClient: MockClient(server.handle),
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      await signInSyncFixture(client, 'A');
      final env = _Harness(server, storage: raw, clientOverride: client);
      await env.boot();
      final entry = _entry();
      final save = expectLater(
        env.store.completeTrainingSession(entry, generation: env.generation),
        throwsStateError,
      );
      await server.entered.future;
      await signInSyncFixture(env.client, 'B');
      server.hold!.complete();
      await save;
      expect((await env.cache.readTrainingHistory())!.single.id, entry.id);
      expect(await env.cache.readTrainingSession(), isNull);
      expect(
        (await env.cache.readOutbox())!.any(
          (op) => op.kind == SyncOpKind.trainingHistoryInsert,
        ),
        isTrue,
      );
      expect(server.rows.values.single['user_id'], 'A');
      expect(
        server.requests
            .where(
              (r) =>
                  r.method == 'POST' &&
                  r.url.path.endsWith('/rpc/apply_sync_operation') &&
                  (jsonDecode(r.body) as Map)['p_kind'] ==
                      'trainingHistoryInsert',
            )
            .single
            .headers['authorization'],
        'Bearer ${syncFixtureToken('A')}',
      );
      final b = _Harness(server, storage: raw, owner: 'B');
      await b.boot();
      expect(b.store.trainingHistory, isEmpty);
    },
  );

  test(
    'source edits/deletion leave history immutable; stale player cannot overwrite new recovery',
    () async {
      final env = _Harness(_Server(), storage: InMemoryKeyValueStore());
      await env.boot();
      final entry = _entry();
      await env.store.completeTrainingSession(
        entry,
        generation: env.generation,
      );
      await env.store.saveTrainingPlan(
        entry.snapshot.plan.copyWith(
          proposal: entry.snapshot.plan.proposal.copyWith(title: 'Edited'),
        ),
      );
      await env.store.deleteTrainingPlan(entry.snapshot.plan.id);
      expect(env.store.trainingHistory.single.toRow(), entry.toRow());
      expect(
        await env.store.saveTrainingSession(entry.snapshot, generation: 0),
        isFalse,
      );
      expect(await env.cache.readTrainingSession(), isNull);
      expect(env.store.trainingHistory.length, 1);
      final duplicate = await env.store.completeTrainingSession(
        entry,
        generation: env.generation,
      );
      expect(duplicate, SyncDelivery.delivered);
      expect(env.server.rows.length, 1);
      await env.store.deleteTrainingHistory(entry.id);
      expect(env.store.trainingHistory, isEmpty);
      expect(env.server.rows, isEmpty);
    },
  );

  test(
    'failed cleanup cannot revive completed recovery; delete clears recovery first',
    () async {
      final env = _Harness(_Server(), storage: InMemoryKeyValueStore());
      await env.boot();
      final entry = _entry();
      await env.store.completeTrainingSession(
        entry,
        generation: env.generation,
      );
      expect(env.store.trainingSession, isNull);
      // Explicit legacy stale recovery exercises deletion's atomic retirement.
      await env.cache.writeTrainingSession(entry.recoverySnapshot());
      expect((await env.cache.readTrainingSession())?.sessionId, entry.id);
      env.cache.failClear = true;
      await expectLater(
        env.store.deleteTrainingHistory(entry.id),
        throwsStateError,
      );
      expect(env.store.trainingHistory.single.id, entry.id);
      env.cache.failClear = false;
      await env.store.deleteTrainingHistory(entry.id);
      expect(await env.cache.readTrainingSession(), isNull);
      expect(env.store.trainingHistory, isEmpty);
    },
  );

  test('discard writes only recovery, never completed history', () async {
    final env = _Harness(_Server(), storage: InMemoryKeyValueStore());
    await env.boot();
    await env.store.saveTrainingSession(_entry().snapshot);
    await env.store.saveTrainingSession(null);
    expect(env.store.trainingHistory, isEmpty);
    expect(env.server.rows, isEmpty);
    expect(await env.cache.readTrainingSession(), isNull);
  });

  test(
    'acknowledged completion survives aged poison rejection and authoritative empty boot',
    () async {
      final raw = InMemoryKeyValueStore();
      final server = _Server()..offline = true;
      final first = _Harness(server, storage: raw);
      await first.boot();
      final entry = _entry();
      await first.store.completeTrainingSession(
        entry,
        generation: first.generation,
      );
      await first.settle();
      first.dispose();
      final cache = LocalCache(raw, 'A');
      final pending = (await cache.readOutbox())!
          .where((op) => op.kind == SyncOpKind.trainingHistoryInsert)
          .single;
      await cache.writeOutbox([
        SyncOp.tryFromJson(
          pending.toJson()
            ..['attempts'] = 999
            ..['queued_at'] = '2020-01-01T00:00:00Z',
        )!,
      ]);
      server.offline = false;
      server.rejectHistory = true;
      final reboot = _Harness(server, storage: raw);
      await reboot.boot();
      await reboot.settle();
      expect(reboot.store.trainingHistory.single.id, entry.id);
      expect(
        (await reboot.cache.readOutbox())!.any(
          (op) => op.kind == SyncOpKind.trainingHistoryInsert,
        ),
        isTrue,
      );
      expect(reboot.store.trainingSession, isNull);
    },
  );

  test(
    'cap retains acknowledged history while rejecting a new completion at full capacity',
    () async {
      final entries = List.generate(
        kOutboxMaxOps,
        (_) => SyncOp.trainingHistoryInsert(_entry()),
      );
      final raw = InMemoryKeyValueStore();
      final cache = LocalCache(raw, 'A');
      await cache.writeOutbox(entries);
      final server = _Server()
        ..offline = true
        ..seedPlan = true;
      final env = _Harness(server, storage: raw);
      final entry = _entry();
      await cache.writeProfile(const UserProfile(onboardingCompleted: true));
      await cache.writeTrainingPlans([entry.snapshot.plan]);
      await cache.writeTrainingSession(entry.snapshot);
      await h.bootUntilIdle(env.store);
      await expectLater(
        env.store.completeTrainingSession(entry, generation: env.generation),
        throwsStateError,
      );
      expect((await env.cache.readTrainingSession())?.sessionId, entry.id);
      expect(env.store.trainingHistory.length, kOutboxMaxOps);
      expect((await env.cache.readOutbox())!.length, kOutboxMaxOps);
    },
  );

  test(
    'a log keeps an unrelated paused checkpoint and its source across restart',
    () async {
      final raw = InMemoryKeyValueStore();
      final server = _Server()..seedPlan = true;
      final env = _Harness(server, storage: raw);
      await env.boot();
      expect(env.store.trainingHistoryAuthoritative, isTrue);
      final paused = _unfinished();
      expect(
        await env.store.saveTrainingSession(
          paused,
          generation: env.generation,
          sourcePlanId: paused.plan.id,
        ),
        isTrue,
      );
      final generation = env.store.trainingSessionGeneration;
      final log = _log();
      expect(await env.store.logCompletedWorkout(log), SyncDelivery.delivered);
      expect(env.store.trainingHistory.single.toRow(), log.toRow());
      expect(_historyInsertRequests(server), 1);
      expect(server.rows.values.single['id'], log.id);
      expect(env.store.trainingSession?.toJson(), paused.toJson());
      expect(env.store.trainingSessionGeneration, generation);
      expect(
        env.store.isTrainingSessionRetired(
          generation: env.generation,
          sourcePlanId: paused.plan.id,
        ),
        isFalse,
      );
      expect(
        (await env.cache.readTrainingSession())?.toJson(),
        paused.toJson(),
      );
      await env.settle();
      env.dispose();

      server.offline = true;
      final reboot = _Harness(server, storage: raw);
      await h.bootUntilIdle(reboot.store);
      expect(reboot.store.trainingSession?.toJson(), paused.toJson());
      expect(reboot.store.trainingHistory.single.id, log.id);
    },
  );

  test(
    'an offline log is durable across restart, replays once and re-confirming writes nothing',
    () async {
      final raw = InMemoryKeyValueStore();
      final storage = EncryptedKeyValueStore(
        raw,
        AesGcmCacheCipher(Uint8List(32)),
      );
      final server = _Server()
        ..offline = true
        ..seedPlan = true;
      final first = _Harness(server, storage: storage);
      await first.boot();
      final log = _log();
      expect(
        await first.store.logCompletedWorkout(log),
        SyncDelivery.queuedOffline,
      );
      expect(
        await first.store.logCompletedWorkout(log),
        SyncDelivery.queuedRetry,
      );
      expect(_historyInserts(first.store.pendingOutbox), hasLength(1));
      expect(first.store.trainingHistory.single.toRow(), log.toRow());
      await first.settle();
      first.dispose();

      final reboot = _Harness(server, storage: storage);
      await reboot.boot();
      expect(reboot.store.trainingHistory.single.toRow(), log.toRow());
      expect(_historyInserts(await reboot.cache.readOutbox()), hasLength(1));
      server.offline = false;
      await reboot.store.syncPendingWrites();
      await reboot.settle();
      expect(server.rows.length, 1);
      final attempts = _historyInsertRequests(server);
      expect(
        await reboot.store.logCompletedWorkout(log),
        SyncDelivery.delivered,
      );
      expect(_historyInserts(await reboot.cache.readOutbox()), isEmpty);
      expect(_historyInsertRequests(server), attempts);
      expect(server.rows.length, 1);
    },
  );

  test(
    'a deleted log ID throws TrainingCompletionDeleted and is never written again',
    () async {
      final server = _Server();
      final env = _Harness(server, storage: InMemoryKeyValueStore());
      await env.boot();
      final log = _log();
      await env.store.logCompletedWorkout(log);
      await env.store.deleteTrainingHistory(log.id);
      expect(env.store.trainingHistoryDeletedIds, {log.id});
      expect(
        () => env.store.trainingHistoryDeletedIds.add(uuidV4()),
        throwsUnsupportedError,
      );
      final requests = _historyInsertRequests(server);
      await expectLater(
        env.store.logCompletedWorkout(log),
        throwsA(isA<TrainingCompletionDeleted>()),
      );
      expect(_historyInsertRequests(server), requests);
      expect(env.store.trainingHistory, isEmpty);
      expect(_historyInserts(await env.cache.readOutbox()), isEmpty);
      expect(server.rows, isEmpty);

      // Another device's tombstone answers the insert after the commit.
      final remote = _log();
      server.deleted.add('A:${remote.id}');
      await expectLater(
        env.store.logCompletedWorkout(remote),
        throwsA(isA<TrainingCompletionDeleted>()),
      );
      expect(env.store.trainingHistoryDeletedIds, {log.id, remote.id});
      expect(env.store.trainingHistory, isEmpty);
      expect(await env.cache.readTrainingHistory(), isEmpty);
      expect(_historyInserts(await env.cache.readOutbox()), isEmpty);
      expect(server.rows, isEmpty);
    },
  );

  test('a log at the history cap throws without writing', () async {
    final raw = InMemoryKeyValueStore();
    final cache = LocalCache(raw, 'A');
    await cache.writeProfile(const UserProfile(onboardingCompleted: true));
    await cache.writeTrainingHistory([
      for (var i = 0; i < TrainingHistorySync.limit; i++) _log(),
    ]);
    final env = _Harness(_Server()..offline = true, storage: raw);
    await h.bootUntilIdle(env.store, frist: const Duration(seconds: 20));
    expect(env.store.trainingHistory, hasLength(TrainingHistorySync.limit));
    await expectLater(env.store.logCompletedWorkout(_log()), throwsStateError);
    expect(env.store.trainingHistory, hasLength(TrainingHistorySync.limit));
    expect(_historyInserts(await env.cache.readOutbox()), isEmpty);
    expect(
      await env.cache.readTrainingHistory(),
      hasLength(TrainingHistorySync.limit),
    );
  });

  test(
    'unreadable receipts keep the history unauthoritative and fail a log closed',
    () async {
      final server = _Server();
      final env = _Harness(server, storage: InMemoryKeyValueStore());
      await env.cache.writeProfile(
        const UserProfile(onboardingCompleted: true),
      );
      env.cache.failDeletionRead = true;
      await h.bootUntilIdle(env.store);
      expect(env.store.trainingHistoryAuthoritative, isFalse);
      await expectLater(
        env.store.logCompletedWorkout(_log()),
        throwsStateError,
      );
      expect(env.store.trainingHistory, isEmpty);
      expect(_historyInserts(await env.cache.readOutbox()), isEmpty);
      expect(server.rows, isEmpty);

      env.cache.failDeletionRead = false;
      await env.store.retryTrainingHistory();
      expect(env.store.trainingHistoryAuthoritative, isTrue);
    },
  );

  test('an account switch during a log throws and writes nothing', () async {
    final server = _Server();
    final env = _Harness(server, storage: InMemoryKeyValueStore());
    await env.cache.writeProfile(const UserProfile(onboardingCompleted: true));
    env.cache.failDeletionRead = true;
    await h.bootUntilIdle(env.store);
    env.cache.failDeletionRead = false;
    final gate = Completer<void>();
    env.cache.holdDeletionRead = gate;
    final logging = env.store.logCompletedWorkout(_log());
    await h.settle();
    await signInSyncFixture(env.client, 'B');
    final rejected = expectLater(logging, throwsStateError);
    gate.complete();
    await rejected;
    expect(env.store.trainingHistory, isEmpty);
    expect(_historyInserts(await env.cache.readOutbox()), isEmpty);
    expect(await env.cache.readTrainingHistory() ?? const [], isEmpty);
    expect(server.rows, isEmpty);
  });

  test(
    'a plan-attached log waits for a session or recovery and keeps the source',
    () async {
      final env = _Harness(
        _Server()..seedPlan = true,
        storage: InMemoryKeyValueStore(),
      );
      await env.boot();
      final paused = _unfinished();
      await env.store.saveTrainingSession(paused);
      final attached = _planAttached();
      await expectLater(
        env.store.logCompletedWorkout(attached, planAttached: true),
        throwsA(isA<TrainingLogBlockedBySession>()),
      );
      expect(env.store.trainingHistory, isEmpty);
      expect(_historyInserts(await env.cache.readOutbox()), isEmpty);
      expect(env.store.trainingSession?.toJson(), paused.toJson());

      // A free log never waits for the session.
      final free = _log();
      expect(await env.store.logCompletedWorkout(free), SyncDelivery.delivered);
      expect(env.store.trainingSession?.toJson(), paused.toJson());

      await env.store.saveTrainingSession(null);
      final skippedOnly = TrainingHistoryEntry(
        snapshot: TrainingSessionSnapshot(
          plan: timerPlan(),
          startedAt: DateTime.utc(2026, 9, 10, 12),
          workoutIndex: 1,
          exerciseIndex: 0,
          setIndex: 0,
          phase: TrainingSessionPhase.review,
          remainingMilliseconds: 0,
          skippedSets: const [
            TrainingSetReference(exerciseIndex: 0, setIndex: 0),
          ],
        ),
        finishedAt: DateTime.utc(2026, 9, 10, 12),
      );
      await expectLater(
        env.store.logCompletedWorkout(skippedOnly, planAttached: true),
        throwsFormatException,
      );
      final generation = env.store.trainingSessionGeneration;
      expect(
        await env.store.logCompletedWorkout(attached, planAttached: true),
        SyncDelivery.delivered,
      );
      expect(env.store.trainingHistory.map((e) => e.id).toSet(), {
        free.id,
        attached.id,
      });
      expect(env.store.trainingSessionGeneration, generation);
      expect(
        env.store.isTrainingSessionRetired(
          generation: generation,
          sourcePlanId: attached.snapshot.plan.id,
        ),
        isFalse,
      );
    },
  );

  test('a plan-attached log waits for a recovered checkpoint', () async {
    final env = _Harness(
      _Server()..failLoads = true,
      storage: InMemoryKeyValueStore(),
    );
    final recovery = _unfinished();
    await _seedRecovery(env, recovery);
    await h.bootUntilIdle(env.store);
    await env.store.prepareTrainingSessionRecovery();
    await expectLater(
      env.store.logCompletedWorkout(_planAttached(), planAttached: true),
      throwsA(isA<TrainingLogBlockedBySession>()),
    );
    expect(env.store.trainingHistory, isEmpty);
    expect(
      (await env.cache.readTrainingSession())?.toJson(),
      recovery.toJson(),
    );
  });

  for (final change in ['edited', 'deleted']) {
    test(
      'finishing after the source plan was $change saves the frozen copy; the stale route still cannot write a checkpoint',
      () async {
        final server = _Server();
        final env = _Harness(server, storage: InMemoryKeyValueStore());
        await env.boot();
        final routeGeneration = env.generation;
        final entry = _entry();
        final sourcePlanId = entry.snapshot.plan.id;
        expect(
          await env.store.saveTrainingSession(
            entry.snapshot,
            generation: routeGeneration,
            sourcePlanId: sourcePlanId,
          ),
          isTrue,
        );
        if (change == 'edited') {
          await env.store.saveTrainingPlan(_editedPlan());
        } else {
          await env.store.deleteTrainingPlan(sourcePlanId);
        }
        expect(
          env.store.isTrainingSessionRetired(
            generation: routeGeneration,
            sourcePlanId: sourcePlanId,
          ),
          isTrue,
        );
        expect(
          await env.store.saveTrainingSession(
            entry.snapshot,
            generation: routeGeneration,
            sourcePlanId: sourcePlanId,
          ),
          isFalse,
        );
        expect(await env.cache.readTrainingSession(), isNull);
        expect(
          await env.store.completeTrainingSession(
            entry,
            generation: routeGeneration,
          ),
          SyncDelivery.delivered,
        );
        expect(env.store.trainingHistory.single.toRow(), entry.toRow());
        expect(server.rows.values.single['session'], entry.toRow()['session']);
      },
    );
  }

  test(
    'completion keeps an unrelated session; a protected recovery still blocks it',
    () async {
      final raw = InMemoryKeyValueStore();
      final server = _Server()..seedPlan = true;
      final env = _Harness(server, storage: raw);
      await env.boot();
      final paused = _unfinished();
      expect(await env.store.saveTrainingSession(paused), isTrue);
      final finished = _entry();
      expect(
        await env.store.completeTrainingSession(
          finished,
          generation: env.generation,
        ),
        SyncDelivery.delivered,
      );
      expect(env.store.trainingHistory.single.id, finished.id);
      expect(env.store.trainingSession?.toJson(), paused.toJson());
      expect(
        (await env.cache.readTrainingSession())?.toJson(),
        paused.toJson(),
      );
      expect(
        env.store.isTrainingSessionRetired(
          generation: env.generation,
          sourcePlanId: paused.plan.id,
        ),
        isFalse,
      );
      await env.settle();
      env.dispose();

      final reboot = _Harness(server, storage: raw);
      await h.bootUntilIdle(reboot.store);
      expect(
        (await reboot.store.prepareTrainingSessionRecovery())?.toJson(),
        paused.toJson(),
      );
      await expectLater(
        reboot.store.completeTrainingSession(
          _entry(),
          generation: reboot.store.trainingSessionGeneration,
        ),
        throwsStateError,
      );
      expect(reboot.store.trainingHistory.single.id, finished.id);
      expect(reboot.store.trainingSession?.toJson(), paused.toJson());
    },
  );
}
