import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health/health.dart';

import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/services/android_health_service.dart';
import 'package:eatova/src/services/apple_health_service.dart';
import 'package:eatova/src/services/crash_reporter.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/recipe_image_store.dart';

import 'support/harness.dart';
import 'support/fake_health_connect_adapter.dart';

final _now = DateTime(2026, 9, 26, 10);

class _Images extends RecipeImageStore {
  @override
  Future<void> clear({
    String? expectedUserId,
    String? expectedSessionId,
  }) async {}
}

class _Health extends Health {
  final calls = <String>[];
  Future<void> Function()? onConfigure;
  Future<bool> Function()? onAuthorize;
  int steps = 4200;

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
    return steps;
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
    return [];
  }
}

HomeStore _storeOf(WidgetTester tester) =>
    (tester.state(find.byType(EatovaHomePage)) as HomePageDebugAccess)
        .debugStore;

Future<void> _pumpHome(WidgetTester tester, _Health plugin) async {
  pinPhoneViewport(tester);
  await pumpLocalized(
    tester,
    EatovaHomePage(
      healthService: AppleHealthService(health: plugin, debugIsIOS: true),
    ),
    scaffold: false,
    safeArea: false,
  );
  await tester.pump();
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  void lifecycle(AppLifecycleState state) =>
      binding.handleAppLifecycleStateChanged(state);

  setUp(() {
    lifecycle(AppLifecycleState.resumed);
    CrashReporter.debugSentrySink = (_, _, _) {};
  });
  tearDown(() {
    CrashReporter.debugSentrySink = null;
    lifecycle(AppLifecycleState.resumed);
  });

  testWidgets('inactive cold start connects and shows steps on first resume', (
    tester,
  ) async {
    await withClock(Clock.fixed(_now), () async {
      final plugin = _Health();
      lifecycle(AppLifecycleState.inactive);
      await _pumpHome(tester, plugin);
      expect(plugin.calls, isEmpty);
      expect(_storeOf(tester).healthAuthState, HealthAuthState.unknown);
      expect(find.byKey(const ValueKey('today-steps-card')), findsNothing);

      lifecycle(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(plugin.calls.where((call) => call == 'authorize'), hasLength(1));
      expect(_storeOf(tester).stepsForFoodDate(_now), 4200);
      expect(find.byKey(const ValueKey('today-steps-card')), findsOneWidget);
    });
  });

  testWidgets('configure interrupted by background recovers on next resume', (
    tester,
  ) async {
    await withClock(Clock.fixed(_now), () async {
      final configured = Completer<void>();
      final plugin = _Health()..onConfigure = () => configured.future;
      await _pumpHome(tester, plugin);
      expect(plugin.calls, ['configure']);
      lifecycle(AppLifecycleState.inactive);
      configured.complete();
      await tester.pump();
      expect(_storeOf(tester).healthSyncing, isFalse);
      expect(_storeOf(tester).healthAuthState, HealthAuthState.unknown);

      lifecycle(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(_storeOf(tester).stepsForFoodDate(_now), 4200);
      expect(find.byKey(const ValueKey('today-steps-card')), findsOneWidget);
    });
  });

  testWidgets(
    'temporary configure failure can recover without Connect Health',
    (tester) async {
      await withClock(Clock.fixed(_now), () async {
        final plugin = _Health()
          ..onConfigure = () async =>
              throw PlatformException(code: 'HEALTH_ERROR');
        await _pumpHome(tester, plugin);
        expect(_storeOf(tester).healthAuthState, HealthAuthState.unknown);
        expect(find.byKey(const ValueKey('today-steps-card')), findsNothing);
        plugin.onConfigure = null;

        lifecycle(AppLifecycleState.inactive);
        lifecycle(AppLifecycleState.resumed);
        await tester.pumpAndSettle();

        expect(_storeOf(tester).stepsForFoodDate(_now), 4200);
        expect(find.byKey(const ValueKey('today-steps-card')), findsOneWidget);
      });
    },
  );

  testWidgets('resume while authorization is busy is replayed after failure', (
    tester,
  ) async {
    await withClock(Clock.fixed(_now), () async {
      final authorization = Completer<bool>();
      final plugin = _Health()..onAuthorize = () => authorization.future;
      await _pumpHome(tester, plugin);
      expect(plugin.calls, ['configure', 'authorize']);
      expect(_storeOf(tester).healthSyncing, isTrue);

      lifecycle(AppLifecycleState.inactive);
      lifecycle(AppLifecycleState.resumed);
      await tester.pump();
      plugin.onAuthorize = null;
      authorization.complete(false);
      await tester.pumpAndSettle();

      expect(plugin.calls.where((call) => call == 'authorize'), hasLength(2));
      expect(_storeOf(tester).stepsForFoodDate(_now), 4200);
      expect(find.byKey(const ValueKey('today-steps-card')), findsOneWidget);
    });
  });

  testWidgets('permission sheet lifecycle cannot cause an authorization loop', (
    tester,
  ) async {
    await withClock(Clock.fixed(_now), () async {
      final plugin = _Health()
        ..onAuthorize = () async {
          lifecycle(AppLifecycleState.inactive);
          lifecycle(AppLifecycleState.resumed);
          return false;
        };
      await _pumpHome(tester, plugin);
      await tester.pumpAndSettle();

      expect(plugin.calls.where((call) => call == 'authorize'), hasLength(2));
      expect(_storeOf(tester).healthSyncing, isFalse);
      expect(find.byKey(const ValueKey('today-steps-card')), findsNothing);

      // A later foreground transition can recover independently of that replay.
      plugin.onAuthorize = null;
      lifecycle(AppLifecycleState.inactive);
      lifecycle(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(plugin.calls.where((call) => call == 'authorize'), hasLength(3));
      expect(_storeOf(tester).stepsForFoodDate(_now), 4200);
    });
  });

  testWidgets(
    'absent read evidence stays hidden and rechecks without a prompt',
    (tester) async {
      await withClock(Clock.fixed(_now), () async {
        final plugin = _Health()..steps = 0;
        await _pumpHome(tester, plugin);
        await tester.pumpAndSettle();
        expect(_storeOf(tester).healthAuthState, HealthAuthState.unverified);
        expect(_storeOf(tester).stepsForFoodDate(_now), isNull);
        expect(find.byKey(const ValueKey('today-steps-card')), findsNothing);

        lifecycle(AppLifecycleState.inactive);
        lifecycle(AppLifecycleState.resumed);
        await tester.pumpAndSettle();
        expect(_storeOf(tester).stepsForFoodDate(_now), isNull);
        expect(find.byKey(const ValueKey('today-steps-card')), findsNothing);

        plugin.steps = 4200;
        lifecycle(AppLifecycleState.inactive);
        lifecycle(AppLifecycleState.resumed);
        await tester.pumpAndSettle();
        expect(plugin.calls.where((call) => call == 'authorize'), hasLength(1));
        expect(_storeOf(tester).stepsForFoodDate(_now), 4200);
        expect(find.byKey(const ValueKey('today-steps-card')), findsOneWidget);
      });
    },
  );

  testWidgets('Android resume preserves explicit account opt-in', (
    tester,
  ) async {
    await withClock(Clock.fixed(_now), () async {
      final adapter = FakeHealthConnectAdapter();
      await pumpLocalized(
        tester,
        EatovaHomePage(healthService: AndroidHealthService(adapter: adapter)),
        scaffold: false,
        safeArea: false,
      );
      await tester.pumpAndSettle();
      lifecycle(AppLifecycleState.inactive);
      lifecycle(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(_storeOf(tester).healthAuthState, HealthAuthState.unknown);
      expect(adapter.requests, 0);
      expect(adapter.permissionReads, 0);
      expect(adapter.intervals, isEmpty);
      expect(find.byKey(const ValueKey('today-steps-card')), findsNothing);
    });
  });

  testWidgets('unmount during authorization discards queued recovery', (
    tester,
  ) async {
    await withClock(Clock.fixed(_now), () async {
      final authorization = Completer<bool>();
      final plugin = _Health()..onAuthorize = () => authorization.future;
      await _pumpHome(tester, plugin);
      lifecycle(AppLifecycleState.inactive);
      lifecycle(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox.shrink());
      authorization.complete(false);
      await tester.pumpAndSettle();

      expect(plugin.calls, ['configure', 'authorize']);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets(
    'sign-out during authorization cannot reconnect the old account',
    (tester) async {
      final images = RecipeImageStore.instance;
      RecipeImageStore.instance = _Images();
      addTearDown(() => RecipeImageStore.instance = images);
      await withClock(Clock.fixed(_now), () async {
        final authorization = Completer<bool>();
        final plugin = _Health()..onAuthorize = () => authorization.future;
        await _pumpHome(tester, plugin);
        final store = _storeOf(tester);
        lifecycle(AppLifecycleState.inactive);
        lifecycle(AppLifecycleState.resumed);
        await store.signOutCleanup();
        authorization.complete(true);
        await tester.pumpAndSettle();

        expect(plugin.calls, ['configure', 'authorize']);
        expect(store.stepsForFoodDate(_now), isNull);
        expect(find.byKey(const ValueKey('today-steps-card')), findsNothing);
      });
    },
  );
}
