import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/settings/goals_screen.dart';
import 'package:eatova/src/services/kcal_calculator.dart';
import 'package:eatova/src/widgets/design/design.dart';
import 'package:eatova/src/widgets/shared/settings_sheet.dart';

import 'support/harness.dart';

// P9-08 — the goals page checked the target weight against the DB range
// (30..300) only, never against the chosen weight goal. "Lose weight" with a
// HIGHER target saved happily; the plan card then showed "80 -> 90" under a
// trending_down icon and `home_store` shipped the contradiction to the coach
// model as "Körpergewicht: 80 kg (Ziel 90 kg)" on a deficit plan.
//
// The onboarding has enforced the rule since day one (`_targetMin`/`_targetMax`
// with the explicit "consistency bound, not a range" comment); since P9-08b
// both sides read it from ONE place (`isConsistentTargetWeight`).
//
// P9-08e hat die DURCHSETZUNG gedreht, nicht die Regel: der Zustand "das Ziel
// liegt auf der falschen Seite des Gewichts" heisst immer, dass die gewaehlte
// Richtung nichts mehr zu tun hat — meistens, weil der Nutzer sein Ziel
// ERREICHT hat (80 kg, Ziel 75, wiegt heute 74). Das war eine Sperre, die die
// ganze Seite dichtmachte, Schrittziel und Erinnerungen eingeschlossen.
//
// Die Zusage bleibt trotzdem gleich und wird hier gemessen: **ein Defizit-Plan
// mit Ziel ueber dem Gewicht darf die App nicht verlassen.** Nur loest ihn die
// Seite jetzt auf (Plan wechselt aufs Halten, sichtbar angekuendigt), statt zu
// blockieren. "Maintain" bleibt frei — jedes Ziel nahe dem heutigen Gewicht
// ist dort plausibel.
//
// P9-08d hat den Ort der Aufloesung verschoben, nicht die Zusage: die Seite
// SCHRIEB die Richtung frueher auf `maintain` um und nahm dem Nutzer damit
// seine Absicht (Seite oeffnen und speichern reichte). Heute wird sie
// ABGELEITET — `KcalCalculator.calculate` liest `effectiveWeightGoal` —, also
// verlaesst das gespeicherte Tagesziel die Seite als Erhaltungsziel, waehrend
// `weightGoal` die Wahl des Nutzers bleibt. Genau darauf baut der Hinweistext
// auf ("trag ein niedrigeres Wunschgewicht ein"): ohne gespeicherte Richtung
// waere dieser Weg zurueck nicht mehr da.

/// Der Plan, den ein gespeichertes Profil ergibt — das, was den Nutzer
/// tatsaechlich erreicht.
KcalTargets _plan(UserProfile p) => const KcalCalculator().calculate(p);
void main() {
  /// 80 kg, target 80 kg, goal "maintain" — the consistent starting point.
  const basis = UserProfile(weightKg: 80, targetWeightKg: 80);

  Future<Future<SettingsResult?>> openSettings(
    WidgetTester tester, {
    UserProfile profile = basis,
    Locale locale = const Locale('de'),
  }) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final prior = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception.toString().contains('overflowed')) return;
      prior?.call(details);
    };
    addTearDown(() => FlutterError.onError = prior);

    late Future<SettingsResult?> result;
    await pumpLocalized(
      tester,
      Builder(
        builder: (context) => Center(
          child: FilledButton(
            key: const ValueKey('open-settings'),
            onPressed: () {
              result = Navigator.of(context).push<SettingsResult>(
                MaterialPageRoute<SettingsResult>(
                  builder: (_) => GoalsScreen(profile: profile),
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
      locale: locale,
      brightness: Brightness.light,
    );
    await tester.tap(find.byKey(const ValueKey('open-settings')));
    await tester.pumpAndSettle();
    return result;
  }

  VoidCallback? saveHandler(WidgetTester tester) => tester
      .widget<PrimaryActionButton>(find.byKey(const ValueKey('settings-save')))
      .onTap;

  Future<void> tippe(WidgetTester tester, String key, String text) async {
    await tester.enterText(find.byKey(ValueKey(key)), text);
    await tester.pump();
  }

  /// Picks [goalName] in the weight-goal sheet. The row sits far down the
  /// scroll, so without [WidgetController.ensureVisible] the tap misses.
  Future<void> waehleZiel(WidgetTester tester, String goalName) async {
    await tester
        .ensureVisible(find.byKey(const ValueKey('settings-weight-goal')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-weight-goal')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('settings-weight-goal-$goalName')));
    await tester.pumpAndSettle();
  }

  Future<SettingsResult?> speichere(
    WidgetTester tester,
    Future<SettingsResult?> result,
  ) async {
    await tester.ensureVisible(find.byKey(const ValueKey('settings-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-save')));
    await tester.pumpAndSettle();
    return result;
  }

  /// Die Erfolgsmeldung, die an die Stelle der Sperre getreten ist.
  String erreichtLose(int gewicht, int ziel) =>
      'Ziel erreicht! Mit $gewicht kg hast du dein Wunschgewicht von $ziel kg '
      'geschafft. Dein Plan wechselt aufs Halten — für ein neues Ziel trag ein '
      'niedrigeres Wunschgewicht ein.';
  String erreichtGain(int gewicht, int ziel) =>
      'Ziel erreicht! Mit $gewicht kg hast du dein Wunschgewicht von $ziel kg '
      'geschafft. Dein Plan wechselt aufs Halten — für ein neues Ziel trag ein '
      'höheres Wunschgewicht ein.';

  Finder erreichtHinweis() =>
      find.byKey(const ValueKey('settings-target-reached'));

  group('Ziele-Seite: Wunschgewicht und Gewichtsziel', () {
    testWidgets(
        'Abnehmen mit hoeherem Wunschgewicht verlaesst die App nicht als '
        'Defizit-Plan', (tester) async {
      // Exactly the reported trigger: target 90 typed at 80 kg, then the goal
      // switched to "Abnehmen · −0,5 kg/Woche".
      final resultFuture = await openSettings(tester);
      await tippe(tester, 'settings-target-weight', '90');
      expect(erreichtHinweis(), findsNothing,
          reason: '90 kg passt zu "Halten" — erst das Ziel macht es zum Thema');

      await waehleZiel(tester, 'lose05kg');

      expect(find.text(erreichtLose(80, 90)), findsOneWidget);
      expect(
        find.byKey(const ValueKey('settings-validation-note')),
        findsNothing,
        reason: 'kein Feldfehler mehr — die Seite loest auf, statt zu sperren',
      );
      expect(saveHandler(tester), isNotNull);

      final result = (await speichere(tester, resultFuture))!.profile;
      expect(result.targetWeightKg, 90, reason: 'die Eingabe bleibt stehen');
      expect(_plan(result).goal, WeightGoal.maintain,
          reason: 'ein Defizit-Plan mit Ziel ueber dem Gewicht darf die App '
              'nicht verlassen');
      expect(_plan(result).appliedKcalDelta, 0);
      expect(result.dailyKcalGoal, _plan(result).kcal,
          reason: 'das gespeicherte Tagesziel ist das Erhaltungsziel');
      expect(result.weightGoal, WeightGoal.lose05kg,
          reason: 'die Richtung ist die ABSICHT und wird nicht ueberschrieben '
              '— sonst haette ein spaeter eingetragenes niedrigeres '
              'Wunschgewicht nichts mehr, worauf es zurueckgreifen koennte');
    });

    testWidgets('Abnehmen auf das aktuelle Gewicht zaehlt als erreicht',
        (tester) async {
      // Same bound as the onboarding (`_targetMax = weight - 1`): losing down
      // to today's weight is no goal, it is "maintain" under another name — und
      // genau so wird es jetzt auch gespeichert.
      final resultFuture = await openSettings(tester);
      await waehleZiel(tester, 'lose025kg');

      expect(find.text(erreichtLose(80, 80)), findsOneWidget);
      expect(saveHandler(tester), isNotNull);

      final result = (await speichere(tester, resultFuture))!.profile;
      expect(_plan(result).goal, WeightGoal.maintain);
      expect(result.weightGoal, WeightGoal.lose025kg,
          reason: 'gewaehlt bleibt gewaehlt');
    });

    testWidgets('Zunehmen mit niedrigerem Wunschgewicht: derselbe Weg',
        (tester) async {
      final resultFuture = await openSettings(tester);
      await tippe(tester, 'settings-target-weight', '70');
      await waehleZiel(tester, 'gain025kg');

      expect(find.text(erreichtGain(80, 70)), findsOneWidget);
      expect(saveHandler(tester), isNotNull);

      final result = (await speichere(tester, resultFuture))!.profile;
      expect(result.targetWeightKg, 70);
      expect(_plan(result).goal, WeightGoal.maintain);
      expect(result.weightGoal, WeightGoal.gain025kg);
    });

    testWidgets('passende Abnehm-Kombination bleibt unangetastet',
        (tester) async {
      final resultFuture = await openSettings(tester);
      await tippe(tester, 'settings-target-weight', '72');
      await waehleZiel(tester, 'lose05kg');

      expect(erreichtHinweis(), findsNothing);
      expect(saveHandler(tester), isNotNull);

      final result = (await speichere(tester, resultFuture))!.profile;
      expect(result.targetWeightKg, 72);
      expect(result.weightGoal, WeightGoal.lose05kg,
          reason: 'solange die Richtung etwas zu tun hat, bleibt sie stehen');
    });

    testWidgets('passende Zunehm-Kombination bleibt unangetastet',
        (tester) async {
      final resultFuture = await openSettings(tester);
      await tippe(tester, 'settings-target-weight', '86');
      await waehleZiel(tester, 'gain05kg');

      expect(erreichtHinweis(), findsNothing);
      expect(saveHandler(tester), isNotNull);

      final result = (await speichere(tester, resultFuture))!.profile;
      expect(result.targetWeightKg, 86);
      expect(result.weightGoal, WeightGoal.gain05kg);
    });

    testWidgets('Halten laesst jedes Wunschgewicht im DB-Bereich zu',
        (tester) async {
      // "Maintain" has no direction, so it cannot contradict a target weight.
      // A stricter rule would lock out saved profiles for nothing.
      final resultFuture = await openSettings(tester);

      await tippe(tester, 'settings-target-weight', '60');
      expect(saveHandler(tester), isNotNull);
      await tippe(tester, 'settings-target-weight', '95');
      expect(saveHandler(tester), isNotNull);
      expect(erreichtHinweis(), findsNothing);

      final result = (await speichere(tester, resultFuture))!.profile;
      expect(result.targetWeightKg, 95);
      expect(result.weightGoal, WeightGoal.maintain);
    });

    testWidgets(
        'Bestandsprofil mit Widerspruch: das Wunschgewicht loest ihn auf',
        (tester) async {
      // Profiles saved BEFORE this rule existed open straight into the note —
      // und speichern trotzdem, falls der Nutzer nur das Schrittziel wollte.
      final resultFuture = await openSettings(
        tester,
        profile: basis.copyWith(
          targetWeightKg: 90,
          weightGoal: WeightGoal.lose05kg,
        ),
      );

      expect(find.text(erreichtLose(80, 90)), findsOneWidget);
      expect(saveHandler(tester), isNotNull);

      await tippe(tester, 'settings-target-weight', '75');
      expect(erreichtHinweis(), findsNothing);

      final result = (await speichere(tester, resultFuture))!.profile;
      expect(result.targetWeightKg, 75);
      expect(result.weightGoal, WeightGoal.lose05kg,
          reason: 'ein wieder sinnvolles Ziel behaelt die gewaehlte Richtung');
    });

    testWidgets(
        'Bestandsprofil mit Widerspruch: das Gewichtsziel loest ihn auch auf',
        (tester) async {
      final resultFuture = await openSettings(
        tester,
        profile: basis.copyWith(
          targetWeightKg: 70,
          weightGoal: WeightGoal.gain025kg,
        ),
      );

      expect(find.text(erreichtGain(80, 70)), findsOneWidget);

      // The second way out: keep the target, change the direction.
      await waehleZiel(tester, 'lose05kg');
      expect(erreichtHinweis(), findsNothing);

      final result = (await speichere(tester, resultFuture))!.profile;
      expect(result.targetWeightKg, 70);
      expect(result.weightGoal, WeightGoal.lose05kg);
    });

    testWidgets('ungueltiges Gewicht erzeugt keinen Erreicht-Hinweis',
        (tester) async {
      // "75,5" -> 755 via digitsOnly. The weight field carries its own range
      // error; a congratulation next to it would be absurd — there is no
      // current weight to compare against.
      await openSettings(tester);
      await waehleZiel(tester, 'lose05kg');
      await tippe(tester, 'settings-target-weight', '72');
      await tippe(tester, 'settings-weight', '755');

      expect(find.text('30–300 kg (ganze Zahl)'), findsOneWidget,
          reason: 'nur der Bereichsfehler am Gewicht');
      expect(erreichtHinweis(), findsNothing);
      expect(saveHandler(tester), isNull);
    });

    testWidgets('die Bereichsgrenze bleibt eine Sperre', (tester) async {
      await openSettings(tester);
      await waehleZiel(tester, 'lose05kg');
      await tippe(tester, 'settings-target-weight', '755');

      expect(find.text('30–300 kg (ganze Zahl)'), findsOneWidget);
      expect(erreichtHinweis(), findsNothing,
          reason: '755 kg ist ausserhalb der Spalte — kein Erfolg, ein Fehler');
      expect(saveHandler(tester), isNull);
    });

    testWidgets('die englische Fassung nennt denselben Erfolg', (tester) async {
      await openSettings(
        tester,
        profile: basis.copyWith(
          targetWeightKg: 90,
          weightGoal: WeightGoal.lose05kg,
        ),
        locale: const Locale('en'),
      );

      expect(
        find.text('Goal reached! At 80 kg you have hit your target weight of '
            '90 kg. Your plan switches to holding — for a new goal, enter a '
            'lower target weight.'),
        findsOneWidget,
      );
      expect(saveHandler(tester), isNotNull);
    });
  });

  // =========================================================================
  // P9-08e — der gemessene Fall: Zielerreichung ist der Normalfall
  // =========================================================================
  group('Ziel erreicht: 80 kg, Wunschgewicht 75, heute 74', () {
    const abnehmer = UserProfile(
      weightKg: 80,
      targetWeightKg: 75,
      weightGoal: WeightGoal.lose05kg,
      dailyStepsGoal: 8000,
    );

    testWidgets('das neue Gewicht sperrt die Seite nicht', (tester) async {
      final resultFuture = await openSettings(tester, profile: abnehmer);
      expect(erreichtHinweis(), findsNothing, reason: '80 > 75, alles offen');

      await tippe(tester, 'settings-weight', '74');

      expect(find.text(erreichtLose(74, 75)), findsOneWidget);
      expect(
        find.byKey(const ValueKey('settings-validation-note')),
        findsNothing,
      );
      expect(saveHandler(tester), isNotNull,
          reason: 'Zielerreichung ist der Normalfall einer Abnehm-App');

      // Und das, was der Nutzer eigentlich wollte, geht mit durch.
      await tippe(tester, 'settings-steps-goal', '9000');
      final result = (await speichere(tester, resultFuture))!.profile;
      expect(result.weightKg, 74);
      expect(result.dailyStepsGoal, 9000);
      expect(result.targetWeightKg, 75);
      expect(_plan(result).goal, WeightGoal.maintain,
          reason: 'der Plan haelt jetzt, statt weiter Defizit zu fahren');
      expect(result.dailyKcalGoal, _plan(result).kcal);
      expect(result.weightGoal, WeightGoal.lose05kg,
          reason: 'die Absicht ueberlebt — sie ist der Weg zum naechsten Ziel');
    });

    testWidgets('ein neues, niedrigeres Ziel nimmt die Richtung wieder auf',
        (tester) async {
      final resultFuture = await openSettings(tester, profile: abnehmer);
      await tippe(tester, 'settings-weight', '74');
      expect(erreichtHinweis(), findsOneWidget);

      await tippe(tester, 'settings-target-weight', '70');
      expect(erreichtHinweis(), findsNothing);

      final result = (await speichere(tester, resultFuture))!.profile;
      expect(result.targetWeightKg, 70);
      expect(result.weightGoal, WeightGoal.lose05kg);
    });
  });
}
