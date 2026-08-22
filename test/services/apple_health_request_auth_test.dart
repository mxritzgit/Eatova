import 'package:flutter_test/flutter_test.dart';
import 'package:health/health.dart';

import 'package:eatova/src/services/apple_health_service.dart';
import 'package:eatova/src/services/health_service.dart';

// Sentinel remainder, cluster B (2026-08-08). `requestAuthorization()` turned
// an ERROR into `unsupported`, which hides the connect button, and Apple's
// `success == false` ("the request failed", not a user "no") into `denied`.
//
// New contract: both failure shapes land on `unknown`, so the card offers a
// retry. `unsupported` is reserved for the one device fact: non-iOS.

/// Implements only what `requestAuthorization` calls; the rest throws via
/// noSuchMethod, which the service's try/catch reads as "no signal".
class _FakeHealth implements Health {
  _FakeHealth({this.configureError, this.sheetShown = true, this.steps});

  final Object? configureError;
  final bool sheetShown;
  final int? steps;

  @override
  Future<void> configure() async {
    final err = configureError;
    if (err != null) throw err;
  }

  @override
  Future<bool> requestAuthorization(List<HealthDataType> types,
          {List<HealthDataAccess>? permissions}) async =>
      sheetShown;

  @override
  Future<bool?> hasPermissions(List<HealthDataType> types,
          {List<HealthDataAccess>? permissions}) async =>
      null;

  @override
  Future<int?> getTotalStepsInInterval(DateTime startTime, DateTime endTime,
          {bool includeManualEntry = true}) async =>
      steps;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('nicht Teil des requestAuthorization-Pfads');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Plugin-Fehler beim Anfordern -> unknown, NICHT unsupported', () async {
    final service = AppleHealthService(
      health: _FakeHealth(configureError: StateError('Kanal kaputt')),
      debugIsIOS: true,
    );

    expect(await service.requestAuthorization(), HealthAuthState.unknown,
        reason: 'unsupported versteckt den Verbinden-Button dauerhaft — ein '
            'Fehler ist kein Geraete-Fakt und braucht einen Rueckweg');
    expect(service.authState, HealthAuthState.unknown);
  });

  test('Sheet-Aufruf scheitert (success=false) -> unknown, NICHT denied',
      () async {
    final service = AppleHealthService(
      health: _FakeHealth(sheetShown: false),
      debugIsIOS: true,
    );

    expect(await service.requestAuthorization(), HealthAuthState.unknown,
        reason: 'Apples false heisst „Anfrage gescheitert", nicht '
            '„Nutzer-Nein" — `denied` schickte den Nutzer in die '
            'Einstellungen, wo nichts zu finden ist');
  });

  test('Kontrolle: echte Schritt-Evidenz -> granted', () async {
    final service = AppleHealthService(
      health: _FakeHealth(steps: 5000),
      debugIsIOS: true,
    );

    expect(await service.requestAuthorization(), HealthAuthState.granted);
  });

  test('Nicht-iOS bleibt ehrlich unsupported (der echte Geraete-Fakt)',
      () async {
    final service = AppleHealthService(
      health: _FakeHealth(),
      debugIsIOS: false,
    );

    expect(await service.requestAuthorization(), HealthAuthState.unsupported);
  });
}
