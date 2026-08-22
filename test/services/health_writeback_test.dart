import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/services/health_service.dart';

// PROD-7 two-way health sync: tests the HealthService seam, NOT the real
// HealthKit channel (null/unsupported in tests). Off-iOS every method must
// no-op safely, and a recording fake proves the write payloads' shape.

class _RecordedWeight {
  const _RecordedWeight(this.kg, this.when);
  final double kg;
  final DateTime when;
}

/// Recording fake: keeps the write payloads, serves pre-fillable read data.
class _RecordingHealthService implements HealthService {
  HealthAuthState _state = HealthAuthState.granted;
  final List<_RecordedWeight> weightWrites = [];
  List<WeightSample> weightSamples = const [];
  SleepSample? lastSleep;
  bool writeReturns = true;

  @override
  HealthAuthState get authState => _state;

  @override
  void reset() => _state = HealthAuthState.unknown;

  @override
  Future<HealthAuthState> requestAuthorization() async {
    _state = HealthAuthState.granted;
    return _state;
  }

  @override
  Future<HealthSnapshot?> readSnapshot() async => HealthSnapshot(
        stepsToday: 4200,
        fetchedAt: DateTime(2026, 6, 4, 12),
        latestWeightKg:
            weightSamples.isEmpty ? null : weightSamples.last.kg,
        lastSleepMinutes: lastSleep?.minutesAsleep,
      );

  @override
  Future<bool> writeWeight(double kg, DateTime when) async {
    weightWrites.add(_RecordedWeight(kg, when));
    return writeReturns;
  }

  @override
  Future<List<WeightSample>> readWeightSamples({
    required DateTime from,
    required DateTime to,
  }) async =>
      weightSamples;

  @override
  Future<SleepSample?> readLastSleep({DateTime? before}) async => lastSleep;

  @override
  Future<int?> readStepsOnDay(DateTime day) async => null;
}

void main() {
  group('NoopHealthService (off-iOS + Test-Default ist sicher)', () {
    const noop = NoopHealthService();

    test('reports unsupported + readSnapshot null', () async {
      expect(noop.authState, HealthAuthState.unsupported);
      expect(await noop.requestAuthorization(), HealthAuthState.unsupported);
      expect(await noop.readSnapshot(), isNull);
    });

    test('writeWeight no-ops to false', () async {
      expect(await noop.writeWeight(80.5, DateTime(2026, 6, 4)), isFalse);
    });

    test('read groundwork no-ops to empty/null', () async {
      expect(
        await noop.readWeightSamples(
          from: DateTime(2026, 1, 1),
          to: DateTime(2026, 6, 4),
        ),
        isEmpty,
      );
      expect(await noop.readLastSleep(), isNull);
    });
  });

  group('Write-Back-Payloads (Seam korrekt geformt)', () {
    test('writeWeight reicht value + date 1:1 durch', () async {
      final svc = _RecordingHealthService();
      final when = DateTime(2026, 6, 4, 7, 30);

      final ok = await svc.writeWeight(79.3, when);

      expect(ok, isTrue);
      expect(svc.weightWrites, hasLength(1));
      expect(svc.weightWrites.single.kg, 79.3);
      expect(svc.weightWrites.single.when, when);
    });

    test('fehlgeschlagener Write wird als false durchgereicht', () async {
      final svc = _RecordingHealthService()..writeReturns = false;
      expect(await svc.writeWeight(80, DateTime(2026, 6, 4)), isFalse);
    });
  });

  group('Import-Groundwork (Snapshot fuehrt Health-Daten zurueck)', () {
    test('readSnapshot uebernimmt letztes Gewicht + Schlaf, wenn vorhanden',
        () async {
      final svc = _RecordingHealthService()
        ..weightSamples = [
          WeightSample(kg: 81.0, measuredAt: DateTime(2026, 6, 1)),
          WeightSample(kg: 80.2, measuredAt: DateTime(2026, 6, 3)),
        ]
        ..lastSleep =
            SleepSample(minutesAsleep: 462, end: DateTime(2026, 6, 4, 6, 30));

      final snap = await svc.readSnapshot();

      expect(snap, isNotNull);
      expect(snap!.stepsToday, 4200);
      // The latest sample wins.
      expect(snap.latestWeightKg, 80.2);
      expect(snap.lastSleepMinutes, 462);
    });

    test('readSnapshot ohne Health-Daten bleibt Steps-only (Felder null)',
        () async {
      final svc = _RecordingHealthService();
      final snap = await svc.readSnapshot();
      expect(snap, isNotNull);
      expect(snap!.stepsToday, 4200);
      expect(snap.latestWeightKg, isNull);
      expect(snap.lastSleepMinutes, isNull);
    });
  });
}
