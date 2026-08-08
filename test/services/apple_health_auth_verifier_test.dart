import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/services/apple_health_service.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/widgets/profile/profile_widgets.dart';

// REVIEW B3 — "verweigerte Berechtigung sieht aus wie 0 Schritte".
//
// Die drei Glieder der Kette (alle in health 13.3.1 nachgelesen):
//  1) hasPermission(type:access:) (HealthDataOperations.swift:91-105) gibt fuer
//     READ (case 0) und READ_WRITE (default) IMMER nil zurueck — nur WRITE
//     (case 1) liefert mit `status == .sharingAuthorized` einen echten Bool.
//  2) requestAuthorization reicht Apples `success` durch
//     (HealthDataOperations.swift:180-185). Das ist true, SOBALD das Sheet
//     fehlerfrei angezeigt wurde — auch wenn der Nutzer keinen einzigen
//     Schalter umgelegt hat.
//  3) getTotalStepsInInterval (HealthDataReader.swift:872-881) summiert eine
//     HKStatisticsCollectionQuery und liefert `Int(totalSteps)` — ohne
//     Leseberechtigung also 0, NIE null.
//
// Folge: "Sheet lief durch" darf nicht als granted gelten. [HealthAuthVerifier]
// leitet den Zustand stattdessen aus echten Signalen ab.

/// Kurzschreibweise fuer die Rohsignale eines Zugriffs.
HealthAuthEvidence _ev({
  bool? writeGrant,
  int? steps,
  double? latestWeightKg,
  int? sleepMinutes,
}) =>
    HealthAuthEvidence(
      writeGrant: writeGrant,
      steps: steps,
      latestWeightKg: latestWeightKg,
      sleepMinutes: sleepMinutes,
    );

void main() {
  group('HealthAuthVerifier — Sheet-Erfolg allein ist kein granted', () {
    test('Sheet gezeigt, nichts eingeschaltet -> unverified, nicht granted',
        () {
      final v = HealthAuthVerifier();

      // Genau das Szenario aus dem Review: WRITE ist wahrheitsgemaess aus,
      // Steps kommen als 0 zurueck (nicht null!), kein Gewicht, kein Schlaf.
      final state = v.resolve(
        _ev(writeGrant: false, steps: 0),
        now: DateTime(2026, 8, 8, 9),
      );

      expect(state, HealthAuthState.unverified);
      expect(state, isNot(HealthAuthState.granted));
    });

    test('unverifiziert -> readSnapshot-Ersatz liefert null statt 0 Schritte',
        () {
      final v = HealthAuthVerifier();

      final snap = v.verifiedSnapshot(
        _ev(writeGrant: false, steps: 0),
        now: DateTime(2026, 8, 8, 9),
      );

      // Kern des Fixes: KEIN Snapshot mit stepsToday: 0 — sonst rechnet der
      // Food-Tab burnedKcal = 0 und adjustedGoal = goal + 0, dauerhaft still.
      expect(snap, isNull);
    });

    test('echte Schritte -> granted, Snapshot traegt die Zahl', () {
      final v = HealthAuthVerifier();
      final now = DateTime(2026, 8, 8, 18);

      final snap = v.verifiedSnapshot(_ev(writeGrant: false, steps: 9812),
          now: now);

      expect(v.state, HealthAuthState.granted);
      expect(snap, isNotNull);
      expect(snap!.stepsToday, 9812);
      expect(snap.fetchedAt, now);
    });

    test('nur Gewichtsprobe (0 Schritte) reicht als Lese-Beweis', () {
      final v = HealthAuthVerifier();
      expect(
        v.resolve(_ev(writeGrant: false, steps: 0, latestWeightKg: 80.2),
            now: DateTime(2026, 8, 8)),
        HealthAuthState.granted,
      );
    });

    test('nur Schlafprobe (0 Schritte) reicht als Lese-Beweis', () {
      final v = HealthAuthVerifier();
      expect(
        v.resolve(_ev(writeGrant: false, steps: 0, sleepMinutes: 431),
            now: DateTime(2026, 8, 8)),
        HealthAuthState.granted,
      );
    });
  });

  group('HealthAuthVerifier — echter Ruhetag ist kein Fehlalarm', () {
    test('WRITE wahrheitsgemaess erteilt -> 0 Schritte bleiben granted', () {
      final v = HealthAuthVerifier();

      // Nutzer hat im Sheet alles eingeschaltet: WRITE (Gewicht) meldet
      // truthful true. Telefon lag zuhause -> 0 Schritte, nicht gewogen,
      // kein Schlaf getrackt. Das ist KEIN Berechtigungsproblem.
      final state = v.resolve(
        _ev(writeGrant: true, steps: 0),
        now: DateTime(2026, 8, 8, 22),
      );

      expect(state, HealthAuthState.granted);
    });

    test('nur-LESEN-Nutzer: Ruhetag nach frischer Evidenz bleibt granted', () {
      final v = HealthAuthVerifier();

      // Gestern kamen echte Schritte an (WRITE hat er nie freigegeben).
      v.resolve(_ev(writeGrant: false, steps: 7400),
          now: DateTime(2026, 8, 7, 20));

      // Heute Ruhetag: 0 Schritte, nichts sonst.
      final state = v.resolve(
        _ev(writeGrant: false, steps: 0),
        now: DateTime(2026, 8, 8, 20),
      );

      expect(state, HealthAuthState.granted,
          reason: 'ein einzelner 0-Schritte-Tag darf die Verifikation nicht '
              'kippen');
    });
  });

  group('HealthAuthVerifier — Verfall nach nachtraeglichem Entzug', () {
    test('WRITE war erteilt und ist weg -> denied (wahrheitsgemaesser Entzug)',
        () {
      final v = HealthAuthVerifier();
      v.resolve(_ev(writeGrant: true, steps: 6000),
          now: DateTime(2026, 8, 7, 20));

      final state = v.resolve(
        _ev(writeGrant: false, steps: 0),
        now: DateTime(2026, 8, 8, 20),
      );

      expect(state, HealthAuthState.denied);
    });

    test('denied bleibt denied, solange WRITE aus bleibt', () {
      final v = HealthAuthVerifier();
      v.resolve(_ev(writeGrant: true, steps: 6000), now: DateTime(2026, 8, 7));
      v.resolve(_ev(writeGrant: false, steps: 0), now: DateTime(2026, 8, 8));

      expect(
        v.resolve(_ev(writeGrant: false, steps: 0), now: DateTime(2026, 8, 9)),
        HealthAuthState.denied,
      );
    });

    test('LESEN laeuft weiter, obwohl WRITE entzogen wurde -> granted', () {
      final v = HealthAuthVerifier();
      v.resolve(_ev(writeGrant: true, steps: 6000), now: DateTime(2026, 8, 7));

      expect(
        v.resolve(_ev(writeGrant: false, steps: 8100),
            now: DateTime(2026, 8, 8)),
        HealthAuthState.granted,
        reason: 'echte Lesedaten schlagen den WRITE-Entzug',
      );
    });

    test('nur-LESEN-Entzug: Evidenz verfaellt nach TTL -> unverified', () {
      final v = HealthAuthVerifier(evidenceTtl: const Duration(days: 3));
      v.resolve(_ev(writeGrant: false, steps: 7400),
          now: DateTime(2026, 8, 1, 20));

      // Nutzer nimmt am 2.8. in den iOS-Einstellungen den Lesezugriff weg.
      // Vier Tage lang kommen nur noch 0-Schritte-Antworten.
      final state = v.resolve(
        _ev(writeGrant: false, steps: 0),
        now: DateTime(2026, 8, 5, 20),
      );

      expect(state, HealthAuthState.unverified);
    });

    test('unverifiziert nach Verfall -> Snapshot ist wieder null', () {
      final v = HealthAuthVerifier(evidenceTtl: const Duration(days: 3));
      v.resolve(_ev(writeGrant: false, steps: 7400), now: DateTime(2026, 8, 1));

      expect(
        v.verifiedSnapshot(_ev(writeGrant: false, steps: 0),
            now: DateTime(2026, 8, 5)),
        isNull,
      );
    });
  });

  group('HealthConnectionCard — unverifiziert bleibt handlungsfaehig', () {
    Future<void> pumpCard(WidgetTester tester, HealthAuthState state) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HealthConnectionCard(
              state: state,
              lastFetch: DateTime.now(),
              onConnect: () {},
              onRefresh: () {},
            ),
          ),
        ),
      );
    }

    testWidgets('unverified zeigt KEIN "Synchronisiert" und keinen Refresh',
        (tester) async {
      await pumpCard(tester, HealthAuthState.unverified);

      expect(find.textContaining('Synchronisiert'), findsNothing);
      expect(find.byKey(const ValueKey('profile-health-refresh')), findsNothing);
    });

    testWidgets('unverified bietet weiter einen Aktions-Button an',
        (tester) async {
      await pumpCard(tester, HealthAuthState.unverified);

      expect(find.byKey(const ValueKey('profile-health-connect')),
          findsOneWidget);
      expect(find.text('Prüfen'), findsOneWidget);
    });

    testWidgets('unverified fuehrt zum iOS-Datenzugriff, nicht nur "Fehler"',
        (tester) async {
      await pumpCard(tester, HealthAuthState.unverified);

      final subtitle = tester.widget<Text>(
        find.textContaining('Datenzugriff'),
      );
      expect(subtitle.data, contains('Keine Daten'));
      expect(subtitle.data, contains('Einstellungen'));
      expect(subtitle.data, contains('Health'));
    });

    testWidgets('granted zeigt weiterhin Refresh + Synchronisiert',
        (tester) async {
      await pumpCard(tester, HealthAuthState.granted);

      expect(find.byKey(const ValueKey('profile-health-refresh')),
          findsOneWidget);
      expect(find.textContaining('Synchronisiert'), findsOneWidget);
      expect(find.byKey(const ValueKey('profile-health-connect')), findsNothing);
    });

    testWidgets('denied bleibt eigenstaendig sichtbar (jetzt erreichbar)',
        (tester) async {
      await pumpCard(tester, HealthAuthState.denied);

      expect(find.byKey(const ValueKey('profile-health-connect')),
          findsOneWidget);
      expect(find.textContaining('entzogen'), findsOneWidget);
    });

    testWidgets('unknown zeigt weiterhin "Verbinden"', (tester) async {
      await pumpCard(tester, HealthAuthState.unknown);

      expect(find.text('Verbinden'), findsOneWidget);
    });
  });
}
