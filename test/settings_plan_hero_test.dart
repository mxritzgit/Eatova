import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/settings/goals_screen.dart';
import 'package:eatova/src/services/kcal_calculator.dart';
import 'package:eatova/src/theme/app_theme.dart';

// B2 — the plan card promised the CHOSEN pace even though the safety floor
// raises the daily target, so "maintenance 1997 · −1 kg/week" stood right
// above "1200", which is −0.72 kg/week.
//
// Numbers as of the calorie review 2026-08-21: default profile 78 kg / 178 cm
// / 30 y / neutral / sedentary → maintenance 2164, cap 825 kcal/day, floor
// 1350. At "−1 kg/week" the cap binds and 1350 lands EXACTLY on the floor, so
// testing the floor itself needs a lighter profile (see [klemmProfil]).
void main() {
  /// Profile whose stored energy goals match the calculation exactly — only
  /// then does the screen start in live mode (manual switch off).
  UserProfile autoProfil(
    WeightGoal goal, {
    UserProfile basis = const UserProfile(),
  }) {
    final p = basis.copyWith(weightGoal: goal);
    final t = const KcalCalculator().calculate(p);
    return p.copyWith(
      dailyKcalGoal: t.kcal,
      proteinGoalG: t.proteinG,
      carbsGoalG: t.carbsG,
      fatGoalG: t.fatG,
    );
  }

  /// Profile where cap AND floor bind: maintenance 1578, cap 605, floor 1200.
  /// −1100 is capped to −605, lands at 950 and is raised to 1200 — effectively
  /// −378 kcal/day, i.e. −0.35 kg/week.
  const klemmProfil = UserProfile(
    weightKg: 55,
    heightCm: 160,
    ageYears: 35,
    sex: BiologicalSex.female,
    targetWeightKg: 55,
  );

  Future<void> openSettings(
    WidgetTester tester, {
    required UserProfile profile,
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

    await tester.pumpWidget(
      MaterialApp(
        theme: buildEatovaTheme(Brightness.light),
        locale: const Locale('de'),
        supportedLocales: const [Locale('de'), Locale('en')],
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                key: const ValueKey('open-settings'),
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) => GoalsScreen(profile: profile),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open-settings')));
    await tester.pumpAndSettle();
  }

  testWidgets('Plan-Karte zeigt das effektive statt des versprochenen Tempos',
      (tester) async {
    await openSettings(tester, profile: autoProfil(WeightGoal.lose1kg));

    // Maintenance 2164, target 1350 (deficit capped at 825) → −0.75 kg/week.
    expect(find.text('Erhaltung 2164 · −0,75 kg/Woche'), findsOneWidget);
    expect(find.text('Erhaltung 2164 · −1 kg/Woche'), findsNothing);
  });

  testWidgets('Plan-Karte erklaert die Sicherheitsklemme in einem Satz',
      (tester) async {
    await openSettings(
      tester,
      profile: autoProfil(WeightGoal.lose1kg, basis: klemmProfil),
    );

    // Maintenance 1578, target 1200 (raised from 950) → −0.35 kg/week. The
    // floor binds harder than the cap, so the sentence names the floor.
    expect(find.text('Erhaltung 1578 · −0,35 kg/Woche'), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-pace-warning')), findsOneWidget);
    expect(
      find.text(
        'Aus Sicherheitsgründen liegt dein Tagesziel bei 1200 kcal statt '
        '950 kcal. Dein tatsächliches Tempo ist damit −0,35 kg/Woche statt '
        '−1 kg/Woche.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('Plan-Karte erklaert den 1-%-Defizitdeckel in einem Satz',
      (tester) async {
    await openSettings(tester, profile: autoProfil(WeightGoal.lose1kg));

    // The floor does not bind — the target lands exactly ON it and
    // `floorApplied` needs a real undershoot. The cap (858 rounded down to
    // 825) slows −1100 to −825, and the sentence names the rounded step.
    expect(find.byKey(const ValueKey('settings-pace-warning')), findsOneWidget);
    expect(
      find.text(
        'Schneller als 1 % deines Körpergewichts pro Woche empfehlen wir '
        'nicht: Dein Defizit ist auf 825 kcal/Tag begrenzt. Dein tatsächliches '
        'Tempo ist damit −0,75 kg/Woche statt −1 kg/Woche.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('ohne Klemme bleibt die Plan-Karte ohne Hinweis', (tester) async {
    await openSettings(tester, profile: autoProfil(WeightGoal.maintain));

    // 2163.85 → 2150 kcal; −14 kcal/day is inside the 0.05 noise band.
    expect(find.byKey(const ValueKey('settings-pace-warning')), findsNothing);
    expect(find.text('Erhaltung 2164 · Gewicht stabil'), findsOneWidget);
  });

  testWidgets('manuelles Tagesziel bestimmt das angezeigte Tempo',
      (tester) async {
    // 2500 stored with the persisted manual flag (F7-01): +336 kcal/day,
    // i.e. +0.3 kg/week. NOT the default 2200 — those +36 kcal/day stay in the
    // noise band and would render the same string as the computed target.
    await openSettings(
      tester,
      profile: const UserProfile()
          .copyWith(dailyKcalGoal: 2500, manualEnergy: true),
    );

    expect(find.text('Erhaltung 2164 · +0,3 kg/Woche'), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-pace-warning')), findsNothing);
  });
}
