import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/settings/goals_screen.dart';
import 'package:eatova/src/widgets/shared/target_bmi_hint.dart';

import 'support/harness.dart';

// Pure BMI hint logic (target_bmi_hint.dart): exactly 18.5 and exactly 35.0
// trigger NO hint, only strictly below/above. Formatting uses a German
// decimal comma. The last test pins the goals page wiring: the gentle hint
// on the target weight appears and disappears live while typing.
void main() {
  group('targetBmi', () {
    test('berechnet kg/m² korrekt', () {
      // 70 kg / 1,78 m² = 22,09…
      final bmi = targetBmi(heightCm: 178, targetWeightKg: 70)!;
      expect(bmi, closeTo(22.09, 0.01));
    });

    test('liefert null bei unplausibler Größe oder Gewicht', () {
      expect(targetBmi(heightCm: 0, targetWeightKg: 70), isNull);
      expect(targetBmi(heightCm: -170, targetWeightKg: 70), isNull);
      expect(targetBmi(heightCm: 178, targetWeightKg: 0), isNull);
    });
  });

  group('targetBmiHintText', () {
    test('kein Hinweis im unauffälligen Bereich', () {
      expect(targetBmiHintText(heightCm: 178, targetWeightKg: 70), isNull);
      expect(targetBmiHintText(heightCm: 165, targetWeightKg: 60), isNull);
    });

    test('Grenzfall: BMI exakt 18,5 löst keinen Hinweis aus', () {
      // 74 kg / 2,00 m² = exactly 18,5.
      expect(targetBmiHintText(heightCm: 200, targetWeightKg: 74), isNull);
    });

    test('knapp unter 18,5 zeigt den sanften Untergewichts-Hinweis', () {
      // 73 kg / 2,00 m² = 18,25.
      final text = targetBmiHintText(heightCm: 200, targetWeightKg: 73);
      expect(text, isNotNull);
      expect(text, contains('unterhalb'));
      expect(text, contains('18,3'));
    });

    test('deutlich unter 18,5: Wortlaut nicht moralisierend, mit Komma-BMI',
        () {
      // 50 kg / 1,80 m² = 15,43.
      final text = targetBmiHintText(heightCm: 180, targetWeightKg: 50);
      expect(
        text,
        'Dieses Zielgewicht entspräche einem BMI von 15,4 — das liegt '
        'unterhalb des als gesund geltenden Bereichs.',
      );
    });

    test('Grenzfall: BMI exakt 35,0 löst keinen Hinweis aus', () {
      // 140 kg / 2,00 m² = exactly 35,0.
      expect(targetBmiHintText(heightCm: 200, targetWeightKg: 140), isNull);
    });

    test('knapp über 35 zeigt den milden Hinweis nach oben', () {
      // 141 kg / 2,00 m² = 35,25.
      final text = targetBmiHintText(heightCm: 200, targetWeightKg: 141);
      expect(text, isNotNull);
      expect(text, contains('oberhalb'));
      expect(text, contains('35,3'));
    });

    test('unplausible Größe → kein Hinweis statt Division durch null', () {
      expect(targetBmiHintText(heightCm: 0, targetWeightKg: 55), isNull);
    });
  });

  testWidgets('Ziele-Seite: der Hinweis kommt und geht live beim Tippen',
      (tester) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await pumpLocalized(
      tester,
      const GoalsScreen(
        profile: UserProfile(heightCm: 178, targetWeightKg: 70),
      ),
      brightness: Brightness.light,
      scaffold: false,
      safeArea: false,
      settle: true,
    );
    final hinweis = find.byKey(const ValueKey('target-bmi-hint'));
    Future<void> ziel(String kg) async {
      await tester.enterText(
        find.byKey(const ValueKey('settings-target-weight')),
        kg,
      );
      await tester.pump();
    }

    // Target 70 kg / 1.78 m -> BMI 22.1: no hint.
    expect(hinweis, findsNothing);

    // Target 55 kg -> BMI 17.4 (< 18.5): the gentle hint appears.
    await ziel('55');
    expect(hinweis, findsOneWidget);
    expect(find.textContaining('unterhalb'), findsOneWidget);

    // Target 120 kg -> BMI 37.9 (> 35): the mild upward hint.
    await ziel('120');
    expect(hinweis, findsOneWidget);
    expect(find.textContaining('oberhalb'), findsOneWidget);

    // Back into the unremarkable range: the hint disappears.
    await ziel('70');
    expect(hinweis, findsNothing);
  });
}
