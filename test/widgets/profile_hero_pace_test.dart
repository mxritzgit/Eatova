// B2: Die Plan-Karte im Profil verspricht ein Tempo, das sie nicht liefert.
//
// GoalPlanCard zeigte `goal.paceLabel` — das GEWAEHLTE Tempo — obwohl ein
// konkretes Profil vorliegt. Seit dem Kalorien-Review 2026-08-21 bremsen zwei
// Dinge das Wunsch-Tempo: der 1-%-Defizitdeckel (kg × 11 kcal/Tag) und die
// geschlechtsabhaengige Untergrenze (1200 weiblich / 1500 maennlich / 1350
// neutral). Fuer das Standardprofil (78 kg / 178 cm / 30 J. / neutral /
// sitzend, Ziel 68 kg, lose1kg) kappt der Deckel das Defizit von 1100 auf
// 858 kcal: real sind es −0,8 kg/Woche, nicht −1.
//
// KcalTargets (W2-03) liefert dafuer effectivePaceLabel; weeksToGoalRange
// rechnet mit der effektiven Rate (linear bis dynamisch) und liefert null,
// wenn die Klemme das ganze Defizit frisst — beides wird hier festgenagelt.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/widgets/profile/profile_widgets.dart';

/// Standardprofil aus dem Review: BMR 1665, Erhaltung 2330 (PAL 1,4), Deckel
/// 78 × 11 = 858 kcal/Tag → 2330 − 858 = 1472 → 1450 kcal. Die neutrale
/// Untergrenze (1350) greift nicht; reales Defizit 880 kcal/Tag ≙
/// −0,8 kg/Woche, Prognose 13 (linear) bis 15 (dynamisch) Wochen statt 10.
///
/// dailyKcalGoal ist auf der Karte reine Anzeige (Tagesziel-Chip) und haelt
/// hier den Rechner-Wert, damit die Karte in sich stimmig bleibt.
const _standard = UserProfile(
  weightKg: 78,
  heightCm: 178,
  ageYears: 30,
  targetWeightKg: 68,
  weightGoal: WeightGoal.lose1kg,
  dailyKcalGoal: 1450,
);

/// Kleines, aelteres Profil: Erhaltung 1227, Wunsch −275 → 950 kcal; die
/// 1200er-Untergrenze (weiblich) hebt das Ziel an und laesst 27 kcal/Tag
/// Defizit uebrig — unterhalb von weeklyRateNoiseKg. weeksToGoalRange muss
/// hier null liefern statt einer Fantasie-Wochenzahl.
const _clampedFlat = UserProfile(
  weightKg: 40,
  heightCm: 150,
  ageYears: 60,
  sex: BiologicalSex.female,
  targetWeightKg: 36,
  weightGoal: WeightGoal.lose025kg,
  dailyKcalGoal: 1200,
);

/// Profil, bei dem die Untergrenze WIRKLICH klemmt: Erhaltung 1700, Deckel
/// 55 × 11 = 605 → 1095 → 1100 kcal → 1200 (weiblich). Effektiv −500 kcal/Tag
/// ≙ −0,45 kg/Woche. paceWarning nennt die Klemme (hoechste Bindungskraft),
/// nicht den ebenfalls greifenden Deckel.
const _clampedFloor = UserProfile(
  weightKg: 55,
  heightCm: 160,
  ageYears: 35,
  sex: BiologicalSex.female,
  targetWeightKg: 50,
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
      theme: buildEatovaTheme(Brightness.dark),
      // GoalPlanCard liest seit der i18n-Migration context.l10n.
      locale: const Locale('de'),
      supportedLocales: const [Locale('de'), Locale('en')],
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      // Kein backgroundColor mehr: das Theme setzt scaffoldBackgroundColor
      // aus den Tokens, ein harter Wert wuerde den Hell-Modus aushebeln.
      home: Scaffold(
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

    expect(find.text('−0,8 kg/Woche'), findsOneWidget,
        reason: 'Der 1-%-Deckel laesst nur 858 statt 1100 kcal Defizit zu');
    expect(find.text('−1 kg/Woche'), findsNothing,
        reason: 'Das gewaehlte Tempo ist ein Wunsch, kein Plan');
  });

  testWidgets('Die Zeit-Prognose bleibt an derselben effektiven Rate haengen',
      (tester) async {
    await _pumpCard(tester, _standard);

    // Linear: 10 kg / 0,8 kg pro Woche = 12,5 -> 13. Dynamisch (Bedarf sinkt
    // um 22 kcal pro verlorenem kg): 15. Beides aus der effektiven Rate,
    // nicht aus den 10 Wochen des Wunsch-Tempos.
    expect(find.text('Noch 10 kg · Ziel in ca. 13–15 Wochen'), findsOneWidget,
        reason: 'Spanne aus weeksToGoalRange, untere Grenze 13 statt 10');
  });

  testWidgets('Frisst die Klemme das ganze Defizit, wird nichts versprochen',
      (tester) async {
    await _pumpCard(tester, _clampedFlat);

    // weeksToGoalRange == null -> die Karte darf keine Wochenzahl erfinden.
    expect(find.text('Noch 4 kg bis zum Wunschgewicht'), findsOneWidget);
    expect(find.textContaining('Wochen'), findsNothing);
    // ... und das Tempo ist ehrlich „stabil", nicht −0,25 kg/Woche.
    expect(find.text('Gewicht stabil'), findsOneWidget);
    expect(find.text('−0,25 kg/Woche'), findsNothing);
  });

  testWidgets('Weicht der Plan vom Wunsch ab, erklaert die Karte das auf Abruf',
      (tester) async {
    await _pumpCard(tester, _standard);

    // Der fertige Satz aus KcalTargets.paceWarning haengt als Tooltip/
    // Semantics am Tempo-Chip — kein zweiter Fliesstext-Block auf der Karte
    // (den zeigt W3-04 im Settings-Sheet), aber auch nicht wortlos. Fuer das
    // Standardprofil greift nur der Deckel, also der Deckel-Satz.
    expect(
      find.byTooltip(
        'Schneller als 1 % deines Körpergewichts pro Woche empfehlen wir '
        'nicht: Dein Defizit ist auf 858 kcal/Tag begrenzt. Dein tatsächliches '
        'Tempo ist damit −0,8 kg/Woche statt −1 kg/Woche.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('Klemmt die Untergrenze, nennt der Hinweis die Klemme',
      (tester) async {
    await _pumpCard(tester, _clampedFloor);

    // Deckel UND Untergrenze greifen; paceWarning nennt die bindendere
    // Untergrenze mit dem ungeklemmten 1100er-Wert, nicht den Deckel.
    expect(find.text('−0,45 kg/Woche'), findsOneWidget);
    expect(
      find.byTooltip(
        'Aus Sicherheitsgründen liegt dein Tagesziel bei 1200 kcal statt '
        '1100 kcal. Dein tatsächliches Tempo ist damit −0,45 kg/Woche statt '
        '−1 kg/Woche.',
      ),
      findsOneWidget,
    );
    expect(find.text('Noch 5 kg · Ziel in ca. 11–13 Wochen'), findsOneWidget,
        reason: '5 kg / 0,4545 = 11 linear, 13 dynamisch');
  });

  testWidgets('Ohne Abweichung haengt kein Hinweis am Tempo-Chip',
      (tester) async {
    // Grosser, aktiver Nutzer (BMR 2040, Erhaltung 3774 bei PAL 1,85): weder
    // die 1500er-Untergrenze noch der Deckel (1100 > 550) greifen, uebrig
    // bleibt nur die 50er-Rundung des Tagesziels — 3200 statt 3224 ergibt
    // −0,52 statt −0,50 kg/Woche und liegt damit im Rauschband
    // (weeklyRateNoiseKg), also kein Hinweis.
    await _pumpCard(
      tester,
      const UserProfile(
        weightKg: 100,
        heightCm: 188,
        ageYears: 28,
        sex: BiologicalSex.male,
        activityLevel: ActivityLevel.active,
        targetWeightKg: 90,
        weightGoal: WeightGoal.lose05kg,
        dailyKcalGoal: 3200,
      ),
    );

    expect(find.text('−0,52 kg/Woche'), findsOneWidget);
    expect(find.byWidgetPredicate(_isPaceWarningTooltip), findsNothing,
        reason: 'Kein Widerspruch -> kein Hinweis');
  });
}

/// Der „Ziel anpassen"-IconButton bringt seinen eigenen Tooltip mit — hier
/// zaehlt nur der Tempo-Hinweis. „tatsächliches Tempo" steht in allen vier
/// paceWarning-Saetzen (Untergrenze, Obergrenze, Deckel, nackter Unterschied).
bool _isPaceWarningTooltip(Widget widget) {
  final message = widget is Tooltip ? widget.message : null;
  return message != null && message.contains('tatsächliches Tempo');
}
