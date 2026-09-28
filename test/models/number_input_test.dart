import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/number_input.dart';

// The one parser behind every numeric form field. Before it, each field had its
// own rule: `digitsOnly` turned "3,5" into 35, and
// `double.tryParse(text.replaceAll(',', '.'))` read "1.000" as 1.

double? _wert(String text) => NumberInput.parse(text).value;

void main() {
  group('Dezimaltrenner', () {
    test('Komma und Punkt bedeuten dasselbe', () {
      expect(_wert('3,5'), 3.5);
      expect(_wert('3.5'), 3.5);
      expect(_wert('72,25'), 72.25);
      expect(_wert('0,125'), 0.125, reason: 'fuehrende Null: kein Tausender');
      expect(_wert('0.125'), 0.125);
      expect(_wert('1234,567'), 1234.567, reason: 'vier Stellen vor dem Trenner');
      expect(_wert('12,5000'), 12.5, reason: 'vier Nachkommastellen');
    });

    test('ganze Zahlen, auch mit fuehrenden Nullen', () {
      expect(_wert('0'), 0);
      expect(_wert('42'), 42);
      expect(_wert('007'), 7);
      expect(_wert('10000'), 10000);
    });

    test('allein stehender Trenner am Anfang oder Ende', () {
      expect(_wert(',5'), 0.5);
      expect(_wert('.5'), 0.5);
      expect(_wert(',500'), 0.5, reason: 'ohne Ganzzahlteil kein Tausender');
      expect(_wert('5,'), 5);
      expect(_wert('5.'), 5);
    });

    test('Leerraum aussen wird ignoriert', () {
      expect(_wert('  3,5 '), 3.5);
      expect(NumberInput.parse('   '), isA<EmptyNumberInput>());
      expect(NumberInput.parse(''), isA<EmptyNumberInput>());
    });
  });

  group('Tausendergruppen', () {
    test('eindeutig gruppierte Eingaben', () {
      expect(_wert('1.000,5'), 1000.5);
      expect(_wert('1,000.5'), 1000.5);
      expect(_wert('12.345,67'), 12345.67);
      expect(_wert('1.000.000'), 1000000);
      expect(_wert('1,000,000'), 1000000);
      expect(_wert('1.000.000,25'), 1000000.25);
      expect(_wert('1.000,'), 1000, reason: 'Gruppe plus leerer Bruch');
    });

    test('mehrdeutige Eingaben werden nicht geraten', () {
      for (final (text, dezimal, gruppiert) in <(String, double, double)>[
        ('1.000', 1, 1000),
        ('1,000', 1, 1000),
        ('2,500', 2.5, 2500),
        ('2.500', 2.5, 2500),
        ('10.000', 10, 10000),
        ('999,999', 999.999, 999999),
        ('1,125', 1.125, 1125),
      ]) {
        final eingabe = NumberInput.parse(text);
        expect(eingabe, isA<AmbiguousNumberInput>(), reason: text);
        expect(eingabe.value, isNull, reason: '$text darf keinen Wert haben');
        expect(eingabe.wholeValue, isNull, reason: text);
        final mehrdeutig = eingabe as AmbiguousNumberInput;
        expect(mehrdeutig.decimal, dezimal, reason: text);
        expect(mehrdeutig.grouped, gruppiert, reason: text);
      }
    });

    test('ungueltige Gruppen', () {
      for (final text in <String>[
        '1.00,5',
        '1,5.000',
        '1.000,000.5',
        '0.000,5',
        '1.000.5',
        '1,000,5',
        '10000.000,5',
        '.5,',
        '5.,',
      ]) {
        expect(
          NumberInput.parse(text),
          isA<InvalidNumberInput>(),
          reason: text,
        );
      }
    });
  });

  group('ungueltige Zeichen werden abgelehnt, nicht entfernt', () {
    test('Buchstaben, Vorzeichen, Leerraum, Exponenten', () {
      for (final text in <String>[
        '3,5 g',
        '-5',
        '+5',
        '1 000',
        '1e3',
        'NaN',
        'Infinity',
        'abc',
        '3,,5',
        '..',
        ',',
        '٣',
      ]) {
        final eingabe = NumberInput.parse(text);
        expect(eingabe, isA<InvalidNumberInput>(), reason: text);
        expect(eingabe.value, isNull, reason: text);
        expect(eingabe.wholeValue, isNull, reason: text);
      }
    });

    test('ueberlange Ziffernfolge ist keine Unendlichkeit', () {
      expect(NumberInput.parse('9' * 400), isA<InvalidNumberInput>());
    });
  });

  group('ganze Zahlen', () {
    test('wholeValue nur ohne Bruchteil', () {
      expect(NumberInput.parse('3').wholeValue, 3);
      expect(NumberInput.parse('3,0').wholeValue, 3);
      expect(NumberInput.parse('1.000.000').wholeValue, 1000000);
      expect(
        NumberInput.parse('3,5').wholeValue,
        isNull,
        reason: '3,5 ist keine ganze Zahl — und schon gar nicht 35',
      );
      expect(NumberInput.parse('1.000,5').wholeValue, isNull);
      expect(NumberInput.parse('').wholeValue, isNull);
    });

    test('isWhole unterscheidet Bruch und ganze Zahl', () {
      expect((NumberInput.parse('3,5') as ParsedNumberInput).isWhole, isFalse);
      expect((NumberInput.parse('3,00') as ParsedNumberInput).isWhole, isTrue);
    });

    test('jenseits von 2^53 gibt es keinen exakten int', () {
      expect(NumberInput.parse('9007199254740991').wholeValue,
          9007199254740991);
      expect(NumberInput.parse('90071992547409930').wholeValue, isNull);
    });
  });
}
