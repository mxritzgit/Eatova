import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/model_limits.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/onboarding_screen.dart';
import 'package:eatova/src/theme/app_theme.dart';

/// Delegates for the MaterialApp instances here; the screen uses
/// `context.l10n` throughout.
const _l10nDelegates = [
  AppLocalizations.delegate,
  GlobalMaterialLocalizations.delegate,
  GlobalWidgetsLocalizations.delegate,
  GlobalCupertinoLocalizations.delegate,
];

// Behaviour tests for the onboarding flow: steps, validation, keys and texts.
// Every pumpWidget needs `theme:`, because the screen reads its colors via
// `context.t` and AppTokens.of throws without the theme extension.
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
        theme: buildEatovaTheme(Brightness.light),
        locale: const Locale('de'),
        supportedLocales: const [Locale('de'), Locale('en')],
        localizationsDelegates: _l10nDelegates,
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

    // intro → sex
    await next();
    await tester.tap(find.byKey(const ValueKey('onboarding-sex-male')));
    await tester.pumpAndSettle();
    await next();

    // age / height / weight — keep the defaults
    await next(); // age
    await next(); // height
    await next(); // weight

    // activity
    await tester.tap(find.byKey(const ValueKey('onboarding-activity-moderate')));
    await tester.pumpAndSettle();
    await next();

    // goal: losing weight unlocks the target and pace steps
    await tester.tap(find.byKey(const ValueKey('onboarding-goal-lose')));
    await tester.pumpAndSettle();
    await next();

    // target weight — keep the default (weight − 5)
    expect(find.byKey(const ValueKey('onboarding-step-target')), findsOneWidget);
    await next();

    // pace: −1 kg/week
    await tester.tap(find.byKey(const ValueKey('onboarding-pace-lose1kg')));
    await tester.pumpAndSettle();
    await next();

    // diet: pick vegetarian
    expect(find.byKey(const ValueKey('onboarding-step-diet')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('onboarding-diet-vegetarian')));
    await tester.pumpAndSettle();
    await next();

    // summary
    expect(find.byKey(const ValueKey('onboarding-summary-kcal')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('onboarding-finish')));
    await tester.pumpAndSettle();

    expect(captured, isNotNull);
    return captured!;
  }

  testWidgets('onboarding walks every step and produces a finished profile',
      (tester) async {
    final result = await runFullFlow(tester);

    // Selections were kept.
    expect(result.sex, BiologicalSex.male);
    expect(result.activityLevel, ActivityLevel.moderate);
    expect(result.weightGoal, WeightGoal.lose1kg);
    expect(result.targetWeightKg, 73); // 78 − 5
    expect(result.diet, DietPreference.vegetarian);
    expect(result.onboardingCompleted, isTrue);

    // Daily target: BMR(male,78,178,30) = 1747.5 × 1.6 (moderate) = 2796.
    // −1 kg/week wants −1100, but the 1 % deficit cap (825 kcal/day) allows
    // only −825 → 1971 → rounded to 1950. The male floor (1500) does not bite.
    expect(result.dailyKcalGoal, 1950);
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
        theme: buildEatovaTheme(Brightness.light),
        locale: const Locale('de'),
        supportedLocales: const [Locale('de'), Locale('en')],
        localizationsDelegates: _l10nDelegates,
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
    // The default goal is maintain, so target and pace are skipped and the
    // diet step comes next.
    await next(); // goal → diet

    // Target and pace are skipped, the diet step is not.
    expect(find.byKey(const ValueKey('onboarding-step-target')), findsNothing);
    expect(find.byKey(const ValueKey('onboarding-step-diet')), findsOneWidget);
    await next(); // diet → summary, keeping the default diet

    expect(find.byKey(const ValueKey('onboarding-summary-kcal')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('onboarding-finish')));
    await tester.pumpAndSettle();

    expect(captured, isNotNull);
    expect(captured!.weightGoal, WeightGoal.maintain);
    expect(captured!.diet, DietPreference.none); // default unchanged
    expect(captured!.onboardingCompleted, isTrue);
  });

  // Viewport pinning and overflow tolerance as in runFullFlow, for tests that
  // do not walk the whole flow.
  Future<void> pumpOnboarding(
    WidgetTester tester, {
    required UserProfile initialProfile,
    ValueChanged<UserProfile>? onComplete,
    // A fresh key forces a real remount with initState. Needed when a test
    // pumps the onboarding twice with different profiles, or the existing
    // state object is merely updated and keeps its step.
    Key? screenKey,
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
        localizationsDelegates: _l10nDelegates,
        home: OnboardingScreen(
          key: screenKey,
          firstName: 'Moritz',
          initialProfile: initialProfile,
          onComplete: onComplete ?? (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('age is clamped to a minimum of 16 (DSGVO Art. 8)',
      (tester) async {
    // A legacy profile below the minimum is lifted to 16.
    await pumpOnboarding(
      tester,
      initialProfile: const UserProfile(ageYears: 13),
    );

    Future<void> next() async {
      await tester.tap(find.byKey(const ValueKey('onboarding-next')));
      await tester.pumpAndSettle();
    }

    await next(); // intro → sex
    await next(); // sex → age

    String ageValue() => tester
        .widget<Text>(find.byKey(const ValueKey('onboarding-age-value')))
        .data!;
    expect(ageValue(), '16');

    // The stepper cannot go below the minimum.
    await tester.tap(find.byKey(const ValueKey('onboarding-age-dec')));
    await tester.pumpAndSettle();
    expect(ageValue(), '16');
  });

  testWidgets(
      'target step shows gentle BMI hint below 18.5 and hides it again',
      (tester) async {
    // 60 kg / 178 cm: the default loss target of 55 kg gives BMI 17.4, below
    // 18.5, so the hint shows.
    await pumpOnboarding(
      tester,
      initialProfile: const UserProfile(weightKg: 60),
    );

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
    await tester.tap(find.byKey(const ValueKey('onboarding-goal-lose')));
    await tester.pumpAndSettle();
    await next(); // goal → target

    expect(find.byKey(const ValueKey('onboarding-step-target')), findsOneWidget);
    expect(find.byKey(const ValueKey('target-bmi-hint')), findsOneWidget);
    expect(find.textContaining('unterhalb'), findsOneWidget);

    // Raising the target to 59 kg gives BMI 18.6 and the hint disappears.
    for (var i = 0; i < 4; i++) {
      await tester.tap(find.byKey(const ValueKey('onboarding-target-inc')));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('target-bmi-hint')), findsNothing);
    expect(find.textContaining('unterhalb'), findsNothing);
  });

  // -------------------------------------------------------------------------
  // D4 · System back (Android button / edge gesture)
  // -------------------------------------------------------------------------

  Future<void> tapNext(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('onboarding-next')));
    await tester.pumpAndSettle();
  }

  Future<void> advance(WidgetTester tester, int times) async {
    for (var i = 0; i < times; i++) {
      await tapNext(tester);
    }
  }

  /// Simulates the Android back button / edge gesture (`popRoute` on
  /// `flutter/navigation`) and reports whether the engine would close the
  /// activity, i.e. whether `SystemNavigator.pop` was called.
  Future<bool> systemBackClosesApp(WidgetTester tester) async {
    final platformCalls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        platformCalls.add(call.method);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'flutter/navigation',
      const JSONMethodCodec().encodeMethodCall(const MethodCall('popRoute')),
      (_) {},
    );
    await tester.pumpAndSettle();
    return platformCalls.contains('SystemNavigator.pop');
  }

  testWidgets(
      'Systemzurueck geht einen Schritt zurueck statt acht Antworten wegzuwerfen',
      (tester) async {
    // A loss goal makes target and pace visible, so the flow has 11 steps.
    await pumpOnboarding(
      tester,
      initialProfile: const UserProfile(
        weightGoal: WeightGoal.lose1kg,
        targetWeightKg: 68,
      ),
    );

    // After eight answered steps we stand on the diet step.
    await advance(tester, 9);
    expect(find.byKey(const ValueKey('onboarding-step-diet')), findsOneWidget);

    final closesApp = await systemBackClosesApp(tester);

    expect(
      closesApp,
      isFalse,
      reason: 'Die Randgeste darf auf der Root-Route nicht die Activity '
          'beenden — acht Antworten waeren weg.',
    );
    expect(find.byKey(const ValueKey('onboarding-step-pace')), findsOneWidget,
        reason: 'Systemzurueck muss dasselbe tun wie der Header-Pfeil.');
  });

  testWidgets('Systemzurueck und Header-Pfeil landen auf demselben Schritt',
      (tester) async {
    await pumpOnboarding(
      tester,
      initialProfile: const UserProfile(
        weightGoal: WeightGoal.lose1kg,
        targetWeightKg: 68,
      ),
    );
    await advance(tester, 9);

    await systemBackClosesApp(tester); // gesture: diet → pace
    expect(find.byKey(const ValueKey('onboarding-step-pace')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('onboarding-back'))); // arrow
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('onboarding-step-target')), findsOneWidget);
  });

  testWidgets('Systemzurueck auf dem Intro-Schritt schliesst die App',
      (tester) async {
    // Step 0: nothing invested, so the root route releases the pop and the app
    // behaves like any other Android app.
    await pumpOnboarding(tester, initialProfile: const UserProfile());
    expect(find.byKey(const ValueKey('onboarding-step-intro')), findsOneWidget);
    expect(find.byKey(const ValueKey('onboarding-back')), findsNothing);

    expect(await systemBackClosesApp(tester), isTrue);
  });

  // -------------------------------------------------------------------------
  // B2 · The plan card shows the effective pace, not the promised one
  // -------------------------------------------------------------------------

  /// The two texts of the goal row in the breakdown: [label, value].
  List<String> goalRowTexts(WidgetTester tester) => tester
      .widgetList<Text>(
        find.descendant(
          of: find.byKey(const ValueKey('onboarding-summary-goal-row')),
          matching: find.byType(Text),
        ),
      )
      .map((t) => t.data ?? '')
      .toList();

  String textOfKey(WidgetTester tester, String key) =>
      tester.widget<Text>(find.byKey(ValueKey(key))).data!;

  /// Runs the onboarding to the summary without tapping anything; all answers
  /// come from [initialProfile].
  Future<void> pumpToSummary(
    WidgetTester tester,
    UserProfile initialProfile, {
    required int steps,
  }) async {
    await pumpOnboarding(
      tester,
      initialProfile: initialProfile,
      screenKey: UniqueKey(),
    );
    await advance(tester, steps);
    expect(find.byKey(const ValueKey('onboarding-summary-kcal')), findsOneWidget);
  }

  testWidgets(
      'Zusammenfassung weist das tatsaechliche Tempo aus, nicht das versprochene',
      (tester) async {
    // Default profile: 78 kg / 178 cm / 30 y / neutral / sedentary (PAL 1.3),
    // target 68 kg at −1 kg/week. Maintenance 2164; the 1 % deficit cap
    // (825 kcal/day) allows only −825 → 1350 after rounding. That equals the
    // neutral floor (1350) without undercutting it, so no clamp. Really
    // −814 kcal ≙ −0.74 kg/week, shown as −0.75 on the 0.05 grid.
    await pumpToSummary(
      tester,
      const UserProfile(weightGoal: WeightGoal.lose1kg, targetWeightKg: 68),
      steps: 10,
    );

    expect(textOfKey(tester, 'onboarding-summary-kcal'), '1350');
    expect(goalRowTexts(tester), ['Ziel · −0,75 kg/Woche', '−814 kcal']);

    // The promise must not appear as a commitment anywhere.
    expect(find.text('Ziel · −1 kg/Woche'), findsNothing);
    expect(find.text('−1100 kcal'), findsNothing);

    // 2164 − 1350 = 814: the card adds up internally.
    expect(textOfKey(tester, 'onboarding-summary-maintenance'), '2164 kcal');

    // Warning from KcalTargets.paceWarning: the deficit cap speaks here, not
    // the floor (floorApplied needs a real undercut). Since the cap is rounded
    // to the 0.05 kg/week grid, the sentence names 825 and −0.75.
    expect(
      textOfKey(tester, 'onboarding-summary-pace-warning'),
      'Schneller als 1 % deines Körpergewichts pro Woche empfehlen wir nicht: '
      'Dein Defizit ist auf 825 kcal/Tag begrenzt. Dein tatsächliches Tempo '
      'ist damit −0,75 kg/Woche statt −1 kg/Woche.',
    );

    // Forecast from the real rate, as a range: linear 10 / 0.74 = 13.5 → 14
    // weeks, dynamic (falling requirement) 16 weeks.
    expect(
      textOfKey(tester, 'onboarding-summary-timeline'),
      '68 kg in ca. 14–16 Wochen erreichbar – anfangs schneller, später '
      'langsamer.',
    );
  });

  testWidgets(
      'identischer Plan wird nicht mehr als zwei verschiedene Versprechen ausgewiesen',
      (tester) async {
    // Cap and floor stack at 55 kg / 160 cm / 35 y / female / sedentary:
    // maintenance 1578, cap 605, so both paces get −605 → 950, and the female
    // floor lifts both to 1200. Really −378 kcal ≙ −0.35 kg/week for both.
    const klemme = UserProfile(
      weightKg: 55,
      heightCm: 160,
      ageYears: 35,
      sex: BiologicalSex.female,
      targetWeightKg: 48,
    );

    await pumpToSummary(
      tester,
      klemme.copyWith(weightGoal: WeightGoal.lose1kg),
      steps: 10,
    );
    final ambitioniert = [
      textOfKey(tester, 'onboarding-summary-kcal'),
      ...goalRowTexts(tester),
      textOfKey(tester, 'onboarding-summary-timeline'),
    ];

    await pumpToSummary(
      tester,
      klemme.copyWith(weightGoal: WeightGoal.lose075kg),
      steps: 10,
    );
    final zuegig = [
      textOfKey(tester, 'onboarding-summary-kcal'),
      ...goalRowTexts(tester),
      textOfKey(tester, 'onboarding-summary-timeline'),
    ];

    expect(zuegig, ambitioniert,
        reason: 'Gleiches Tagesziel muss gleiches Tempo und gleiche Prognose '
            'zeigen — sonst versprechen zwei Plaene Verschiedenes bei '
            'identischer Zahl.');
    // Forecast 55 → 48 kg: linear 7 / 0.3436 = 20.4 → 21 weeks, dynamic 26.
    expect(ambitioniert, [
      '1200',
      'Ziel · −0,35 kg/Woche',
      '−378 kcal',
      '48 kg in ca. 21–26 Wochen erreichbar – anfangs schneller, später '
          'langsamer.',
    ]);
  });

  testWidgets('ohne belastbare Prognose steht keine Wochenzahl da',
      (tester) async {
    // 40 kg / 150 cm / 45 y / female / sedentary: maintenance 1237, the gentle
    // pace wants −275 (the cap of 440 does not bite) → 950, and the female
    // floor lifts to 1200. What is left is −37 kcal ≙ −0.03 kg/week, below the
    // rounding noise (weeklyRateNoiseKg = 0.05), so "weight stable" and
    // weeksToGoal correctly returns null instead of a fantasy number.
    // The age is 45, not 60: at 60 the clamp would tip the plan the other way
    // (+61 kcal) and no longer sit in the noise.
    await pumpToSummary(
      tester,
      const UserProfile(
        weightKg: 40,
        heightCm: 150,
        ageYears: 45,
        sex: BiologicalSex.female,
        weightGoal: WeightGoal.lose025kg,
        targetWeightKg: 38,
      ),
      steps: 10,
    );

    expect(goalRowTexts(tester), ['Ziel · Gewicht stabil', '−37 kcal']);
    expect(find.textContaining('in ca.'), findsNothing);
    // The open form ("at the earliest in N weeks") is banned too: it presumes
    // a linear forecast that does not exist here.
    expect(find.textContaining('frühestens'), findsNothing);
    expect(
      textOfKey(tester, 'onboarding-summary-timeline'),
      'Für dieses Ziel lässt sich kein verlässlicher Zeitraum schätzen.',
    );
    // When the clamp eats nearly the whole deficit, paceWarning uses
    // commonPaceWarningFloorStable instead of the awkward pace phrasing.
    expect(
      textOfKey(tester, 'onboarding-summary-pace-warning'),
      'Aus Sicherheitsgründen liegt dein Tagesziel bei 1200 kcal statt '
      '950 kcal. Damit bleibt dein Gewicht praktisch stabil, statt '
      '−0,25 kg/Woche zu erreichen.',
    );
  });

  testWidgets('ohne Sicherheitsklemme steht kein Warnsatz auf der Karte',
      (tester) async {
    // 78 kg / 178 cm / 30 y / neutral / sedentary at −0.75 kg/week: the wanted
    // −825 sits exactly on the cap, and 1350 exactly on the floor, which needs
    // a real undercut. No limit bites, the promise holds (−814 vs −825 is pure
    // rounding noise).
    await pumpToSummary(
      tester,
      const UserProfile(weightGoal: WeightGoal.lose075kg, targetWeightKg: 68),
      steps: 10,
    );

    expect(textOfKey(tester, 'onboarding-summary-kcal'), '1350');
    expect(goalRowTexts(tester), ['Ziel · −0,75 kg/Woche', '−814 kcal']);
    expect(
      find.byKey(const ValueKey('onboarding-summary-pace-warning')),
      findsNothing,
    );
  });

  /// The subtitle of a pace option, searched inside its own row.
  Finder paceOptionText(String goalName, String text) => find.descendant(
        of: find.byKey(ValueKey('onboarding-pace-$goalName')),
        matching: find.text(text),
      );

  // The pace step is number 9 of 11, so weight, height, age, sex and activity
  // are all fixed and `KcalCalculator.calculate` can run. The picker used to
  // show the raw kcal delta, promising two different paces for what is one
  // and the same plan once cap and floor apply.
  //
  // The title stays the promise (it is the option's name), but the subtitle
  // now names the plan this option actually produces for this body. Two
  // options with an identical subtitle are more honest than two different
  // promises for the same plan.
  testWidgets('der Tempo-Picker nennt den Plan, den jede Option ergibt',
      (tester) async {
    await pumpOnboarding(
      tester,
      initialProfile: const UserProfile(
        weightGoal: WeightGoal.lose1kg,
        targetWeightKg: 68,
      ),
    );
    await advance(tester, 8);
    expect(find.byKey(const ValueKey('onboarding-step-pace')), findsOneWidget);

    // Title = the choice; unchanged.
    expect(find.text('Ambitioniert · −1 kg/Woche'), findsOneWidget);
    expect(find.text('Zügig · −0,75 kg/Woche'), findsOneWidget);

    // Subtitle = the consequence for this body (maintenance 2164). The
    // ambitious pace wants −1100 but the cap allows −825 → 1350 kcal ≙
    // −0.75 kg/week, stated before the choice, not only in the summary.
    expect(
      paceOptionText('lose1kg', 'Ergibt 1350 kcal/Tag · −0,75 kg/Woche'),
      findsOneWidget,
    );

    // The brisk pace wants −825 and sits exactly on the cap: the same plan as
    // the ambitious one, and the subtitle says so.
    expect(
      paceOptionText('lose075kg', 'Ergibt 1350 kcal/Tag · −0,75 kg/Woche'),
      findsOneWidget,
    );

    // Where neither cap nor floor bites, the same line carries the numbers the
    // chosen pace really delivers, on the 0.05 grid.
    expect(
      paceOptionText('lose05kg', 'Ergibt 1600 kcal/Tag · −0,5 kg/Woche'),
      findsOneWidget,
    );
    expect(
      paceOptionText('lose025kg', 'Ergibt 1900 kcal/Tag · −0,25 kg/Woche'),
      findsOneWidget,
    );

    // The uncovered promise is gone: −1 kg/week appears exactly once on the
    // step, as the option's name, not as its consequence.
    expect(find.text('−1100 kcal / Tag'), findsNothing);
    expect(find.text('−825 kcal / Tag'), findsNothing);
    expect(find.textContaining('−1 kg/Woche'), findsOneWidget);
  });

  // -------------------------------------------------------------------------
  // Mirrored limits: the onboarding used to hardcode narrower ranges than
  // `profiles` allows (ProfileLimits), without importing model_limits.dart, so
  // the copies could drift apart unnoticed.
  // -------------------------------------------------------------------------

  /// Jumps from the intro to step [field] and reads its large number.
  Future<String> pickerValue(
    WidgetTester tester,
    UserProfile initialProfile, {
    required String field,
    required int steps,
  }) async {
    await pumpOnboarding(
      tester,
      initialProfile: initialProfile,
      screenKey: UniqueKey(),
    );
    await advance(tester, steps);
    return tester
        .widget<Text>(find.byKey(ValueKey('onboarding-$field-value')))
        .data!;
  }

  testWidgets(
      'ein Gewicht von 210 kg ueberlebt das Onboarding — die DB erlaubt bis 300',
      (tester) async {
    // initState used to clamp silently to 200, so a 210 kg user could not
    // state their weight truthfully even though profiles.weight_kg allows it.
    expect(
      await pickerValue(
        tester,
        const UserProfile(weightKg: 210),
        field: 'weight',
        steps: 4,
      ),
      '210',
    );
  });

  testWidgets(
      'eine Groesse von 115 cm ueberlebt das Onboarding — die DB erlaubt ab 100',
      (tester) async {
    expect(
      await pickerValue(
        tester,
        const UserProfile(heightCm: 115),
        field: 'height',
        steps: 3,
      ),
      '115',
    );
  });

  testWidgets('das Alter reicht bis 100, genau wie die DB-Constraint',
      (tester) async {
    expect(
      await pickerValue(
        tester,
        const UserProfile(ageYears: 100),
        field: 'age',
        steps: 2,
      ),
      '100',
    );
  });

  testWidgets(
      'die Regler-Grenzen stammen aus ProfileLimits, nicht aus Literalen',
      (tester) async {
    // The finding is drift, not any single number. The minimum age is GDPR
    // Art. 8 and has already been moved once (13 -> 16), so a stale copy would
    // be a legal violation waiting to happen. The expectations therefore check
    // against the constants, not against literals.
    Future<double> sliderRange(
      WidgetTester tester, {
      required String field,
      required int steps,
      required bool min,
    }) async {
      await pumpOnboarding(
        tester,
        initialProfile: const UserProfile(),
        screenKey: UniqueKey(),
      );
      await advance(tester, steps);
      final slider =
          tester.widget<Slider>(find.byKey(ValueKey('onboarding-$field-slider')));
      return min ? slider.min : slider.max;
    }

    expect(
      await sliderRange(tester, field: 'age', steps: 2, min: true),
      ProfileLimits.ageYearsMin.toDouble(),
      reason: 'Mindestalter ist Art. 8 DSGVO, keine UI-Vorliebe.',
    );
    expect(
      await sliderRange(tester, field: 'age', steps: 2, min: false),
      ProfileLimits.ageYearsMax.toDouble(),
    );
    expect(
      await sliderRange(tester, field: 'height', steps: 3, min: true),
      ProfileLimits.heightCmMin.toDouble(),
    );
    expect(
      await sliderRange(tester, field: 'height', steps: 3, min: false),
      ProfileLimits.heightCmMax.toDouble(),
    );
    expect(
      await sliderRange(tester, field: 'weight', steps: 4, min: true),
      ProfileLimits.weightKgMin.toDouble(),
    );
    expect(
      await sliderRange(tester, field: 'weight', steps: 4, min: false),
      ProfileLimits.weightKgMax.toDouble(),
    );
  });
}
