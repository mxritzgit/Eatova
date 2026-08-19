import 'package:flutter_test/flutter_test.dart';
import 'package:health/health.dart';

import 'package:eatova/src/services/apple_health_service.dart';
import 'package:eatova/src/services/health_service.dart';

// Komplettreview 2026-08-19, zwei Funde am Health-Pfad:
//
// FUND 1 (Release-Blocker) — der SLEEP-Scope wurde angefragt und gelesen, aber
// von keinem Feature genutzt: `HealthSnapshot.lastSleepMinutes` kam in ganz
// lib/ nur in den beiden Health-Dateien vor, `refreshHealthSteps` liest aus
// dem Snapshot ausschliesslich `stepsToday` und `latestWeightKg`. Der
// Zwecktext in Info.plist versprach trotzdem einen Nutzen. Apple lehnt
// HealthKit-Scopes ohne beobachtbares Feature im Review ab (Guideline 5.1.1).
//
// FUND 2 — eine reine SCHREIB-Freigabe galt als Lese-Beweis. Das HealthKit-
// Sheet fuehrt „Schreiben erlauben" und „Lesen erlauben" als zwei unabhaengige
// Abschnitte: wer nur den Gewichts-Schreibschalter umlegte, war laut Verifier
// `granted` und bekam dauerhaft 0 Schritte unter einem gruenen
// „Synchronisiert".

/// Zeichnet auf, welche Scopes angefragt und welche Typen tatsaechlich
/// abgefragt werden. Alles Uebrige wirft via noSuchMethod — die Evidenz-Leser
/// im Service stehen je in einem eigenen try/catch (Muster aus
/// apple_health_request_auth_test).
class _RecordingHealth implements Health {
  _RecordingHealth({this.steps, this.writeGrant});

  final int? steps;
  final bool? writeGrant;

  /// Ein Eintrag je `requestAuthorization`-Aufruf, jeweils die volle Liste.
  final List<List<HealthDataType>> requestedTypes = [];
  final List<List<HealthDataAccess>?> requestedPermissions = [];

  /// Jeder Typ, fuer den wirklich Daten gelesen wurden.
  final List<HealthDataType> queriedTypes = [];

  @override
  Future<void> configure() async {}

  @override
  Future<bool> requestAuthorization(List<HealthDataType> types,
      {List<HealthDataAccess>? permissions}) async {
    requestedTypes.add(types);
    requestedPermissions.add(permissions);
    return true;
  }

  @override
  Future<bool?> hasPermissions(List<HealthDataType> types,
          {List<HealthDataAccess>? permissions}) async =>
      writeGrant;

  @override
  Future<int?> getTotalStepsInInterval(DateTime startTime, DateTime endTime,
          {bool includeManualEntry = true}) async =>
      steps;

  @override
  Future<List<HealthDataPoint>> getHealthDataFromTypes({
    required List<HealthDataType> types,
    Map<HealthDataType, HealthDataUnit>? preferredUnits,
    required DateTime startTime,
    required DateTime endTime,
    List<RecordingMethod> recordingMethodsToFilter = const [],
  }) async {
    queriedTypes.addAll(types);
    return const <HealthDataPoint>[];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('nicht Teil des geprueften Pfads');
}

/// Kurzschreibweise fuer die Rohsignale eines Zugriffs.
HealthAuthEvidence _ev({
  bool? writeGrant,
  int? steps,
  double? latestWeightKg,
}) =>
    HealthAuthEvidence(
      writeGrant: writeGrant,
      steps: steps,
      latestWeightKg: latestWeightKg,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Fund 1 — kein SLEEP-Scope mehr', () {
    test('das Berechtigungs-Sheet fragt Schlaf nicht mehr an', () async {
      final fake = _RecordingHealth(steps: 4200);
      final service = AppleHealthService(health: fake, debugIsIOS: true);

      await service.requestAuthorization();

      final types = fake.requestedTypes.single;
      expect(types, isNot(contains(HealthDataType.SLEEP_ASLEEP)),
          reason: 'ein Scope, den kein Feature liest, kostet die Freigabe im '
              'App Review');
      expect(types,
          containsAll(const [HealthDataType.STEPS, HealthDataType.WEIGHT]));
    });

    test('Typen und Permissions bleiben parallele Listen', () async {
      final fake = _RecordingHealth(steps: 4200);
      final service = AppleHealthService(health: fake, debugIsIOS: true);

      await service.requestAuthorization();

      final types = fake.requestedTypes.single;
      final permissions = fake.requestedPermissions.single;
      expect(permissions, isNotNull);
      expect(permissions!.length, types.length,
          reason: 'package:health erwartet permissions[i] passend zu types[i] '
              '— verrutscht die Liste, autorisiert der Dialog still das '
              'Falsche');
      expect(permissions[types.indexOf(HealthDataType.STEPS)],
          HealthDataAccess.READ);
      expect(permissions[types.indexOf(HealthDataType.WEIGHT)],
          HealthDataAccess.READ_WRITE,
          reason: 'Gewicht bleibt READ_WRITE: Import vorbefuellen + Write-Back '
              'nach dem Wiegen');
    });

    test('der Evidenz-Sammler liest keine Schlafdaten mehr', () async {
      final fake = _RecordingHealth(steps: 0, writeGrant: false);
      final service = AppleHealthService(health: fake, debugIsIOS: true);

      await service.requestAuthorization();

      expect(fake.queriedTypes, isNot(contains(HealthDataType.SLEEP_ASLEEP)),
          reason: 'auf einen nie angefragten Scope darf die App auch nicht '
              'zugreifen');
      expect(fake.queriedTypes, contains(HealthDataType.WEIGHT),
          reason: 'der Gewichts-Lesepfad ist der verbliebene zweite '
              'Evidenz-Traeger und muss laufen');
    });

    test('Lese-Beweis stuetzt sich nur noch auf Schritte und Gewicht', () {
      expect(_ev(writeGrant: true, steps: 0).hasReadEvidence, isFalse);
      expect(_ev(writeGrant: false, steps: 12).hasReadEvidence, isTrue);
      expect(
        _ev(writeGrant: false, steps: 0, latestWeightKg: 81.4).hasReadEvidence,
        isTrue,
      );
    });
  });

  group('Fund 2 — reine Schreib-Freigabe ist kein Lese-Beweis', () {
    test('nur WRITE eingeschaltet, nie Daten gesehen -> unverified', () {
      final v = HealthAuthVerifier();

      final state = v.resolve(
        _ev(writeGrant: true, steps: 0),
        now: DateTime(2026, 8, 19, 21),
      );

      expect(state, HealthAuthState.unverified,
          reason: 'das Sheet trennt Schreiben und Lesen — der Schreibschalter '
              'sagt nichts darueber, ob Schritte ankommen');
    });

    test('nur WRITE eingeschaltet -> Snapshot bleibt null statt 0 Schritte',
        () {
      final v = HealthAuthVerifier();

      final snap = v.verifiedSnapshot(
        _ev(writeGrant: true, steps: 0),
        now: DateTime(2026, 8, 19, 21),
      );

      // Sonst rechnet der Food-Tab dauerhaft burnedKcal = 0 und
      // adjustedGoal = goal + 0, waehrend die Profilkarte „Synchronisiert"
      // zeigt.
      expect(snap, isNull);
    });

    test('Kontrolle: echte Schritte -> granted, auch ohne WRITE', () {
      final v = HealthAuthVerifier();

      expect(
        v.resolve(_ev(writeGrant: false, steps: 9812),
            now: DateTime(2026, 8, 19)),
        HealthAuthState.granted,
      );
    });

    test('Ruhetag nach echter Evidenz bleibt granted (auch mit WRITE)', () {
      final v = HealthAuthVerifier();
      v.resolve(_ev(writeGrant: true, steps: 7400),
          now: DateTime(2026, 8, 18, 20));

      expect(
        v.resolve(_ev(writeGrant: true, steps: 0),
            now: DateTime(2026, 8, 19, 20)),
        HealthAuthState.granted,
        reason: 'ein einzelner 0-Schritte-Tag darf die Verifikation nicht '
            'kippen',
      );
    });

    test('Lesezugriff entzogen, WRITE bleibt an -> verfaellt nach TTL', () {
      final v = HealthAuthVerifier(evidenceTtl: const Duration(days: 3));
      v.resolve(_ev(writeGrant: true, steps: 7400), now: DateTime(2026, 8, 1));

      // Nutzer nimmt in den iOS-Einstellungen NUR den Lesezugriff weg und
      // laesst den Gewichts-Schreibschalter an: der Share-Status bleibt true,
      // es kommen aber nie wieder Daten an.
      final state = v.resolve(
        _ev(writeGrant: true, steps: 0),
        now: DateTime(2026, 8, 6),
      );

      expect(state, HealthAuthState.unverified,
          reason: 'sonst haelt der Schreibschalter den granted-Zustand '
              'unbegrenzt am Leben');
    });

    test('WRITE-Entzug bleibt der harte denied-Beweis', () {
      final v = HealthAuthVerifier();
      v.resolve(_ev(writeGrant: true, steps: 6000), now: DateTime(2026, 8, 18));

      expect(
        v.resolve(_ev(writeGrant: false, steps: 0), now: DateTime(2026, 8, 19)),
        HealthAuthState.denied,
      );
    });

    test('Ende zu Ende: Connect mit reiner Schreib-Freigabe ist nicht granted',
        () async {
      // hasPermissions meldet den wahrheitsgemaessen Share-Status true,
      // Schritte kommen als 0 zurueck (nicht null!), Gewichtsabfrage leer —
      // exakt der Nutzer, der im Sheet nur „Gewicht schreiben" umgelegt hat.
      final fake = _RecordingHealth(steps: 0, writeGrant: true);
      final service = AppleHealthService(health: fake, debugIsIOS: true);

      final state = await service.requestAuthorization();

      expect(state, HealthAuthState.unverified);
      expect(service.authState, HealthAuthState.unverified,
          reason: 'die Profilkarte darf hier nicht „Synchronisiert" zeigen');
    });
  });
}
