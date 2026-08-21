import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/model_limits.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/onboarding_screen.dart';
import 'package:eatova/src/theme/app_theme.dart';

/// Delegates fuer die drei MaterialApp-Instanzen dieser Datei — der Screen
/// ruft seit Paket 6 (i18n) durchgehend `context.l10n`.
const _l10nDelegates = [
  AppLocalizations.delegate,
  GlobalMaterialLocalizations.delegate,
  GlobalWidgetsLocalizations.delegate,
  GlobalCupertinoLocalizations.delegate,
];

// Der Design-Refactor 2026-08-09 hat am Onboarding nichts als das Aussehen
// geaendert — Ablauf, Schritte, Validierung, Keys und Texte sind gleich
// geblieben. Diese Datei ist der Beleg dafuer: die einzige Aenderung gegenueber
// der Fassung davor ist das `theme:` an den drei pumpWidget-Stellen (der
// Screen liest seine Farben jetzt ueber `context.t`, und AppTokens.of wirft
// bewusst, wenn die ThemeExtension fehlt).
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

    // Berechnetes Tagesziel (Kalorien-Review 2026-08-21): BMR(male,78,178,30)
    // = 1747.5 × 1.7 (moderat) = 2970.75. „−1 kg/Woche" wuenscht −1100, der
    // 1-%-Defizitdeckel (78 kg × 11 = 858 kcal/Tag) laesst nur −858 zu
    // → 2112.75 → auf 50 gerundet = 2100. Die Untergrenze fuer Maenner (1500)
    // greift nicht.
    expect(result.dailyKcalGoal, 2100);
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
    // sitzend (PAL 1,4), Ziel 68 kg bei −1 kg/Woche. Erhaltung 2330,
    // gewuenscht −1100 — der 1-%-Defizitdeckel (78 kg × 11 = 858 kcal/Tag)
    // laesst nur −858 zu → 1472 → auf 50 gerundet 1450. Real sind das
    // −880 kcal ≙ −0,8 kg/Woche.
    await pumpToSummary(
      tester,
      const UserProfile(weightGoal: WeightGoal.lose1kg, targetWeightKg: 68),
      steps: 10,
    );

    expect(textOfKey(tester, 'onboarding-summary-kcal'), '1450');
    expect(goalRowTexts(tester), ['Ziel · −0,8 kg/Woche', '−880 kcal']);

    // Das Versprechen darf nirgends mehr als Zusage stehen.
    expect(find.text('Ziel · −1 kg/Woche'), findsNothing);
    expect(find.text('−1100 kcal'), findsNothing);

    // 2330 − 1450 = 880: die Karte rechnet in sich auf.
    expect(textOfKey(tester, 'onboarding-summary-maintenance'), '2330 kcal');

    // Fertiger Warnsatz aus KcalTargets.paceWarning — hier spricht der
    // Defizitdeckel, nicht die Untergrenze (1450 liegt ueber den 1350 fuer
    // „divers").
    expect(
      textOfKey(tester, 'onboarding-summary-pace-warning'),
      'Schneller als 1 % deines Körpergewichts pro Woche empfehlen wir nicht: '
      'Dein Defizit ist auf 858 kcal/Tag begrenzt. Dein tatsächliches Tempo '
      'ist damit −0,8 kg/Woche statt −1 kg/Woche.',
    );

    // Prognose aus der echten Rate, als Spanne: linear 10 kg / 0,8 = 12,5 →
    // 13 Wochen (nicht 10), dynamisch mit sinkendem Bedarf (22 kcal pro
    // verlorenem Kilo) 15 Wochen.
    expect(
      textOfKey(tester, 'onboarding-summary-timeline'),
      '68 kg in ca. 13–15 Wochen erreichbar – anfangs schneller, später '
      'langsamer.',
    );
  });

  testWidgets(
      'identischer Plan wird nicht mehr als zwei verschiedene Versprechen ausgewiesen',
      (tester) async {
    // Fuer das Standardprofil laufen „Zuegig" und „Ambitioniert" seit dem
    // 1-%-Deckel auseinander (1500 vs. 1450 kcal). In dieselbe Klemme laufen
    // beide bei 55 kg / 160 cm / 35 J. / weiblich / sitzend: Erhaltung 1700,
    // Deckel 55 × 11 = 605 — beide Tempi wuenschen mehr (−825 / −1100), beide
    // bekommen −605 → 1095 → 1100, und die Untergrenze fuer Frauen hebt beide
    // auf 1200. Real: −500 kcal ≙ −0,45 kg/Woche, fuer beide.
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
    // Prognose 55 → 48 kg: linear 7 / 0,4545 = 15,4 → 16 Wochen, dynamisch 19.
    expect(ambitioniert, [
      '1200',
      'Ziel · −0,45 kg/Woche',
      '−500 kcal',
      '48 kg in ca. 16–19 Wochen erreichbar – anfangs schneller, später '
          'langsamer.',
    ]);
  });

  testWidgets('ohne belastbare Prognose steht keine Wochenzahl da',
      (tester) async {
    // 40 kg / 150 cm / 60 J. / weiblich / sitzend: Erhaltung 1227, „Sanft"
    // wuenscht −275 → 950 → die Untergrenze fuer Frauen hebt auf 1200. Uebrig
    // bleiben −27 kcal ≙ −0,02 kg/Woche — unterhalb des Rundungsrauschens
    // (weeklyRateNoiseKg = 0,05), also „Gewicht stabil". weeksToGoal liefert
    // korrekt null statt einer Fantasie-Wochenzahl aus einer Division durch
    // fast nichts.
    await pumpToSummary(
      tester,
      const UserProfile(
        weightKg: 40,
        heightCm: 150,
        ageYears: 60,
        sex: BiologicalSex.female,
        weightGoal: WeightGoal.lose025kg,
        targetWeightKg: 38,
      ),
      steps: 10,
    );

    expect(goalRowTexts(tester), ['Ziel · Gewicht stabil', '−27 kcal']);
    expect(find.textContaining('in ca.'), findsNothing);
    // Auch die offene Form „fruehestens in ca. N Wochen" darf hier nicht
    // stehen — sie setzt eine lineare Prognose voraus, die es nicht gibt.
    expect(find.textContaining('frühestens'), findsNothing);
    expect(
      textOfKey(tester, 'onboarding-summary-timeline'),
      'Für dieses Ziel lässt sich kein verlässlicher Zeitraum schätzen.',
    );
    expect(
      textOfKey(tester, 'onboarding-summary-pace-warning'),
      'Aus Sicherheitsgründen liegt dein Tagesziel bei 1200 kcal statt '
      '950 kcal. Dein tatsächliches Tempo ist damit Gewicht stabil statt '
      '−0,25 kg/Woche.',
    );
  });

  testWidgets('ohne Sicherheitsklemme steht kein Warnsatz auf der Karte',
      (tester) async {
    // 78 kg / 178 cm / 30 J. / neutral / sitzend bei −0,75 kg/Woche:
    // Erhaltung 2330, gewuenscht −825 — unter dem 1-%-Deckel von 858 kcal/Tag;
    // Ziel 1500 liegt ueber der Untergrenze von 1350 fuer „divers". Keine der
    // drei Grenzen greift, das Versprechen wird gehalten (−830 statt
    // −825 kcal ist reines 50er-Rundungsrauschen).
    await pumpToSummary(
      tester,
      const UserProfile(weightGoal: WeightGoal.lose075kg, targetWeightKg: 68),
      steps: 10,
    );

    expect(textOfKey(tester, 'onboarding-summary-kcal'), '1500');
    expect(goalRowTexts(tester), ['Ziel · −0,75 kg/Woche', '−830 kcal']);
    expect(
      find.byKey(const ValueKey('onboarding-summary-pace-warning')),
      findsNothing,
    );
  });

  /// Der Untertitel einer Tempo-Option — innerhalb ihrer eigenen Zeile gesucht.
  Finder paceOptionText(String goalName, String text) => find.descendant(
        of: find.byKey(ValueKey('onboarding-pace-$goalName')),
        matching: find.text(text),
      );

  // Diese Erwartung hiess bis Welle 6 „der Tempo-Picker zeigt weiter das
  // gewaehlte Tempo" und nagelte fest, dass im Picker '−1100 kcal / Tag' steht.
  // Die Begruendung dafuer lautete: „dort gibt es noch kein Profil-Ergebnis".
  //
  // Das war fuer den Onboarding-Picker falsch. Der Tempo-Schritt ist Nummer 9
  // von 11 (_Step: intro, sex, age, height, weight, activity, goal, target,
  // PACE, diet, summary) — Gewicht, Groesse, Alter, Geschlecht und Aktivitaet
  // stehen zu diesem Zeitpunkt alle fest, `KcalCalculator.calculate` braucht
  // nichts weiter. Fuer das Standardprofil ergeben „Zuegig" (−825 kcal) und
  // „Ambitioniert" (−1100 kcal) beide dasselbe Tagesziel von 1200 kcal; der
  // Picker versprach zwei verschiedene Tempi fuer denselben Plan und erst der
  // NAECHSTE Schritt korrigierte auf −0,72 kg/Woche. Genau das nennt der
  // Review woertlich „identischer Plan, zwei verschiedene Versprechen".
  //
  // Der Titel bleibt das Versprechen — er ist der Name der Option, und zwei
  // Zeilen „Ambitioniert · −0,72 kg/Woche" waeren nicht unterscheidbar. Neu
  // ist der Untertitel: er nennt statt des ungedeckten kcal-Deltas den Plan,
  // den die Option mit DIESEM Koerper ergibt.
  //
  // Seit dem Kalorien-Review 2026-08-21 (PAL 1,4 statt 1,2, Untergrenze 1350
  // fuer „divers", 1-%-Defizitdeckel) fallen „Zuegig" und „Ambitioniert" fuer
  // das Standardprofil nicht mehr zusammen — jetzt ist es der Deckel, der
  // „Ambitioniert" auf −0,8 kg/Woche drueckt. Das Prinzip ist dasselbe: der
  // Untertitel sagt, was WIRKLICH herauskommt, bevor der Nutzer waehlt.
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

    // Titel = Auswahl. Bleibt.
    expect(find.text('Ambitioniert · −1 kg/Woche'), findsOneWidget);
    expect(find.text('Zügig · −0,75 kg/Woche'), findsOneWidget);

    // Untertitel = Folge, mit DIESEM Koerper gerechnet (78 kg / 178 cm /
    // 30 J. / neutral / sitzend, Erhaltung 2330). „Ambitioniert" wuenscht
    // −1100, bekommt wegen des 1-%-Deckels (858) nur −858 → 1450 kcal ≙
    // −0,8 kg/Woche — und genau das steht da, vor der Auswahl, nicht erst in
    // der Zusammenfassung.
    expect(
      paceOptionText('lose1kg', 'Ergibt 1450 kcal/Tag · −0,8 kg/Woche'),
      findsOneWidget,
    );

    // Wo weder Deckel noch Untergrenze greifen, steht dieselbe Zeile mit den
    // Zahlen, die das gewaehlte Tempo auch wirklich liefert.
    expect(
      paceOptionText('lose075kg', 'Ergibt 1500 kcal/Tag · −0,75 kg/Woche'),
      findsOneWidget,
    );
    expect(
      paceOptionText('lose05kg', 'Ergibt 1800 kcal/Tag · −0,48 kg/Woche'),
      findsOneWidget,
    );
    expect(
      paceOptionText('lose025kg', 'Ergibt 2050 kcal/Tag · −0,25 kg/Woche'),
      findsOneWidget,
    );

    // Das ungedeckte Versprechen ist weg: „−1 kg/Woche" steht genau einmal
    // auf dem Schritt — als Name der Option, nicht als Folge.
    expect(find.text('−1100 kcal / Tag'), findsNothing);
    expect(find.text('−825 kcal / Tag'), findsNothing);
    expect(find.textContaining('−1 kg/Woche'), findsOneWidget);
  });

  // -------------------------------------------------------------------------
  // Gespiegelte Grenzen — das Onboarding hatte 16..99 / 40..200 / 120..220 als
  // Literale im Code, waehrend `profiles` 16..100 / 30..300 / 100..250 zulaesst
  // (ProfileLimits). model_limits.dart wurde gar nicht importiert, die Kopien
  // konnten also unbemerkt auseinanderlaufen.
  // -------------------------------------------------------------------------

  /// Springt vom Intro zum Schritt [field] und liest dessen grosse Zahl.
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
    // Vorher wurde in initState still auf 200 geklemmt: ein Nutzer mit 210 kg
    // konnte sein Gewicht gar nicht wahrheitsgemaess angeben, obwohl
    // profiles.weight_kg (30..300) es akzeptiert haette.
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
    // Der eigentliche Fund ist nicht die einzelne Zahl, sondern dass die
    // Kopien driften koennen. Die 16 ist Art. 8 DSGVO (Gesundheitsdaten nach
    // Art. 9) und wurde mit Migration 20260807090000 schon einmal von 13 auf
    // 16 verschoben — eine Kopie, die beim naechsten Mal stehen bleibt, ist
    // ein Rechtsverstoss mit Ansage. Deshalb pruefen die Erwartungen gegen die
    // Konstanten, nicht gegen Zahlen: verschiebt jemand ProfileLimits, wandert
    // das Onboarding mit.
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
