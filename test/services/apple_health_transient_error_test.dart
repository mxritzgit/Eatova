import 'package:clock/clock.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health/health.dart';

import 'package:eatova/src/services/apple_health_service.dart';
import 'package:eatova/src/services/crash_reporter.dart';

// Sentry 2026-10-04, STEPS_ERROR (the plugin wraps every HealthKit error of
// the step query in it and keeps the reason only in the message):
// - FLUTTER-H, 1.1.0 (4): today's step query failed at 04:24, right after the
//   app came to the foreground.
// - FLUTTER-K, 1.1.0 (383): twelve PAST days of the energy-check backfill
//   failed in a row, one per second (the retry wait), 22 s after a cold
//   start in the foreground, while the newer days of the 21-day window read
//   fine.
// Both fit an interval without any step samples, which HealthKit's
// statistics query reports as an error instead of a zero sum: no steps
// since midnight at 04:24, no history before the step data begins. So a
// generic HealthKit error is only reported when the same interval does have
// step samples; a past day gets no retry (the backfill is best effort and
// tries again next session); today's read keeps its one retry for a
// briefly unreadable store.

final _now = DateTime(2026, 10, 4, 4, 24, 42);

HealthDataPoint _stepSample(DateTime at) => HealthDataPoint(
  uuid: 'sample-${at.millisecondsSinceEpoch}',
  value: NumericHealthValue(numericValue: 120),
  type: HealthDataType.STEPS,
  unit: HealthDataUnit.COUNT,
  dateFrom: at,
  dateTo: at.add(const Duration(minutes: 5)),
  sourcePlatform: HealthPlatformType.appleHealth,
  sourceDeviceId: 'device',
  sourceId: 'com.apple.health',
  sourceName: 'iPhone',
);

class _Health extends Health {
  final calls = <String>[];
  final List<Object> stepResults = [];
  Object? weightResult;

  /// Raw step samples HealthKit holds for the queried interval.
  List<HealthDataPoint> stepSamples = const [];

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
    if (types.contains(HealthDataType.STEPS)) {
      calls.add('stepSamples');
      return stepSamples;
    }
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

  group('today', () {
    test('a step error that clears after a short wait is not reported',
        () async {
      await withClock(Clock.fixed(_now), () async {
        plugin.stepResults.addAll([stepsError(), 4200]);

        expect((await service.readSnapshot())?.stepsToday, 4200);
        expect(plugin.calls.where((c) => c == 'steps'), hasLength(2));
        expect(waits, hasLength(1), reason: 'one short wait, then one retry');
        expect(reports, isEmpty);
      });
    });

    test('no step samples since midnight is no error (FLUTTER-H at 04:24)',
        () async {
      await withClock(Clock.fixed(_now), () async {
        plugin.stepResults.add(stepsError());

        expect(await service.readSnapshot(), isNull);
        expect(plugin.calls, contains('stepSamples'));
        expect(reports, isEmpty);
      });
    });

    test('a step error with samples in the interval is reported once',
        () async {
      await withClock(Clock.fixed(_now), () async {
        plugin.stepResults.add(stepsError());
        plugin.stepSamples = [_stepSample(DateTime(2026, 10, 4, 1))];

        expect(await service.readSnapshot(), isNull);
        expect(plugin.calls.where((c) => c == 'steps'), hasLength(2));
        expect(reports, ['health.readSteps']);
      });
    });
  });

  group('past days (energy-check backfill)', () {
    test('a day without step samples is no value: no retry, no report '
        '(FLUTTER-K, twelve days in a row)', () async {
      await withClock(Clock.fixed(_now), () async {
        plugin.stepResults.add(stepsError());

        for (var n = 1; n <= 12; n++) {
          expect(
            await service.readStepsOnDay(DateTime(2026, 10, 4 - n)),
            isNull,
          );
        }
        expect(plugin.calls.where((c) => c == 'steps'), hasLength(12),
            reason: 'one query per day, no retry');
        expect(waits, isEmpty, reason: 'no second-long wait per day');
        expect(reports, isEmpty);
      });
    });

    test('a day whose samples exist reports the failure, without retry',
        () async {
      await withClock(Clock.fixed(_now), () async {
        plugin.stepResults.add(stepsError());
        plugin.stepSamples = [_stepSample(DateTime(2026, 10, 3, 12))];

        expect(await service.readStepsOnDay(DateTime(2026, 10, 3)), isNull);
        expect(plugin.calls.where((c) => c == 'steps'), hasLength(1));
        expect(waits, isEmpty);
        expect(reports, ['health.readStepsOnDay']);
      });
    });

    test('a readable day keeps its steps', () async {
      await withClock(Clock.fixed(_now), () async {
        plugin.stepResults.add(7300);

        expect(await service.readStepsOnDay(DateTime(2026, 10, 3)), 7300);
        expect(reports, isEmpty);
      });
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
