import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/model_limits.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/onboarding_screen.dart';
import 'package:eatova/src/widgets/shared/target_bmi_hint.dart';

import '../support/harness.dart';

// J1 — das umgedrehte Zielgewicht-Fenster.
//
// Am Spaltenrand kippt das Fenster: Zunehmen bei 300 kg will min 301 und darf
// max 300, Abnehmen bei 30 kg will min 30 und darf max 29. Geklemmt wurde an
// ZWEI Stellen mit VERSCHIEDENEN Regeln — `_targetSafe` faltete nach unten auf
// den Spaltendeckel (300), `_NumberPicker` nach oben auf sein eigenes `min`
// (301). Der Schritt zeigte deshalb die grosse Zahl 301 ueber einer Fussnote
// „0 kg zunehmen", der BMI-Hinweis rechnete mit 300, und beide Stepper
// schrieben einen Wert, den der Aufrufer sofort wieder wegklemmte: tote
// Bedienelemente.
//
// Die Wurzel ist das Fenster selbst. Es gibt jetzt genau eines
// (`_targetWindow`); ist es leer, gibt es nichts zu waehlen, und der Schritt
// (samt Tempo-Schritt) entfaellt — wie bei „Gewicht halten". Der Plan liest
// sich ueber `effectiveWeightGoal` ohnehin als Halten.
//
// Schwesterdatei: test/onboarding_target_consistency_test.dart (P9-07), die
// dieselbe Zusicherung fuer die normalen Fenster festnagelt.

/// Alle Richtungen, die ein Zielgewicht haben — je eine pro Seite. Die Paces
/// unterscheiden sich fuer die Fensterregel nicht.
const _abnehmen = WeightGoal.lose05kg;
const _zunehmen = WeightGoal.gain025kg;

void main() {
  UserProfile? fertiges;

  Future<void> starte(WidgetTester tester) async {
    pinPhoneViewport(tester);

    // Die 52-px-Ziffern sprengen den festgenagelten Viewport an einigen
    // Schritten; das ist ein eigener Layoutfall (text_scale_stress_test) und
    // hier nicht das Thema.
    final prior = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception.toString().contains('overflowed')) return;
      prior?.call(details);
    };
    addTearDown(() => FlutterError.onError = prior);

    fertiges = null;
    await pumpLocalized(
      tester,
      OnboardingScreen(
        key: UniqueKey(),
        firstName: 'Moritz',
        initialProfile: const UserProfile(),
        onComplete: (p) => fertiges = p,
      ),
      brightness: Brightness.light,
      scaffold: false,
      safeArea: false,
      settle: true,
    );
  }

  Future<void> weiter(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('onboarding-next')));
    await tester.pumpAndSettle();
  }

  /// Setzt einen Picker ueber seinen eigenen Slider-Callback — deterministisch,
  /// wo ein Zug es nicht ist, und laeuft durch dasselbe `_set` wie die Hand.
  Future<void> setze(WidgetTester tester, String feld, int wert) async {
    final slider = tester.widget<Slider>(
      find.byKey(ValueKey<String>('onboarding-$feld-slider')),
    );
    slider.onChanged!(wert.toDouble());
    await tester.pumpAndSettle();
  }

  Future<void> tippe(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(ValueKey<String>(key)));
    await tester.pumpAndSettle();
  }

  /// Wie [tippe], aber fuer Bedienelemente INNERHALB des Schritt-Scrollers —
  /// die koennen unter der Kante liegen. (Kopf und Weiter-Knopf stehen
  /// ausserhalb, dort wuerde `ensureVisible` keinen Scroller finden.)
  Future<void> tippeImSchritt(WidgetTester tester, String key) async {
    final finder = find.byKey(ValueKey<String>(key));
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  String angezeigt(WidgetTester tester, String feld) => tester
      .widget<Text>(find.byKey(ValueKey<String>('onboarding-$feld-value')))
      .data!;

  /// intro → … → Richtung gewaehlt → einmal weiter. Danach steht entweder der
  /// Zielgewicht-Schritt da oder der naechste danach.
  Future<void> bisNachDerRichtung(
    WidgetTester tester, {
    required int gewicht,
    required bool zunehmen,
  }) async {
    await starte(tester);
    for (var i = 0; i < 4; i++) {
      await weiter(tester); // intro → sex → age → height → weight
    }
    await setze(tester, 'weight', gewicht);
    await weiter(tester); // activity
    await weiter(tester); // goal
    await tippe(tester, zunehmen ? 'onboarding-goal-gain' : 'onboarding-goal-lose');
    await weiter(tester);
  }

  // =========================================================================
  // Der Befund selbst
  // =========================================================================

  testWidgets(
      'Zunehmen am 300-kg-Deckel: kein Zielgewicht-Schritt mit toten Knoepfen',
      (tester) async {
    await bisNachDerRichtung(tester, gewicht: 300, zunehmen: true);

    // Es gibt kein Zielgewicht, das bei 300 kg noch „zunehmen" hiesse — die
    // Spalte endet dort. Also wird auch keines angeboten.
    expect(find.byKey(const ValueKey('onboarding-step-target')), findsNothing,
        reason: 'ein leeres Fenster hat nichts zu waehlen');
    expect(find.byKey(const ValueKey('onboarding-target-value')), findsNothing);
    expect(find.byKey(const ValueKey('onboarding-target-inc')), findsNothing,
        reason: 'ein Knopf, der nichts bewegen kann, gehoert nicht hin');
    expect(find.byKey(const ValueKey('onboarding-target-dec')), findsNothing);
    // Die Zahl aus dem Befund: 301 stand ueber „0 kg zunehmen" und ausserhalb
    // der Spalte (30 … 300).
    expect(find.text('301'), findsNothing);
    expect(find.text('0 kg zunehmen'), findsNothing);

    // Der Schritt danach ist die Ernaehrung — das Tempo faellt mit, weil ohne
    // Ziel auch kein Tempo geplant wird.
    expect(find.byKey(const ValueKey('onboarding-step-diet')), findsOneWidget);
    expect(find.byKey(const ValueKey('onboarding-step-pace')), findsNothing);
  });

  testWidgets('Abnehmen am 30-kg-Boden: spiegelbildlich derselbe Fall',
      (tester) async {
    await bisNachDerRichtung(tester, gewicht: 30, zunehmen: false);

    expect(find.byKey(const ValueKey('onboarding-step-target')), findsNothing);
    expect(find.text('0 kg abnehmen'), findsNothing,
        reason: 'vorher stand da eine 30 ueber „0 kg abnehmen" und zwei tote '
            'Stepper');
    expect(find.byKey(const ValueKey('onboarding-step-diet')), findsOneWidget);
  });

  testWidgets('der Plan am Deckel ist widerspruchsfrei und behaelt die Absicht',
      (tester) async {
    await bisNachDerRichtung(tester, gewicht: 300, zunehmen: true);

    await weiter(tester); // diet → summary
    expect(find.byKey(const ValueKey('onboarding-summary-kcal')), findsOneWidget);

    // Die Zeile der Karte liest `effectivePaceLabel`; der Zeitraumsatz liest
    // jetzt dieselbe Quelle. Vorher stand daneben „Fuer dieses Ziel laesst sich
    // kein verlaesslicher Zeitraum schaetzen" — ein Raetsel ueber einem Plan,
    // der schlicht haelt.
    expect(find.text('Ziel · Gewicht stabil'), findsOneWidget);
    expect(
      tester
          .widget<Text>(
              find.byKey(const ValueKey('onboarding-summary-timeline')))
          .data,
      'Du hältst dein Gewicht von 300 kg.',
    );

    await tippe(tester, 'onboarding-finish');
    expect(fertiges, isNotNull);
    expect(fertiges!.weightKg, 300);
    expect(fertiges!.targetWeightKg, 300,
        reason: 'das Wunschgewicht bleibt in der Spalte (30 … 300)');
    expect(fertiges!.targetWeightKg,
        lessThanOrEqualTo(ProfileLimits.targetWeightKgMax));
    expect(fertiges!.weightGoal, _zunehmen,
        reason: 'die Absicht wird nicht ueberschrieben (P9-08d) — ein '
            'niedrigeres Gewicht nimmt sie spaeter wieder auf');
    // …und genau deshalb plant der Rechner Halten, ohne dass irgendwer etwas
    // umschreiben musste.
    expect(fertiges!.effectiveWeightGoal, WeightGoal.maintain);
  });

  // =========================================================================
  // Gegenprobe: die normalen Fenster bleiben unangetastet
  // =========================================================================

  testWidgets('ein normales Fenster verhaelt sich unveraendert',
      (tester) async {
    await bisNachDerRichtung(tester, gewicht: 80, zunehmen: true);

    expect(find.byKey(const ValueKey('onboarding-step-target')), findsOneWidget);
    expect(angezeigt(tester, 'target'), '85'); // 80 + 5
    expect(find.text('5 kg zunehmen'), findsOneWidget);

    // Die Bedienelemente bewegen etwas — das ist der Unterschied zum Deckel.
    await tippeImSchritt(tester, 'onboarding-target-inc');
    expect(angezeigt(tester, 'target'), '86');
    expect(find.text('6 kg zunehmen'), findsOneWidget);
    await tippeImSchritt(tester, 'onboarding-target-dec');
    await tippeImSchritt(tester, 'onboarding-target-dec');
    expect(angezeigt(tester, 'target'), '84');
    expect(find.text('4 kg zunehmen'), findsOneWidget);

    // Der Slider spannt genau ueber das Fenster der Richtung.
    final slider = tester.widget<Slider>(
      find.byKey(const ValueKey('onboarding-target-slider')),
    );
    expect(slider.min, targetWeightMinFor(_zunehmen, 80).toDouble());
    expect(slider.max, targetWeightMaxFor(_zunehmen, 80).toDouble());
  });

  testWidgets('ein Fenster mit genau einem Wert bleibt ein Schritt',
      (tester) async {
    // 299 kg + zunehmen laesst genau die 300 uebrig. Das ist KEIN leeres
    // Fenster — es waere ueberkorrigiert, den Schritt auch hier zu schlucken.
    await bisNachDerRichtung(tester, gewicht: 299, zunehmen: true);

    expect(find.byKey(const ValueKey('onboarding-step-target')), findsOneWidget);
    expect(angezeigt(tester, 'target'), '300');
    expect(find.text('1 kg zunehmen'), findsOneWidget);
    expect(find.byKey(const ValueKey('onboarding-target-slider')), findsNothing,
        reason: 'ein einziger erlaubter Wert hat nichts zu schieben');
  });

  // =========================================================================
  // Die Zusicherung selbst, ueber die Raender gefahren
  // =========================================================================

  testWidgets(
      'Zahl, Fussnote und BMI-Hinweis nennen ueberall dieselben Kilogramm',
      (tester) async {
    // Die Faelle, an denen die zwei Klemmen auseinanderliefen, plus je ein
    // gewoehnlicher zur Kontrolle.
    const faelle = <({int gewicht, bool zunehmen})>[
      (gewicht: 300, zunehmen: true),
      (gewicht: 299, zunehmen: true),
      (gewicht: 80, zunehmen: true),
      (gewicht: 30, zunehmen: false),
      (gewicht: 31, zunehmen: false),
      (gewicht: 80, zunehmen: false),
    ];

    for (final fall in faelle) {
      final ziel = fall.zunehmen ? _zunehmen : _abnehmen;
      final min = targetWeightMinFor(ziel, fall.gewicht);
      final max = targetWeightMaxFor(ziel, fall.gewicht);
      final leer = min > max;
      final wo = '${fall.gewicht} kg / '
          '${fall.zunehmen ? "zunehmen" : "abnehmen"}';

      await bisNachDerRichtung(
        tester,
        gewicht: fall.gewicht,
        zunehmen: fall.zunehmen,
      );

      if (leer) {
        expect(find.byKey(const ValueKey('onboarding-step-target')), findsNothing,
            reason: '$wo: kein konsistentes Ziel, also kein Schritt');
        continue;
      }

      expect(find.byKey(const ValueKey('onboarding-step-target')), findsOneWidget,
          reason: '$wo: das Fenster $min … $max ist waehlbar');
      final zahl = int.parse(angezeigt(tester, 'target'));
      expect(zahl, inInclusiveRange(min, max), reason: wo);

      // Die Fussnote nennt genau die Differenz zu dieser Zahl…
      final delta = (fall.gewicht - zahl).abs();
      expect(
        find.text(
          fall.zunehmen ? '$delta kg zunehmen' : '$delta kg abnehmen',
        ),
        findsOneWidget,
        reason: wo,
      );
      // …und der BMI-Hinweis rechnet mit derselben Zahl. Default-Groesse des
      // Onboardings: 178 cm.
      final erwartet = targetBmiHintText(heightCm: 178, targetWeightKg: zahl);
      if (erwartet == null) {
        expect(find.byKey(const ValueKey('target-bmi-hint')), findsNothing,
            reason: wo);
      } else {
        expect(find.text(erwartet), findsOneWidget, reason: wo);
      }
    }
  });

  // =========================================================================
  // Die zweite Klemmregel ist weg, nicht bloss uebersteuert
  // =========================================================================
  test('im Bildschirm klemmt nur noch EINE Regel', () {
    // Der Kern von J1: nicht dass die beiden Regeln heute dasselbe ergeben,
    // sondern dass es die zweite nicht mehr gibt. Kaeme sie zurueck, koennte
    // der Picker wieder etwas anderes zeichnen als Fussnote, BMI-Hinweis und
    // gespeicherter Plan sagen — und genau das war unsichtbar, weil beide
    // Seiten „irgendwie" klemmten.
    final code = File('lib/src/screens/onboarding_screen.dart')
        .readAsStringSync()
        .split('\n')
        .where((z) => !z.trimLeft().startsWith('//'))
        .join('\n');

    expect(
      code,
      isNot(contains('max < min ? min : max')),
      reason: 'die Ausweichregel des Pickers: sie faltete ein leeres Fenster '
          'nach OBEN auf min (301), waehrend der Aufrufer nach UNTEN auf den '
          'Spaltendeckel faltete (300)',
    );
    expect(
      code,
      contains('assert(min <= max'),
      reason: 'stattdessen ein Vertrag — ein leeres Fenster darf den Picker '
          'gar nicht mehr erreichen',
    );
    expect(
      code,
      contains('targetWeightMinFor'),
      reason: 'die Fensterregel selbst bleibt in user_profile.dart (P9-08b)',
    );
  });
}
