// B2: the plan card promised a pace it does not deliver — it showed the CHOSEN
// pace even with a concrete profile. Two things brake the wish: the 1 % deficit
// cap (kg × 11 kcal/day, rounded down to 0.05 kg/week = 55-kcal steps) and the
// sex-dependent floor (1200 female / 1500 male / 1350 neutral).
//
// KcalTargets supplies effectivePaceLabel (snapped to the 0.05 grid) and
// weeksToGoalRange, which computes from the effective rate and returns null
// when the clamp eats the whole deficit. Both are pinned here.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/widgets/profile/profile_widgets.dart';

/// Standard profile: BMR 1664.5, maintenance 2164 (PAL 1.3), cap 78 × 11 = 858
/// rounded down to 825 kcal/day → 1339 → 1350 kcal. That equals the neutral
/// floor exactly, so it is NOT clamped (floorApplied tests for "less than").
/// Real deficit 814 kcal/day ≙ −0.74 → label "−0,75 kg/Woche", forecast 14–16
/// weeks instead of 10. dailyKcalGoal is display only and holds the computed
/// value so the card stays self-consistent.
const _standard = UserProfile(
  weightKg: 78,
  heightCm: 178,
  ageYears: 30,
  targetWeightKg: 68,
  weightGoal: WeightGoal.lose1kg,
  dailyKcalGoal: 1350,
);

/// Small profile: maintenance 1237, wish −275 (the cap 40 × 11 = 440 is above
/// the wish and does not bite) → 950 kcal; the female floor of 1200 raises the
/// target and leaves 37 kcal/day ≙ 0.034 kg/week — below weeklyRateNoiseKg.
/// weeksToGoalRange must return null here instead of a fantasy week count, and
/// paceWarning produces the "stable" sentence.
///
/// Age 45, not 60: with PAL 1.3 a 60-year-old would land 61 kcal ABOVE
/// maintenance, just outside the noise band and thus no longer "stable".
const _clampedFlat = UserProfile(
  weightKg: 40,
  heightCm: 150,
  ageYears: 45,
  sex: BiologicalSex.female,
  targetWeightKg: 36,
  weightGoal: WeightGoal.lose025kg,
  dailyKcalGoal: 1200,
);

/// Profile where the floor REALLY clamps: maintenance 1578, cap 605 → 950 →
/// 1200 (female). Effectively −378 kcal/day ≙ −0.3436 → "−0,35 kg/Woche".
/// paceWarning names the floor (the binding constraint), not the cap.
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
      // GoalPlanCard reads context.l10n.
      locale: const Locale('de'),
      supportedLocales: const [Locale('de'), Locale('en')],
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      // No backgroundColor: the theme sets scaffoldBackgroundColor from the
      // tokens, and a hard value would break light mode.
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

    // Linear: 10 kg / 0.74 per week = 13.5 -> 14. Dynamic (requirement drops
    // 22 kcal per lost kg): 16. Both from the effective rate, not the 10 weeks
    // of the wished pace.
    expect(find.text('Noch 10 kg · Ziel in ca. 14–16 Wochen'), findsOneWidget,
        reason: 'Spanne aus weeksToGoalRange, untere Grenze 14 statt 10');
  });

  testWidgets('Frisst die Klemme das ganze Defizit, wird nichts versprochen',
      (tester) async {
    await _pumpCard(tester, _clampedFlat);

    // weeksToGoalRange == null -> the card must not invent a week count.
    expect(find.text('Noch 4 kg bis zum Wunschgewicht'), findsOneWidget);
    expect(find.textContaining('Wochen'), findsNothing);
    // ... and the pace is honestly "stable", not −0.25 kg/week.
    expect(find.text('Gewicht stabil'), findsOneWidget);
    expect(find.text('−0,25 kg/Woche'), findsNothing);
  });

  testWidgets('Weicht der Plan vom Wunsch ab, erklaert die Karte das auf Abruf',
      (tester) async {
    await _pumpCard(tester, _standard);

    // KcalTargets.paceWarning hangs on the pace chip as tooltip/semantics —
    // no second prose block on the card, but not silent either. For the
    // standard profile only the cap bites.
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

    // Cap AND floor bite; paceWarning names the binding floor with the
    // unclamped 950 value, not the cap.
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
    // Large, active user (maintenance 3570 at PAL 1.75): neither the 1500
    // floor nor the cap bites, only the 50-kcal rounding of the daily target
    // remains — 3000 instead of 3020 computes to −0.52 kg/week, inside the
    // noise band, so no warning. The 0.05 grid shows "−0,5".
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
    // The edit IconButton has its own tooltip; what counts is that NO tooltip
    // wraps the pace chip (_MaybeTooltip passes it through when paceWarning is
    // null).
    expect(find.ancestor(of: paceValue, matching: find.byType(Tooltip)),
        findsNothing,
        reason: 'Kein Widerspruch -> kein Hinweis');
  });
}
