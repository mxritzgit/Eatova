// Correcting weigh-ins in Apple Health (review 2026-10-19): only the weight
// sample Eatova wrote at a weigh-in's moment is deleted, by its UUID; a
// scale's sample in the same second stays, and a failed read deletes
// nothing and reports false.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health/health.dart';

import 'package:eatova/src/services/apple_health_service.dart';
import 'package:eatova/src/services/crash_reporter.dart';

const _own = 'com.eatova.app';
final _at = DateTime(2026, 10, 19, 7, 30);

HealthDataPoint _weight(String uuid, String source, DateTime at) =>
    HealthDataPoint(
      uuid: uuid,
      value: NumericHealthValue(numericValue: 80),
      type: HealthDataType.WEIGHT,
      unit: HealthDataUnit.KILOGRAM,
      dateFrom: at,
      dateTo: at,
      sourcePlatform: HealthPlatformType.appleHealth,
      sourceDeviceId: 'device',
      sourceId: source,
      sourceName: source,
    );

class _Health extends Health {
  List<HealthDataPoint> points = const [];
  Object? readError;
  final deleted = <String>[];
  (DateTime, DateTime)? window;

  @override
  Future<void> configure() async {}

  @override
  Future<List<HealthDataPoint>> getHealthDataFromTypes({
    required List<HealthDataType> types,
    Map<HealthDataType, HealthDataUnit>? preferredUnits,
    required DateTime startTime,
    required DateTime endTime,
    List<RecordingMethod> recordingMethodsToFilter = const [],
  }) async {
    expect(types, [HealthDataType.WEIGHT]);
    window = (startTime, endTime);
    final error = readError;
    if (error != null) throw error;
    return points;
  }

  @override
  Future<bool> deleteByUUID({required String uuid, HealthDataType? type}) async {
    expect(type, HealthDataType.WEIGHT);
    deleted.add(uuid);
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Health plugin;
  late AppleHealthService service;

  setUp(() {
    plugin = _Health();
    service = AppleHealthService(
      health: plugin,
      debugIsIOS: true,
      ownSourceId: () async => _own,
    );
    CrashReporter.debugSentrySink = (_, _, _) {};
    addTearDown(() => CrashReporter.debugSentrySink = null);
  });

  test("deletes only Eatova's own sample at the moment", () async {
    plugin.points = [
      _weight('own', _own, _at),
      _weight('scale', 'com.withings.wiscale2', _at),
      _weight('own-other-day', _own, _at.subtract(const Duration(days: 1))),
    ];

    expect(await service.deleteOwnWeight(_at), isTrue);

    expect(plugin.deleted, ['own']);
    expect(plugin.window, (
      _at.subtract(const Duration(seconds: 1)),
      _at.add(const Duration(seconds: 1)),
    ));
  });

  test("a scale's sample alone is no own sample", () async {
    plugin.points = [_weight('scale', 'com.withings.wiscale2', _at)];

    expect(await service.deleteOwnWeight(_at), isFalse);
    expect(plugin.deleted, isEmpty);
  });

  test('a failed read deletes nothing', () async {
    plugin.readError = PlatformException(code: 'HEALTH_ERROR');

    expect(await service.deleteOwnWeight(_at), isFalse);
    expect(plugin.deleted, isEmpty);
  });

  test('without a known own source nothing is deleted', () async {
    service = AppleHealthService(
      health: plugin,
      debugIsIOS: true,
      ownSourceId: () async => null,
    );
    plugin.points = [_weight('own', _own, _at)];

    expect(await service.deleteOwnWeight(_at), isFalse);
    expect(plugin.deleted, isEmpty);
  });

  test('off iOS it is a no-op', () async {
    service = AppleHealthService(
      health: plugin,
      debugIsIOS: false,
      ownSourceId: () async => _own,
    );
    plugin.points = [_weight('own', _own, _at)];

    expect(await service.deleteOwnWeight(_at), isFalse);
    expect(plugin.window, isNull);
  });
}
