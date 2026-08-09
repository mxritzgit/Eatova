import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/onboarding_screen.dart';
import 'package:eatova/src/theme/app_theme.dart';

// DESIGN_REFACTOR §7.2 / §5: jeder Screen rendert in BEIDEN Helligkeiten und
// bei Systemschrift 200 % ohne RenderFlex-Overflow.
//
// Das Onboarding hat elf Schritte, und mehrere davon sind Layout-Grenzfaelle:
// drei Geschlechts-Kacheln nebeneinander, die 52er-Ziffer zwischen zwei
// 52er-Rundknoepfen, und die Zusammenfassung mit Hero, drei Makro-Kacheln,
// vierzeiliger Aufschluesselung und Warnsatz. Sie werden deshalb alle einzeln
// durchlaufen statt nur der erste Schritt.
//
// Anders als in den Verhaltens-Tests werden Overflows hier NICHT geschluckt —
// sie sind der Pruefgegenstand.
void main() {
  /// Abnehm-Ziel vorbelegt → Zielgewicht- und Tempo-Schritt sind sichtbar,
  /// der Flow hat alle 11 Schritte. Die Sicherheitsklemme greift, also traegt
  /// die Zusammenfassung zusaetzlich den Warnsatz.
  const vollerFlow = UserProfile(
    weightGoal: WeightGoal.lose1kg,
    targetWeightKg: 68,
  );

  Future<void> pumpAlleSchritte(
    WidgetTester tester,
    String fall, {
    required Brightness brightness,
    double textScale = 1.0,
  }) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3.0;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    final overflows = <String>[];
    final prior = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception.toString().contains('overflowed')) {
        overflows.add(details.summary.toString());
        return;
      }
      prior?.call(details);
    };

    const schritte = <String>[
      'intro',
      'sex',
      'age',
      'height',
      'weight',
      'activity',
      'goal',
      'target',
      'pace',
      'diet',
      'summary',
    ];
    final gesehen = <String>[];

    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildEatovaTheme(brightness),
          home: OnboardingScreen(
            firstName: 'Moritz',
            initialProfile: vollerFlow,
            onComplete: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      for (final schritt in schritte) {
        if (find.byKey(ValueKey('onboarding-step-$schritt')).evaluate().isEmpty) {
          continue;
        }
        gesehen.add(schritt);
        if (schritt == 'summary') break;
        await tester.tap(find.byKey(const ValueKey('onboarding-next')));
        await tester.pumpAndSettle();
      }
    } finally {
      FlutterError.onError = prior;
    }

    expect(gesehen, schritte,
        reason: '$fall hat nicht alle elf Schritte durchlaufen');
    expect(tester.takeException(), isNull);
    expect(
      overflows,
      isEmpty,
      reason: '$fall overflowt:\n${overflows.join('\n')}',
    );
  }

  testWidgets('alle Schritte rendern im Hellmodus', (tester) async {
    await pumpAlleSchritte(tester, 'hell', brightness: Brightness.light);
  });

  testWidgets('alle Schritte rendern im Dunkelmodus', (tester) async {
    await pumpAlleSchritte(tester, 'dunkel', brightness: Brightness.dark);
  });

  testWidgets('alle Schritte rendern bei textScale 2.0 (hell)', (tester) async {
    await pumpAlleSchritte(
      tester,
      'hell @2.0',
      brightness: Brightness.light,
      textScale: 2.0,
    );
  });

  testWidgets('alle Schritte rendern bei textScale 2.0 (dunkel)',
      (tester) async {
    await pumpAlleSchritte(
      tester,
      'dunkel @2.0',
      brightness: Brightness.dark,
      textScale: 2.0,
    );
  });

  testWidgets('Weiter-Knopf und Zurueck-Pfeil bleiben Knoepfe',
      (tester) async {
    // Vorher ein FilledButton und ein IconButton — beide trugen `isButton` von
    // selbst. Jetzt sind es [PrimaryActionButton] und [SquareIconButton], also
    // InkWells: ohne ausdrueckliche Semantik kuendigt ein Screenreader die
    // beiden einzigen Navigationsmittel des Onboardings nur noch als Text an.
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildEatovaTheme(Brightness.light),
        home: OnboardingScreen(
          firstName: 'Moritz',
          initialProfile: vollerFlow,
          onComplete: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.getSemantics(find.byKey(const ValueKey('onboarding-next'))),
      isSemantics(isButton: true),
    );

    // Ein Schritt weiter — jetzt gibt es auch den Zurueck-Pfeil.
    await tester.tap(find.byKey(const ValueKey('onboarding-next')));
    await tester.pumpAndSettle();
    // „Zurück", nicht „Zurueck": das Label wird VORGELESEN, die ASCII-
    // Umschrift klaenge bei TalkBack wie „zurookk". Der Test pinnt die
    // Korrektur, statt sie stillschweigend mitzunehmen.
    expect(
      tester.getSemantics(find.byKey(const ValueKey('onboarding-back'))),
      isSemantics(isButton: true, label: 'Zurück'),
    );
  });

  testWidgets('die Zusammenfassung bleibt auch ohne Warnsatz heil',
      (tester) async {
    // Ohne Sicherheitsklemme faellt der Warnkasten weg — anderer Zweig,
    // andere Hoehenverteilung.
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3.0;
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    final overflows = <String>[];
    final prior = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception.toString().contains('overflowed')) {
        overflows.add(details.summary.toString());
        return;
      }
      prior?.call(details);
    };

    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildEatovaTheme(Brightness.light),
          home: OnboardingScreen(
            firstName: 'Moritz',
            initialProfile: const UserProfile(
              activityLevel: ActivityLevel.moderate,
              weightGoal: WeightGoal.lose1kg,
              targetWeightKg: 68,
            ),
            onComplete: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (var i = 0; i < 10; i++) {
        await tester.tap(find.byKey(const ValueKey('onboarding-next')));
        await tester.pumpAndSettle();
      }
    } finally {
      FlutterError.onError = prior;
    }

    expect(find.byKey(const ValueKey('onboarding-summary-kcal')),
        findsOneWidget);
    expect(
      find.byKey(const ValueKey('onboarding-summary-pace-warning')),
      findsNothing,
    );
    expect(overflows, isEmpty, reason: overflows.join('\n'));
  });
}
