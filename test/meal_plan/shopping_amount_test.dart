// The weekly receipt sums amounts (2026-10-11): a leading quantity is parsed
// into a unit and a low/high value, German and English, case-insensitive.
// A number that may use either separator for thousands is never a guess.

import 'package:eatova/src/models/shopping_amount.dart';
import 'package:flutter_test/flutter_test.dart';

ShoppingAmount _a(
  ShoppingUnit unit,
  double low, {
  double? high,
  bool approx = false,
}) => ShoppingAmount(unit, low, high: high, approx: approx);

void main() {
  test('Mengen werden mit Einheit, Spanne und ca. gelesen', () {
    const g = ShoppingUnit.mass, ml = ShoppingUnit.volume;
    final cases = <String, ShoppingAmount>{
      '180 g': _a(g, 180),
      '100g': _a(g, 100),
      '250 Gramm': _a(g, 250),
      '1 kg': _a(g, 1000),
      '1,5 kg': _a(g, 1500),
      '1.5 KG': _a(g, 1500),
      '500 mg': _a(g, .5),
      '2 oz': _a(g, 2 * 28.349523125),
      '1 lb': _a(g, 453.59237),
      '2 lbs': _a(g, 2 * 453.59237),
      '250 ml': _a(ml, 250),
      '2 cl': _a(ml, 20),
      '1 dl': _a(ml, 100),
      '1 l': _a(ml, 1000),
      '0,5 l': _a(ml, 500),
      '1,5 Liter': _a(ml, 1500),
      '1 EL': _a(ShoppingUnit.tbsp, 1),
      '1 el': _a(ShoppingUnit.tbsp, 1),
      '1 1/2 EL': _a(ShoppingUnit.tbsp, 1.5),
      '1½ EL': _a(ShoppingUnit.tbsp, 1.5),
      '2 Esslöffel': _a(ShoppingUnit.tbsp, 2),
      '1 Tbsp.': _a(ShoppingUnit.tbsp, 1),
      '1 TL': _a(ShoppingUnit.tsp, 1),
      '½ TL': _a(ShoppingUnit.tsp, .5),
      '2 Teelöffel': _a(ShoppingUnit.tsp, 2),
      '2 tsp': _a(ShoppingUnit.tsp, 2),
      '1 Prise': _a(ShoppingUnit.pinch, 1),
      '2 Prisen': _a(ShoppingUnit.pinch, 2),
      '1 Msp.': _a(ShoppingUnit.pinch, 1),
      '2 pinches': _a(ShoppingUnit.pinch, 2),
      '3': _a(ShoppingUnit.piece, 3),
      '1/2': _a(ShoppingUnit.piece, .5),
      '0,125': _a(ShoppingUnit.piece, .125),
      '2 Stück': _a(ShoppingUnit.piece, 2),
      '2 Stk.': _a(ShoppingUnit.piece, 2),
      '4 pieces': _a(ShoppingUnit.piece, 4),
      '3 pcs': _a(ShoppingUnit.piece, 3),
      '1 Dose': _a(ShoppingUnit.can, 1),
      '2 Dosen': _a(ShoppingUnit.can, 2),
      '2 cans': _a(ShoppingUnit.can, 2),
      '1 Packung': _a(ShoppingUnit.pack, 1),
      '2 Packungen': _a(ShoppingUnit.pack, 2),
      '1 Pck.': _a(ShoppingUnit.pack, 1),
      '1 Päckchen': _a(ShoppingUnit.pack, 1),
      '1 pack': _a(ShoppingUnit.pack, 1),
      '1 Becher': _a(ShoppingUnit.tub, 1),
      '1 Glas': _a(ShoppingUnit.jar, 1),
      '2 Gläser': _a(ShoppingUnit.jar, 2),
      '1 jar': _a(ShoppingUnit.jar, 1),
      '1 Bund': _a(ShoppingUnit.bunch, 1),
      '2 bunches': _a(ShoppingUnit.bunch, 2),
      '2 Zehen': _a(ShoppingUnit.clove, 2),
      '1 clove': _a(ShoppingUnit.clove, 1),
      '2 Scheiben': _a(ShoppingUnit.slice, 2),
      '1 slice': _a(ShoppingUnit.slice, 1),
      '1 Tasse': _a(ShoppingUnit.cup, 1),
      '2 cups': _a(ShoppingUnit.cup, 2),
      '1 Handvoll': _a(ShoppingUnit.handful, 1),
      '2 handfuls': _a(ShoppingUnit.handful, 2),
      '2 Zweige': _a(ShoppingUnit.sprig, 2),
      '1 sprig': _a(ShoppingUnit.sprig, 1),
      '1 cm': _a(ShoppingUnit.centimetre, 1),
      '2–3': _a(ShoppingUnit.piece, 2, high: 3),
      '2-3 EL': _a(ShoppingUnit.tbsp, 2, high: 3),
      '1/2 - 1 TL': _a(ShoppingUnit.tsp, .5, high: 1),
      'ca. 2–3': _a(ShoppingUnit.piece, 2, high: 3, approx: true),
      'ca 200 g': _a(g, 200, approx: true),
      'etwa 200 g': _a(g, 200, approx: true),
      'approx. 1 cup': _a(ShoppingUnit.cup, 1, approx: true),
      'about 90 g': _a(g, 90, approx: true),
      '2 x 150 g': _a(g, 300),
      '2×100 g': _a(g, 200),
      'eine Prise': _a(ShoppingUnit.pinch, 1),
      'ein': _a(ShoppingUnit.piece, 1),
      'zwei': _a(ShoppingUnit.piece, 2),
      'a pinch': _a(ShoppingUnit.pinch, 1),
      'half a': _a(ShoppingUnit.piece, .5),
    };
    for (final MapEntry(key: text, value: amount) in cases.entries) {
      expect(parseShoppingAmount(text), amount, reason: text);
    }
  });

  test('was keine summierbare Menge ist, bleibt ungelesen', () {
    for (final text in [
      // Thousands in one locale, a decimal in the other.
      '1.000',
      '1.000 g',
      '1,250',
      '10.500 g',
      '0 g',
      '3/0',
      '3–2',
      // Pack words without a unit of their own.
      '2 Stangen',
      '1 Knolle',
      '1 head',
      'etwas',
      'some',
      '',
      '2 Tomaten',
    ]) {
      expect(parseShoppingAmount(text), isNull, reason: text);
    }
  });

  test('berechneter Text kennt sein Dezimalzeichen', () {
    expect(
      parseShoppingAmount('1,125 EL', decimalSeparator: ','),
      _a(ShoppingUnit.tbsp, 1.125),
    );
    expect(
      parseShoppingAmount('1.125 EL', decimalSeparator: '.'),
      _a(ShoppingUnit.tbsp, 1.125),
    );
    expect(parseShoppingAmount('1.125 EL', decimalSeparator: ','), isNull);
    expect(parseShoppingAmount('1,125 EL'), isNull);
  });

  test('die Menge wird nur als eigenes Wort abgetrennt', () {
    final cases = <String, (String?, String)>{
      '180 g Hähnchenbrustfilet, roh': ('180 g', 'Hähnchenbrustfilet, roh'),
      '1 cm Ingwer': ('1 cm', 'Ingwer'),
      '1 Päckchen Backpulver': ('1 Päckchen', 'Backpulver'),
      'eine Prise Salz': ('eine Prise', 'Salz'),
      'Eine Zwiebel': ('Eine', 'Zwiebel'),
      'a pinch of salt': ('a pinch', 'salt'),
      '2 cups of flour': ('2 cups', 'flour'),
      'half a lemon': ('half a', 'lemon'),
      '2 Stangen Lauch': ('2 Stangen', 'Lauch'),
      '2 large eggs': ('2', 'large eggs'),
      '1 l Milch': ('1 l', 'Milch'),
      '1 Lauch': ('1', 'Lauch'),
      '100g Mehl': ('100g', 'Mehl'),
      '1½ EL Öl': ('1 1/2 EL', 'Öl'),
      'ca. 2–3 Eier': ('ca. 2–3', 'Eier'),
      '2 x 150 g Lachs': ('2 x 150 g', 'Lachs'),
      // Vague words and words that merely start like a number.
      'ein paar Tomaten': (null, 'ein paar Tomaten'),
      'a few eggs': (null, 'a few eggs'),
      'a little oil': (null, 'a little oil'),
      'Apfel': (null, 'Apfel'),
      'Eis': (null, 'Eis'),
      'Salz': (null, 'Salz'),
      '200 g': (null, '200 g'),
    };
    for (final MapEntry(key: text, value: (amount, label)) in cases.entries) {
      final split = splitShoppingAmount(text);
      expect((split.amount, split.label), (amount, label), reason: text);
    }
  });

  test('eine Menge hinter dem Namen braucht eine Einheit oder ein Zeichen', () {
    const cases = <String, (String, String)?>{
      'Hähnchenbrust 150g': ('150g', 'Hähnchenbrust'),
      'Hähnchenbrust 150 g': ('150 g', 'Hähnchenbrust'),
      'Skyr: 150 g': ('150 g', 'Skyr'),
      'Haferflocken – 40 g': ('40 g', 'Haferflocken'),
      'Hähnchenbrustfilet (ca. 200 g)': ('ca. 200 g', 'Hähnchenbrustfilet'),
      'Brot 2 Scheiben': ('2 Scheiben', 'Brot'),
      'Mehl Type 550 1 kg': ('1 kg', 'Mehl Type 550'),
      'Eier: 2': ('2', 'Eier'),
      'Zwiebel (1)': ('1', 'Zwiebel'),
      // A number that is not an amount, or nothing after the name.
      'Mehl Type 405': null,
      'Joghurt 1,5 %': null,
      'Eier 2': null,
      'Zwiebel (1': null,
      'Tortilla-Wrap': null,
      'Reis (300 g gekocht)': null,
      '150 g': null,
      'Salz': null,
    };
    for (final MapEntry(key: text, value: expected) in cases.entries) {
      final split = splitTrailingShoppingAmount(text);
      expect(
        split == null ? null : (split.amount, split.label),
        expected,
        reason: text,
      );
    }
  });

  test('Summen je Einheit, Spannen getrennt, ca. steckt an', () {
    final sums = sumShoppingAmounts([
      _a(ShoppingUnit.handful, 1),
      _a(ShoppingUnit.mass, 300),
      _a(ShoppingUnit.mass, 250, approx: true),
      _a(ShoppingUnit.piece, 2, high: 3),
      _a(ShoppingUnit.piece, 1),
      _a(ShoppingUnit.tsp, 1),
      _a(ShoppingUnit.tbsp, 2),
    ]);
    expect(sums, [
      _a(ShoppingUnit.mass, 550, approx: true),
      _a(ShoppingUnit.piece, 3, high: 4),
      _a(ShoppingUnit.handful, 1),
      _a(ShoppingUnit.tbsp, 2),
      _a(ShoppingUnit.tsp, 1),
    ]);
    expect(
      () => _a(ShoppingUnit.mass, 1) + _a(ShoppingUnit.volume, 1),
      throwsArgumentError,
    );
    expect(_a(ShoppingUnit.tbsp, 1).isSpoonOrPinch, isTrue);
    expect(_a(ShoppingUnit.mass, 1).isSpoonOrPinch, isFalse);
    expect(
      _a(ShoppingUnit.piece, 1, high: 2, approx: true).scaled(1.5),
      _a(ShoppingUnit.piece, 1.5, high: 3, approx: true),
    );
  });
}
