import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/widgets/shared/target_bmi_hint.dart';

// Pure BMI-Hinweis-Logik (target_bmi_hint.dart): Grenzfälle exakt 18,5 und
// exakt 35,0 lösen KEINEN Hinweis aus; erst strikt darunter/darüber. Die
// Formatierung nutzt deutsches Dezimalkomma.
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
      // 74 kg / 2,00 m² = exakt 18,5.
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
      // 140 kg / 2,00 m² = exakt 35,0.
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
}
