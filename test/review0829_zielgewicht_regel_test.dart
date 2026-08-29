// Die EINE Regel zwischen Wunschgewicht und Gewichtsziel — und was sie an den
// drei Stellen bedeutet, die sie lesen.
//
//   * P9-08b — sie stand nach Welle 1 doppelt da: als Picker-Fenster im
//     Onboarding (`_targetMin`/`_targetMax`) und als Feldpruefung auf der
//     Ziele-Seite (`_targetWeightError`). Gleiche Schwellen, kein Bezug
//     zueinander — zwei Kopien driften. Sie liegt jetzt in `user_profile.dart`.
//   * P9-08c — die Plan-Karte waehlte das Richtungs-Icon allein ueber
//     `goal.isGain` und zeichnete deshalb "80 → 90" unter `trending_down`,
//     solange ein Altprofil den Widerspruch trug.
//   * P9-08d — geheilt wurde er nirgends: kein Migrationsschritt, keine Heilung
//     beim Laden. `withEffectiveWeightGoal` ist jetzt der eine Punkt dafuer;
//     die Ziele-Seite ruft ihn, `ProfileSync.load`/`applyLiveGoals` noch nicht
//     (Fremdbedarf, unten festgehalten).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/model_limits.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/widgets/profile/profile_widgets.dart';

import 'support/harness.dart';

/// Alle Ziele mit Richtung, je Richtung eines — die Paces unterscheiden sich
/// fuer diese Regel nicht.
const _abnehmen = WeightGoal.lose05kg;
const _zunehmen = WeightGoal.gain025kg;

Future<void> _pumpKarte(WidgetTester tester, UserProfile profile) async {
  tester.view.devicePixelRatio = 3.0;
  tester.view.physicalSize = const Size(402, 900) * 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await pumpLocalized(
    tester,
    GoalPlanCard(profile: profile),
    padding: const EdgeInsets.all(20),
    safeArea: false,
  );
  await tester.pumpAndSettle();
}

IconData _planIcon(WidgetTester tester) => tester
    .widget<Icon>(
      find.descendant(
        of: find.byType(GoalPlanCard),
        matching: find.byIcon(Icons.trending_down_rounded).evaluate().isNotEmpty
            ? find.byIcon(Icons.trending_down_rounded)
            : find.byIcon(Icons.trending_up_rounded),
      ),
    )
    .icon!;

void main() {
  // =========================================================================
  // P9-08b — eine Regel, keine zweite Kopie
  // =========================================================================
  group('isConsistentTargetWeight: die Regel selbst', () {
    test('Abnehmen zielt UNTER das heutige Gewicht', () {
      expect(isConsistentTargetWeight(_abnehmen, 80, 79), isTrue);
      expect(isConsistentTargetWeight(_abnehmen, 80, 80), isFalse,
          reason: 'ziel == gewicht ist keine Richtung');
      expect(isConsistentTargetWeight(_abnehmen, 80, 81), isFalse);
    });

    test('Zunehmen zielt UEBER das heutige Gewicht', () {
      expect(isConsistentTargetWeight(_zunehmen, 80, 81), isTrue);
      expect(isConsistentTargetWeight(_zunehmen, 80, 80), isFalse);
      expect(isConsistentTargetWeight(_zunehmen, 80, 79), isFalse);
    });

    test('Halten hat keine Richtung und widerspricht deshalb nie', () {
      for (final ziel in <int>[30, 79, 80, 81, 300]) {
        expect(isConsistentTargetWeight(WeightGoal.maintain, 80, ziel), isTrue);
        expect(hasReachedTargetWeight(WeightGoal.maintain, 80, ziel), isFalse,
            reason: 'ohne Richtung gibt es auch nichts zu erreichen');
      }
    });

    test('erreicht ist derselbe Zustand von der anderen Seite', () {
      for (final gewicht in <int>[30, 60, 80, 300]) {
        for (final ziel in <int>[30, 59, 80, 81, 300]) {
          for (final ziel2 in <WeightGoal>[_abnehmen, _zunehmen]) {
            expect(
              hasReachedTargetWeight(ziel2, gewicht, ziel),
              !isConsistentTargetWeight(ziel2, gewicht, ziel),
              reason: '$ziel2 bei $gewicht kg, Ziel $ziel kg',
            );
          }
        }
      }
    });

    test('das Fenster bleibt in der DB-Spalte, ausser es kippt am Rand', () {
      // Abnehmen: 30 … gewicht-1, Zunehmen: gewicht+1 … 300.
      expect(targetWeightMinFor(_abnehmen, 80), ProfileLimits.targetWeightKgMin);
      expect(targetWeightMaxFor(_abnehmen, 80), 79);
      expect(targetWeightMinFor(_zunehmen, 80), 81);
      expect(targetWeightMaxFor(_zunehmen, 80), ProfileLimits.targetWeightKgMax);

      // Am Spaltenrand kippt das Fenster — dokumentiert, nicht wegdefiniert:
      // bei 300 kg gibt es kein konsistentes Zunehm-Ziel mehr.
      expect(
        targetWeightMinFor(_zunehmen, ProfileLimits.targetWeightKgMax),
        greaterThan(targetWeightMaxFor(_zunehmen, ProfileLimits.targetWeightKgMax)),
      );
      expect(
        isConsistentTargetWeight(_zunehmen, 300, 300),
        isFalse,
        reason: 'ueber 300 kg endet die Spalte, nicht die Regel',
      );
    });

    test('keine der beiden Seiten rechnet die Schwelle noch selbst aus', () {
      // Das ist der Punkt von P9-08b: nicht dass die Zahlen heute gleich sind,
      // sondern dass es nur noch EINE Stelle gibt, an der sie stehen.
      const dateien = <String>[
        'lib/src/screens/onboarding_screen.dart',
        'lib/src/screens/settings/goals_screen.dart',
      ];
      for (final pfad in dateien) {
        final quelle = File(pfad).readAsStringSync();
        final code = quelle
            .split('\n')
            .where((z) => !z.trimLeft().startsWith('//'))
            .join('\n');
        expect(
          code,
          isNot(contains('_weight + 1')),
          reason: '$pfad buchstabiert die Zunehm-Schwelle selbst',
        );
        expect(
          code,
          isNot(contains('_weight - 1')),
          reason: '$pfad buchstabiert die Abnehm-Schwelle selbst',
        );
        expect(
          code,
          anyOf(
            contains('targetWeightMinFor'),
            contains('hasReachedTargetWeight'),
          ),
          reason: '$pfad liest die Regel nicht aus user_profile.dart',
        );
      }
    });
  });

  // =========================================================================
  // P9-08d — die Heilung des Bestandsprofils
  // =========================================================================
  group('withEffectiveWeightGoal: der eine Heilungspunkt', () {
    test('ein widerspruchsfreies Profil bleibt dieselbe Instanz', () {
      const gesund = UserProfile(
        weightKg: 80,
        targetWeightKg: 75,
        weightGoal: _abnehmen,
      );
      expect(identical(gesund.withEffectiveWeightGoal, gesund), isTrue,
          reason: 'Aufrufer entscheiden per identical ueber den Rueckschreiber');
    });

    test('das Altprofil aus dem Befund faellt auf Halten zurueck', () {
      // 80 kg auf Defizit-Plan mit Ziel 90 kg — genau die Zeile, die als
      // "Körpergewicht: 80 kg (Ziel 90 kg)." in den Coach-Kontext lief.
      const alt = UserProfile(
        weightKg: 80,
        targetWeightKg: 90,
        weightGoal: _abnehmen,
      );
      expect(alt.reachedTargetWeight, isTrue);
      expect(alt.effectiveWeightGoal, WeightGoal.maintain);

      final geheilt = alt.withEffectiveWeightGoal;
      expect(geheilt.weightGoal, WeightGoal.maintain);
      expect(geheilt.targetWeightKg, 90,
          reason: 'das Wunschgewicht ist eine Eingabe und wird nicht erfunden');
      expect(geheilt.weightKg, 80);
    });

    test('Halten bleibt Halten, egal wo das Wunschgewicht liegt', () {
      const halten = UserProfile(weightKg: 80, targetWeightKg: 95);
      expect(identical(halten.withEffectiveWeightGoal, halten), isTrue);
    });
  });

  // =========================================================================
  // P9-08c — das Richtungs-Icon der Plan-Karte
  // =========================================================================
  group('Plan-Karte: das Icon folgt den beiden Zahlen darunter', () {
    testWidgets('Altprofil "Abnehmen" mit hoeherem Ziel zeigt nach OBEN',
        (tester) async {
      await _pumpKarte(
        tester,
        const UserProfile(
          weightKg: 80,
          targetWeightKg: 90,
          weightGoal: _abnehmen,
          dailyKcalGoal: 1800,
        ),
      );

      expect(find.text('80'), findsOneWidget);
      expect(find.text('90'), findsOneWidget);
      expect(_planIcon(tester), Icons.trending_up_rounded,
          reason: '80 → 90 unter trending_down war die Luege');
    });

    testWidgets('Altprofil "Zunehmen" mit niedrigerem Ziel zeigt nach UNTEN',
        (tester) async {
      await _pumpKarte(
        tester,
        const UserProfile(
          weightKg: 80,
          targetWeightKg: 70,
          weightGoal: _zunehmen,
          dailyKcalGoal: 2600,
        ),
      );

      expect(_planIcon(tester), Icons.trending_down_rounded);
    });

    testWidgets('das gesunde Profil zeichnet unveraendert', (tester) async {
      await _pumpKarte(
        tester,
        const UserProfile(
          weightKg: 80,
          targetWeightKg: 72,
          weightGoal: _abnehmen,
          dailyKcalGoal: 1800,
        ),
      );
      expect(_planIcon(tester), Icons.trending_down_rounded);

      await _pumpKarte(
        tester,
        const UserProfile(
          weightKg: 80,
          targetWeightKg: 86,
          weightGoal: _zunehmen,
          dailyKcalGoal: 2600,
        ),
      );
      expect(_planIcon(tester), Icons.trending_up_rounded);
    });

    testWidgets('bei gleichen Zahlen entscheidet weiter das Ziel',
        (tester) async {
      // Kein Pfeil aus den Zahlen ableitbar (80 → 80): dann bleibt das
      // gespeicherte Ziel die einzige Quelle.
      await _pumpKarte(
        tester,
        const UserProfile(
          weightKg: 80,
          targetWeightKg: 80,
          weightGoal: _zunehmen,
          dailyKcalGoal: 2600,
        ),
      );
      expect(_planIcon(tester), Icons.trending_up_rounded);
    });

    testWidgets('Halten behaelt sein eigenes Symbol', (tester) async {
      await _pumpKarte(
        tester,
        const UserProfile(weightKg: 80, targetWeightKg: 90),
      );
      expect(
        find.descendant(
          of: find.byType(GoalPlanCard),
          matching: find.byIcon(Icons.shield_moon_outlined),
        ),
        findsOneWidget,
      );
    });
  });

  // =========================================================================
  // P9-08d — was NICHT in diesen Dateien liegt
  // =========================================================================
  group('Fremdbedarf: die Heilung fehlt noch am Ladepfad', () {
    test('applyLiveGoals heilt die Richtung noch nicht mit', () {
      // Der Rueckschreib-Weg steht schon: ProfileSync.load ruft applyLiveGoals
      // und queued per `healedLiveGoals`. Ein Aufruf von
      // `withEffectiveWeightGoal` dort schliesst P9-08d ganz — samt der Zeile
      // in home_store.dart:227, die den Widerspruch heute noch an das Modell
      // schickt. Beide Dateien stehen NICHT auf der Aenderungsliste dieses
      // Laufs; dieser Test faellt auf, wenn jemand sie anfasst.
      final quelle =
          File('lib/src/services/kcal_calculator.dart').readAsStringSync();
      expect(
        quelle.contains('withEffectiveWeightGoal'),
        isFalse,
        reason: 'Fremdbedarf erledigt? Dann diesen Test loeschen und den '
            'geheilten Ladepfad hier pinnen.',
      );
      expect(quelle, contains('UserProfile applyLiveGoals(UserProfile profile)'),
          reason: 'der Einhaengepunkt heisst noch so');
    });

    test('der Coach-Kontext nimmt Gewicht und Ziel weiter roh aus dem Profil',
        () {
      final quelle = File('lib/src/app/home_store.dart').readAsStringSync();
      expect(
        quelle,
        contains(r"'Körpergewicht: ${p.weightKg} kg (Ziel ${p.targetWeightKg} kg).'"),
        reason: 'die Zeile aus P9-08d — sie wird widerspruchsfrei, sobald der '
            'Ladepfad heilt, nicht durch eine zweite Regel hier',
      );
    });
  });
}
