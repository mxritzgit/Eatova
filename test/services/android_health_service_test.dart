import 'dart:async';

import 'package:clock/clock.dart';
import 'package:eatova/src/services/android_health_service.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/platform_health_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health/health.dart';

import '../support/fake_health_connect_adapter.dart';

class _HealthPermissionPlugin extends Health {
  List<HealthDataType>? requested;
  List<HealthDataAccess>? access;

  @override
  Future<bool> requestAuthorization(
    List<HealthDataType> types, {
    List<HealthDataAccess>? permissions,
  }) async {
    requested = types;
    access = permissions;
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime(2026, 9, 10, 14, 32);
  late FakeHealthConnectAdapter adapter;
  late AndroidHealthService service;
  setUp(() {
    adapter = FakeHealthConnectAdapter();
    service = AndroidHealthService(adapter: adapter);
  });

  test('desktop has no health provider', () {
    expect(
      createPlatformHealthService(platform: TargetPlatform.windows),
      isA<NoopHealthService>(),
    );
  });

  test(
    'opening the account never prompts, reads records or starts installation',
    () async {
      await service.readSnapshot();
      expect(service.authState, HealthAuthState.unknown);
      expect(adapter.requests, 0);
      expect(adapter.intervals, isEmpty);
      adapter.status =
          HealthConnectSdkStatus.sdkUnavailableProviderUpdateRequired;
      await service.readSnapshot();
      expect(service.authState, HealthAuthState.updateRequired);
      expect(adapter.installs, 0);
    },
  );

  test(
    'unavailable device never requests permission or reads records',
    () async {
      adapter.status = HealthConnectSdkStatus.sdkUnavailable;
      expect(await service.requestAuthorization(), HealthAuthState.unavailable);
      expect(await service.readSnapshot(), isNull);
      expect(adapter.requests, 0);
      expect(adapter.permissionReads, 0);
    },
  );

  test(
    'installation/update action can recover without restarting the service',
    () async {
      adapter.status =
          HealthConnectSdkStatus.sdkUnavailableProviderUpdateRequired;
      expect(
        await service.requestAuthorization(),
        HealthAuthState.updateRequired,
      );
      expect(adapter.installs, 1);
      adapter.status = HealthConnectSdkStatus.sdkAvailable;
      expect(await service.requestAuthorization(), HealthAuthState.granted);
    },
  );

  test('unknown availability fails closed', () async {
    adapter.status = null;
    expect(await service.requestAuthorization(), HealthAuthState.error);
    expect(adapter.requests, 0);
  });

  test('denial is confirmed from permissions after the prompt', () async {
    adapter.permission = false;
    expect(await service.requestAuthorization(), HealthAuthState.denied);
    expect(adapter.requests, 1);
    expect(await service.readSnapshot(), isNull);
    expect(adapter.intervals, isEmpty);
    adapter.permission = true;
    expect(await service.readSnapshot(), isNotNull);
    expect(service.authState, HealthAuthState.granted);
  });

  test('two accounts cannot overlap the plugin permission callback', () async {
    adapter.permission = false;
    final opened = Completer<void>();
    final reply = Completer<void>();
    adapter.onRequest = () {
      opened.complete();
      return reply.future;
    };
    final old = service.requestAuthorization();
    await opened.future;
    service.reset();
    final next = service.requestAuthorization();
    await Future<void>.delayed(Duration.zero);
    expect(adapter.requests, 1);
    adapter.permission = true;
    reply.complete();
    expect(await old, HealthAuthState.unknown);
    expect(await next, HealthAuthState.granted);
  });

  test(
    'new grant is verified before a single local-day aggregate is read',
    () async {
      adapter.permission = false;
      adapter.onRequest = () async {
        adapter.permission = true;
      };
      await service.requestAuthorization();
      final snapshot = await withClock(Clock.fixed(now), service.readSnapshot);
      expect(snapshot?.stepsToday, 8400);
      expect(snapshot?.fetchedAt, now);
      expect(snapshot?.latestWeightKg, isNull);
      expect(adapter.intervals, [(start: DateTime(2026, 9, 10), end: now)]);
      expect(adapter.requests, 1);
    },
  );

  test(
    'missing sample remains null; a measured zero is a real snapshot',
    () async {
      await service.requestAuthorization();
      adapter.steps = null;
      expect(await withClock(Clock.fixed(now), service.readSnapshot), isNull);
      expect(service.authState, HealthAuthState.noData);
      adapter.steps = 0;
      expect(
        (await withClock(Clock.fixed(now), service.readSnapshot))?.stepsToday,
        0,
      );
      expect(service.authState, HealthAuthState.granted);
    },
  );

  test('revoked permission prevents the next read', () async {
    await service.requestAuthorization();
    await withClock(Clock.fixed(now), service.readSnapshot);
    adapter.permission = false;
    expect(await service.readSnapshot(), isNull);
    expect(service.authState, HealthAuthState.denied);
    expect(adapter.intervals, hasLength(1));
    adapter.permission = true;
    expect(await withClock(Clock.fixed(now), service.readSnapshot), isNotNull);
  });

  test('revocation during aggregate discards a successful result', () async {
    await service.requestAuthorization();
    adapter.onAggregate = () async {
      adapter.permission = false;
      return 9999;
    };
    expect(await withClock(Clock.fixed(now), service.readSnapshot), isNull);
    expect(service.authState, HealthAuthState.denied);
  });

  test('platform permission and generic errors remain distinct', () async {
    await service.requestAuthorization();
    adapter.onAggregate = () async =>
        throw PlatformException(code: 'permission_denied');
    expect(await service.readSnapshot(), isNull);
    expect(service.authState, HealthAuthState.denied);
    adapter.onAggregate = () async => throw StateError('private record');
    expect(await service.readSnapshot(), isNull);
    expect(service.authState, HealthAuthState.error);
  });

  test(
    'history uses calendar boundaries and preserves a measured zero',
    () async {
      await service.requestAuthorization();
      adapter.steps = 0;
      final day = DateTime(2026, 3, 29, 13);
      expect(
        await withClock(Clock.fixed(now), () => service.readStepsOnDay(day)),
        0,
      );
      expect(adapter.intervals.single, (
        start: DateTime(2026, 3, 29),
        end: DateTime(2026, 3, 30),
      ));
      adapter.intervals.clear();
      expect(
        await withClock(Clock.fixed(now), () => service.readStepsOnDay(now)),
        0,
      );
      expect(adapter.intervals.single.end, now);
      adapter.intervals.clear();
      expect(
        await withClock(
          Clock.fixed(now),
          () => service.readStepsOnDay(DateTime(2026, 9, 11)),
        ),
        isNull,
      );
      expect(adapter.intervals, isEmpty);
    },
  );

  test(
    'history restrictions return no value without erasing current state',
    () async {
      await service.requestAuthorization();
      adapter.onAggregate = () async =>
          throw PlatformException(code: 'read_failed');
      expect(await service.readStepsOnDay(DateTime(2020)), isNull);
      expect(service.authState, HealthAuthState.granted);
      adapter.onAggregate = () async =>
          throw PlatformException(code: 'permission_denied');
      expect(await service.readStepsOnDay(DateTime(2020)), isNull);
      expect(service.authState, HealthAuthState.granted);
    },
  );

  test(
    'reset while permission sheet is open cannot connect the next account',
    () async {
      adapter.permission = false;
      final opened = Completer<void>();
      final reply = Completer<void>();
      adapter.onRequest = () {
        opened.complete();
        return reply.future;
      };
      final old = service.requestAuthorization();
      await opened.future;
      service.reset();
      adapter.permission = true;
      reply.complete();
      expect(await old, HealthAuthState.unknown);
      expect(service.authState, HealthAuthState.unknown);
      expect(await service.readSnapshot(), isNull);
      expect(adapter.intervals, isEmpty);
    },
  );

  test('late read does not overwrite the next account state', () async {
    await service.requestAuthorization();
    final started = Completer<void>();
    final reply = Completer<int?>();
    adapter.onAggregate = () {
      started.complete();
      return reply.future;
    };
    final old = service.readSnapshot();
    await started.future;
    service.reset();
    adapter.onAggregate = null;
    adapter.steps = null;
    await service.requestAuthorization();
    await service.readSnapshot();
    expect(service.authState, HealthAuthState.noData);
    reply.complete(99999);
    expect(await old, isNull);
    expect(service.authState, HealthAuthState.noData);
  });

  test('late history result is discarded after reset', () async {
    await service.requestAuthorization();
    final started = Completer<void>();
    final reply = Completer<int?>();
    adapter.onAggregate = () {
      started.complete();
      return reply.future;
    };
    final old = service.readStepsOnDay(DateTime(2026, 9, 9));
    await started.future;
    service.reset();
    reply.complete(8800);
    expect(await old, isNull);
  });

  test('settings failure is recoverable, Android weight is a no-op', () async {
    expect(await service.openSettings(), isTrue);
    expect(adapter.settings, 1);
    adapter.onSettings = () async => throw StateError('no activity');
    expect(await service.openSettings(), isFalse);
    expect(service.authState, HealthAuthState.error);
    expect(await service.writeWeight(70, now), isFalse);
    expect(await service.readWeightSamples(from: now, to: now), isEmpty);
    expect(adapter.requests, 0);
    expect(adapter.intervals, isEmpty);
  });

  test(
    'plugin adapter requests only READ_STEPS and preserves nullable native aggregates',
    () async {
      final plugin = _HealthPermissionPlugin();
      const channel = MethodChannel('eatova/health_connect_test');
      final calls = <MethodCall>[];
      int? result;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return call.method == 'hasStepsPermission' ? true : result;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final real = PluginHealthConnectAdapter(health: plugin, channel: channel);
      await real.requestStepsPermission();
      expect(plugin.requested, [HealthDataType.STEPS]);
      expect(plugin.access, [HealthDataAccess.READ]);
      expect(await real.hasStepsPermission(), isTrue);
      final start = DateTime(2026, 9, 10);
      expect(await real.aggregateSteps(start, now), isNull);
      result = 0;
      expect(await real.aggregateSteps(start, now), 0);
      expect(calls.last.arguments, {
        'startTime': start.millisecondsSinceEpoch,
        'endTime': now.millisecondsSinceEpoch,
      });
      result = null;
      await real.installOrUpdate();
      await real.openSettings();
      expect(calls.map((c) => c.method), [
        'hasStepsPermission',
        'aggregateSteps',
        'aggregateSteps',
        'installOrUpdate',
        'openSettings',
      ]);
    },
  );
}
