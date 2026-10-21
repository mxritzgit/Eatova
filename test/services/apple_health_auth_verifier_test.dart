import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
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
      // verifiedSnapshot reads the same verdict; the null snapshot of an
      // unverified state is pinned at the top of this file.
    });
  });

  // The Apple Health card per state. The Android Health Connect variant:
  // widgets/health_connect_card_test.dart.
  testWidgets('HealthConnectionCard: nur granted wirkt synchronisiert, '
      'unverified und denied bleiben handlungsfaehig', (tester) async {
    for (final (state, hint, action) in <(HealthAuthState, String, String?)>[
      (
        HealthAuthState.unverified,
        deL10n.profileHealthUnverifiedHint,
        deL10n.profileHealthActionCheck,
      ),
      (
        HealthAuthState.denied,
        deL10n.profileHealthDeniedHint,
        deL10n.profileHealthActionCheck,
      ),
      (
        HealthAuthState.unknown,
        deL10n.profileHealthSetupHint,
        deL10n.profileHealthActionConnect,
      ),
      (
        HealthAuthState.granted,
        deL10n.profileHealthSyncedAt(deL10n.profileHealthTimeJustNow),
        null,
      ),
    ]) {
      await pumpLocalized(
        tester,
        HealthConnectionCard(
          state: state,
          lastFetch: clock.now(),
          onConnect: () {},
          onRefresh: () {},
        ),
        safeArea: false,
      );

      final granted = state == HealthAuthState.granted;
      expect(find.byKey(const ValueKey('profile-health-refresh')),
          granted ? findsOneWidget : findsNothing,
          reason: '$state');
      expect(find.byKey(const ValueKey('profile-health-connect')),
          granted ? findsNothing : findsOneWidget,
          reason: '$state');
      if (action != null) {
        expect(find.text(action), findsOneWidget, reason: '$state');
      }
      expect(find.text(hint), findsOneWidget, reason: '$state');
    }
  });
}
