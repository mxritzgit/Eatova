// B2: Die Plan-Karte im Profil verspricht ein Tempo, das sie nicht liefert.
//
// GoalPlanCard zeigte `goal.paceLabel` — das GEWAEHLTE Tempo — obwohl ein
// konkretes Profil vorliegt. Fuer das Standardprofil (78 kg / 178 cm / 30 J. /
// sitzend, Ziel 68 kg, lose1kg) kappt die 1200er-Sicherheitsgrenze das Defizit
// von 1100 auf 797 kcal: real sind es −0,72 kg/Woche, nicht −1.
//
// KcalTargets (W2-03) liefert dafuer effectivePaceLabel; weeksToGoal rechnet
// bereits mit der effektiven Rate und liefert null, wenn die Klemme das ganze
// Defizit frisst — beides wird hier festgenagelt.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/theme/app_colors.dart';
import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/widgets/profile/profile_widgets.dart';

/// Standardprofil aus dem Review: Erhaltung 1997, gewuenscht 900, ausgegeben
/// 1200 → reales Defizit 797 kcal/Tag ≙ −0,7245 kg/Woche, 14 statt 10 Wochen.
const _standard = UserProfile(
  weightKg: 78,
  heightCm: 178,
  ageYears: 30,
  targetWeightKg: 68,
  weightGoal: WeightGoal.lose1kg,
  dailyKcalGoal: 1200,
);

/// Kleines, aelteres Profil: die Erhaltung (1209) liegt selbst schon fast auf
/// der Untergrenze, das Defizit schrumpft auf 9 kcal/Tag. weeksToGoal muss
/// hier null liefern statt einer Fantasie-Wochenzahl.
const _clampedFlat = UserProfile(
  weightKg: 50,
  heightCm: 155,
  ageYears: 60,
  sex: BiologicalSex.female,
  targetWeightKg: 45,
  weightGoal: WeightGoal.lose1kg,
  dailyKcalGoal: 1200,
);

Future<void> _pumpCard(WidgetTester tester, UserProfile profile) async {
  tester.view.devicePixelRatio = 3.0;
  tester.view.physicalSize = const Size(402, 900) * 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      theme: buildEatovaTheme(),
      home: Scaffold(
        backgroundColor: bg,
        body: Padding(
          padding: const EdgeInsets.all(20),
          child: GoalPlanCard(profile: profile, onEdit: () {}),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Die Plan-Karte zeigt das ERREICHBARE Tempo, nicht das gewaehlte',
      (tester) async {
    await _pumpCard(tester, _standard);

    expect(find.text('−0,72 kg/Woche'), findsOneWidget,
        reason: 'Die 1200er-Klemme laesst nur 797 kcal Defizit uebrig');
    expect(find.text('−1 kg/Woche'), findsNothing,
        reason: 'Das gewaehlte Tempo ist ein Wunsch, kein Plan');
  });

  testWidgets('Die Zeit-Prognose bleibt an derselben effektiven Rate haengen',
      (tester) async {
    await _pumpCard(tester, _standard);

    expect(find.text('Noch 10 kg · Ziel in ca. 14 Wochen'), findsOneWidget,
        reason: '10 kg / 0,7245 kg pro Woche = 13,8 -> 14, nicht 10');
  });

  testWidgets('Frisst die Klemme das ganze Defizit, wird nichts versprochen',
      (tester) async {
    await _pumpCard(tester, _clampedFlat);

    // weeksToGoal == null -> die Karte darf keine Wochenzahl erfinden.
    expect(find.text('Noch 5 kg bis zum Wunschgewicht'), findsOneWidget);
    expect(find.textContaining('Wochen'), findsNothing);
    // ... und das Tempo ist ehrlich „stabil", nicht −1 kg/Woche.
    expect(find.text('Gewicht stabil'), findsOneWidget);
    expect(find.text('−1 kg/Woche'), findsNothing);
  });

  testWidgets('Weicht der Plan vom Wunsch ab, erklaert die Karte das auf Abruf',
      (tester) async {
    await _pumpCard(tester, _standard);

    // Der fertige Satz aus KcalTargets.paceWarning haengt als Tooltip/
    // Semantics am Tempo-Chip — kein zweiter Fliesstext-Block auf der Karte
    // (den zeigt W3-04 im Settings-Sheet), aber auch nicht wortlos.
    expect(
      find.byTooltip(
        'Aus Sicherheitsgründen liegt dein Tagesziel bei 1200 kcal statt '
        '900 kcal. Dein tatsächliches Tempo ist damit −0,72 kg/Woche statt '
        '−1 kg/Woche.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('Ohne Abweichung haengt kein Hinweis am Tempo-Chip',
      (tester) async {
    // Grosser, aktiver Nutzer (Erhaltung 3541): die Untergrenze greift nicht,
    // uebrig bleibt nur die 50er-Rundung des Tagesziels — 3000 statt 2991
    // ergibt −0,49 statt −0,50 kg/Woche und liegt damit im Rauschband
    // (weeklyRateNoiseKg), also kein Hinweis.
    await _pumpCard(
      tester,
      const UserProfile(
        weightKg: 100,
        heightCm: 190,
        ageYears: 28,
        sex: BiologicalSex.male,
        activityLevel: ActivityLevel.active,
        targetWeightKg: 90,
        weightGoal: WeightGoal.lose05kg,
        dailyKcalGoal: 3000,
      ),
    );

    expect(find.text('−0,49 kg/Woche'), findsOneWidget);
    expect(find.byWidgetPredicate(_isPaceWarningTooltip), findsNothing,
        reason: 'Kein Widerspruch -> kein Hinweis');
  });
}

/// Der „Ziel anpassen"-IconButton bringt seinen eigenen Tooltip mit — hier
/// zaehlt nur der Tempo-Hinweis.
bool _isPaceWarningTooltip(Widget widget) {
  final message = widget is Tooltip ? widget.message : null;
  return message != null && message.contains('Tempo ist damit');
}
