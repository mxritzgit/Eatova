import 'dart:async';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/services/android_health_service.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/kcal_calculator.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/secure_cache_store.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_health_connect_adapter.dart';

class _DelayedConsentStore extends InMemoryKeyValueStore {
  final readStarted = Completer<void>();
  final result = Completer<String?>();

  @override
  Future<String?> getString(String key) {
    readStarted.complete();
    return result.future;
  }
}

void _ignoreSnack(
  String message, {
  IconData icon = Icons.info_outline,
  SnackTone tone = SnackTone.positive,
  Duration? duration,
  SnackBarAction? action,
}) {}

HomeStore _store(
  AndroidHealthService health, {
  LocalCache? cache,
  EatovaSync? sync,
}) => HomeStore(
  sync: sync,
  health: health,
  notificationService: const NoopNotificationService(),
  initialUserName: 'Test',
  emitSnack: _ignoreSnack,
  debugCache: cache,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime(2026, 9, 10, 12);
  late FakeHealthConnectAdapter adapter;
  late AndroidHealthService service;
  late HomeStore store;
  setUp(() {
    adapter = FakeHealthConnectAdapter();
    service = AndroidHealthService(adapter: adapter);
    store = _store(service);
  });
  tearDown(() => store.dispose());

  test('late consent cache read cannot reconnect the next account', () async {
    final delayed = _DelayedConsentStore();
    store.dispose();
    store = _store(service, cache: LocalCache(delayed, 'health-a'));
    final old = store.restoreHealthConnection();
    await delayed.readStarted.future;
    store.dispose();
    store = _store(
      service,
      cache: LocalCache(InMemoryKeyValueStore(), 'health-b'),
    );
    delayed.result.complete('{"enabled":true}');
    await old;
    expect(service.authState, HealthAuthState.unknown);
    expect(adapter.intervals, isEmpty);
    expect(await service.readSnapshot(), isNull);
  });

  test(
    'successful connection is encrypted and reconnects only its account after cold start',
    () async {
      final raw = InMemoryKeyValueStore();
      final encrypted = EncryptedKeyValueStore(
        raw,
        AesGcmCacheCipher(Uint8List.fromList(List.filled(32, 7))),
      );
      final cacheA = LocalCache(encrypted, 'health-a');
      store.dispose();
      store = _store(service, cache: cacheA);
      await store.connectHealth();
      expect(await cacheA.readHealthConnectEnabled(), isTrue);
      final ciphertext =
          raw.snapshot['eatova.v1.health_connect_enabled.health-a']!;
      expect(ciphertext, startsWith(cacheCipherMagic));
      expect(ciphertext, isNot(contains('enabled')));
      store.dispose();

      // A new process/service, same account and encrypted storage. Production
      // boot calls the restoration before the network/outbox finishes.
      service = AndroidHealthService(adapter: adapter);
      adapter.intervals.clear();
      final client = SupabaseClient(
        'https://ci.invalid',
        'ci-dummy-key',
        httpClient: MockClient(
          (request) async => http.Response(
            '[]',
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          ),
        ),
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      addTearDown(client.dispose);
      store = _store(
        service,
        cache: LocalCache(encrypted, 'health-a'),
        sync: EatovaSync.forUser(client, 'health-a'),
      );
      store.start();
      await store.profileReady;
      await Future<void>.delayed(Duration.zero);
      expect(store.dailySteps, 8400);
      expect(adapter.requests, 0);
      store.dispose();

      store = _store(service, cache: LocalCache(encrypted, 'health-b'));
      adapter.intervals.clear();
      await store.restoreHealthConnection();
      expect(adapter.intervals, isEmpty);
      expect(store.healthAuthState, HealthAuthState.unknown);
      expect(store.dailySteps, 0);
      // Ciphertext copied to B also cannot authorize B (AAD is the slot key).
      await raw.setString(
        'eatova.v1.health_connect_enabled.health-b',
        ciphertext,
      );
      await store.restoreHealthConnection();
      expect(adapter.intervals, isEmpty);
    },
  );

  test('denial and malformed consent never allow automatic import', () async {
    final raw = InMemoryKeyValueStore();
    final cache = LocalCache(raw, 'health-a');
    store.dispose();
    store = _store(service, cache: cache);
    adapter.permission = false;
    await store.connectHealth();
    expect(await cache.readHealthConnectEnabled(), isFalse);
    store.dispose();
    adapter.permission = true;
    await raw.setString(
      'eatova.v1.health_connect_enabled.health-a',
      '{"enabled":"true"}',
    );
    store = _store(service, cache: LocalCache(raw, 'health-a'));
    await store.restoreHealthConnection();
    expect(adapter.intervals, isEmpty);
    await raw.setString(
      'eatova.v1.health_connect_enabled.health-a',
      'invalid json',
    );
    await store.restoreHealthConnection();
    expect(adapter.intervals, isEmpty);
  });

  test(
    'logout cache purge removes reconnect consent even when outbox survives',
    () async {
      final raw = InMemoryKeyValueStore();
      final cache = LocalCache(raw, 'health-a');
      await cache.writeHealthConnectEnabled(true);
      await cache.clear(preserveOutbox: true);
      expect(await cache.readHealthConnectEnabled(), isFalse);
    },
  );

  test(
    'connected without records has no measured zero or kcal entry',
    () async {
      adapter.steps = null;
      await withClock(Clock.fixed(now), store.connectHealth);
      expect(store.healthAuthState, HealthAuthState.noData);
      expect(store.healthLastFetch, isNull);
      expect(
        withClock(Clock.fixed(now), () => store.stepsForFoodDate(now)),
        isNull,
      );
      expect(store.dailyActivity, isEmpty);
      expect(store.burnedKcalForFoodDate(now), 0);
      adapter.steps = 0;
      await withClock(Clock.fixed(now), store.refreshHealthSteps);
      expect(store.dailyActivity['2026-09-10'], (steps: 0, kcal: 0));
      expect(withClock(Clock.fixed(now), () => store.stepsForFoodDate(now)), 0);
    },
  );

  test(
    'aggregate feeds the existing calorie model and revocation clears live data',
    () async {
      await withClock(Clock.fixed(now), store.connectHealth);
      final kcal = estimateKcalBurnedFromSteps(
        steps: adapter.steps!,
        weightKg: store.profile.weightKg,
        heightCm: store.profile.heightCm,
        sex: store.profile.sex,
      );
      expect(store.dailyActivity['2026-09-10'], (steps: 8400, kcal: kcal));
      expect(
        withClock(Clock.fixed(now), () => store.burnedKcalForFoodDate(now)),
        kcal,
      );
      adapter.permission = false;
      await withClock(Clock.fixed(now), store.refreshHealthSteps);
      expect(store.healthAuthState, HealthAuthState.denied);
      expect(
        withClock(Clock.fixed(now), () => store.stepsForFoodDate(now)),
        isNull,
      );
      expect(store.dailySteps, 0);
      expect(
        withClock(Clock.fixed(now), () => store.burnedKcalForFoodDate(now)),
        0,
      );
    },
  );

  test(
    'midnight does not reuse yesterday steps before the next aggregate',
    () async {
      await withClock(Clock.fixed(now), store.connectHealth);
      final nextDay = DateTime(2026, 9, 11, 0, 1);
      expect(
        withClock(Clock.fixed(nextDay), () => store.stepsForFoodDate(nextDay)),
        isNull,
      );
      expect(
        withClock(
          Clock.fixed(nextDay),
          () => store.burnedKcalForFoodDate(nextDay),
        ),
        0,
      );
      expect(
        withClock(Clock.fixed(nextDay), () => store.stepsForFoodDate(now)),
        8400,
      );
    },
  );

  test('duplicate taps during permission request are coalesced', () async {
    adapter.permission = false;
    final opened = Completer<void>();
    final reply = Completer<void>();
    adapter.onRequest = () {
      opened.complete();
      return reply.future;
    };
    final pending = store.connectHealth();
    await opened.future;
    expect(store.healthSyncing, isTrue);
    await store.connectHealth();
    await store.refreshHealthSteps();
    expect(adapter.requests, 1);
    adapter.permission = true;
    reply.complete();
    await pending;
    expect(store.healthSyncing, isFalse);
  });

  test(
    'dispose while reading cannot put account A steps in account B',
    () async {
      await service.requestAuthorization();
      final started = Completer<void>();
      final reply = Completer<int?>();
      adapter.onAggregate = () {
        started.complete();
        return reply.future;
      };
      final pending = store.refreshHealthSteps();
      await started.future;
      store.dispose();
      store = _store(service);
      reply.complete(99999);
      await pending;
      expect(service.authState, HealthAuthState.unknown);
      expect(store.healthAuthState, HealthAuthState.unknown);
      expect(store.dailyActivity, isEmpty);
      expect(store.dailySteps, 0);
      expect(await service.readSnapshot(), isNull);
    },
  );
}
