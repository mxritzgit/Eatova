import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/services/apple_health_service.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/widgets/profile/profile_widgets.dart';

import '../support/harness.dart';

// REVIEW B3 — "denied permission looks like 0 steps": hasPermission returns
// nil for READ, `requestAuthorization` succeeds once the sheet was shown, and
// getTotalStepsInInterval returns 0 rather than null without permission. So
// "the sheet ran" must not count as granted.

/// Shorthand for the raw signals of one access.
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
  group('HealthAuthVerifier — Sheet-Erfolg allein ist kein granted', () {
    test('Sheet gezeigt, nichts eingeschaltet -> unverified, nicht granted',
        () {
      final v = HealthAuthVerifier();

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

      // No snapshot with stepsToday 0, or the food tab silently burns 0.
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

    // The sleep probe is gone: Apple rejects scopes without observable use.
  });

  group('HealthAuthVerifier — echter Ruhetag ist kein Fehlalarm', () {
    test('WRITE erteilt, aber schon einmal Lesedaten -> Ruhetag bleibt granted',
        () {
      final v = HealthAuthVerifier();

      v.resolve(_ev(writeGrant: true, steps: 6100),
          now: DateTime(2026, 8, 7, 22));

      // Rest day -> 0 steps. NOT a permission problem.
      final state = v.resolve(
        _ev(writeGrant: true, steps: 0),
        now: DateTime(2026, 8, 8, 22),
      );

      expect(state, HealthAuthState.granted);
    });

    // Review 2026-08-19: WRITE alone -> granted was the finding — the sheet
    // separates write and read, so a write-only grant means 0 steps forever.

    test('nur-LESEN-Nutzer: Ruhetag nach frischer Evidenz bleibt granted', () {
      final v = HealthAuthVerifier();

      v.resolve(_ev(writeGrant: false, steps: 7400),
          now: DateTime(2026, 8, 7, 20));

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
    // `AppTokens.of` throws without the ThemeExtension and
    // HealthConnectionCard reads context.l10n — both come from the harness.
    Future<void> pumpCard(WidgetTester tester, HealthAuthState state) =>
        pumpLocalized(
          tester,
          HealthConnectionCard(
            state: state,
            lastFetch: DateTime.now(),
            onConnect: () {},
            onRefresh: () {},
          ),
          reducedMotion: false,
          safeArea: false,
        );

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
