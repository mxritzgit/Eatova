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
//     beim Laden. Der erste Anlauf schrieb `withEffectiveWeightGoal` beim
//     Speichern ins Profil; das heilte nur, WENN der Nutzer die Ziele-Seite
//     einmal speichert, und kostete dabei seine Absicht (Seite oeffnen und
//     speichern machte aus `lose05kg` ein `maintain`, danach half auch ein
//     niedrigeres Wunschgewicht nicht mehr).
//
//     Seit diesem Lauf wird `effectiveWeightGoal` nur noch ABGELEITET:
//     `KcalCalculator.calculate` (und ueber sie `applyLiveGoals` am Ladepfad),
//     die Coach-Zeile und die Plan-Karte lesen es, `weightGoal` bleibt die
//     Absicht. Das schliesst P9-08d fuer JEDES Bestandsprofil ohne Speichern —
//     die Gegenprobe dazu steht unten in "ohne Speichern".

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/model_limits.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/settings/goals_screen.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/kcal_calculator.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';
import 'package:eatova/src/widgets/design/design.dart';
import 'package:eatova/src/widgets/profile/profile_widgets.dart';
import 'package:eatova/src/widgets/shared/settings_sheet.dart';

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

/// Das Richtungssymbol der Karte. Genau eines der drei darf gezeichnet sein —
/// deshalb prueft der Helfer das mit, statt das erstbeste zu nehmen.
IconData _planIcon(WidgetTester tester) {
  const kandidaten = <IconData>[
    Icons.trending_down_rounded,
    Icons.trending_up_rounded,
    Icons.shield_moon_outlined,
  ];
  final gezeichnet = kandidaten
      .where(
        (icon) => find
            .descendant(
              of: find.byType(GoalPlanCard),
              matching: find.byIcon(icon),
            )
            .evaluate()
            .isNotEmpty,
      )
      .toList();
  expect(gezeichnet, hasLength(1),
      reason: 'genau ein Richtungssymbol erwartet, gezeichnet: $gezeichnet');
  return gezeichnet.single;
}

void _noopSnack(
  String message, {
  IconData icon = Icons.info_outline,
  SnackTone tone = SnackTone.positive,
  Duration? duration,
  SnackBarAction? action,
}) {}

/// Ein HomeStore ohne Sync/Health/Notifications — nur fuer [HomeStore.profile]
/// und [HomeStore.coachContext].
HomeStore _store(UserProfile profile) {
  final store = HomeStore(
    sync: null,
    health: const NoopHealthService(),
    notificationService: const NoopNotificationService(),
    initialUserName: 'Test',
    emitSnack: _noopSnack,
  );
  addTearDown(store.dispose);
  store.profile = profile;
  return store;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
  // P9-08d — abgeleitet statt geschrieben
  // =========================================================================
  group('effectiveWeightGoal: abgeleitet, nie geschrieben', () {
    test('ein widerspruchsfreies Profil behaelt seine Richtung', () {
      const gesund = UserProfile(
        weightKg: 80,
        targetWeightKg: 75,
        weightGoal: _abnehmen,
      );
      expect(gesund.reachedTargetWeight, isFalse);
      expect(gesund.effectiveWeightGoal, _abnehmen);
    });

    test('das Altprofil aus dem Befund plant Halten — und behaelt die Absicht',
        () {
      // 80 kg auf Defizit-Plan mit Ziel 90 kg — genau das Profil, das als
      // "Körpergewicht: 80 kg (Ziel 90 kg)." samt Defizit in den Coach-Kontext
      // lief.
      const alt = UserProfile(
        weightKg: 80,
        targetWeightKg: 90,
        weightGoal: _abnehmen,
      );
      expect(alt.reachedTargetWeight, isTrue);
      expect(alt.effectiveWeightGoal, WeightGoal.maintain);
      expect(alt.weightGoal, _abnehmen,
          reason: 'weightGoal ist die ABSICHT und wird nicht ueberschrieben — '
              'nur so hilft spaeter ein niedrigeres Wunschgewicht noch');
      expect(alt.targetWeightKg, 90,
          reason: 'das Wunschgewicht ist eine Eingabe und wird nicht erfunden');
    });

    test('ein niedrigeres Wunschgewicht nimmt die Absicht wieder auf', () {
      // Der Weg, den der Hinweistext der Ziele-Seite verspricht. Er
      // funktioniert nur, solange die Richtung gespeichert bleibt.
      const alt = UserProfile(
        weightKg: 80,
        targetWeightKg: 90,
        weightGoal: _abnehmen,
      );
      expect(alt.copyWith(targetWeightKg: 70).effectiveWeightGoal, _abnehmen);
    });

    test('Halten bleibt Halten, egal wo das Wunschgewicht liegt', () {
      const halten = UserProfile(weightKg: 80, targetWeightKg: 95);
      expect(halten.effectiveWeightGoal, WeightGoal.maintain);
      expect(halten.reachedTargetWeight, isFalse,
          reason: 'ohne Richtung gibt es nichts zu erreichen');
    });
  });

  // =========================================================================
  // P9-08c — das Richtungs-Icon der Plan-Karte
  // =========================================================================
  group('Plan-Karte: gezeichnet wird der Plan, nicht die Absicht', () {
    testWidgets('Altprofil "Abnehmen" mit hoeherem Ziel zeichnet Halten',
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

      // Die beiden Zahlen bleiben stehen — es sind Eingaben.
      expect(find.text('80'), findsOneWidget);
      expect(find.text('90'), findsOneWidget);
      // …aber ueber ihnen steht kein Abnehm-Plan mehr: weder das Wort noch ein
      // Tempo. "80 → 90" unter trending_down UND unter "Abnehmen" war die
      // Luege; die Karte liest jetzt effectiveWeightGoal.
      expect(_planIcon(tester), Icons.shield_moon_outlined);
      expect(find.text('Gewicht halten'), findsOneWidget);
      expect(find.text('HALTEN'), findsOneWidget,
          reason: 'auch der Beschriftungspol des Wunschgewichts');
      expect(find.text('Abnehmen'), findsNothing);
      expect(find.text('stabil'), findsOneWidget,
          reason: 'kein Defizit-Tempo neben einem Ziel ueber dem Gewicht');
    });

    testWidgets('Altprofil "Zunehmen" mit niedrigerem Ziel: derselbe Weg',
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

      expect(_planIcon(tester), Icons.shield_moon_outlined);
      expect(find.text('Zunehmen'), findsNothing);
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

    testWidgets('bei gleichen Zahlen ist die Richtung erledigt',
        (tester) async {
      // Kein Pfeil aus den Zahlen ableitbar (80 → 80) — und auch nichts mehr
      // zuzunehmen: Ziel == Gewicht heisst "erreicht" (siehe
      // isConsistentTargetWeight oben), also Halten.
      await _pumpKarte(
        tester,
        const UserProfile(
          weightKg: 80,
          targetWeightKg: 80,
          weightGoal: _zunehmen,
          dailyKcalGoal: 2600,
        ),
      );
      expect(_planIcon(tester), Icons.shield_moon_outlined);
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
  // P9-08d — die Ableitung sitzt an den Verbrauchern
  // =========================================================================
  group('Ableitung statt Rueckschreiber: die Quellen', () {
    test('das Modell hat keinen schreibenden Heilungspunkt mehr', () {
      // Der Kern der Umstellung. Kaeme `withEffectiveWeightGoal` zurueck,
      // koennte ein Aufrufer die Absicht wieder ueberschreiben — und genau
      // dieser Schreibzugriff hat "Seite oeffnen, speichern" zu einem stillen
      // Absichtsverlust gemacht.
      final quelle =
          File('lib/src/models/user_profile.dart').readAsStringSync();
      expect(quelle, contains('WeightGoal get effectiveWeightGoal'));
      expect(
        quelle.contains('get withEffectiveWeightGoal'),
        isFalse,
        reason: 'effectiveWeightGoal wird abgeleitet, nicht geschrieben',
      );
    });

    test('KcalCalculator.calculate rechnet mit dem wirksamen Ziel', () {
      // Der eine Punkt, ueber den Ladepfad (applyLiveGoals), Plan-Hero,
      // Ziele-Seite und Plan-Karte gemeinsam heilen.
      final quelle =
          File('lib/src/services/kcal_calculator.dart').readAsStringSync();
      expect(quelle, contains('profile.effectiveWeightGoal'));
      expect(quelle.contains('withEffectiveWeightGoal'), isFalse);
      expect(quelle, contains('UserProfile applyLiveGoals(UserProfile profile)'),
          reason: 'der Einhaengepunkt am Ladepfad heisst noch so');
    });

    test('der Coach-Kontext nennt die wirksame Richtung', () {
      final quelle = File('lib/src/app/home_store.dart').readAsStringSync();
      expect(
        quelle,
        contains(r"'Wirksames Gewichtsziel: ${p.effectiveWeightGoal"),
        reason: 'Gewicht und Ziel allein liessen das Modell die Richtung raten',
      );
    });
  });

  // =========================================================================
  // P9-08d — der Befund selbst: OHNE Speichern
  // =========================================================================
  //
  // Das ist die Zusicherung, die der Rueckschreiber nur nach einem Speichern
  // halten konnte. Kein Aufruf hier speichert irgendetwas.
  group('Bestandsprofil "Abnehmen, 80 kg, Ziel 90" ohne Speichern', () {
    /// Genau der Befund — inklusive des Defizit-Tagesziels, das eine aeltere
    /// Version gerechnet und in die Zeile gehaengt hat (2200 - 550 -> 1650).
    const alt = UserProfile(
      weightKg: 80,
      targetWeightKg: 90,
      weightGoal: _abnehmen,
      dailyKcalGoal: 1650,
      onboardingCompleted: true,
    );

    test('der Plan ist kein Defizit-Plan', () {
      const rechner = KcalCalculator();
      final ziele = rechner.calculate(alt);

      expect(ziele.goal, WeightGoal.maintain);
      expect(ziele.appliedKcalDelta, 0, reason: 'kein Defizit im Plan');
      expect(ziele.kcal, greaterThan(alt.dailyKcalGoal),
          reason: 'das gespeicherte 1650-kcal-Ziel war das Defizit');
      expect(
        ziele.kcal,
        rechner.calculate(alt.copyWith(weightGoal: WeightGoal.maintain)).kcal,
        reason: 'wortgleich mit dem Profil, das Halten auch gespeichert haette',
      );
      expect(ziele.paceWarning(), isNull,
          reason: 'nichts zu warnen: es wird kein Tempo versprochen');
      expect(ziele.effectivePaceLabel(), 'Gewicht stabil');
    });

    test('applyLiveGoals heilt das gespeicherte Tagesziel am Ladepfad', () {
      // ProfileSync.load ruft genau das und schreibt das Ergebnis zurueck.
      final geheilt = const KcalCalculator().applyLiveGoals(alt);

      expect(identical(geheilt, alt), isFalse, reason: 'es gibt etwas zu heilen');
      expect(geheilt.dailyKcalGoal, 2200);
      expect(geheilt.weightGoal, _abnehmen,
          reason: 'geheilt wird der Plan, nicht die Absicht');
      expect(geheilt.targetWeightKg, 90);
    });

    test('der Coach-Kontext traegt keinen Widerspruch mehr', () {
      final ctx = _store(alt).coachContext;

      expect(ctx, contains('Körpergewicht: 80 kg (Ziel 90 kg).'),
          reason: 'Gewicht und Wunschgewicht sind Eingaben und bleiben stehen');
      expect(ctx, contains('Wirksames Gewichtsziel: Gewicht halten.'));
      expect(ctx, isNot(contains('Abnehmen')),
          reason: 'ein Defizit-Plan neben einem Ziel UEBER dem Gewicht war der '
              'Widerspruch, den das Modell zu beraten versuchte');
      // Die Zeile steht vor der Essensliste, also im Teil, den die Kappung der
      // Edge Function nie erreicht.
      expect(
        ctx.indexOf('Wirksames Gewichtsziel'),
        lessThan(ctx.indexOf('Heute gegessen')),
      );
    });

    testWidgets('die Ziele-Seite zeigt Halten, ohne die Absicht zu verlieren',
        (tester) async {
      await _oeffneZiele(tester, alt);

      // Die Zeile behauptet kein Tempo mehr, das nicht laeuft (B3).
      expect(find.text('−0,5 kg/Woche'), findsNothing);
      expect(find.text('Gewicht stabil'), findsWidgets);
      // Der Hinweis nennt den Weg zurueck — und der funktioniert nur, weil
      // die Absicht gespeichert bleibt.
      expect(
        find.byKey(const ValueKey('settings-target-reached')),
        findsOneWidget,
      );
    });
  });

  // =========================================================================
  // Die Invariante, staerker als vorher
  // =========================================================================
  group('kein widerspruechliches Profil ergibt je einen Defizit-Plan', () {
    test('ueber alle Richtungen, Gewichte und Wunschgewichte', () {
      const rechner = KcalCalculator();
      for (final ziel in <WeightGoal>[...lossPaceGoals, ...gainPaceGoals]) {
        for (final gewicht in <int>[50, 65, 80, 120]) {
          for (final wunsch in <int>[40, 60, 80, 100]) {
            final p = UserProfile(
              weightKg: gewicht,
              targetWeightKg: wunsch,
              weightGoal: ziel,
              onboardingCompleted: true,
            );
            final ziele = rechner.calculate(p);
            if (isConsistentTargetWeight(ziel, gewicht, wunsch)) {
              expect(ziele.goal, ziel,
                  reason: 'solange die Richtung etwas zu tun hat, plant sie');
              continue;
            }
            expect(ziele.goal, WeightGoal.maintain,
                reason: '$ziel bei $gewicht kg, Wunsch $wunsch kg');
            expect(ziele.appliedKcalDelta, 0,
                reason: '$ziel bei $gewicht kg, Wunsch $wunsch kg');
            // Und die Absicht ueberlebt: nichts wurde ins Profil geschrieben.
            expect(p.weightGoal, ziel);
          }
        }
      }
    });
  });

  // =========================================================================
  // (B2) — Speichern ohne Aenderung darf die Absicht nicht umschreiben
  // =========================================================================
  group('Ziele-Seite: oeffnen, nichts anfassen, speichern', () {
    testWidgets('das Gewichtsziel bleibt, was der Nutzer gewaehlt hat',
        (tester) async {
      // Der gemessene Nebeneffekt des Rueckschreibers: 74 kg, Wunsch 75,
      // "Abnehmen" — Seite oeffnen und speichern machte daraus `maintain`,
      // und danach half der Rat des Hinweistextes ("trag ein niedrigeres
      // Wunschgewicht ein") nicht mehr.
      const erreicht = UserProfile(
        weightKg: 74,
        targetWeightKg: 75,
        weightGoal: _abnehmen,
      );
      final ergebnis = await _oeffneZiele(tester, erreicht);
      final gespeichert = (await _speichere(tester, ergebnis))!.profile;

      expect(gespeichert.weightGoal, _abnehmen,
          reason: 'nichts angefasst, also nichts an der Absicht zu aendern');
      expect(gespeichert.targetWeightKg, 75);
      expect(gespeichert.weightKg, 74);
      // Der Plan aber haelt — genau das, was der Hinweis ankuendigt.
      expect(
        const KcalCalculator().calculate(gespeichert).goal,
        WeightGoal.maintain,
      );
      expect(gespeichert.dailyKcalGoal,
          const KcalCalculator().calculate(gespeichert).kcal);
    });

    testWidgets('und ein niedrigeres Wunschgewicht wirkt danach wieder',
        (tester) async {
      // Die Fortsetzung derselben Sitzung: was der Hinweistext verspricht,
      // muss auch beim zweiten Besuch noch stimmen.
      const erreicht = UserProfile(
        weightKg: 74,
        targetWeightKg: 75,
        weightGoal: _abnehmen,
      );
      final ergebnis = await _oeffneZiele(tester, erreicht);
      await tester.enterText(
          find.byKey(const ValueKey('settings-target-weight')), '70');
      await tester.pump();
      final gespeichert = (await _speichere(tester, ergebnis))!.profile;

      expect(gespeichert.targetWeightKg, 70);
      expect(gespeichert.weightGoal, _abnehmen);
      expect(const KcalCalculator().calculate(gespeichert).goal, _abnehmen,
          reason: 'die Richtung hat wieder etwas zu tun');
    });
  });
}

/// Oeffnet die Ziele-Seite als Route und gibt das Pop-Ergebnis zurueck.
Future<Future<SettingsResult?>> _oeffneZiele(
  WidgetTester tester,
  UserProfile profile,
) async {
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
          key: const ValueKey('open-goals'),
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
    brightness: Brightness.light,
  );
  await tester.tap(find.byKey(const ValueKey('open-goals')));
  await tester.pumpAndSettle();
  return result;
}

Future<SettingsResult?> _speichere(
  WidgetTester tester,
  Future<SettingsResult?> result,
) async {
  await tester.ensureVisible(find.byKey(const ValueKey('settings-save')));
  await tester.pumpAndSettle();
  expect(
    tester
        .widget<PrimaryActionButton>(find.byKey(const ValueKey('settings-save')))
        .onTap,
    isNotNull,
  );
  await tester.tap(find.byKey(const ValueKey('settings-save')));
  await tester.pumpAndSettle();
  return result;
}
