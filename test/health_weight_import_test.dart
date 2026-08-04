import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:shiftfit/src/app/home_store.dart';
import 'package:shiftfit/src/services/health_service.dart';
import 'package:shiftfit/src/services/notification_service.dart';

// HealthKit-Gewichts-Import (2026-08-04): refreshHealthSteps() wertet jetzt
// auch snapshot.latestWeightKg aus und bietet den Wert per Snack-Aktion
// ("Übernehmen") zum Import an, statt ihn wegzuwerfen. Getestet wird:
//  * Angebot bei neuem Gewicht (auch wenn noch NIE gewogen wurde),
//  * In-Memory-Dedup: derselbe Wert wird nicht bei jedem Resume erneut
//    angeboten,
//  * 0.1-kg-Schwelle gegen das letzte geloggte Gewicht,
//  * importHealthWeight schreibt NICHT nach HealthKit zurueck (kein
//    Echo-Duplikat), logWeight dagegen schon,
//  * der Import aktualisiert weightLog und unterdrueckt damit von selbst
//    weitere Angebote desselben Werts.

/// Fake-HealthService: liefert einen kontrollierbaren Snapshot (Steps +
/// optionales Gewicht) und zaehlt writeWeight-Aufrufe.
class _FakeHealthService implements HealthService {
  int steps = 4200;
  double? nextWeightKg;
  int writeWeightCalls = 0;

  @override
  HealthAuthState get authState => HealthAuthState.granted;

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
}

/// Capture fuer den context-freien SnackEmitter des Stores: merkt sich
/// Nachricht + Aktion jedes Aufrufs, damit Tests Angebot und Aktions-Tap
/// pruefen koennen.
class _SnackCapture {
  final List<String> messages = <String>[];
  final List<SnackBarAction?> actions = <SnackBarAction?>[];

  void call(
    String message, {
    IconData icon = Icons.info_outline,
    Color accent = Colors.white,
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
    // Steps-Pfad bleibt unangetastet mit dabei.
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

    // Tap auf "Übernehmen" (die Page reicht onPressed 1:1 durch).
    s.snacks.actions.single!.onPressed();

    expect(s.store.weightLog.latest?.weightKg, 82.4);
    expect(s.health.writeWeightCalls, 0);

    // Naechster Resume mit unveraendertem HealthKit-Stand: weightLog.latest ==
    // kg, die 0.1-kg-Schwelle unterdrueckt das Angebot von selbst.
    await s.store.refreshHealthSteps();
    expect(s.snacks.messages, hasLength(1));
  });
}
