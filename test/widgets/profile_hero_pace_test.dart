// B2: Die Plan-Karte im Profil verspricht ein Tempo, das sie nicht liefert.
//
// GoalPlanCard zeigte `goal.paceLabel` — das GEWAEHLTE Tempo — obwohl ein
// konkretes Profil vorliegt. Seit dem Kalorien-Review 2026-08-21 bremsen zwei
// Dinge das Wunsch-Tempo: der 1-%-Defizitdeckel (kg × 11 kcal/Tag, auf die
// 0,05 kg/Woche = 55-kcal-Schritte abgerundet) und die
// geschlechtsabhaengige Untergrenze (1200 weiblich / 1500 maennlich / 1350
// neutral). Fuer das Standardprofil (78 kg / 178 cm / 30 J. / neutral /
// sitzend, Ziel 68 kg, lose1kg) kappt der Deckel das Defizit von 1100 auf
// 825 kcal: real sind es −0,75 kg/Woche, nicht −1.
//
// KcalTargets (W2-03) liefert dafuer effectivePaceLabel (seit dem Review auf
// das 0,05-Raster gerundet, s. paceLabelForWeeklyRateKg); weeksToGoalRange
// rechnet mit der effektiven Rate (linear bis dynamisch) und liefert null,
// wenn die Klemme das ganze Defizit frisst — beides wird hier festgenagelt.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/widgets/profile/profile_widgets.dart';

/// Standardprofil aus dem Review: BMR 1664,5, Erhaltung 2164 (PAL 1,3 —
/// seit „jeder Schritt zaehlt" ohne Gehen), Deckel 78 × 11 = 858 → auf
/// 0,05 kg/Woche abgerundet 825 kcal/Tag → 2164 − 825 = 1339 → 1350 kcal.
/// Das ist exakt die neutrale Untergrenze (1350): uncappedKcal == floor, also
/// NICHT geklemmt (floorApplied prueft auf „kleiner"). Reales Defizit
/// 814 kcal/Tag ≙ −0,74 → Label „−0,75 kg/Woche", Prognose 14 (linear) bis
/// 16 (dynamisch) Wochen statt 10.
///
/// dailyKcalGoal ist auf der Karte reine Anzeige (Tagesziel-Chip) und haelt
/// hier den Rechner-Wert, damit die Karte in sich stimmig bleibt.
const _standard = UserProfile(
  weightKg: 78,
  heightCm: 178,
  ageYears: 30,
  targetWeightKg: 68,
  weightGoal: WeightGoal.lose1kg,
  dailyKcalGoal: 1350,
);

/// Kleines Profil: Erhaltung 1237 (BMR 951,5 × 1,3), Wunsch −275 (der Deckel
/// 40 × 11 = 440 liegt ueber dem Wunsch, greift also nicht) → 962 →
/// 950 kcal; die 1200er-Untergrenze (weiblich) hebt das Ziel an und laesst
/// 37 kcal/Tag Defizit uebrig (≙ 0,034 kg/Woche) — unterhalb von
/// weeklyRateNoiseKg. weeksToGoalRange muss hier null liefern statt einer
/// Fantasie-Wochenzahl; paceWarning formuliert dafuer den „Stable"-Satz
/// (commonPaceWarningFloorStable) ohne „tatsächliches Tempo".
///
/// 45 statt frueher 60 Jahre: mit der PAL-Leiter ohne Gehen (1,3 statt 1,4)
/// laege die 60-Jaehrige bei Erhaltung 1139 → 850 → 1200 und damit 61 kcal
/// UEBER dem Bedarf (+0,055 kg/Woche) — knapp ausserhalb des Rauschbands,
/// also kein „stabil" mehr.
const _clampedFlat = UserProfile(
  weightKg: 40,
  heightCm: 150,
  ageYears: 45,
  sex: BiologicalSex.female,
  targetWeightKg: 36,
  weightGoal: WeightGoal.lose025kg,
  dailyKcalGoal: 1200,
);

/// Profil, bei dem die Untergrenze WIRKLICH klemmt: Erhaltung 1578 (BMR 1214
/// × 1,3), Deckel 55 × 11 = 605 (0,55 kg/Woche) → 973 → 950 kcal → 1200
/// (weiblich). Effektiv −378 kcal/Tag ≙ −0,3436 → „−0,35 kg/Woche".
/// paceWarning nennt die Klemme (hoechste Bindungskraft), nicht den ebenfalls
/// greifenden Deckel.
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

    expect(find.text('−0,75 kg/Woche'), findsOneWidget,
        reason: 'Der 1-%-Deckel laesst nur 825 statt 1100 kcal Defizit zu');
    expect(find.text('−1 kg/Woche'), findsNothing,
        reason: 'Das gewaehlte Tempo ist ein Wunsch, kein Plan');
  });

  testWidgets('Die Zeit-Prognose bleibt an derselben effektiven Rate haengen',
      (tester) async {
    await _pumpCard(tester, _standard);

    // Linear: 10 kg / 0,74 kg pro Woche = 13,5 -> 14. Dynamisch (Bedarf
    // sinkt um 22 kcal pro verlorenem kg): 16. Beides aus der effektiven
    // Rate, nicht aus den 10 Wochen des Wunsch-Tempos.
    expect(find.text('Noch 10 kg · Ziel in ca. 14–16 Wochen'), findsOneWidget,
        reason: 'Spanne aus weeksToGoalRange, untere Grenze 14 statt 10');
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
    // Standardprofil greift nur der Deckel, also der Deckel-Satz mit dem
    // abgerundeten 825er-Deckel und dem gerasterten Tempo.
    expect(
      find.byTooltip(
        'Schneller als 1 % deines Körpergewichts pro Woche empfehlen wir '
        'nicht: Dein Defizit ist auf 825 kcal/Tag begrenzt. Dein tatsächliches '
        'Tempo ist damit −0,75 kg/Woche statt −1 kg/Woche.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('Klemmt die Untergrenze, nennt der Hinweis die Klemme',
      (tester) async {
    await _pumpCard(tester, _clampedFloor);

    // Deckel UND Untergrenze greifen; paceWarning nennt die bindendere
    // Untergrenze mit dem ungeklemmten 950er-Wert (Erhaltung 1578 minus
    // Deckel 605 = 973, auf 50 gerundet), nicht den Deckel.
    expect(find.text('−0,35 kg/Woche'), findsOneWidget);
    expect(
      find.byTooltip(
        'Aus Sicherheitsgründen liegt dein Tagesziel bei 1200 kcal statt '
        '950 kcal. Dein tatsächliches Tempo ist damit −0,35 kg/Woche statt '
        '−1 kg/Woche.',
      ),
      findsOneWidget,
    );
    expect(find.text('Noch 5 kg · Ziel in ca. 15–18 Wochen'), findsOneWidget,
        reason: '5 kg / 0,3436 = 14,6 → 15 linear, 18 dynamisch');
  });

  testWidgets('Ohne Abweichung haengt kein Hinweis am Tempo-Chip',
      (tester) async {
    // Grosser, aktiver Nutzer (BMR 2040, Erhaltung 3570 bei PAL 1,75): weder
    // die 1500er-Untergrenze noch der Deckel (1100 > 550) greifen, uebrig
    // bleibt nur die 50er-Rundung des Tagesziels — 3000 statt 3020 ergibt
    // rechnerisch −0,52 kg/Woche. Das liegt im Rauschband (weeklyRateNoiseKg),
    // also kein Hinweis — und das 0,05-Raster des Labels zeigt davon genau
    // das gewaehlte „−0,5", nicht mehr die falsche Praezision „−0,52".
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
        dailyKcalGoal: 3000,
      ),
    );

    final paceValue = find.text('−0,5 kg/Woche');
    expect(paceValue, findsOneWidget);
    expect(find.text('−0,52 kg/Woche'), findsNothing,
        reason: 'Label rastert auf 0,05 kg/Woche');
    // Der „Ziel anpassen"-IconButton bringt seinen eigenen Tooltip mit — hier
    // zaehlt nur, dass KEIN Tooltip den Tempo-Chip umschliesst (_MaybeTooltip
    // reicht das Chip bei paceWarning == null unveraendert durch).
    expect(find.ancestor(of: paceValue, matching: find.byType(Tooltip)),
        findsNothing,
        reason: 'Kein Widerspruch -> kein Hinweis');
  });
}
