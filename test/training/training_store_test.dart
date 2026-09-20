import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:clock/clock.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/coach_training_proposal.dart';
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
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import '../outbox/outbox_test_helpers.dart' as h;
import '../support/atomic_store_faults.dart';
import '../support/sync_operation_fake.dart';

TrainingPlan plan([String id = 'coach_message', String title = 'Strength']) =>
    TrainingPlan(
      id: id,
      proposal: CoachTrainingProposal(
        title: title,
        workouts: [
          TrainingWorkout(
            title: 'Day A',
            exercises: [
              TrainingExercise(
                name: 'Squat',
                sets: 3,
                reps: 8,
                restSeconds: 60,
              ),
            ],
          ),
        ],
      ),
    );

class _Server {
  bool offline = false;
  bool failReads = false;
  bool rejectTrainingWrites = false;
  bool retryTrainingWrites = false;
  bool trainingOffline = false;
  Completer<void>? holdTracking;
  Completer<void>? holdStats;
  final trackingEntered = Completer<void>();
  final statsEntered = Completer<void>();
  Completer<void>? holdRead;
  Completer<void>? holdWrite;
  Completer<void>? holdTrainingResponse;
  final readEntered = Completer<void>();
  final writeEntered = Completer<void>();
  final rows = <String, Map<String, dynamic>>{};
  final requests = <http.Request>[];
  late final operations = SyncOperationFake(
    meals: {},
    weights: {},
    favorites: {},
    recipes: {},
    trainingPlans: rows,
    readProfile: () => null,
    writeProfile: (_) {},
    readStats: () => {},
    incrementStats: (_, _, _) {},
    recordDay: (_) {},
  );

  Future<http.Response> handle(http.Request request) async {
    requests.add(request);
    final params = request.url.path.endsWith('/rpc/apply_sync_operation')
        ? (jsonDecode(request.body) as Map).cast<String, dynamic>()
        : null;
    final kind = params?['p_kind'];
    if ((request.url.path.endsWith('/rpc/record_tracking_day') ||
            kind == 'trackingDay') &&
        holdTracking != null) {
      if (!trackingEntered.isCompleted) trackingEntered.complete();
      await holdTracking!.future;
      return http.Response(
        '{"code":"503","message":"fixture"}',
        503,
        headers: {'content-type': 'application/json'},
        request: request,
      );
    }
    if ((request.url.path.endsWith('/rpc/increment_lifetime_stats') ||
            kind == 'statsIncrement') &&
        holdStats != null) {
      if (!statsEntered.isCompleted) statsEntered.complete();
      await holdStats!.future;
      return http.Response(
        '{}',
        200,
        headers: {'content-type': 'application/json'},
        request: request,
      );
    }
    if (offline) throw http.ClientException('offline');
    final training =
        request.url.path.endsWith('/training_plans') ||
        kind == 'trainingPlanUpsert' ||
        kind == 'trainingPlanDelete';
    if (training && trainingOffline && request.method != 'GET') {
      throw http.ClientException('fixture training offline');
    }
    Object? body = const [];
    if (training && request.method == 'GET') {
      if (failReads) throw http.ClientException('offline');
      body = rows.values.map((row) => Map<String, dynamic>.of(row)).toList();
      if (!readEntered.isCompleted) readEntered.complete();
      await holdRead?.future;
    } else if (training) {
      await holdTrainingResponse?.future;
      if (retryTrainingWrites) {
        return http.Response(
          '{"code":"503","message":"fixture"}',
          503,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      }
      if (rejectTrainingWrites) {
        return http.Response(
          '{"code":"23502","message":"fixture"}',
          400,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      }
      if (!writeEntered.isCompleted) writeEntered.complete();
      await holdWrite?.future;
      if (params != null) {
        body = operations.apply(params);
      } else if (_isTrainingWrite(request, 'trainingPlanDelete')) {
        rows.remove(request.url.queryParameters['id']!.substring(3));
      } else {
        final decoded = jsonDecode(request.body);
        final row = (decoded is List ? decoded.single : decoded) as Map;
        rows[row['id'] as String] = row.cast<String, dynamic>();
      }
    } else if (params != null) {
      body = operations.apply(params);
    }
    if (request.url.path.endsWith('/profiles')) body = null;
    if (request.url.path.endsWith('/lifetime_stats')) body = {};
    return http.Response(
      jsonEncode(body),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
      request: request,
    );
  }
}

class _Harness {
  _Harness(
    this.server, {
    KeyValueStore? storage,
    String userId = 'user-training',
    LocalCache? cacheOverride,
  }) {
    cache =
        cacheOverride ?? LocalCache(storage ?? InMemoryKeyValueStore(), userId);
    client = SupabaseClient(
      'https://example.invalid',
      'fixture',
      httpClient: MockClient(server.handle),
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    store = HomeStore(
      sync: EatovaSync.forUser(client, userId),
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
  late final LocalCache cache;
  late final SupabaseClient client;
  late final HomeStore store;
  bool _disposed = false;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    store.dispose();
  }

  Future<void> boot() async {
    await cache.writeProfile(const UserProfile(onboardingCompleted: true));
    await h.boot(store);
    await h.pumpUntil(
      () => !store.bootLoadInFlight,
      frist: const Duration(seconds: 20),
    );
    expect(store.bootLoadInFlight, isFalse);
  }

  Future<void> flush() async {
    store.flushPendingWrites();
    await h.settle();
    await cache.flush();
    await cache.settle();
  }
}

bool _isTrainingWrite(http.Request request, [String? kind]) =>
    request.url.path.endsWith('/rpc/apply_sync_operation') &&
    (kind == null
        ? (jsonDecode(request.body)['p_kind'] as String).startsWith(
            'trainingPlan',
          )
        : jsonDecode(request.body)['p_kind'] == kind);

class _FailOutboxCache extends _TransientOutboxFailureCache {
  _FailOutboxCache([KeyValueStore? storage])
    : super(storage ?? InMemoryKeyValueStore());
}

class _TransientOutboxFailureCache extends LocalCache {
  _TransientOutboxFailureCache(KeyValueStore storage)
    : this._(AtomicStoreFaults(storage));

  _TransientOutboxFailureCache._(this.faults) : super(faults, 'user-training') {
    faults.beforeWrite = beforeWrite;
  }

  final AtomicStoreFaults faults;

  int failuresRemaining = 0;

  Future<void> beforeWrite(Map<String, String?> changes) async {
    if (changes.keys.any((key) => key.contains('.outbox.')) &&
        failuresRemaining > 0) {
      failuresRemaining--;
      throw StateError('fixture outbox transaction failure');
    }
  }
}

class _HeldOutboxCache extends _TransientOutboxFailureCache {
  _HeldOutboxCache() : super(InMemoryKeyValueStore());
  final gate = Completer<void>();
  bool hold = false;
  @override
  Future<void> beforeWrite(Map<String, String?> changes) async {
    if (!hold || !changes.keys.any((key) => key.contains('.outbox.'))) return;
    await gate.future;
    throw StateError('fixture outbox transaction failure');
  }
}

class _RecoveringOutboxCache extends _TransientOutboxFailureCache {
  _RecoveringOutboxCache(super.storage) {
    faults.beforeRead = (keys) async {
      if (!keys.any((key) => key.contains('.outbox.'))) return;
      if (unreadable) {
        throw const UnreadableCacheSlot('outbox', 'fixture unavailable');
      }
      await holdRepair?.future;
    };
  }

  bool unreadable = true;
  Completer<void>? holdRepair;
  List<SyncOp>? immediateRecovery;
  final failedWrite = Completer<void>();

  @override
  Future<List<SyncOp>?> readOutboxOrThrow() {
    if (unreadable) {
      return Future.error(
        const UnreadableCacheSlot('outbox', 'fixture unavailable'),
      );
    }
    if (immediateRecovery != null) return Future.value(immediateRecovery);
    return _readAfterRepairGate();
  }

  Future<List<SyncOp>?> _readAfterRepairGate() async {
    await holdRepair?.future;
    return super.readOutboxOrThrow();
  }

  @override
  Future<void> beforeWrite(Map<String, String?> changes) async {
    try {
      await super.beforeWrite(changes);
    } catch (_) {
      if (!failedWrite.isCompleted) failedWrite.complete();
      rethrow;
    }
  }
}

class _HeldInitialOutboxCache extends _TransientOutboxFailureCache {
  _HeldInitialOutboxCache(super.store) {
    faults.beforeRead = (keys) async {
      if (!keys.any((key) => key.contains('.outbox.')) || entered.isCompleted) {
        return;
      }
      entered.complete();
      await release.future;
    };
  }

  final entered = Completer<void>();
  final release = Completer<void>();
}

class _HeldOutboxStorage extends InMemoryKeyValueStore {
  int writes = 0;
  int? holdAt;
  int? failFrom;
  final failAt = <int>{};
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<KeyValueCommit> writeBatch(
    Map<String, String?> changes, {
    Map<String, int> expectedVersions = const {},
  }) async {
    if (changes.keys.any((key) => key.contains('.outbox.'))) {
      final attempt = ++writes;
      if (attempt == holdAt) {
        entered.complete();
        await release.future;
      }
      if (failAt.contains(attempt) ||
          (failFrom != null && attempt >= failFrom!)) {
        throw StateError('fixture outbox write failure');
      }
    }
    return super.writeBatch(changes, expectedVersions: expectedVersions);
  }
}

class _AcknowledgmentHeldCache extends _TransientOutboxFailureCache {
  _AcknowledgmentHeldCache() : super(InMemoryKeyValueStore());

  final entered = Completer<void>();
  final release = Completer<void>();
  int writes = 0;

  @override
  Future<void> beforeWrite(Map<String, String?> changes) async {
    if (changes.keys.any((key) => key.contains('.outbox.')) && ++writes == 2) {
      entered.complete();
      await release.future;
    }
  }
}

class _SessionStorage extends InMemoryKeyValueStore {
  Completer<void>? gate;
  bool fail = false;
  int? failFromWrite;
  int sessionWrites = 0;
  @override
  Future<KeyValueCommit> writeBatch(
    Map<String, String?> changes, {
    Map<String, int> expectedVersions = const {},
  }) async {
    if (changes.keys.any((key) => key.contains('.training_session.'))) {
      sessionWrites++;
      await gate?.future;
      if (fail || (failFromWrite != null && sessionWrites >= failFromWrite!)) {
        throw StateError('fixture storage failure');
      }
    }
    return super.writeBatch(changes, expectedVersions: expectedVersions);
  }
}

class _TrainingReadFailCipher implements CacheCipher {
  final delegate = AesGcmCacheCipher(Uint8List(32));
  bool blockSessionRead = false;
  bool blockPlanRead = false;
  bool blockPlanWrite = false;

  @override
  Future<String> decrypt(String key, String armored) {
    if ((blockSessionRead && key.contains('.training_session.')) ||
        (blockPlanRead && key.contains('.training_plans.'))) {
      throw StateError('fixture transient decrypt failure');
    }
    return delegate.decrypt(key, armored);
  }

  @override
  Future<String> encrypt(String key, String plaintext) {
    if (blockPlanWrite && key.contains('.training_plans.')) {
      throw StateError('fixture mirror write failure');
    }
    return delegate.encrypt(key, plaintext);
  }
}

TrainingSessionSnapshot _snapshot() => TrainingSessionSnapshot(
  sessionId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  startedAt: DateTime.utc(2026, 9, 10),
  plan: plan(),
  workoutIndex: 0,
  exerciseIndex: 0,
  setIndex: 0,
  phase: TrainingSessionPhase.exercise,
  remainingMilliseconds: 0,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'unknown plan library preserves full recovery across offline reboot',
    () async {
      final raw = InMemoryKeyValueStore();
      final cipher = _TrainingReadFailCipher();
      final encrypted = EncryptedKeyValueStore(raw, cipher);
      final env = _Harness(_Server()..offline = true, storage: encrypted);
      await env.cache.writeTrainingPlans([plan(), plan('other')]);
      await env.cache.writeTrainingSession(_snapshot());
      const planKey = 'eatova.v1.training_plans.user-training';
      final originalPlans = raw.snapshot[planKey];
      cipher.blockPlanRead = true;
      await env.boot();
      expect(env.store.trainingPlans, isEmpty);
      expect(
        env.store.trainingSession?.toJson(),
        _snapshot().toJson(),
        reason: 'A failed library read is not evidence of source deletion',
      );
      await env.store.saveTrainingSession(_snapshot());
      await env.store.deleteTrainingPlan('other');
      await env.flush();
      expect(env.store.trainingSession?.toJson(), _snapshot().toJson());
      expect(
        raw.snapshot[planKey],
        originalPlans,
        reason: 'Unknown partial state must not overwrite the complete mirror',
      );
      env.dispose();
      cipher.blockPlanRead = false;
      final reboot = _Harness(_Server()..offline = true, storage: encrypted);
      await reboot.boot();
      expect(reboot.store.trainingPlans.map((p) => p.id), [plan().id]);
      expect(reboot.store.trainingSession?.toJson(), _snapshot().toJson());
    },
  );

  for (final mirror in ['empty', 'old-workout']) {
    test('stale cached library preserves newer full recovery: $mirror', () async {
      final raw = InMemoryKeyValueStore();
      final cipher = _TrainingReadFailCipher();
      final encrypted = EncryptedKeyValueStore(raw, cipher);
      final env = _Harness(_Server(), storage: encrypted);
      await env.boot();
      if (mirror == 'old-workout') await env.store.saveTrainingPlan(plan());
      await env.flush();
      const planKey = 'eatova.v1.training_plans.user-training';
      final oldMirror = raw.snapshot[planKey];
      expect(oldMirror, isNotNull);
      final updated = plan().copyWith(
        proposal: CoachTrainingProposal(
          title: 'Updated plan',
          workouts: [plan().workouts.single.copyWith(title: 'Updated workout')],
        ),
      );
      final checkpoint = TrainingSessionSnapshot(
        plan: updated,
        workoutIndex: 0,
        exerciseIndex: 0,
        setIndex: 1,
        phase: TrainingSessionPhase.exercise,
        remainingMilliseconds: 0,
        completedSets: const [
          TrainingSetReference(exerciseIndex: 0, setIndex: 0),
        ],
      );
      await env.cache.writeTrainingSession(checkpoint);
      env.server.rows[updated.id] = updated.toRow();
      await env.cache.settle();
      expect(raw.snapshot[planKey], oldMirror);
      env.dispose();
      env.server.offline = true;
      final reboot = _Harness(env.server, storage: encrypted);
      await reboot.boot();
      expect(
        reboot.store.trainingPlans.map((p) => p.workouts.single.title),
        mirror == 'empty' ? isEmpty : ['Day A'],
      );
      expect(
        (await reboot.cache.readTrainingSession())?.toJson(),
        checkpoint.toJson(),
      );
      expect(
        reboot.store.trainingSession?.toJson(),
        checkpoint.toJson(),
        reason:
            'A best-effort plan mirror cannot invalidate a durable full checkpoint',
      );
      await reboot.store.saveTrainingSession(checkpoint);
      expect(reboot.store.trainingSession?.toJson(), checkpoint.toJson());
    });
  }

  test(
    'queued source deletion stays decisive when the library is unknown',
    () async {
      final raw = InMemoryKeyValueStore();
      final cipher = _TrainingReadFailCipher();
      final env = _Harness(
        _Server()..offline = true,
        storage: EncryptedKeyValueStore(raw, cipher),
      );
      await env.cache.writeTrainingPlans([plan()]);
      await env.cache.writeTrainingSession(_snapshot());
      await env.cache.writeOutbox([SyncOp.trainingPlanDelete(plan().id)]);
      cipher.blockPlanRead = true;
      final visible = <TrainingSessionSnapshot>[];
      env.store.addListener(() {
        final snapshot = env.store.trainingSession;
        if (snapshot != null) visible.add(snapshot);
      });
      await env.boot();
      expect(
        visible,
        isEmpty,
        reason: 'No hydration notification may offer stale Resume',
      );
      expect(env.store.trainingSession, isNull);
      expect(await env.cache.readTrainingSession(), isNull);
      cipher.blockPlanRead = false;
      await expectLater(
        env.store.saveTrainingSession(_snapshot()),
        throwsStateError,
      );
      await env.store.adoptTrainingPlan(plan());
      final adopted = env.store.trainingPlans.single;
      expect(adopted.id, plan().id);
      expect(adopted.incarnation, 1);
      expect(env.store.trainingSession, isNull);
      await expectLater(
        env.store.saveTrainingSession(_snapshot()),
        throwsStateError,
      );
      final checkpoint = TrainingSessionSnapshot(
        sessionId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
        startedAt: DateTime.utc(2026, 9, 20),
        plan: adopted,
        workoutIndex: 0,
        exerciseIndex: 0,
        setIndex: 0,
        phase: TrainingSessionPhase.exercise,
        remainingMilliseconds: 0,
      );
      await env.store.saveTrainingSession(checkpoint);
      expect(env.store.trainingSession?.toJson(), checkpoint.toJson());
      expect(
        (await env.cache.readTrainingSession())?.toJson(),
        checkpoint.toJson(),
      );
    },
  );

  test(
    'session read repair preserves recovery when the library is unknown',
    () async {
      final raw = InMemoryKeyValueStore();
      final cipher = _TrainingReadFailCipher();
      final env = _Harness(
        _Server()..offline = true,
        storage: EncryptedKeyValueStore(raw, cipher),
      );
      await env.cache.writeTrainingPlans([plan(), plan('other')]);
      await env.cache.writeTrainingSession(_snapshot());
      cipher.blockSessionRead = true;
      cipher.blockPlanRead = true;
      await env.boot();
      expect(env.store.trainingSession, isNull);
      cipher.blockSessionRead = false;
      await env.store.deleteTrainingPlan('other');
      expect(env.store.trainingSession?.toJson(), _snapshot().toJson());
      await env.store.deleteTrainingPlan(plan().id);
      expect(env.store.trainingSession, isNull);
      expect(await env.cache.readTrainingSession(), isNull);
    },
  );

  for (final offline in [false, true]) {
    test(
      'source deletion clears paused recovery durably, offline=$offline',
      () async {
        final storage = InMemoryKeyValueStore();
        final server = _Server();
        final first = _Harness(server, storage: storage);
        await first.boot();
        await first.store.saveTrainingPlan(plan());
        await first.store.saveTrainingSession(_snapshot());
        server.offline = offline;
        await first.store.deleteTrainingPlan(plan().id);
        expect(first.store.trainingSession, isNull);
        expect(await first.cache.readTrainingSession(), isNull);
        await first.cache.flush();
        await first.cache.settle();
        first.dispose();
        server.offline = true;
        final reboot = _Harness(server, storage: storage);
        await reboot.boot();
        expect(reboot.store.trainingSession, isNull);
        expect(reboot.store.trainingPlans, isEmpty);
      },
    );
  }

  TrainingPlan multiPlan(List<TrainingWorkout> workouts) => TrainingPlan(
    id: plan().id,
    proposal: CoachTrainingProposal(title: 'Multiple days', workouts: workouts),
  );
  TrainingSessionSnapshot snapshotFor(TrainingPlan source, {int workout = 0}) =>
      TrainingSessionSnapshot(
        plan: source,
        workoutIndex: workout,
        exerciseIndex: 0,
        setIndex: 0,
        phase: TrainingSessionPhase.exercise,
        remainingMilliseconds: 0,
      );

  test(
    'unrelated plan deletion and workout removal/reorder preserve recovery',
    () async {
      final storage = InMemoryKeyValueStore();
      final env = _Harness(_Server(), storage: storage);
      await env.boot();
      final source = plan().workouts.single;
      final other = source.copyWith(
        title: 'Other day',
        exercises: [
          for (var i = 0; i < source.exercises.length; i++)
            source.exercises[i].copyWith(id: 'other-$i'),
        ],
      );
      final original = multiPlan([other, source]);
      final snapshot = snapshotFor(original, workout: 1);
      await env.store.saveTrainingPlan(original);
      await env.store.saveTrainingPlan(plan('unrelated'));
      await env.store.saveTrainingSession(snapshot);
      await env.store.deleteTrainingPlan('unrelated');
      await env.store.saveTrainingPlan(multiPlan([source, other]));
      expect(env.store.trainingSession?.toJson(), snapshot.toJson());
      await env.store.saveTrainingPlan(multiPlan([source]));
      expect(env.store.trainingSession?.toJson(), snapshot.toJson());
      await env.cache.flush();
      await env.cache.settle();
      env.dispose();
      final reboot = _Harness(_Server()..offline = true, storage: storage);
      await reboot.boot();
      expect(reboot.store.trainingSession?.toJson(), snapshot.toJson());
    },
  );

  for (final change in ['remove', 'edit', 'duplicate removal']) {
    test('source workout $change retires paused recovery', () async {
      final env = _Harness(_Server());
      await env.boot();
      final source = plan().workouts.single;
      final other = source.copyWith(
        title: 'Other day',
        exercises: [
          for (var i = 0; i < source.exercises.length; i++)
            source.exercises[i].copyWith(id: 'other-$i'),
        ],
      );
      final original = multiPlan([
        source,
        change == 'duplicate removal'
            ? source.copyWith(
                exercises: [
                  for (var i = 0; i < source.exercises.length; i++)
                    source.exercises[i].copyWith(id: 'duplicate-$i'),
                ],
              )
            : other,
      ]);
      await env.store.saveTrainingPlan(original);
      await env.store.saveTrainingSession(snapshotFor(original));
      await env.store.saveTrainingPlan(
        multiPlan([
          if (change == 'edit') source.copyWith(title: 'Changed source'),
          change == 'duplicate removal' ? source : other,
        ]),
      );
      expect(env.store.trainingSession, isNull);
      expect(await env.cache.readTrainingSession(), isNull);
    });
  }

  test(
    'failed source suspension sends no delete and retains confirmed progress',
    () async {
      final storage = _SessionStorage();
      final env = _Harness(_Server(), storage: storage);
      await env.boot();
      await env.store.saveTrainingPlan(plan());
      await env.store.saveTrainingSession(_snapshot());
      storage.fail = true;
      await expectLater(
        env.store.deleteTrainingPlan(plan().id),
        throwsStateError,
      );
      expect(
        env.server.requests.where(
          (request) => _isTrainingWrite(request, 'trainingPlanDelete'),
        ),
        isEmpty,
      );
      expect(env.store.trainingPlans.single.id, plan().id);
      expect(env.store.trainingSession?.toJson(), _snapshot().toJson());
      expect(
        (await env.cache.readTrainingSession())?.toJson(),
        _snapshot().toJson(),
      );
    },
  );

  test(
    'failed offline source delete rolls back suspension without losing progress',
    () async {
      final env = _Harness(_Server(), cacheOverride: _FailOutboxCache());
      await env.boot();
      await env.store.saveTrainingPlan(plan());
      await env.store.saveTrainingSession(_snapshot());
      env.server.offline = true;
      (env.cache as _FailOutboxCache).failuresRemaining = 1;
      await expectLater(
        env.store.deleteTrainingPlan(plan().id),
        throwsStateError,
      );
      expect(env.store.trainingPlans.single.id, plan().id);
      expect(env.store.pendingOutbox, isEmpty);
      expect(env.store.trainingSession?.toJson(), _snapshot().toJson());
      expect(
        (await env.cache.readTrainingSession())?.toJson(),
        _snapshot().toJson(),
      );
    },
  );

  test(
    'committed source deletion clears checkpoint in the same transaction',
    () async {
      final storage = _SessionStorage();
      final env = _Harness(_Server(), storage: storage);
      await env.boot();
      await env.store.saveTrainingPlan(plan());
      await env.store.saveTrainingSession(_snapshot());
      env.server.offline = true;
      final before = storage.sessionWrites;
      await env.store.deleteTrainingPlan(plan().id);
      expect(storage.sessionWrites, before + 1);
      expect(env.store.trainingSession, isNull);
      expect(await env.cache.readTrainingSession(), isNull);
      expect(
        env.store.pendingOutbox.single.kind,
        SyncOpKind.trainingPlanDelete,
      );
      env.dispose();
      final reboot = _Harness(_Server()..offline = true, storage: storage);
      await reboot.boot();
      expect(reboot.store.trainingSession, isNull);
      expect(reboot.store.trainingPlans, isEmpty);
    },
  );

  test(
    'failed atomic deletion preserves plan and checkpoint across crash',
    () async {
      final storage = _SessionStorage();
      final env = _Harness(_Server(), storage: storage);
      await env.boot();
      await env.store.saveTrainingPlan(plan());
      await env.store.saveTrainingSession(_snapshot());
      final writes = env.server.requests.where(_isTrainingWrite).length;
      storage.fail = true;
      await expectLater(
        env.store.deleteTrainingPlan(plan().id),
        throwsStateError,
      );
      expect(env.server.requests.where(_isTrainingWrite), hasLength(writes));
      expect(env.store.trainingSession?.toJson(), _snapshot().toJson());
      expect(env.store.trainingPlans.single.id, plan().id);
      env.dispose();
      storage.fail = false;
      final reboot = _Harness(_Server()..offline = true, storage: storage);
      await reboot.boot();
      expect(reboot.store.trainingSession?.toJson(), _snapshot().toJson());
      expect(reboot.store.trainingPlans.single.id, plan().id);
      expect(reboot.store.pendingOutbox, isEmpty);
    },
  );

  test(
    'checkpoint already in storage settles before source deletion',
    () async {
      final storage = _SessionStorage();
      final env = _Harness(_Server(), storage: storage);
      await env.boot();
      await env.store.saveTrainingPlan(plan());
      await env.store.saveTrainingSession(_snapshot());
      final generation = env.store.trainingSessionGeneration;
      storage.gate = Completer<void>();
      final checkpoint = env.store.saveTrainingSession(
        _snapshot(),
        generation: generation,
      );
      await h.settle();
      final deletion = env.store.deleteTrainingPlan(plan().id);
      final lateCheckpoint = expectLater(
        env.store.saveTrainingSession(_snapshot(), generation: generation),
        throwsStateError,
      );
      storage.gate!.complete();
      await checkpoint;
      await deletion;
      await lateCheckpoint;
      expect(env.store.trainingSession, isNull);
      expect(await env.cache.readTrainingSession(), isNull);
      await env.store.adoptTrainingPlan(plan());
      final replacement = env.store.trainingPlans.single;
      expect(replacement.id, plan().id);
      expect(replacement.incarnation, 1);
      await expectLater(
        env.store.saveTrainingSession(_snapshot(), generation: generation),
        throwsStateError,
      );
      await expectLater(
        env.store.saveTrainingSession(
          null,
          generation: generation,
          sourcePlanId: plan().id,
        ),
        throwsStateError,
      );
      await env.store.saveTrainingSession(snapshotFor(replacement));
      expect(env.store.trainingSession, isNotNull);
    },
  );

  test('in-flight source delete rejects newly arriving checkpoint', () async {
    final server = _Server();
    final env = _Harness(server);
    await env.boot();
    await env.store.saveTrainingPlan(plan());
    server.holdWrite = Completer<void>();
    final deletion = env.store.deleteTrainingPlan(plan().id);
    await expectLater(
      env.store.saveTrainingSession(_snapshot()),
      throwsStateError,
    );
    server.holdWrite!.complete();
    await deletion;
    expect(await env.cache.readTrainingSession(), isNull);
  });

  test(
    'irreparably malformed session JSON does not block Training CRUD',
    () async {
      final storage = InMemoryKeyValueStore({
        'eatova.v1.training_session.user-training': '{broken-json',
      });
      final env = _Harness(_Server(), storage: storage);
      await env.boot();
      expect(await env.store.saveTrainingPlan(plan()), SyncDelivery.delivered);
      await env.store.saveTrainingSession(_snapshot());
      await env.store.deleteTrainingPlan(plan().id);
      expect(env.store.trainingSession, isNull);
      expect(await env.cache.readTrainingSession(), isNull);
    },
  );

  test(
    'failed local deletion never starts HTTP or retires confirmed recovery',
    () async {
      final cache = _FailOutboxCache();
      final env = _Harness(_Server(), cacheOverride: cache);
      await env.boot();
      await env.store.saveTrainingPlan(plan());
      await env.store.saveTrainingSession(_snapshot());
      final requests = env.server.requests.length;
      cache.failuresRemaining = 1;
      await expectLater(
        env.store.deleteTrainingPlan(plan().id),
        throwsStateError,
      );
      expect(env.server.requests, hasLength(requests));
      expect(env.store.pendingOutbox, isEmpty);
      expect(env.store.trainingSession?.toJson(), _snapshot().toJson());
      await env.store.saveTrainingSession(_snapshot());
    },
  );

  test(
    'offline delete followed by re-adoption permits a new paused session',
    () async {
      final env = _Harness(_Server());
      await env.boot();
      await env.store.saveTrainingPlan(plan());
      await env.store.saveTrainingSession(_snapshot());
      env.server.offline = true;
      await env.store.deleteTrainingPlan(plan().id);
      await env.store.adoptTrainingPlan(plan());
      final replacement = env.store.trainingPlans.single;
      expect(replacement.id, plan().id);
      expect(replacement.incarnation, 1);
      await env.store.saveTrainingSession(snapshotFor(replacement));
      expect(env.store.trainingSession, isNotNull);
      expect(await env.cache.readTrainingSession(), isNotNull);
    },
  );

  test(
    'repair of unreadable orphan cannot revive it through identical re-adoption',
    () async {
      final raw = InMemoryKeyValueStore();
      final cipher = _TrainingReadFailCipher();
      final encrypted = EncryptedKeyValueStore(raw, cipher);
      final env = _Harness(_Server(), storage: encrypted);
      await env.cache.writeTrainingSession(_snapshot());
      cipher.blockSessionRead = true;
      await env.boot();
      cipher.blockSessionRead = false;
      await env.store.saveTrainingPlan(plan());
      expect(env.store.trainingSession, isNull);
      expect(await env.cache.readTrainingSession(), isNull);
      await env.store.saveTrainingSession(_snapshot());
      expect(env.store.trainingSession, isNotNull);
    },
  );

  test(
    'unreadable recovery cannot resurrect an acknowledged delete on offline reboot',
    () async {
      final raw = InMemoryKeyValueStore();
      final cipher = _TrainingReadFailCipher();
      final encrypted = EncryptedKeyValueStore(raw, cipher);
      final env = _Harness(
        _Server()..rows[plan().id] = plan().toRow(),
        storage: encrypted,
      );
      await env.cache.writeTrainingPlans([plan()]);
      await env.cache.writeTrainingSession(_snapshot());
      cipher.blockSessionRead = true;
      cipher.blockPlanWrite = true;
      await env.boot();
      var acknowledged = false;
      try {
        await env.store.deleteTrainingPlan(plan().id);
        acknowledged = true;
      } on StateError {
        expect(
          env.server.requests.where(
            (request) => _isTrainingWrite(request, 'trainingPlanDelete'),
          ),
          isEmpty,
        );
      }
      await env.cache.flush();
      await env.cache.settle();
      env.dispose();
      cipher.blockSessionRead = false;
      cipher.blockPlanWrite = false;
      final reboot = _Harness(_Server()..offline = true, storage: encrypted);
      await reboot.boot();
      if (acknowledged) {
        expect(
          reboot.store.trainingSession,
          isNull,
          reason: 'A successful delete must not re-expose unreadable recovery',
        );
      } else {
        expect(reboot.store.trainingSession?.toJson(), _snapshot().toJson());
      }
    },
  );

  test(
    'failed authoritative clear cannot resurrect legacy progress on re-adoption',
    () async {
      final storage = _SessionStorage();
      final env = _Harness(_Server(), storage: storage);
      await env.cache.writeTrainingSession(_snapshot());
      storage.fail = true;
      await env.boot();
      expect(env.store.trainingSession, isNull);
      await expectLater(env.store.saveTrainingPlan(plan()), throwsStateError);
      expect(env.server.rows, isEmpty);
      storage.fail = false;
      await env.store.saveTrainingPlan(plan());
      await env.cache.flush();
      await env.cache.settle();
      env.dispose();
      final reboot = _Harness(env.server, storage: storage);
      await reboot.boot();
      expect(reboot.store.trainingSession, isNull);
      expect(await reboot.cache.readTrainingSession(), isNull);
    },
  );

  test(
    'session read repair allows retry and preserves an unrelated checkpoint',
    () async {
      final raw = InMemoryKeyValueStore();
      final cipher = _TrainingReadFailCipher();
      final encrypted = EncryptedKeyValueStore(raw, cipher);
      final env = _Harness(
        _Server()
          ..rows[plan().id] = plan().toRow()
          ..rows['other'] = plan('other').toRow(),
        storage: encrypted,
      );
      await env.cache.writeTrainingPlans([plan(), plan('other')]);
      await env.cache.writeTrainingSession(_snapshot());
      cipher.blockSessionRead = true;
      await env.boot();
      await expectLater(
        env.store.deleteTrainingPlan('other'),
        throwsStateError,
      );
      cipher.blockSessionRead = false;
      await env.store.deleteTrainingPlan('other');
      expect(env.store.trainingSession?.toJson(), _snapshot().toJson());
      expect(
        (await env.cache.readTrainingSession())?.toJson(),
        _snapshot().toJson(),
      );
      await env.store.deleteTrainingPlan(plan().id);
      expect(env.store.trainingSession, isNull);
      expect(await env.cache.readTrainingSession(), isNull);
    },
  );

  test(
    'old route without a checkpoint stays retired after source re-adoption',
    () async {
      final env = _Harness(_Server());
      await env.boot();
      await env.store.saveTrainingPlan(plan());
      final generation = env.store.trainingSessionGeneration;
      await env.store.deleteTrainingPlan(plan().id);
      await env.store.adoptTrainingPlan(plan());
      final replacement = env.store.trainingPlans.single;
      expect(replacement.id, plan().id);
      expect(replacement.incarnation, 1);
      await expectLater(
        env.store.saveTrainingSession(
          _snapshot(),
          generation: generation,
          sourcePlanId: plan().id,
        ),
        throwsStateError,
      );
      await env.store.saveTrainingSession(snapshotFor(replacement));
      expect(env.store.trainingSession, isNotNull);
    },
  );

  test(
    'unrelated deletion keeps the active route checkpoint generation valid',
    () async {
      final env = _Harness(_Server());
      await env.boot();
      await env.store.saveTrainingPlan(plan());
      await env.store.saveTrainingPlan(plan('other'));
      await env.store.saveTrainingSession(_snapshot());
      final generation = env.store.trainingSessionGeneration;
      await env.store.deleteTrainingPlan('other');
      await env.store.saveTrainingSession(
        _snapshot(),
        generation: generation,
        sourcePlanId: plan().id,
      );
      expect(env.store.trainingSession, isNotNull);
    },
  );

  test('obsolete route cannot clear another source checkpoint', () async {
    final env = _Harness(_Server());
    await env.boot();
    await env.store.saveTrainingPlan(plan());
    await env.store.saveTrainingPlan(plan('other'));
    await env.store.saveTrainingSession(snapshotFor(plan('other')));
    await expectLater(
      env.store.saveTrainingSession(null, sourcePlanId: plan().id),
      throwsStateError,
    );
    await expectLater(
      env.store.saveTrainingSession(_snapshot(), sourcePlanId: plan().id),
      throwsStateError,
    );
    expect(env.store.trainingSession?.plan.id, 'other');
  });

  test(
    'legacy queued source deletion suppresses recovery before an offline boot',
    () async {
      final env = _Harness(_Server()..offline = true);
      await env.cache.writeTrainingPlans([plan()]);
      await env.cache.writeTrainingSession(_snapshot());
      await env.cache.writeOutbox([SyncOp.trainingPlanDelete(plan().id)]);
      var exposed = false;
      env.store.addListener(() => exposed |= env.store.trainingSession != null);
      await env.boot();
      expect(exposed, isFalse);
      expect(env.store.trainingSession, isNull);
      expect(await env.cache.readTrainingSession(), isNull);
    },
  );

  test(
    'suspended recovery stays encrypted, account-scoped and replaceable after crash',
    () async {
      final raw = InMemoryKeyValueStore();
      final encrypted = EncryptedKeyValueStore(
        raw,
        AesGcmCacheCipher(Uint8List(32)),
      );
      final cache = LocalCache(encrypted, 'user-training');
      addTearDown(cache.close);
      await cache.writeTrainingPlans([plan()]);
      await cache.writeTrainingSession(_snapshot());
      expect(await cache.suspendTrainingSession(_snapshot()), isTrue);
      expect(raw.snapshot.values.join(), isNot(contains('Squat')));
      expect(
        raw.snapshot.values.join(),
        isNot(contains('source_change_pending')),
      );
      final other = LocalCache(encrypted, 'other');
      addTearDown(other.close);
      expect(await other.readTrainingSession(), isNull);
      final reboot = _Harness(
        _Server()..rows[plan().id] = plan().toRow(),
        storage: encrypted,
      );
      await reboot.boot();
      expect(reboot.store.trainingSession, isNull);
      await reboot.store.saveTrainingSession(_snapshot());
      expect(reboot.store.trainingSession, isNotNull);
    },
  );

  test(
    'authoritative missing source retires a legacy checkpoint without exposing resume',
    () async {
      final env = _Harness(_Server());
      await env.cache.writeTrainingSession(_snapshot());
      await env.boot();
      expect(env.store.trainingSession, isNull);
      expect(await env.cache.readTrainingSession(), isNull);
    },
  );

  for (final committed in [false, true]) {
    test(
      'logout waits for atomic training decision (committed=$committed)',
      () async {
        final raw = _HeldOutboxStorage();
        final encrypted = EncryptedKeyValueStore(
          raw,
          AesGcmCacheCipher(Uint8List(32)),
        );
        final server = _Server()..offline = true;
        final env = _Harness(server, storage: encrypted);
        await env.cache.writeTrainingPlans([plan()]);
        await env.boot();
        raw.writes = 0;
        raw.holdAt = 1;
        if (!committed) raw.failAt.add(1);
        final outcome = expectLater(
          env.store.deleteTrainingPlan(plan().id),
          throwsStateError,
        );
        await raw.entered.future;
        var closed = false;
        final logout = env.store.signOutCleanup().then((_) => closed = true);
        await h.settle();
        expect(closed, isFalse);
        raw.release.complete();
        await outcome;
        await logout;
        expect(env.cache.isClosed, isTrue);
        final reopened = LocalCache(encrypted, 'user-training');
        addTearDown(reopened.close);
        final pending = await reopened.readOutbox() ?? [];
        expect(pending, hasLength(committed ? 1 : 0));
        if (committed) {
          expect(pending.single.kind, SyncOpKind.trainingPlanDelete);
        }
        expect(server.requests.where(_isTrainingWrite), isEmpty);
        expect(raw.snapshot.values.join(), isNot(contains('Strength')));
      },
    );
  }

  test(
    'successful automatic persistence acknowledges replacement when later writes fail',
    () async {
      final raw = _HeldOutboxStorage();
      final encrypted = EncryptedKeyValueStore(
        raw,
        AesGcmCacheCipher(Uint8List(32)),
      );
      final server = _Server();
      final env = _Harness(server, storage: encrypted);
      await env.boot();
      server.offline = true;
      await env.store.saveTrainingPlan(plan('coach_message', 'Previous'));
      await env.cache.settle();
      raw.writes = 0;
      raw.failFrom = 2;
      expect(
        await env.store.saveTrainingPlan(plan('coach_message', 'Replacement')),
        SyncDelivery.queuedOffline,
      );
      await env.cache.settle();
      expect(env.store.trainingPlans.single.title, 'Replacement');
      expect(
        (await env.cache.readOutbox())!.last.trainingPlan?.title,
        'Replacement',
      );
      raw.failFrom = null;
      env.dispose();
      final restarted = _Harness(server, storage: encrypted);
      await restarted.boot();
      expect(restarted.store.trainingPlans.single.title, 'Replacement');
      server.offline = false;
      await restarted.flush();
      await h.pumpUntil(() => restarted.store.pendingOutbox.isEmpty);
      expect(
        (server.rows['coach_message']!['plan'] as Map)['title'],
        'Replacement',
      );
    },
  );

  test(
    'failed acknowledgment retains the same operation for receipt replay',
    () async {
      final cache = _TransientOutboxFailureCache(InMemoryKeyValueStore());
      final server = _Server()..holdWrite = Completer<void>();
      final env = _Harness(server, cacheOverride: cache);
      await env.boot();
      final save = env.store.saveTrainingPlan(
        plan('coach_message', 'Committed'),
      );
      await server.writeEntered.future;
      final id = env.store.pendingOutbox.single.operationId;
      cache.failuresRemaining = 1;
      server.holdWrite!.complete();
      expect(await save, SyncDelivery.queuedRetry);
      expect(env.store.pendingOutbox.single.operationId, id);
      expect((await cache.readOutbox())!.single.operationId, id);
      expect((server.rows.values.single['plan'] as Map)['title'], 'Committed');
      await env.store.syncPendingWrites();
      expect(env.store.pendingOutbox, isEmpty);
      final writes = server.requests.where(_isTrainingWrite).toList();
      expect(writes, hasLength(2));
      expect(jsonDecode(writes.first.body), jsonDecode(writes.last.body));
    },
  );

  for (final firstWriteSucceeds in [false, true]) {
    test(
      'mixed cap retains every accepted intent (commit=$firstWriteSucceeds)',
      () async {
        final cache = _TransientOutboxFailureCache(InMemoryKeyValueStore());
        final env = _Harness(_Server()..offline = true, cacheOverride: cache);
        final prior = [
          SyncOp.trainingPlanUpsert(plan('coach_message', 'Previous')),
          ...List.generate(
            kOutboxMaxOps - 2,
            (i) => SyncOp.trainingPlanDelete('deleted_$i'),
          ),
        ];
        await cache.writeOutbox(prior);
        await env.boot();
        if (!firstWriteSucceeds) cache.failuresRemaining = 1;
        await expectLater(
          env.store.saveTrainingPlan(plan('coach_message', 'Replacement')),
          firstWriteSucceeds
              ? completion(
                  anyOf(SyncDelivery.queuedRetry, SyncDelivery.queuedOffline),
                )
              : throwsStateError,
        );
        if (firstWriteSucceeds) {
          await expectLater(
            env.store.saveTrainingPlan(plan('additional')),
            throwsStateError,
          );
        }
        final durable = (await cache.readOutbox())!;
        expect(durable, hasLength(prior.length + (firstWriteSucceeds ? 1 : 0)));
        expect(
          durable.take(prior.length).map((op) => op.operationId),
          prior.map((op) => op.operationId),
        );
        expect(
          env.store.trainingPlans.single.title,
          firstWriteSucceeds ? 'Replacement' : 'Previous',
        );
        expect(env.server.requests.where(_isTrainingWrite), isNotEmpty);
        expect(env.server.rows, isEmpty);
      },
    );
  }

  test('a late request cannot overtake its accepted successor', () async {
    final server = _Server()..holdWrite = Completer<void>();
    final env = _Harness(server);
    await env.boot();
    final first = env.store.saveTrainingPlan(plan('coach_message', 'Older'));
    await server.writeEntered.future;
    await env.store.saveTrainingPlan(plan('coach_message', 'Newer'));
    expect(server.requests.where(_isTrainingWrite), hasLength(1));
    expect(env.store.pendingOutbox, hasLength(2));
    server.holdWrite!.complete();
    await first;
    await env.store.syncPendingWrites();
    expect(env.store.pendingOutbox, isEmpty);
    expect((server.rows.values.single['plan'] as Map)['title'], 'Newer');
    expect(env.store.trainingPlans.single.title, 'Newer');
  });

  test(
    'refused full-queue admission never starts a live training request',
    () async {
      final server = _Server()..offline = true;
      final env = _Harness(server);
      await env.cache.writeOutbox(
        List.generate(
          kOutboxMaxOps,
          (index) => SyncOp.trainingPlanDelete('deleted_$index'),
        ),
      );
      await env.boot();
      server.offline = false;
      final release = Completer<void>();
      server.holdTrainingResponse = release;
      try {
        await expectLater(env.store.saveTrainingPlan(plan()), throwsStateError);
        expect(
          server.requests.where(
            (r) => _isTrainingWrite(r, 'trainingPlanUpsert'),
          ),
          isEmpty,
        );
        await expectLater(
          env.store.saveTrainingPlan(plan('coach_message', 'Newer intent')),
          throwsStateError,
        );
        expect(env.store.trainingPlans, isEmpty);
        expect(env.store.pendingOutbox, hasLength(kOutboxMaxOps));
      } finally {
        release.complete();
        await h.settle();
      }
      expect(server.rows, isEmpty);
    },
  );

  for (final atCapacity in [false, true]) {
    test(
      'repair preserves acknowledged training ops when replacement fails (full=$atCapacity)',
      () async {
        final storage = InMemoryKeyValueStore();
        final cache = _RecoveringOutboxCache(storage);
        final server = _Server()..offline = true;
        final env = _Harness(server, cacheOverride: cache);
        final prior = [
          SyncOp.trainingPlanUpsert(plan('coach_message', 'Confirmed')),
          if (atCapacity)
            ...List.generate(
              kOutboxMaxOps - 1,
              (index) => SyncOp.trainingPlanDelete('deleted_$index'),
            ),
        ];
        await cache.writeOutbox(prior);
        await env.boot();
        expect(env.store.pendingOutbox, isEmpty);
        cache.unreadable = false;
        cache.immediateRecovery = prior;
        cache.failuresRemaining = 2;
        server.offline = false;
        server.retryTrainingWrites = true;
        final release = Completer<void>();
        server.holdTrainingResponse = release;
        final outcome = expectLater(
          env.store.saveTrainingPlan(
            plan('coach_message', 'Failed replacement'),
          ),
          throwsStateError,
        );
        if (!atCapacity) {
          await cache.failedWrite.future.timeout(const Duration(seconds: 3));
        }
        release.complete();
        await outcome;
        await cache.settle();
        expect(env.store.pendingOutbox, hasLength(prior.length));
        expect(env.store.pendingOutbox.first.trainingPlan?.title, 'Confirmed');
        expect(
          (await cache.readOutbox())!.first.trainingPlan?.title,
          'Confirmed',
        );
        expect(server.rows, isEmpty);
      },
    );
  }

  test('unreadable predecessor order blocks a training live send', () async {
    final cache = _RecoveringOutboxCache(InMemoryKeyValueStore());
    final server = _Server()..offline = true;
    final env = _Harness(server, cacheOverride: cache);
    await cache.writeOutbox([
      SyncOp.trainingPlanUpsert(plan('coach_message', 'Confirmed')),
    ]);
    await env.boot();
    cache.unreadable = false;
    cache.holdRepair = Completer<void>();
    server.offline = false;
    final save = env.store.saveTrainingPlan(plan('coach_message', 'Unconfirmed'));
    try {
      await h.settle();
      expect(
        server.requests.where((r) => _isTrainingWrite(r, 'trainingPlanUpsert')),
        isEmpty,
      );
    } finally {
      cache.holdRepair!.complete();
    }
    await save;
    await env.flush();
    await h.pumpUntil(() => env.store.pendingOutbox.isEmpty);
    expect(
      (server.rows['coach_message']!['plan'] as Map)['title'],
      'Unconfirmed',
    );
  });

  test('initial outbox hydration fences early training confirmation', () async {
    final cache = _HeldInitialOutboxCache(InMemoryKeyValueStore());
    final env = _Harness(_Server()..offline = true, cacheOverride: cache);
    await cache.writeOutbox([
      SyncOp.trainingPlanUpsert(plan('coach_message', 'Confirmed')),
    ]);
    await cache.writeProfile(const UserProfile(onboardingCompleted: true));
    env.store.start();
    await cache.entered.future.timeout(const Duration(seconds: 3));
    try {
      await expectLater(
        env.store.saveTrainingPlan(plan('coach_message', 'Too early')),
        throwsStateError,
      );
      expect(
        (await cache.readOutbox())!.single.trainingPlan?.title,
        'Confirmed',
      );
    } finally {
      cache.release.complete();
    }
    await h.pumpUntil(
      () => !env.store.bootLoadInFlight,
      frist: const Duration(seconds: 20),
    );
    expect(env.store.pendingOutbox.single.trainingPlan?.title, 'Confirmed');
  });

  test('replay waits for pending training durability acknowledgment', () async {
    final server = _Server();
    final cache = _AcknowledgmentHeldCache();
    final env = _Harness(server, cacheOverride: cache);
    await env.boot();
    server.retryTrainingWrites = true;
    final save = env.store.saveTrainingPlan(plan());
    // Install the observer before releasing the controlled asynchronous write.
    final outcome = expectLater(save, completion(SyncDelivery.queuedRetry));
    await cache.entered.future;
    env.store.flushPendingWrites();
    await h.settle();
    cache.release.complete();
    await outcome;
    expect(env.store.trainingPlans.single.id, 'coach_message');
    expect(env.store.pendingOutbox.single.attempts, 1);
    expect(
      server.requests.where((r) => _isTrainingWrite(r, 'trainingPlanUpsert')),
      hasLength(1),
    );
    server.retryTrainingWrites = false;
    await env.flush();
    await h.pumpUntil(() => env.store.pendingOutbox.isEmpty);
    expect(server.rows, hasLength(1));
  });

  test(
    'full outbox refuses a training edit without evicting its saved predecessor',
    () async {
      final cache = _TransientOutboxFailureCache(InMemoryKeyValueStore());
      final env = _Harness(_Server()..offline = true, cacheOverride: cache);
      await cache.writeOutbox([
        SyncOp.trainingPlanUpsert(plan('coach_message', 'Confirmed')),
        ...List.generate(
          kOutboxMaxOps - 1,
          (index) => SyncOp.trainingPlanDelete('deleted_$index'),
        ),
      ]);
      await env.boot();
      cache.failuresRemaining = 2;
      await expectLater(
        env.store.saveTrainingPlan(plan('coach_message', 'Failed')),
        throwsStateError,
      );
      await cache.settle();
      expect(env.store.pendingOutbox, hasLength(kOutboxMaxOps));
      expect(env.store.pendingOutbox.first.trainingPlan?.title, 'Confirmed');
      expect(
        (await cache.readOutbox())!.first.trainingPlan?.title,
        'Confirmed',
      );
    },
  );

  for (final previousDelete in [false, true]) {
    test(
      'failed offline replacement preserves acknowledged ${previousDelete ? 'delete' : 'save'} through restart',
      () async {
        final storage = InMemoryKeyValueStore();
        final server = _Server();
        final cache = _TransientOutboxFailureCache(storage);
        final first = _Harness(server, cacheOverride: cache);
        await first.boot();
        if (previousDelete) await first.store.saveTrainingPlan(plan());
        server.offline = true;
        final result = previousDelete
            ? await first.store.deleteTrainingPlan('coach_message')
            : await first.store.saveTrainingPlan(
                plan('coach_message', 'Previously confirmed'),
              );
        expect(result, SyncDelivery.queuedOffline);
        await cache.settle();
        cache.failuresRemaining = 2;
        await expectLater(
          first.store.saveTrainingPlan(plan('coach_message', 'Failed edit')),
          throwsStateError,
        );
        await cache.settle();
        expect(first.store.pendingOutbox, hasLength(1));
        expect(first.store.pendingOutbox.single.isDelete, previousDelete);
        expect(await cache.readOutbox(), hasLength(1));
        if (!previousDelete) {
          expect(
            first.store.trainingPlans.single.title,
            'Previously confirmed',
          );
          expect(
            (await cache.readOutbox())!.single.trainingPlan?.title,
            'Previously confirmed',
          );
        }
        first.dispose();
        final restarted = _Harness(server, storage: storage);
        await restarted.boot();
        expect(restarted.store.pendingOutbox, hasLength(1));
        expect(restarted.store.pendingOutbox.single.isDelete, previousDelete);
        expect(
          restarted.store.trainingPlans,
          hasLength(previousDelete ? 0 : 1),
        );
        server.offline = false;
        await restarted.flush();
        await h.pumpUntil(() => restarted.store.pendingOutbox.isEmpty);
        if (previousDelete) {
          expect(server.rows, isEmpty);
        } else {
          expect(
            (server.rows['coach_message']!['plan'] as Map)['title'],
            'Previously confirmed',
          );
        }
      },
    );
  }

  test(
    'successful offline replacements retain every accepted operation until replay',
    () async {
      final env = _Harness(_Server());
      await env.boot();
      env.server.offline = true;
      for (var revision = 0; revision < 6; revision++) {
        expect(
          await env.store.saveTrainingPlan(
            plan('coach_message', 'Edit $revision'),
          ),
          isNot(SyncDelivery.delivered),
        );
      }
      await env.cache.settle();
      expect(env.store.pendingOutbox, hasLength(6));
      expect(
        (await env.cache.readOutbox())!.map((op) => op.trainingPlan?.title),
        List.generate(6, (revision) => 'Edit $revision'),
      );
      env.server.offline = false;
      await env.store.syncPendingWrites();
      expect(env.store.pendingOutbox, isEmpty);
      expect((env.server.rows.values.single['plan'] as Map)['title'], 'Edit 5');
    },
  );

  test('outbox capacity cannot falsely acknowledge a dropped plan', () async {
    final env = _Harness(_Server()..offline = true);
    await env.cache.writeOutbox(
      List.generate(
        kOutboxMaxOps,
        (index) => SyncOp.trainingPlanDelete('deleted_$index'),
      ),
    );
    await env.boot();
    await expectLater(env.store.saveTrainingPlan(plan()), throwsStateError);
    expect(env.store.trainingPlans, isEmpty);
    expect(env.store.pendingOutbox, hasLength(kOutboxMaxOps));
    expect(env.store.pendingOutbox.every((op) => op.isDelete), isTrue);
  });

  test(
    'older server-confirmed save remains visible after newer save fails',
    () async {
      final server = _Server();
      final env = _Harness(server, cacheOverride: _FailOutboxCache());
      await env.boot();
      server.holdWrite = Completer<void>();
      final older = env.store.saveTrainingPlan(
        plan('coach_message', 'Confirmed'),
      );
      await server.writeEntered.future;
      (env.cache as _FailOutboxCache).failuresRemaining = 1;
      final acceptedId = env.store.pendingOutbox.single.operationId;
      await expectLater(
        env.store.saveTrainingPlan(plan('coach_message', 'Failed')),
        throwsStateError,
      );
      server.holdWrite!.complete();
      expect(await older, SyncDelivery.queuedRetry);
      expect(env.store.trainingPlans.single.title, 'Confirmed');
      expect((server.rows.values.single['plan'] as Map)['title'], 'Confirmed');
      expect(env.store.pendingOutbox.single.operationId, acceptedId);
      await env.store.syncPendingWrites();
      expect(env.store.pendingOutbox, isEmpty);
      expect(env.store.trainingPlans.single.title, 'Confirmed');
    },
  );

  test('aged training tombstone survives its first server rejection', () async {
    await withClock(Clock.fixed(DateTime.utc(2026, 9, 8)), () async {
      final server = _Server()
        ..rows['coach_message'] = plan().toRow()
        ..rejectTrainingWrites = true;
      final env = _Harness(server);
      await env.cache.writeOutbox([
        SyncOp.tryFromJson({
          'kind': 'trainingPlanDelete',
          'entity_id': 'coach_message',
          'payload': <String, dynamic>{},
          'queued_at': '2026-08-01T00:00:00Z',
        })!,
      ]);
      await env.boot();
      expect(env.store.trainingPlans, isEmpty);
      expect(
        env.store.pendingOutbox.single.kind,
        SyncOpKind.trainingPlanDelete,
      );
      expect(env.store.pendingOutbox.single.attempts, 1);
    });
  });

  test(
    'validated server plans are cached even when profile cannot load',
    () async {
      final server = _Server()..rows['coach_message'] = plan().toRow();
      final env = _Harness(server);
      await h.bootUntilIdle(env.store);
      await env.flush();
      expect(env.store.trainingPlans.single.id, 'coach_message');
      expect((await env.cache.readTrainingPlans())?.single.id, 'coach_message');
    },
  );

  test(
    'an older save included in a newer receipt cannot replace the newer edit',
    () async {
      final server = _Server();
      final cache = _HeldOutboxCache();
      final env = _Harness(server, cacheOverride: cache);
      await env.boot();
      server.offline = true;
      cache.hold = true;
      final older = expectLater(
        env.store.saveTrainingPlan(plan()),
        throwsStateError,
      );
      await h.settle();
      expect(env.store.trainingPlans, isEmpty);
      server.offline = false;
      cache.hold = false;
      final newer = env.store.saveTrainingPlan(plan('coach_message', 'Newer'));
      cache.gate.complete();
      await older;
      expect(await newer, SyncDelivery.delivered);
      expect(env.store.trainingPlans.single.title, 'Newer');
      await env.flush();
      expect((server.rows.values.single['plan'] as Map)['title'], 'Newer');
    },
  );

  test(
    'session checkpoint survives restart paused with its full plan',
    () async {
      final kv = InMemoryKeyValueStore();
      final first = _Harness(_Server(), storage: kv);
      await first.boot();
      await first.store.saveTrainingPlan(plan());
      await first.store.saveTrainingSession(_snapshot());
      first.dispose();
      final next = _Harness(first.server, storage: kv);
      await next.boot();
      expect(next.store.trainingSession?.plan.title, 'Strength');
      expect(next.store.trainingSession?.toJson()['status'], 'paused');
      await next.store.saveTrainingSession(null);
      expect(next.store.trainingSession, isNull);
      expect(await next.cache.readTrainingSession(), isNull);
    },
  );

  test(
    'failed session checkpoint throws and keeps last confirmed state',
    () async {
      final kv = _SessionStorage();
      final env = _Harness(_Server(), storage: kv);
      await env.boot();
      await env.store.saveTrainingPlan(plan());
      await env.store.saveTrainingSession(_snapshot());
      kv.fail = true;
      await expectLater(env.store.saveTrainingSession(null), throwsStateError);
      expect(env.store.trainingSession, isNotNull);
      expect(await env.cache.readTrainingSession(), isNotNull);
    },
  );

  test(
    'serialized checkpoints prevent an old pause overtaking discard',
    () async {
      final kv = _SessionStorage()..gate = Completer<void>();
      final cache = LocalCache(kv, 'A');
      addTearDown(cache.close);
      final first = cache.writeTrainingSession(_snapshot());
      await h.settle();
      final clear = cache.writeTrainingSession(null);
      await h.settle();
      expect(kv.sessionWrites, 1);
      kv.gate!.complete();
      expect(await first, isTrue);
      expect(await clear, isTrue);
      expect(await cache.readTrainingSession(), isNull);
    },
  );

  test('logout fences a checkpoint already waiting inside storage', () async {
    final kv = _SessionStorage()..gate = Completer<void>();
    final cache = LocalCache(kv, 'A');
    final write = cache.writeTrainingSession(_snapshot());
    await h.settle();
    final clear = cache.clear(preserveOutbox: true);
    kv.gate!.complete();
    await write;
    await clear;
    expect(kv.snapshot, isEmpty);
  });

  test(
    'failed offline deletion leaves the last confirmed plan visible',
    () async {
      final server = _Server();
      final env = _Harness(server, cacheOverride: _FailOutboxCache());
      await env.boot();
      await env.store.saveTrainingPlan(plan());
      server.offline = true;
      (env.cache as _FailOutboxCache).failuresRemaining = 1;
      await expectLater(
        env.store.deleteTrainingPlan('coach_message'),
        throwsStateError,
      );
      expect(env.store.trainingPlans.single.id, 'coach_message');
      expect(env.store.selectedTrainingPlanId, 'coach_message');
      expect(env.store.pendingOutbox, isEmpty);
    },
  );

  test('adoption, editing and selection persist with one stable row', () async {
    final kv = InMemoryKeyValueStore();
    final env = _Harness(_Server(), storage: kv);
    await env.boot();
    expect(env.server.rows, isEmpty);
    expect(await env.store.saveTrainingPlan(plan()), SyncDelivery.delivered);
    await env.store.saveTrainingPlan(plan());
    await env.store.saveTrainingPlan(plan('manual', 'Second'));
    env.store.selectTrainingPlan('coach_message');
    await env.store.saveTrainingPlan(plan('coach_message', 'Edited'));
    await env.flush();
    expect(env.store.trainingPlans, hasLength(2));
    expect(env.server.rows, hasLength(2));
    expect(env.store.selectedTrainingPlan?.title, 'Edited');
    env.dispose();
    final next = _Harness(_Server()..offline = true, storage: kv);
    await next.boot();
    expect(next.store.trainingPlans, hasLength(2));
    expect(next.store.selectedTrainingPlanId, 'coach_message');
    expect(next.store.selectedTrainingPlan?.title, 'Edited');
    expect(next.store.trainingPlansLoadFailed, isTrue);
  });

  test(
    'offline edit and delete survive restart and replay in entity order',
    () async {
      final kv = InMemoryKeyValueStore();
      final server = _Server();
      final first = _Harness(server, storage: kv);
      await first.boot();
      server.offline = true;
      expect(
        await first.store.saveTrainingPlan(plan()),
        SyncDelivery.queuedOffline,
      );
      await first.store.saveTrainingPlan(plan('coach_message', 'Latest'));
      await first.store.saveTrainingPlan(plan('deleted', 'Delete me'));
      await first.store.deleteTrainingPlan('deleted');
      await first.flush();
      first.dispose();
      final second = _Harness(server, storage: kv);
      await second.boot();
      expect(second.store.trainingPlans.map((p) => p.title), ['Latest']);
      expect(
        second.store.pendingOutbox.map((o) => o.kind),
        contains(SyncOpKind.trainingPlanDelete),
      );
      server.offline = false;
      await second.flush();
      await h.pumpUntil(() => second.store.pendingOutbox.isEmpty);
      expect(server.rows.keys, ['coach_message']);
      expect((server.rows['coach_message']!['plan'] as Map)['title'], 'Latest');
      expect(second.store.lifetimeStats.workoutsCompleted, 0);
    },
  );

  test(
    'stale boot response cannot undo an edit or resurrect a delete',
    () async {
      final server = _Server()
        ..rows['coach_message'] = plan().toRow()
        ..rows['deleted'] = plan('deleted').toRow()
        ..holdRead = Completer<void>();
      final env = _Harness(server);
      await env.cache.writeTrainingPlans([plan(), plan('deleted')]);
      await env.cache.writeProfile(
        const UserProfile(onboardingCompleted: true),
      );
      env.store.start();
      await server.readEntered.future;
      await env.store.saveTrainingPlan(plan('coach_message', 'Fresh'));
      await env.store.deleteTrainingPlan('deleted');
      server.holdRead!.complete();
      await h.pumpUntil(() => !env.store.bootLoadInFlight);
      expect(env.store.trainingPlans.map((p) => p.title), ['Fresh']);
    },
  );

  test(
    'in-flight upsert followed by delete and re-adoption delivers latest',
    () async {
      final server = _Server();
      final env = _Harness(server);
      await env.boot();
      server.holdWrite = Completer<void>();
      final first = env.store.saveTrainingPlan(plan());
      await server.writeEntered.future;
      await env.store.deleteTrainingPlan('coach_message');
      await env.store.adoptTrainingPlan(plan('coach_message', 'Re-adopted'));
      expect(env.store.trainingPlans.single.incarnation, 1);
      server.holdWrite!.complete();
      await first;
      await h.pumpUntil(() => env.store.pendingOutbox.isEmpty);
      expect(server.rows, hasLength(1));
      expect(server.rows.keys, ['coach_message']);
      expect(server.rows.values.single['incarnation'], 1);
      expect((server.rows.values.single['plan'] as Map)['title'], 'Re-adopted');
    },
  );

  test(
    'queued save reports failure when no durable outbox copy exists',
    () async {
      final server = _Server();
      final env = _Harness(server, cacheOverride: _FailOutboxCache());
      await env.boot();
      server.offline = true;
      (env.cache as _FailOutboxCache).failuresRemaining = 1;
      await expectLater(env.store.saveTrainingPlan(plan()), throwsStateError);
      expect(env.store.pendingOutbox, isEmpty);
      expect(env.store.trainingPlans, isEmpty);
      expect(env.store.selectedTrainingPlanId, isNull);
      server.offline = false;
      await env.store.saveTrainingPlan(plan());
      expect(server.rows, hasLength(1));
    },
  );

  test(
    'logout preserves only pending operations and rejects late saves',
    () async {
      final kv = InMemoryKeyValueStore();
      final server = _Server();
      final env = _Harness(server, storage: kv);
      await env.boot();
      server.offline = true;
      await env.store.saveTrainingPlan(plan());
      await env.store.signOutCleanup();
      expect(await env.cache.readTrainingPlans(), isNull);
      expect(await env.cache.readTrainingSelection(), isNull);
      expect(
        (await env.cache.readOutbox())!.single.trainingPlan?.id,
        'coach_message',
      );
      expect(() => env.store.saveTrainingPlan(plan('late')), throwsStateError);
      final other = LocalCache(kv, 'other-user');
      addTearDown(other.close);
      expect(await other.readOutbox(), isNull);
      expect(await other.readTrainingPlans(), isNull);
    },
  );

  test(
    'training payload and selection use encrypted account namespaces',
    () async {
      final raw = InMemoryKeyValueStore();
      final encrypted = EncryptedKeyValueStore(
        raw,
        AesGcmCacheCipher(Uint8List(32)),
      );
      final cache = LocalCache(encrypted, 'A');
      addTearDown(cache.close);
      await cache.writeTrainingPlans([plan()]);
      await cache.writeTrainingSelection('coach_message');
      await cache.writeOutbox([SyncOp.trainingPlanUpsert(plan())]);
      expect(raw.snapshot.values.join(), isNot(contains('Strength')));
      expect(raw.snapshot.values.join(), isNot(contains('coach_message')));
      expect((await cache.readTrainingPlans())!.single.title, 'Strength');
      final other = LocalCache(encrypted, 'B');
      addTearDown(other.close);
      expect(await other.readTrainingPlans(), isNull);
      await cache.clear(preserveOutbox: true);
      expect(raw.snapshot.keys, ['eatova.v1.outbox.A']);
    },
  );

  test('corrupt envelope IDs are never replayed under another entity key', () {
    final op = SyncOp.tryFromJson({
      'kind': 'trainingPlanUpsert',
      'entity_id': 'first',
      'payload': {'training_plan': plan('second').toRow()},
    });
    expect(op, isNotNull);
    expect(op!.trainingPlan, isNull);
    expect(SyncOp.trainingPlanDelete('first').isDelete, isTrue);
  });
}
