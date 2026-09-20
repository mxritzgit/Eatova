import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/durable_cache_store.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/services/secure_cache_store.dart';
import 'package:eatova/src/services/sync_error_messages.dart';
import 'package:eatova/src/services/sync_execution_guard.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase/supabase.dart';

import 'outbox/outbox_test_helpers.dart' as h;
import 'support/atomic_store_faults.dart';

const _owner = 'user-outbox';
final _now = DateTime.utc(2026, 9, 20, 12);

Future<void> _signIn(SupabaseClient client) async {
  final payload = base64Url
      .encode(
        utf8.encode(
          jsonEncode({
            'sub': _owner,
            'session_id': 'resource-session',
            'exp': 4102444800,
          }),
        ),
      )
      .replaceAll('=', '');
  await client.auth.recoverSession(
    jsonEncode({
      'access_token': 'fixture.$payload.signature',
      'refresh_token': 'fixture-refresh',
      'token_type': 'bearer',
      'expires_in': 3600,
      'expires_at': 4102444800,
      'user': {
        'id': _owner,
        'aud': 'authenticated',
        'created_at': '2026-01-01T00:00:00Z',
        'app_metadata': {},
        'user_metadata': {},
      },
    }),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late h.FakeServer server;
  late SupabaseClient client;

  HomeStore makeStore({
    LocalCache? cache,
    Future<LocalCache?> Function(String)? factory,
  }) => HomeStore(
    sync: EatovaSync.forUser(client, _owner),
    debugCache: cache,
    debugCacheFactory: factory,
    health: const NoopHealthService(),
    notificationService: const NoopNotificationService(),
    initialUserName: 'Fixture',
    emitSnack: h.SnackCapture().call,
  );

  setUp(() async {
    CacheKeyProvider.debugReset();
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp(
      'eatova_store_lifecycle_',
    );
    LocalCache.debugDatabasePath = '${directory.path}/cache.sqlite';
    server = h.FakeServer();
    client = SupabaseClient(
      'https://ci.invalid',
      'ci-dummy-key',
      httpClient: server.client(),
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
  });

  tearDown(() async {
    await client.dispose();
    await DurableCacheStore.closeAll();
    CacheKeyProvider.debugReset();
    LocalCache.debugDatabasePath = null;
    final root = await Directory.systemTemp.resolveSymbolicLinks();
    final target = await directory.resolveSymbolicLinks();
    expect(target.startsWith('$root${Platform.pathSeparator}'), isTrue);
    await directory.delete(recursive: true);
  });

  test(
    'owned production cache releases its SQLite handle and reopens durable data',
    () async {
      await withClock(Clock.fixed(_now), () async {
        LocalCache? opened;
        final store = makeStore(
          factory: (uid) async => opened = await LocalCache.create(uid),
        );
        await h.bootUntilIdle(store);
        final original = opened!;
        final connection = original.atomicStore;
        await original.writeProfile(
          const UserProfile(weightKg: 93, onboardingCompleted: true),
        );
        store.dispose();
        await store.storageReleased;
        expect(original.isClosed, isTrue);
        final reopened = (await LocalCache.create(_owner))!;
        try {
          expect(
            identical(reopened.atomicStore, connection),
            isFalse,
            reason:
                'No old HomeStore reference may keep the pooled SQLite connection alive',
          );
          expect((await reopened.readProfile())!.weightKg, 93);
        } finally {
          await reopened.releaseStorage();
        }
      });
    },
  );

  test(
    'cache creation finishing after dispose is released without starting HTTP',
    () async {
      final gate = Completer<LocalCache?>();
      final entered = Completer<void>();
      final store = makeStore(
        factory: (_) {
          entered.complete();
          return gate.future;
        },
      );
      store.start();
      await entered.future;
      store.dispose();
      final opened = (await LocalCache.create(_owner))!;
      gate.complete(opened);
      await store.storageReleased;
      expect(opened.isClosed, isTrue);
      expect(server.requests, isEmpty);
    },
  );

  test(
    'caller-owned injected cache remains usable after HomeStore disposal',
    () async {
      final cache = LocalCache(InMemoryKeyValueStore(), _owner);
      final store = makeStore(cache: cache);
      await h.bootUntilIdle(store);
      store.dispose();
      await store.storageReleased;
      expect(cache.isClosed, isFalse);
      await cache.writeProfile(const UserProfile(weightKg: 94));
      expect((await cache.readProfile())!.weightKg, 94);
      await cache.releaseStorage();
    },
  );

  test(
    'owned disposal waits for an already entered entity transaction',
    () async {
      await withClock(Clock.fixed(_now), () async {
        await _signIn(client);
        final raw = InMemoryKeyValueStore();
        final controlled = AtomicStoreFaults(raw);
        final cache = LocalCache(controlled, _owner);
        final store = makeStore(factory: (_) async => cache);
        await h.bootUntilIdle(store);
        final entered = Completer<void>(), release = Completer<void>();
        controlled.beforeWrite = (changes) async {
          if (changes.containsKey('eatova.v1.logged_meals.$_owner')) {
            entered.complete();
            await release.future;
          }
        };
        final saving = store
            .addResultToDailyTotal(h.mealResult('Pending'))
            .then((_) => true, onError: (Object _) => false);
        await entered.future;
        store.dispose();
        await h.settle();
        expect(cache.isClosed, isFalse);
        release.complete();
        await saving;
        await store.storageReleased;
        expect(cache.isClosed, isTrue);
        final reopened = LocalCache(raw, _owner);
        expect(
          (await reopened.readLoggedMeals())!.single.result.mealName,
          'Pending',
        );
        expect(await reopened.readSyncOperations(), hasLength(2));
        expect(server.operations('mealInsert'), isEmpty);
        await reopened.releaseStorage();
      });
    },
  );

  test(
    'claim release failure does not turn a committed receipt into a failed save',
    () async {
      var now = _now;
      await withClock(Clock(() => now), () async {
        await _signIn(client);
        final controlled = AtomicStoreFaults(InMemoryKeyValueStore());
        final cache = LocalCache(controlled, _owner);
        final store = makeStore(cache: cache);
        addTearDown(store.dispose);
        await h.bootUntilIdle(store);
        var releaseFailures = 0;
        controlled.beforeWrite = (changes) async {
          if (changes.containsKey(syncClaimKey(_owner)) &&
              changes[syncClaimKey(_owner)] == null) {
            releaseFailures++;
            throw StateError('fixture lease cleanup failure');
          }
        };
        final outcome = await store.createUserRecipe(
          h.userRecipe('user_cleanup'),
        );
        expect(outcome, SyncDelivery.delivered);
        expect(releaseFailures, 1);
        expect(await cache.readSyncOperations(), isEmpty);
        expect(server.operations('recipeUpsert'), hasLength(1));
        controlled.beforeWrite = null;
        now = now.add(
          SyncExecutionGuard.leaseDuration + const Duration(seconds: 1),
        );
        await store.syncPendingWrites();
        expect(server.operations('recipeUpsert'), hasLength(1));
        expect(
          await cache.atomicStore!.getString(syncClaimKey(_owner)),
          isNull,
        );
        await cache.releaseStorage();
      });
    },
  );
}
