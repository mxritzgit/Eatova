import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  // Viewport-Pinning + Overflow-Toleranz wie in runFullFlow, für Tests die
  // nicht den kompletten Flow fahren.
  Future<void> pumpOnboarding(
    WidgetTester tester, {
    required UserProfile initialProfile,
    ValueChanged<UserProfile>? onComplete,
    // Frischer Key = echtes Remount samt initState. Noetig, wenn ein Test das
    // Onboarding zweimal mit unterschiedlichen Profilen pumpt: sonst wird das
    // bestehende State-Objekt nur aktualisiert und behaelt seinen Schritt.
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
    // Profil mit zu niedrigem Alter (z.B. Altbestand) → Onboarding hebt auf 16.
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

    // Der Stepper kommt nicht unter das Minimum.
    await tester.tap(find.byKey(const ValueKey('onboarding-age-dec')));
    await tester.pumpAndSettle();
    expect(ageValue(), '16');
  });

  testWidgets(
      'target step shows gentle BMI hint below 18.5 and hides it again',
      (tester) async {
    // Gewicht 60 kg / Größe 178 cm: Default-Ziel beim Abnehmen = 55 kg
    // → Ziel-BMI 17,4 (< 18,5) → Hinweis sichtbar.
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

    // Ziel auf 59 kg anheben → BMI 18,6 → Hinweis verschwindet.
    for (var i = 0; i < 4; i++) {
      await tester.tap(find.byKey(const ValueKey('onboarding-target-inc')));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('target-bmi-hint')), findsNothing);
    expect(find.textContaining('unterhalb'), findsNothing);
  });

  // -------------------------------------------------------------------------
  // D4 · Systemzurueck (Android-Button / Randgeste)
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

  /// Simuliert den Android-Systemzurueck-Button bzw. die Randgeste (die Engine
  /// schickt `popRoute` auf `flutter/navigation`) und meldet, ob die Engine
  /// daraufhin die Activity beenden wuerde — `SystemNavigator.pop` heisst hier
  /// woertlich: die App schliesst sich.
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
    // Abnehm-Ziel vorbelegt → Zielgewicht- und Tempo-Schritt sind sichtbar,
    // der Flow hat 11 Schritte (Index 0..10).
    await pumpOnboarding(
      tester,
      initialProfile: const UserProfile(
        weightGoal: WeightGoal.lose1kg,
        targetWeightKg: 68,
      ),
    );

    // Acht beantwortete Schritte durchlaufen → wir stehen auf „Ernaehrungsweise".
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

    await systemBackClosesApp(tester); // Geste: diet → pace
    expect(find.byKey(const ValueKey('onboarding-step-pace')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('onboarding-back'))); // Pfeil
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('onboarding-step-target')), findsOneWidget);
  });

  testWidgets('Systemzurueck auf dem Intro-Schritt schliesst die App',
      (tester) async {
    // Schritt 0: nichts investiert. Die Root-Route gibt den Pop frei, damit
    // sich die App wie jede andere Android-App verhaelt.
    await pumpOnboarding(tester, initialProfile: const UserProfile());
    expect(find.byKey(const ValueKey('onboarding-step-intro')), findsOneWidget);
    expect(find.byKey(const ValueKey('onboarding-back')), findsNothing);

    expect(await systemBackClosesApp(tester), isTrue);
  });

  // -------------------------------------------------------------------------
  // B2 · Plan-Karte zeigt das effektive Tempo, nicht das versprochene
  // -------------------------------------------------------------------------

  /// Die beiden Texte der „Ziel"-Zeile in der Aufschluesselung: [Label, Wert].
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

  /// Fuehrt das Onboarding bis zur Zusammenfassung durch, ohne unterwegs etwas
  /// anzutippen — alle Antworten kommen aus [initialProfile].
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
    // Standardprofil aus dem Review: 78 kg / 178 cm / 30 J. / neutral /
    // sitzend, Ziel 68 kg bei −1 kg/Woche. Erhaltung 1997, gewuenscht 900,
    // ausgegeben nach 1200er-Klemme 1200 → real −797 kcal ≙ −0,72 kg/Woche.
    await pumpToSummary(
      tester,
      const UserProfile(weightGoal: WeightGoal.lose1kg, targetWeightKg: 68),
      steps: 10,
    );

    expect(textOfKey(tester, 'onboarding-summary-kcal'), '1200');
    expect(goalRowTexts(tester), ['Ziel · −0,72 kg/Woche', '−797 kcal']);

    // Das Versprechen darf nirgends mehr als Zusage stehen.
    expect(find.text('Ziel · −1 kg/Woche'), findsNothing);
    expect(find.text('−1100 kcal'), findsNothing);

    // 1997 − 1200 = 797: die Karte rechnet in sich auf.
    expect(textOfKey(tester, 'onboarding-summary-maintenance'), '1997 kcal');

    // Fertiger Warnsatz aus KcalTargets.paceWarning.
    expect(
      textOfKey(tester, 'onboarding-summary-pace-warning'),
      'Aus Sicherheitsgründen liegt dein Tagesziel bei 1200 kcal statt '
      '900 kcal. Dein tatsächliches Tempo ist damit −0,72 kg/Woche statt '
      '−1 kg/Woche.',
    );

    // Prognose aus der echten Rate: 10 kg / 0,7245 = 13,8 → 14 Wochen (nicht 10).
    expect(
      textOfKey(tester, 'onboarding-summary-timeline'),
      '68 kg in ca. 14 Wochen erreichbar.',
    );
  });

  testWidgets(
      'identischer Plan wird nicht mehr als zwei verschiedene Versprechen ausgewiesen',
      (tester) async {
    // lose075kg und lose1kg ergeben fuer das Standardprofil beide 1200 kcal.
    await pumpToSummary(
      tester,
      const UserProfile(weightGoal: WeightGoal.lose1kg, targetWeightKg: 68),
      steps: 10,
    );
    final ambitioniert = [
      textOfKey(tester, 'onboarding-summary-kcal'),
      ...goalRowTexts(tester),
      textOfKey(tester, 'onboarding-summary-timeline'),
    ];

    await pumpToSummary(
      tester,
      const UserProfile(weightGoal: WeightGoal.lose075kg, targetWeightKg: 68),
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
    expect(ambitioniert, ['1200', 'Ziel · −0,72 kg/Woche', '−797 kcal',
      '68 kg in ca. 14 Wochen erreichbar.']);
  });

  testWidgets('ohne belastbare Prognose steht keine Wochenzahl da',
      (tester) async {
    // 45 kg / 150 cm / 60 J. / weiblich / sitzend: Erhaltung 1112, gewuenscht
    // 550 → Klemme hebt auf 1200. Das Ziel „abnehmen" wirkt damit als
    // Ueberschuss (+88 kcal) — weeksToGoal liefert korrekt null.
    await pumpToSummary(
      tester,
      const UserProfile(
        weightKg: 45,
        heightCm: 150,
        ageYears: 60,
        sex: BiologicalSex.female,
        weightGoal: WeightGoal.lose05kg,
        targetWeightKg: 40,
      ),
      steps: 10,
    );

    expect(goalRowTexts(tester), ['Ziel · +0,08 kg/Woche', '+88 kcal']);
    expect(find.textContaining('in ca.'), findsNothing);
    expect(
      textOfKey(tester, 'onboarding-summary-timeline'),
      'Für dieses Ziel lässt sich kein verlässlicher Zeitraum schätzen.',
    );
    expect(
      textOfKey(tester, 'onboarding-summary-pace-warning'),
      'Aus Sicherheitsgründen liegt dein Tagesziel bei 1200 kcal statt '
      '550 kcal. Dein tatsächliches Tempo ist damit +0,08 kg/Woche statt '
      '−0,5 kg/Woche.',
    );
  });

  testWidgets('ohne Sicherheitsklemme steht kein Warnsatz auf der Karte',
      (tester) async {
    // 78 kg / 178 cm / 30 J. / neutral / moderat (PAL 1,55): Erhaltung 2580,
    // Ziel 1500 — die Klemme greift nicht, das Versprechen wird gehalten
    // (−1080 statt −1100 kcal ist reines 50er-Rundungsrauschen).
    await pumpToSummary(
      tester,
      const UserProfile(
        activityLevel: ActivityLevel.moderate,
        weightGoal: WeightGoal.lose1kg,
        targetWeightKg: 68,
      ),
      steps: 10,
    );

    expect(textOfKey(tester, 'onboarding-summary-kcal'), '1500');
    expect(
      find.byKey(const ValueKey('onboarding-summary-pace-warning')),
      findsNothing,
    );
  });

  testWidgets('der Tempo-Picker zeigt weiter das gewaehlte Tempo',
      (tester) async {
    // Im Picker gibt es noch kein Profil-Ergebnis — dort ist das versprochene
    // Tempo die richtige Beschriftung, nicht die effektive Rate.
    await pumpOnboarding(
      tester,
      initialProfile: const UserProfile(
        weightGoal: WeightGoal.lose1kg,
        targetWeightKg: 68,
      ),
    );
    await advance(tester, 8);
    expect(find.byKey(const ValueKey('onboarding-step-pace')), findsOneWidget);

    expect(find.text('Ambitioniert · −1 kg/Woche'), findsOneWidget);
    expect(find.text('Zügig · −0,75 kg/Woche'), findsOneWidget);
    expect(find.text('−1100 kcal / Tag'), findsOneWidget);
  });
}
