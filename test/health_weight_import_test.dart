import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';

// HealthKit weight import: refreshHealthSteps() also reads
// snapshot.latestWeightKg and offers it via a snack action. Covered:
//  * offer on a new weight, even with no prior log,
//  * in-memory dedup, so a resume does not re-offer the same value,
//  * 0.1 kg threshold against the last logged weight,
//  * importHealthWeight does not write back to HealthKit (no echo
//    duplicate), logWeight does,
//  * the import updates weightLog and thereby suppresses further offers.

/// Fake HealthService: controllable snapshot (steps + optional weight) and a
/// writeWeight call counter.
class _FakeHealthService implements HealthService {
  int steps = 4200;
  double? nextWeightKg;
  int writeWeightCalls = 0;

  @override
  HealthAuthState get authState => HealthAuthState.granted;

  @override
  void reset() {}

  @override
  Future<HealthAuthState> requestAuthorization() async =>
      HealthAuthState.granted;

  @override
  Future<HealthSnapshot?> readSnapshot() async => HealthSnapshot(
        stepsToday: steps,
        fetchedAt: DateTime.now(),
        latestWeightKg: nextWeightKg,
      );

  @override
  Future<bool> writeWeight(double kg, DateTime when) async {
    writeWeightCalls++;
    return true;
  }

  @override
  Future<List<WeightSample>> readWeightSamples({
    required DateTime from,
    required DateTime to,
  }) async =>
      const <WeightSample>[];

  @override
  Future<SleepSample?> readLastSleep({DateTime? before}) async => null;

  @override
  Future<int?> readStepsOnDay(DateTime day) async => null;
}

/// Capture for the store's context-free SnackEmitter: records message and
/// action per call so tests can check the offer and its tap.
class _SnackCapture {
  final List<String> messages = <String>[];
  final List<SnackBarAction?> actions = <SnackBarAction?>[];

  void call(
    String message, {
    IconData icon = Icons.info_outline,
    SnackTone tone = SnackTone.positive,
    Duration? duration,
    SnackBarAction? action,
  }) {
    messages.add(message);
    actions.add(action);
  }
}

({HomeStore store, _FakeHealthService health, _SnackCapture snacks}) _setup() {
  final health = _FakeHealthService();
  final snacks = _SnackCapture();
  final store = HomeStore(
    sync: null,
    health: health,
    notificationService: const NoopNotificationService(),
    initialUserName: 'Test',
    emitSnack: snacks.call,
  );
  return (store: store, health: health, snacks: snacks);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Snapshot-Gewicht ohne bisheriges Log -> Angebot mit deutschem Format',
      () async {
    final s = _setup();
    s.health.nextWeightKg = 82.4;

    await s.store.refreshHealthSteps();

    expect(s.snacks.messages, ['Apple Health: 82,4 kg übernehmen?']);
    expect(s.snacks.actions.single, isNotNull);
    expect(s.snacks.actions.single!.label, 'Übernehmen');
    // The steps path stays untouched.
    expect(s.store.dailySteps, 4200);
  });

  test('derselbe Wert wird bei erneutem Refresh (Resume) NICHT erneut angeboten',
      () async {
    final s = _setup();
    s.health.nextWeightKg = 82.4;

    await s.store.refreshHealthSteps();
    await s.store.refreshHealthSteps();

    expect(s.snacks.messages, hasLength(1),
        reason: 'In-Memory-Dedup: pro Wert nur ein Angebot');
  });

  test('ein NEUER Wert nach einem alten Angebot wird wieder angeboten',
      () async {
    final s = _setup();
    s.health.nextWeightKg = 82.4;
    await s.store.refreshHealthSteps();

    s.health.nextWeightKg = 81.2;
    await s.store.refreshHealthSteps();

    expect(s.snacks.messages, [
      'Apple Health: 82,4 kg übernehmen?',
      'Apple Health: 81,2 kg übernehmen?',
    ]);
  });

  test('Abweichung < 0.1 kg vom letzten geloggten Gewicht -> kein Angebot',
      () async {
    final s = _setup();
    s.store.logWeight(80.0);
    s.health.nextWeightKg = 80.05;

    await s.store.refreshHealthSteps();

    expect(s.snacks.messages, isEmpty);
  });

  test('Snapshot ohne Gewicht -> kein Angebot, Steps laufen normal', () async {
    final s = _setup();
    s.health.nextWeightKg = null;

    await s.store.refreshHealthSteps();

    expect(s.snacks.messages, isEmpty);
    expect(s.store.dailySteps, 4200);
  });

  test('importHealthWeight loggt OHNE HealthKit-Write-Back, logWeight MIT',
      () async {
    final s = _setup();

    s.store.importHealthWeight(82.4);
    expect(s.health.writeWeightCalls, 0,
        reason: 'Import aus HealthKit darf kein Echo-Duplikat zurueckschreiben');
    expect(s.store.weightLog.latest?.weightKg, 82.4);
    expect(s.store.lifetimeStats.weightLogs, 1);

    s.store.logWeight(81.0);
    expect(s.health.writeWeightCalls, 1,
        reason: 'manuelles Wiegen spiegelt weiterhin nach HealthKit');
    expect(s.store.weightLog.latest?.weightKg, 81.0);
  });

  test('Aktions-Tap importiert den Wert und unterdrueckt weitere Angebote',
      () async {
    final s = _setup();
    s.health.nextWeightKg = 82.4;
    await s.store.refreshHealthSteps();
    expect(s.snacks.actions.single, isNotNull);

    // Tap the action; the page forwards onPressed unchanged.
    s.snacks.actions.single!.onPressed();

    expect(s.store.weightLog.latest?.weightKg, 82.4);
    expect(s.health.writeWeightCalls, 0);

    // Next resume with unchanged HealthKit data: weightLog.latest == kg, so
    // the 0.1 kg threshold suppresses the offer.
    await s.store.refreshHealthSteps();
    expect(s.snacks.messages, hasLength(1));
  });
}
