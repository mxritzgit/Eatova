// The price estimate reads a line's printed amount with its own grammar
// (docs/SHOPPING-PRICES.md). Every unit the receipt's display split knows is
// fed through buildShoppingList and parsePriceQuantity, read from the
// display split's source, so a unit added there without a decision here
// fails this test instead of silently showing "k. A.".

import 'dart:io';

import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/planned_meal.dart';
import 'package:eatova/src/models/shopping_list.dart';
import 'package:eatova/src/models/shopping_price.dart';
import 'package:eatova/src/models/shopping_price_amount.dart';
import 'package:flutter_test/flutter_test.dart';

final _day = DateTime(2026, 10, 5);

ShoppingLine _line(String text) => buildShoppingList([
  PlannedMeal.create(
    recipe: recipeCatalogEn.first.copyWith(
      ingredients: text,
      structuredIngredients: const [],
    ),
    day: _day,
    slot: MealSlot.dinner,
  ),
], _day).single.lines.single;

/// The alternatives of `_unit` in shopping_list.dart, expanded: "lbs?" is
/// "lb" and "lbs", "Gl(?:as|äser)" is "Glas" and "Gläser".
List<String> _displayUnits() {
  final source = File('lib/src/models/shopping_list.dart').readAsStringSync();
  final start = source.indexOf('const _unit =');
  expect(start, isNot(-1), reason: '_unit fehlt in shopping_list.dart');
  final declaration = source.substring(start, source.indexOf(';', start));
  final pattern = RegExp(
    r"r'([^']*)'",
  ).allMatches(declaration).map((m) => m[1]!).join();
  expect(pattern, startsWith('(?:'));
  expect(pattern, endsWith(r')\.?'));
  final body = pattern.substring(3, pattern.length - 4);
  final alternatives = <String>[];
  var depth = 0, from = 0;
  for (var i = 0; i < body.length; i++) {
    if (body[i] == '(') depth++;
    if (body[i] == ')') depth--;
    if (body[i] == '|' && depth == 0) {
      alternatives.add(body.substring(from, i));
      from = i + 1;
    }
  }
  alternatives.add(body.substring(from));
  return [for (final alternative in alternatives) ..._expand(alternative)];
}

List<String> _expand(String pattern) {
  final group = RegExp(r'\(\?:([^)]*)\)(\?)?').firstMatch(pattern);
  if (group != null) {
    final head = pattern.substring(0, group.start);
    final tail = pattern.substring(group.end);
    return [
      for (final option in [...group[1]!.split('|'), if (group[2] != null) ''])
        ..._expand('$head$option$tail'),
    ];
  }
  final optional = pattern.indexOf('?');
  if (optional > 0) {
    return [
      ..._expand(
        pattern.substring(0, optional) + pattern.substring(optional + 1),
      ),
      ..._expand(
        pattern.substring(0, optional - 1) + pattern.substring(optional + 1),
      ),
    ];
  }
  return [pattern];
}

/// What "2 `unit`" means. Null: deliberately not convertible.
final Map<String, PriceQuantity?> _expected = {
  'kg': const MassQuantity(2000),
  'g': const MassQuantity(2),
  'mg': const MassQuantity(.002),
  'Gramm': const MassQuantity(2),
  'oz': const MassQuantity(56.7),
  'lb': const MassQuantity(907.2),
  'lbs': const MassQuantity(907.2),
  'ml': const VolumeQuantity(2),
  'cl': const VolumeQuantity(20),
  'dl': const VolumeQuantity(200),
  'l': const VolumeQuantity(2000),
  'Liter': const VolumeQuantity(2000),
  'cup': const VolumeQuantity(480),
  'cups': const VolumeQuantity(480),
  'Tasse': const VolumeQuantity(480),
  'Tassen': const VolumeQuantity(480),
  'EL': const SpoonQuantity(2, tablespoon: true),
  'Esslöffel': const SpoonQuantity(2, tablespoon: true),
  'tbsp': const SpoonQuantity(2, tablespoon: true),
  'TL': const SpoonQuantity(2, tablespoon: false),
  'Teelöffel': const SpoonQuantity(2, tablespoon: false),
  'tsp': const SpoonQuantity(2, tablespoon: false),
  'Msp': const PinchQuantity(),
  'Prise': const PinchQuantity(),
  'Prisen': const PinchQuantity(),
  'pinch': const PinchQuantity(),
  'pinches': const PinchQuantity(),
  'Stück': const CountQuantity(2, PriceUnit.piece),
  'Stk': const CountQuantity(2, PriceUnit.piece),
  'piece': const CountQuantity(2, PriceUnit.piece),
  'pieces': const CountQuantity(2, PriceUnit.piece),
  'pcs': const CountQuantity(2, PriceUnit.piece),
  'Zehe': const CountQuantity(2, PriceUnit.clove),
  'Zehen': const CountQuantity(2, PriceUnit.clove),
  'clove': const CountQuantity(2, PriceUnit.clove),
  'cloves': const CountQuantity(2, PriceUnit.clove),
  'Scheibe': const CountQuantity(2, PriceUnit.slice),
  'Scheiben': const CountQuantity(2, PriceUnit.slice),
  'slice': const CountQuantity(2, PriceUnit.slice),
  'slices': const CountQuantity(2, PriceUnit.slice),
  'Dose': const CountQuantity(2, PriceUnit.can),
  'Dosen': const CountQuantity(2, PriceUnit.can),
  'can': const CountQuantity(2, PriceUnit.can),
  'cans': const CountQuantity(2, PriceUnit.can),
  'Packung': const CountQuantity(2, PriceUnit.pack),
  'Packungen': const CountQuantity(2, PriceUnit.pack),
  'Pck': const CountQuantity(2, PriceUnit.pack),
  'pack': const CountQuantity(2, PriceUnit.pack),
  'packs': const CountQuantity(2, PriceUnit.pack),
  'Becher': const CountQuantity(2, PriceUnit.tub),
  'Glas': const CountQuantity(2, PriceUnit.jar),
  'Gläser': const CountQuantity(2, PriceUnit.jar),
  'jar': const CountQuantity(2, PriceUnit.jar),
  'jars': const CountQuantity(2, PriceUnit.jar),
  'Bund': const CountQuantity(2, PriceUnit.bunch),
  'bunch': const CountQuantity(2, PriceUnit.bunch),
  'bunches': const CountQuantity(2, PriceUnit.bunch),
  'Handvoll': null,
  'handful': null,
  'handfuls': null,
  'Zweig': null,
  'Zweige': null,
  'sprig': null,
  'sprigs': null,
};

void _expectQuantity(
  PriceQuantity? actual,
  PriceQuantity? expected,
  String why,
) {
  switch ((actual, expected)) {
    case (MassQuantity(grams: final a), MassQuantity(grams: final b)):
      expect(a, closeTo(b, 1e-9), reason: why);
    case (VolumeQuantity(ml: final a), VolumeQuantity(ml: final b)):
      expect(a, closeTo(b, 1e-9), reason: why);
    default:
      expect(actual, expected, reason: why);
  }
}

void main() {
  test('every display unit has a decision in the price parser', () {
    final units = _displayUnits();
    expect(units, contains('Gläser'));
    expect(units, contains('pinches'));
    for (final unit in units) {
      expect(
        _expected.containsKey(unit),
        isTrue,
        reason:
            '"$unit" is split off for display but has no price '
            'decision: add it to shopping_price_amount.dart and here',
      );
      final line = _line('2 $unit Mehl');
      expect(line.label, 'Mehl', reason: unit);
      _expectQuantity(parsePriceQuantity(line.amount), _expected[unit], unit);
      // A trailing dot ("Stk.") reads the same.
      final dotted = _line('2 $unit. Mehl');
      _expectQuantity(
        parsePriceQuantity(dotted.amount),
        _expected[unit],
        '$unit.',
      );
    }
  });

  test('numbers, fractions, ranges and multiples', () {
    final cases = <String?, PriceQuantity?>{
      '1 1/2 EL': const SpoonQuantity(1.5, tablespoon: true),
      '1/2': const CountQuantity(.5, PriceUnit.piece),
      'ca. 2–3': const CountQuantity(3, PriceUnit.piece),
      '2-3 EL': const SpoonQuantity(3, tablespoon: true),
      '2 x 150 g': const MassQuantity(300),
      '2×150g': const MassQuantity(300),
      '100g': const MassQuantity(100),
      '0,125': const CountQuantity(.125, PriceUnit.piece),
      '0,25 kg': const MassQuantity(250),
      '1,5 l': const VolumeQuantity(1500),
      '1.5 l': const VolumeQuantity(1500),
      'etwa 200 g': const MassQuantity(200),
      'approx. 2 cups': const VolumeQuantity(480),
      // A thousands separator or a decimal comma: no guess.
      '1.000 g': null,
      '1,250 kg': null,
      '0': null,
      '2 Handvoll': null,
      null: null,
    };
    for (final MapEntry(key: amount, value: expected) in cases.entries) {
      _expectQuantity(parsePriceQuantity(amount), expected, '$amount');
    }
  });

  test('the display split hands over what the parser reads', () {
    expect(_line('½ weiße Zwiebel').amount, '1/2');
    expect(
      parsePriceQuantity(_line('½ weiße Zwiebel').amount),
      const CountQuantity(.5, PriceUnit.piece),
    );
    expect(
      parsePriceQuantity(_line('1½ EL Backpulver').amount),
      const SpoonQuantity(1.5, tablespoon: true),
    );
    expect(
      parsePriceQuantity(_line('2 x 150 g Lachs').amount),
      const MassQuantity(300),
    );
    expect(parsePriceQuantity(_line('Salt, pepper to taste').amount), isNull);
  });
}
