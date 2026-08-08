import 'package:flutter_test/flutter_test.dart';
import 'package:health/health.dart';

import 'package:eatova/src/services/apple_health_service.dart';
import 'package:eatova/src/services/health_service.dart';

// Sentinel-Rest, Cluster B (Nachverifikation 2026-08-08):
// `requestAuthorization()` machte aus einem FEHLER die positive
// Geraete-Behauptung `unsupported` — und die Health-Karte versteckt bei
// `unsupported` den Verbinden-Button komplett („Auf diesem Geraet nicht
// aktiv", profile_widgets_actions.dart). Ein transienter Plugin-Fehler wurde
// damit zur Sackgasse ohne Rueckweg bis zum App-Neustart.
//
// Gleiche Klasse eine Zeile hoeher: Apples `success == false` heisst laut
// eigenem Kommentar „die Anfrage selbst ist gescheitert — kein Nutzer-Nein",
// wurde aber als `denied` uebernommen, das die Karte als „Zugriff entzogen —
// wieder freigeben" rendert und den Nutzer in die Einstellungen schickt, wo
// nichts zu finden ist.
//
// Neuer Vertrag: beide Fehlformen landen auf `unknown` — die Karte zeigt
// „Apple Health einrichten" mit Verbinden-Button, der Nutzer kann es einfach
// erneut versuchen, und der wahre Grund geht an den CrashReporter.
// `unsupported` bleibt dem einzigen echten Geraete-Fakt vorbehalten:
// Nicht-iOS-Plattform.

/// Implementiert nur die Aufrufe, die `requestAuthorization` wirklich macht.
/// Alles Uebrige wirft via noSuchMethod — die Evidenz-Leser im Service stehen
/// je in einem eigenen try/catch und werten das als „kein Signal", genau wie
/// ein fehlender Plattform-Kanal.
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
