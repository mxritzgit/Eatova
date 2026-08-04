import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/onboarding_screen.dart';

void main() {
  Future<UserProfile> runFullFlow(WidgetTester tester) async {
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

    UserProfile? captured;
    await tester.pumpWidget(
      MaterialApp(
        home: OnboardingScreen(
          firstName: 'Moritz',
          initialProfile: const UserProfile(),
          onComplete: (p) => captured = p,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('screen-onboarding')), findsOneWidget);
    expect(find.text('Willkommen, Moritz.'), findsOneWidget);

    Future<void> next() async {
      await tester.tap(find.byKey(const ValueKey('onboarding-next')));
      await tester.pumpAndSettle();
    }

    // Intro → Geschlecht
    await next();
    await tester.tap(find.byKey(const ValueKey('onboarding-sex-male')));
    await tester.pumpAndSettle();
    await next();

    // Alter / Größe / Gewicht — Defaults übernehmen
    await next(); // age
    await next(); // height
    await next(); // weight

    // Aktivität
    await tester.tap(find.byKey(const ValueKey('onboarding-activity-moderate')));
    await tester.pumpAndSettle();
    await next();

    // Ziel: Abnehmen wählen (schaltet Zielgewicht + Tempo frei)
    await tester.tap(find.byKey(const ValueKey('onboarding-goal-lose')));
    await tester.pumpAndSettle();
    await next();

    // Zielgewicht — Default (Gewicht − 5) übernehmen
    expect(find.byKey(const ValueKey('onboarding-step-target')), findsOneWidget);
    await next();

    // Tempo: −1 kg/Woche (ambitioniert)
    await tester.tap(find.byKey(const ValueKey('onboarding-pace-lose1kg')));
    await tester.pumpAndSettle();
    await next();

    // Ernährungsweise: Vegetarisch wählen (PROD-6 Diät-Schritt)
    expect(find.byKey(const ValueKey('onboarding-step-diet')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('onboarding-diet-vegetarian')));
    await tester.pumpAndSettle();
    await next();

    // Zusammenfassung
    expect(find.byKey(const ValueKey('onboarding-summary-kcal')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('onboarding-finish')));
    await tester.pumpAndSettle();

    expect(captured, isNotNull);
    return captured!;
  }

  testWidgets('onboarding walks every step and produces a finished profile',
      (tester) async {
    final result = await runFullFlow(tester);

    // Auswahl wurde übernommen.
    expect(result.sex, BiologicalSex.male);
    expect(result.activityLevel, ActivityLevel.moderate);
    expect(result.weightGoal, WeightGoal.lose1kg);
    expect(result.targetWeightKg, 73); // 78 − 5
    expect(result.diet, DietPreference.vegetarian);
    expect(result.onboardingCompleted, isTrue);

    // Berechnetes Tagesziel: BMR(male,78,178,30)=1747.5 × 1.55 = 2708.6
    // − 1100 (−1 kg/Woche) = 1608.6 → auf 50 gerundet = 1600.
    expect(result.dailyKcalGoal, 1600);
    expect(result.proteinGoalG, greaterThan(0));
    expect(result.carbsGoalG, greaterThan(0));
    expect(result.fatGoalG, greaterThan(0));
  });

  testWidgets('maintain goal skips target and pace steps', (tester) async {
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

    UserProfile? captured;
    await tester.pumpWidget(
      MaterialApp(
        home: OnboardingScreen(
          firstName: 'Moritz',
          initialProfile: const UserProfile(),
          onComplete: (p) => captured = p,
        ),
      ),
    );
    await tester.pumpAndSettle();

    Future<void> next() async {
      await tester.tap(find.byKey(const ValueKey('onboarding-next')));
      await tester.pumpAndSettle();
    }

    await next(); // intro → sex
    await next(); // sex → age
    await next(); // age → height
    await next(); // height → weight
    await next(); // weight → activity
    await next(); // activity → goal
    // Default-Ziel ist "halten" → Zielgewicht + Tempo entfallen, nächster
    // Schritt ist der Diät-Schritt, dann die Summary.
    await next(); // goal → diet

    // Zielgewicht-/Tempo-Schritte sind übersprungen, der Diät-Schritt nicht.
    expect(find.byKey(const ValueKey('onboarding-step-target')), findsNothing);
    expect(find.byKey(const ValueKey('onboarding-step-diet')), findsOneWidget);
    await next(); // diet → summary (Default-Diät „Alles" übernehmen)

    expect(find.byKey(const ValueKey('onboarding-summary-kcal')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('onboarding-finish')));
    await tester.pumpAndSettle();

    expect(captured, isNotNull);
    expect(captured!.weightGoal, WeightGoal.maintain);
    expect(captured!.diet, DietPreference.none); // Default unverändert
    expect(captured!.onboardingCompleted, isTrue);
  });
}
