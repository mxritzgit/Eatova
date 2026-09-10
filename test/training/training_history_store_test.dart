import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/training_history.dart';
import 'package:eatova/src/models/training_session.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/services/secure_cache_store.dart';
import 'package:eatova/src/services/sync_error_messages.dart';
import 'package:eatova/src/services/sync_outbox.dart';
import 'package:eatova/src/services/training_session_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import '../outbox/outbox_test_helpers.dart' as h;
import '../services/user_rpc_test.dart' show signIn;
import 'training_timer_fixtures.dart';

class _Server {
  bool offline = false;
  bool ambiguous = false;
  bool rejectHistory = false;
  Completer<void>? hold;
  final entered = Completer<void>();
  final rows = <String, Map<String, dynamic>>{};
  final requests = <http.Request>[];
  Future<http.Response> handle(http.Request request) async {
    requests.add(request);
    Object? result = [];
    final isHistory = request.url.path.endsWith('/training_history');
    if (isHistory && request.method != 'GET') {
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
      if (request.method == 'POST') {
        final raw = jsonDecode(request.body);
        final row = (raw is List ? raw.single : raw) as Map<String, dynamic>;
        rows.putIfAbsent('${row['user_id']}:${row['id']}', () => row);
        if (ambiguous) throw http.ClientException('fixture lost response');
      } else {
        rows.remove(
          '${request.url.queryParameters['user_id']!.substring(3)}:${request.url.queryParameters['id']!.substring(3)}',
        );
      }
    } else if (isHistory) {
      final owner = request.url.queryParameters['user_id']!.substring(3);
      result = rows.values.where((row) => row['user_id'] == owner).toList();
    } else if (request.url.path.endsWith('/profiles')) {
      result = null;
    } else if (request.url.path.endsWith('/lifetime_stats')) {
      result = {};
    }
    return http.Response(
      jsonEncode(result),
      200,
      headers: {'content-type': 'application/json'},
      request: request,
    );
  }
}

class _Cache extends LocalCache {
  _Cache(super.store, super.userId);
  bool failOutbox = false;
  bool failClear = false;
  Completer<void>? holdOutbox;
  final entered = Completer<void>();
  @override
  Future<bool> writeOutbox(List<SyncOp> ops) async {
    if (ops.any(
      (op) =>
          op.kind == SyncOpKind.trainingHistoryInsert ||
          op.kind == SyncOpKind.trainingHistoryDelete,
    )) {
      if (!entered.isCompleted) entered.complete();
      await holdOutbox?.future;
      if (failOutbox) return false;
    }
    return super.writeOutbox(ops);
  }

  @override
  Future<bool> writeTrainingSession(TrainingSessionSnapshot? value) =>
      value == null && failClear
      ? Future.value(false)
      : super.writeTrainingSession(value);
}

class _Harness {
  _Harness(this.server, {required KeyValueStore storage, this.owner = 'A'}) {
    cache = _Cache(storage, owner);
    client = SupabaseClient(
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
  }

  Future<void> settle() async {
    await h.settle();
    await cache.flush();
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
      final server = _Server()..offline = true;
      final first = _Harness(server, storage: storage);
      await first.boot();
      final entry = _entry();
      final delivery = await first.store.completeTrainingSession(
        entry,
        generation: 0,
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
      reboot.store.flushPendingWrites();
      await reboot.settle();
      expect(server.rows.length, 1);
      server.ambiguous = false;
      reboot.store.flushPendingWrites();
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
    'failed outbox receipt retains recovery and reports no completion',
    () async {
      final env = _Harness(
        _Server()..offline = true,
        storage: InMemoryKeyValueStore(),
      );
      await env.boot();
      env.cache.failOutbox = true;
      final entry = _entry();
      await expectLater(
        env.store.completeTrainingSession(entry, generation: 0),
        throwsStateError,
      );
      expect(env.store.trainingHistory, isEmpty);
      expect((await env.cache.readTrainingSession())?.sessionId, entry.id);
      expect(env.store.trainingSession?.sessionId, entry.id);
      env.cache.failOutbox = false;
      await env.store.completeTrainingSession(entry, generation: 0);
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
      var done = false;
      final save = env.store
          .completeTrainingSession(entry, generation: 0)
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
    'late server callback after A to B rejects publication and retains A recovery',
    () async {
      final server = _Server()..hold = Completer<void>();
      final raw = InMemoryKeyValueStore();
      final env = _Harness(server, storage: raw);
      await env.boot();
      await signIn(env.client, 'A');
      final entry = _entry();
      final save = expectLater(
        env.store.completeTrainingSession(entry, generation: 0),
        throwsStateError,
      );
      await server.entered.future;
      await signIn(env.client, 'B');
      server.hold!.complete();
      await save;
      expect(env.store.trainingHistory, isEmpty);
      expect((await env.cache.readTrainingSession())?.sessionId, entry.id);
      expect(server.rows.values.single['user_id'], 'A');
      expect(
        server.requests
            .where(
              (r) =>
                  r.method == 'POST' &&
                  r.url.path.endsWith('/training_history'),
            )
            .single
            .headers['authorization'],
        'Bearer fixture-A',
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
      await env.store.completeTrainingSession(entry, generation: 0);
      await env.store.saveTrainingPlan(
        entry.snapshot.plan.copyWith(
          proposal: entry.snapshot.plan.proposal.copyWith(title: 'Edited'),
        ),
      );
      await env.store.deleteTrainingPlan(entry.snapshot.plan.id);
      expect(env.store.trainingHistory.single.toRow(), entry.toRow());
      await expectLater(
        env.store.saveTrainingSession(entry.snapshot, generation: 0),
        throwsStateError,
      );
      expect(env.store.trainingHistory.length, 1);
      final duplicate = await env.store.completeTrainingSession(
        entry,
        generation: 0,
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
      env.cache.failClear = true;
      await env.store.completeTrainingSession(entry, generation: 0);
      expect(env.store.trainingSession, isNull);
      expect((await env.cache.readTrainingSession())?.sessionId, entry.id);
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
      await first.store.completeTrainingSession(entry, generation: 0);
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
      final newcomer = SyncOp.trainingPlanDelete('new-delete');
      final capped = capOutbox([...entries, newcomer]);
      expect(capped.queue.length, kOutboxMaxOps);
      expect(capped.dropped, [newcomer]);
      expect(
        capped.queue.every((op) => op.kind == SyncOpKind.trainingHistoryInsert),
        isTrue,
      );

      final raw = InMemoryKeyValueStore();
      final cache = LocalCache(raw, 'A');
      await cache.writeOutbox(entries);
      final server = _Server()..offline = true;
      final env = _Harness(server, storage: raw);
      await cache.writeProfile(const UserProfile(onboardingCompleted: true));
      await h.bootUntilIdle(env.store);
      final entry = _entry();
      await expectLater(
        env.store.completeTrainingSession(entry, generation: 0),
        throwsStateError,
      );
      expect((await env.cache.readTrainingSession())?.sessionId, entry.id);
      expect(env.store.trainingHistory.length, kOutboxMaxOps);
      expect((await env.cache.readOutbox())!.length, kOutboxMaxOps);
    },
  );
}
