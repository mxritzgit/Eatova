import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health/health.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/services/apple_health_service.dart';
import 'package:eatova/src/services/crash_reporter.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';

final _now = DateTime(2026, 9, 16, 6, 27);

class _Health extends Health {
  final calls = <String>[];
  Future<void> Function()? onConfigure;
  Future<bool> Function()? onAuthorize;
  Future<int?> Function()? onSteps;
  Future<List<HealthDataPoint>> Function()? onWeight;
  int? steps = 4200;

  @override
  Future<void> configure() async {
    calls.add('configure');
    await onConfigure?.call();
  }

  @override
  Future<bool> requestAuthorization(
    List<HealthDataType> types, {
    List<HealthDataAccess>? permissions,
  }) async {
    calls.add('authorize');
    return await onAuthorize?.call() ?? true;
  }

  @override
  Future<bool?> hasPermissions(
    List<HealthDataType> types, {
    List<HealthDataAccess>? permissions,
  }) async {
    calls.add('grant');
    return true;
  }

  @override
  Future<int?> getTotalStepsInInterval(
    DateTime startTime,
    DateTime endTime, {
    bool includeManualEntry = true,
  }) async {
    calls.add('steps');
    expect(endTime.isAfter(clock.now()), isFalse);
    return onSteps == null ? steps : await onSteps!();
  }

  @override
  Future<List<HealthDataPoint>> getHealthDataFromTypes({
    required List<HealthDataType> types,
    Map<HealthDataType, HealthDataUnit>? preferredUnits,
    required DateTime startTime,
    required DateTime endTime,
    List<RecordingMethod> recordingMethodsToFilter = const [],
  }) async {
    calls.add('weight');
    return await onWeight?.call() ?? [];
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late _Health plugin;
  late AppleHealthService service;
  late HealthAuthVerifier verifier;
  late List<String?> reports;

  void lifecycle(AppLifecycleState state) =>
      binding.handleAppLifecycleStateChanged(state);

  setUp(() {
    lifecycle(AppLifecycleState.resumed);
    plugin = _Health();
    verifier = HealthAuthVerifier();
    service = AppleHealthService(
      health: plugin,
      verifier: verifier,
      debugIsIOS: true,
    );
    reports = [];
    CrashReporter.debugSentrySink = (_, _, context) => reports.add(context);
  });

  tearDown(() {
    CrashReporter.debugSentrySink = null;
    lifecycle(AppLifecycleState.resumed);
  });

  test('missing steps never become a fresh zero through sticky evidence', () {
    verifier.resolve(
      const HealthAuthEvidence(writeGrant: true, steps: 4200),
      now: _now,
    );
    expect(
      verifier.verifiedSnapshot(
        const HealthAuthEvidence(writeGrant: true),
        now: _now.add(const Duration(minutes: 1)),
      ),
      isNull,
    );
  });

  for (final state in AppLifecycleState.values.where(
    (state) => state != AppLifecycleState.resumed,
  )) {
    test('$state defers HealthKit reads without changing permission', () async {
      await withClock(Clock.fixed(_now), () async {
        lifecycle(state);
        expect(await service.readSnapshot(), isNull);
        expect(await service.readStepsOnDay(_now), isNull);
        expect(await service.readWeightSamples(from: _now, to: _now), isEmpty);
        expect(plugin.calls, isEmpty);
        expect(service.authState, HealthAuthState.unknown);
        expect(reports, isEmpty);
      });
    });
  }

  test('background during configure starts no health query', () async {
    await withClock(Clock.fixed(_now), () async {
      plugin.onConfigure = () async => lifecycle(AppLifecycleState.paused);
      expect(await service.readSnapshot(), isNull);
      expect(plugin.calls, ['configure']);
      expect(reports, isEmpty);
    });
  });

  test('resume-to-background step failure stops the weight query', () async {
    await withClock(Clock.fixed(_now), () async {
      plugin.onSteps = () async {
        lifecycle(AppLifecycleState.paused);
        throw PlatformException(code: 'STEPS_ERROR');
      };
      expect(await service.readSnapshot(), isNull);
      expect(plugin.calls, ['configure', 'grant', 'steps']);
      expect(reports, isEmpty);
      expect(service.authState, HealthAuthState.unknown);
    });
  });

  test('background weight failure discards the interrupted snapshot', () async {
    await withClock(Clock.fixed(_now), () async {
      plugin.onWeight = () async {
        lifecycle(AppLifecycleState.paused);
        throw PlatformException(code: 'HEALTH_ERROR');
      };
      expect(await service.readSnapshot(), isNull);
      expect(reports, isEmpty);
      expect(verifier.lastReadEvidenceAt, isNull);
    });
  });

  test(
    'successful native result after background is deferred until resume',
    () async {
      await withClock(Clock.fixed(_now), () async {
        plugin.onSteps = () async {
          lifecycle(AppLifecycleState.paused);
          return 9000;
        };
        expect(await service.readSnapshot(), isNull);
        expect(plugin.calls, isNot(contains('weight')));
        expect(verifier.lastReadEvidenceAt, isNull);

        lifecycle(AppLifecycleState.resumed);
        plugin.onSteps = null;
        expect((await service.readSnapshot())?.stepsToday, 4200);
        expect(reports, isEmpty);
      });
    },
  );

  test(
    'unrelated failures are still reported after a lifecycle change',
    () async {
      await withClock(Clock.fixed(_now), () async {
        plugin.onSteps = () async {
          lifecycle(AppLifecycleState.paused);
          throw StateError('synthetic programming error');
        };
        expect(await service.readSnapshot(), isNull);
        expect(reports, ['health.readSteps']);
      });
    },
  );

  test(
    'history reads work in foreground and keep real failures visible',
    () async {
      await withClock(Clock.fixed(_now), () async {
        expect(await service.readStepsOnDay(_now), 4200);
        plugin.onSteps = () async =>
            throw PlatformException(code: 'STEPS_ERROR');
        expect(await service.readStepsOnDay(_now), isNull);
        plugin.onWeight = () async =>
            throw PlatformException(code: 'HEALTH_ERROR');
        expect(await service.readWeightSamples(from: _now, to: _now), isEmpty);
        expect(reports, ['health.readStepsOnDay', 'health.readWeightSamples']);
      });
    },
  );

  test(
    'authorization finishing in background remains refreshable on resume',
    () async {
      await withClock(Clock.fixed(_now), () async {
        plugin.onAuthorize = () async {
          lifecycle(AppLifecycleState.paused);
          return true;
        };
        expect(
          await service.requestAuthorization(),
          HealthAuthState.unverified,
        );
        expect(plugin.calls, ['configure', 'authorize']);
        lifecycle(AppLifecycleState.resumed);
        expect((await service.readSnapshot())?.stepsToday, 4200);
        expect(service.authState, HealthAuthState.granted);
      });
    },
  );

  test(
    'reset while authorization is pending cannot restore the old grant',
    () async {
      await withClock(Clock.fixed(_now), () async {
        plugin.onAuthorize = () async {
          service.reset();
          return true;
        };
        expect(await service.requestAuthorization(), HealthAuthState.unknown);
        expect(plugin.calls, ['configure', 'authorize']);
        expect(verifier.lastReadEvidenceAt, isNull);
      });
    },
  );

  test('non-iOS reads stay no-ops', () async {
    service = AppleHealthService(health: plugin, debugIsIOS: false);
    expect(await service.readSnapshot(), isNull);
    expect(await service.readStepsOnDay(_now), isNull);
    expect(await service.readWeightSamples(from: _now, to: _now), isEmpty);
    expect(await service.requestAuthorization(), HealthAuthState.unsupported);
    expect(plugin.calls, isEmpty);
  });

  test(
    'foreground step errors stay reportable and preserve the store',
    () async {
      await withClock(Clock.fixed(_now), () async {
        final store = HomeStore(
          sync: null,
          health: service,
          notificationService: const NoopNotificationService(),
          initialUserName: 'Test',
          emitSnack:
              (
                _, {
                icon = Icons.info_outline,
                tone = SnackTone.positive,
                duration,
                action,
              }) {},
        );
        addTearDown(store.dispose);
        await store.refreshHealthSteps();
        expect(store.dailySteps, 4200);
        expect(store.healthLastFetch, _now);
        final activity = Map.of(store.dailyActivity);

        plugin.onSteps = () async =>
            throw PlatformException(code: 'STEPS_ERROR');
        await withClock(
          Clock.fixed(_now.add(const Duration(minutes: 1))),
          store.refreshHealthSteps,
        );
        expect(store.dailySteps, 4200);
        expect(store.healthLastFetch, _now);
        expect(store.dailyActivity, activity);
        expect(store.healthSyncing, isFalse);
        expect(reports, ['health.readSteps']);
      });
    },
  );

  test(
    'foreground weight errors remain visible without losing real steps',
    () async {
      await withClock(Clock.fixed(_now), () async {
        plugin.onWeight = () async =>
            throw PlatformException(code: 'HEALTH_ERROR');
        expect((await service.readSnapshot())?.stepsToday, 4200);
        expect(reports, ['health.readSnapshot.weight']);
      });
    },
  );

  test(
    'null step result preserves the last value; a measured zero is valid',
    () async {
      await withClock(Clock.fixed(_now), () async {
        expect((await service.readSnapshot())?.stepsToday, 4200);
        plugin.steps = null;
        expect(await service.readSnapshot(), isNull);
        plugin.steps = 0;
        expect((await service.readSnapshot())?.stepsToday, 0);
        expect(service.authState, HealthAuthState.granted);
      });
    },
  );

  test(
    'fast resume retries an interrupted read once with fresh evidence',
    () async {
      await withClock(Clock.fixed(_now), () async {
        plugin.onSteps = () async {
          lifecycle(AppLifecycleState.paused);
          lifecycle(AppLifecycleState.resumed);
          plugin.onSteps = null;
          plugin.steps = 5100;
          throw PlatformException(code: 'STEPS_ERROR');
        };
        expect((await service.readSnapshot())?.stepsToday, 5100);
        expect(plugin.calls.where((call) => call == 'steps'), hasLength(2));
        expect(reports, isEmpty);
      });
    },
  );

  test('repeated lifecycle interruptions do not loop', () async {
    await withClock(Clock.fixed(_now), () async {
      plugin.onSteps = () async {
        lifecycle(AppLifecycleState.paused);
        lifecycle(AppLifecycleState.resumed);
        throw PlatformException(code: 'STEPS_ERROR');
      };
      expect(await service.readSnapshot(), isNull);
      expect(plugin.calls.where((call) => call == 'steps'), hasLength(2));
      expect(reports, isEmpty);
    });
  });

  test(
    'reset invalidates in-flight evidence before a new account can see it',
    () async {
      await withClock(Clock.fixed(_now), () async {
        final started = Completer<void>();
        final pending = Completer<int?>();
        plugin.onSteps = () {
          started.complete();
          return pending.future;
        };
        final read = service.readSnapshot();
        await started.future;
        service.reset();
        pending.complete(9000);
        expect(await read, isNull);
        expect(service.authState, HealthAuthState.unknown);
        expect(verifier.lastReadEvidenceAt, isNull);
        expect(plugin.calls, isNot(contains('weight')));
      });
    },
  );

  test(
    'permission sheet lifecycle does not invalidate the subsequent read',
    () async {
      await withClock(Clock.fixed(_now), () async {
        plugin.onAuthorize = () async {
          lifecycle(AppLifecycleState.inactive);
          lifecycle(AppLifecycleState.resumed);
          return true;
        };
        expect(await service.requestAuthorization(), HealthAuthState.granted);
        expect(reports, isEmpty);
      });
    },
  );
}
