import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/number_input.dart';
import 'package:eatova/src/widgets/common/decimal_text.dart';

// The widget-side half of the shared number input: prefills that read back
// unchanged, the one hint text per problem, and the digit budget that lets
// separators through.

TextEditingValue _wert(String text) => TextEditingValue(
  text: text,
  selection: TextSelection.collapsed(offset: text.length),
);

void main() {
  group('formatDecimalInput', () {
    test('liest sich zurueck als dieselbe Zahl', () {
      for (final l10n in [deL10n, enL10n]) {
        for (final wert in <double>[
          0,
          1,
          1.5,
          2.125,
          12.345,
          999.999,
          0.125,
          1234.567,
          72.25,
          100,
          1000,
        ]) {
          final text = formatDecimalInput(wert, l10n, maxFractionDigits: 6);
          expect(
            NumberInput.parse(text).value,
            wert,
            reason: '${l10n.localeName}: $wert -> "$text"',
          );
        }
      }
    });

    test('nur die mehrdeutige Form bekommt eine Null angehaengt', () {
      expect(formatDecimalInput(2.125, deL10n, maxFractionDigits: 3), '2,1250');
      expect(formatDecimalInput(2.125, enL10n, maxFractionDigits: 3), '2.1250');
      expect(formatDecimalInput(1.5, deL10n), '1,5');
      expect(formatDecimalInput(0.125, deL10n, maxFractionDigits: 3), '0,125');
      expect(formatDecimalInput(1234.567, enL10n, maxFractionDigits: 3),
          '1234.567');
      expect(formatDecimalInput(1000, deL10n), '1000');
    });
  });

  group('numberInputHint', () {
    test('Mehrdeutigkeit nennt beide Lesarten in der Sprache der App', () {
      expect(
        numberInputHint(NumberInput.parse('2,500'), deL10n),
        deL10n.numberInputAmbiguous('2,5', '2500'),
      );
      expect(
        numberInputHint(NumberInput.parse('2,500'), enL10n),
        enL10n.numberInputAmbiguous('2.5', '2500'),
      );
    });

    test('Bruch nur in Ganzzahlfeldern', () {
      expect(numberInputHint(NumberInput.parse('3,5'), deL10n), isNull);
      expect(
        numberInputHint(NumberInput.parse('3,5'), deL10n, wholeNumber: true),
        deL10n.numberInputWholeNumber,
      );
      expect(
        numberInputHint(NumberInput.parse('3,0'), deL10n, wholeNumber: true),
        isNull,
      );
    });

    test('leer, ungueltig und gueltig bleiben beim Feld', () {
      for (final text in <String>['', 'abc', '-5', '42']) {
        expect(
          numberInputHint(NumberInput.parse(text), enL10n, wholeNumber: true),
          isNull,
          reason: text,
        );
      }
    });
  });

  group('DigitBudgetFormatter', () {
    const budget = DigitBudgetFormatter(5);

    test('Trenner zaehlen nicht mit', () {
      final neu = budget.formatEditUpdate(_wert('10.00'), _wert('10.000'));
      expect(neu.text, '10.000');
      final gruppe = budget.formatEditUpdate(_wert(''), _wert('1.000,5'));
      expect(gruppe.text, '1.000,5');
    });

    test('Buchstaben werden nicht gefiltert', () {
      expect(budget.formatEditUpdate(_wert(''), _wert('3,5 g')).text, '3,5 g');
    });

    test('ein volles Feld nimmt keine weitere Ziffer', () {
      final alt = _wert('12.345');
      expect(budget.formatEditUpdate(alt, _wert('12.3456')), alt);
    });

    test('Einfuegen wird nach der letzten passenden Ziffer gekuerzt', () {
      final neu = budget.formatEditUpdate(_wert(''), _wert('123.456,7'));
      expect(neu.text, '123.45');
      expect(neu.selection, const TextSelection.collapsed(offset: 6));
    });

    test('ein zu langer Wert von aussen laesst sich kuerzen', () {
      final neu = budget.formatEditUpdate(_wert('1234567'), _wert('123456'));
      expect(neu.text, '123456');
    });
  });
}
