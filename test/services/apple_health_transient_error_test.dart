import 'package:clock/clock.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health/health.dart';

import 'package:eatova/src/services/apple_health_service.dart';
import 'package:eatova/src/services/crash_reporter.dart';

// Sentry 2026-10-04 (PlatformException code=STEPS_ERROR, context
// health.readSteps, iPhone, 1.1.0 (4)): the step query failed 27 ms after the
// app came to the foreground at 04:24. The plugin wraps every HealthKit error
// of that query in STEPS_ERROR and keeps the reason only in the message;
// right after an unlock HealthKit's protected store is briefly not readable
// ("Protected health data is inaccessible"). The read was not interrupted, so
// the error went straight to Sentry and the steps stayed stale until the next
// resume. A generic HealthKit error in the foreground now gets one retry
// after a short wait; only a failure that persists is reported.

final _now = DateTime(2026, 10, 4, 4, 24, 42);

class _Health extends Health {
  final calls = <String>[];
  final List<Object> stepResults = [];
  Object? weightResult;

  Object _next(List<Object> results) =>
      results.length > 1 ? results.removeAt(0) : results.first;

  @override
  Future<void> configure() async => calls.add('configure');

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
    final result = _next(stepResults);
    if (result is! int) throw result;
    return result;
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
    final result = weightResult;
    if (result is Exception) throw result;
    return const [];
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late _Health plugin;
  late AppleHealthService service;
  late List<String?> reports;
  late List<Duration> waits;

  setUp(() {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    plugin = _Health();
    waits = [];
    service = AppleHealthService(
      health: plugin,
      debugIsIOS: true,
      retryDelay: (duration) async => waits.add(duration),
    );
    reports = [];
    CrashReporter.debugSentrySink = (_, _, context) => reports.add(context);
  });

  tearDown(() => CrashReporter.debugSentrySink = null);

  PlatformException stepsError() => PlatformException(code: 'STEPS_ERROR');

  test('a step error that clears after a short wait is not reported', () async {
    await withClock(Clock.fixed(_now), () async {
      plugin.stepResults.addAll([stepsError(), 4200]);

      expect((await service.readSnapshot())?.stepsToday, 4200);
      expect(plugin.calls.where((c) => c == 'steps'), hasLength(2));
      expect(waits, hasLength(1), reason: 'one short wait, then one retry');
      expect(reports, isEmpty);
    });
  });

  test('a step error that persists is reported once', () async {
    await withClock(Clock.fixed(_now), () async {
      plugin.stepResults.add(stepsError());

      expect(await service.readSnapshot(), isNull);
      expect(plugin.calls.where((c) => c == 'steps'), hasLength(2));
      expect(reports, ['health.readSteps']);
    });
  });

  test('the day backfill gets the same single retry', () async {
    await withClock(Clock.fixed(_now), () async {
      plugin.stepResults.addAll([stepsError(), 7300]);

      expect(
        await service.readStepsOnDay(DateTime(2026, 10, 3)),
        7300,
      );
      expect(reports, isEmpty);
    });
  });

  test('an optional weight error is still reported at once', () async {
    await withClock(Clock.fixed(_now), () async {
      plugin.stepResults.add(4200);
      plugin.weightResult = PlatformException(code: 'HEALTH_ERROR');

      expect((await service.readSnapshot())?.stepsToday, 4200);
      expect(plugin.calls.where((c) => c == 'steps'), hasLength(1));
      expect(waits, isEmpty);
      expect(reports, ['health.readSnapshot.weight']);
    });
  });

  test('a non-HealthKit error is reported without a retry', () async {
    await withClock(Clock.fixed(_now), () async {
      plugin.stepResults.add(StateError('plugin bug'));

      expect(await service.readSnapshot(), isNull);
      expect(plugin.calls.where((c) => c == 'steps'), hasLength(1));
      expect(waits, isEmpty);
      expect(reports, ['health.readSteps']);
    });
  });
}
