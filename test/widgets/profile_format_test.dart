// Der Profil-Screen mischte bisher zwei Zahlenschreibweisen: der Hero zeigte
// „78,4 kg" (deutsch), die Delta-Pille daneben „-2.6 kg" (englisch), weil sie
// direkt aus toStringAsFixed kam. formatKgDe/formatBmiDe sind ab jetzt die
// einzige Quelle fuer kg- und BMI-Zahlen der Profil-Seite.

import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/widgets/profile/profile_widgets.dart';

void main() {
  group('formatKgDe', () {
    test('ganze Kilogramm stehen ohne Nachkommastelle', () {
      expect(formatKgDe(78), '78');
      expect(formatKgDe(78.0), '78');
      expect(formatKgDe(0), '0');
    });

    test('Zehntel bekommen ein Komma, keinen Punkt', () {
      expect(formatKgDe(78.4), '78,4');
      expect(formatKgDe(78.42), '78,4');
      expect(formatKgDe(78.45), '78,5');
    });

    test('das Vorzeichen bleibt erhalten', () {
      expect(formatKgDe(-2.6), '-2,6');
      expect(formatKgDe(-2.0), '-2');
    });

    test('Nicht-Zahlen ergeben keinen „NaN"-Text', () {
      expect(formatKgDe(double.nan), '–');
      expect(formatKgDe(double.infinity), '–');
    });
  });

  group('formatBmiDe', () {
    test('BMI behaelt immer genau eine Nachkommastelle', () {
      expect(formatBmiDe(22.44), '22,4');
      expect(formatBmiDe(22.0), '22,0');
      expect(formatBmiDe(30.55), '30,6');
    });

    test('Nicht-Zahlen ergeben keinen „NaN"-Text', () {
      expect(formatBmiDe(double.nan), '–');
    });
  });
}
