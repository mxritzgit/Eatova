// One weekly receipt (2026-10-11): the same ingredient from several planned
// meals is one row with the summed amount and the days behind it; spices and
// staples move to "Gewürze & Vorrat". A row of one part keeps the id of the
// old per-recipe receipt, a merged row has exactly one new id, and a line
// ticked off before stays ticked off.

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/planned_meal.dart';
import 'package:eatova/src/models/shopping_list.dart';
import 'package:eatova/src/models/shopping_receipt.dart';
import 'package:flutter_test/flutter_test.dart';

final _week = DateTime(2026, 10, 5);
final _serverId = RegExp(r'^\d{4}-\d{2}-\d{2}:[a-f0-9]{64}$');

String _uuid(int n) =>
    '00000000-0000-4000-8000-${n.toString().padLeft(12, '0')}';

String _identity(Object value) =>
    '2026-10-05:${sha256.convert(utf8.encode(jsonEncode(value)))}';

/// An own recipe: no confirmed serving basis.
FitnessRecipe _own(String ingredients, {String title = 'Bowl'}) =>
    recipeCatalogEn.first.copyWith(
      slug: 'user_own',
      title: title,
      ingredients: ingredients,
      structuredIngredients: const [],
    );

FitnessRecipe _imported(
  String ingredients, {
  String basis = 'per_recipe',
  double batch = 4,
}) => recipeCatalogEn.first.copyWith(
  slug: 'user_import_test',
  title: 'Imported',
  ingredients: ingredients,
  structuredIngredients: const [],
  categories: ['Eigene', '$recipeIngredientsBasisPrefix$basis'],
  batchServings: batch,
);

RecipeIngredient _weighed(String name, double grams) => RecipeIngredient(
  name: name,
  grams: grams,
  per100g: const RecipeNutrition(
    caloriesKcal: 370,
    proteinG: 13,
    carbsG: 60,
    fatG: 7,
  ),
);

PlannedMeal _plan(
  FitnessRecipe recipe,
  int n, {
  int day = 0,
  MealSlot slot = MealSlot.dinner,
  double servings = 1,
}) => PlannedMeal.create(
  recipe: recipe,
  day: DateTime(2026, 10, 5 + day),
  slot: slot,
  servings: servings,
  id: _uuid(n),
);

ShoppingReceipt _receipt(
  List<PlannedMeal> plans, {
  AppLocalizations? l10n,
  String separator = '.',
}) =>
    buildShoppingReceipt(plans, _week, decimalSeparator: separator, l10n: l10n);

List<ShoppingRow> _all(ShoppingReceipt receipt) => [
  ...receipt.rows,
  ...receipt.pantry,
];

/// The row whose ingredient key is [key], wherever it is.
ShoppingRow _row(ShoppingReceipt receipt, String key) =>
    _all(receipt).singleWhere((row) => row.parts.first.key.id == key);

ShoppingAmount _a(ShoppingUnit unit, double value) =>
    ShoppingAmount(unit, value);

void main() {
  test('dieselbe Zutat aus mehreren Mahlzeiten ist eine Zeile mit Summe '
      'und Tagen', () {
    final plans = [
      _plan(_own('180 g Hähnchenbrustfilet, roh\n1 Zwiebel'), 1),
      _plan(
        _own('250 g Hähnchenbrust\n1/2 Zwiebel'),
        2,
        day: 3,
        slot: MealSlot.lunch,
      ),
      _plan(_own('120 g chicken breast fillet'), 3, day: 3),
    ];
    final receipt = _receipt(plans, l10n: deL10n);
    expect(receipt.pantry, isEmpty);
    expect(receipt.rows, hasLength(2));
    final chicken = _row(receipt, 'chicken_breast');
    expect(chicken.merged, isTrue);
    expect(chicken.total, [_a(ShoppingUnit.mass, 550)]);
    expect(chicken.label, 'Hähnchenbrust');
    expect(chicken.showsDetail, isTrue);
    expect(chicken.uses.map((u) => (u.day, u.slot, u.amount)), [
      ('2026-10-05', MealSlot.dinner, _a(ShoppingUnit.mass, 180)),
      ('2026-10-08', MealSlot.lunch, _a(ShoppingUnit.mass, 250)),
      ('2026-10-08', MealSlot.dinner, _a(ShoppingUnit.mass, 120)),
    ]);
    expect(_row(receipt, 'onion').total, [_a(ShoppingUnit.piece, 1.5)]);

    // The app language picks the name; without one the shortest wins.
    expect(
      _row(_receipt(plans, l10n: enL10n), 'chicken_breast').label,
      'Chicken breast fillet',
    );
    expect(_row(_receipt(plans), 'chicken_breast').label, 'Hähnchenbrust');
  });

  test('IDs: eine Zutat behält die alte ID, eine zusammengelegte Zeile hat '
      'genau eine neue', () {
    final single = [_plan(_own('180 g Mehl\n2 Eier\nOlivenöl'), 1)];
    final oldIds = buildShoppingList(
      single,
      _week,
    ).single.lines.map((l) => l.id);
    expect(_all(_receipt(single)).map((r) => r.id).toSet(), oldIds.toSet());

    final weighed = [
      _plan(
        _own('').copyWith(structuredIngredients: [_weighed('Oats', 80)]),
        1,
      ),
    ];
    expect(
      _receipt(weighed).rows.single.id,
      buildShoppingList(weighed, _week).single.id,
    );

    final plans = [
      _plan(_own('180 g Hähnchenbrust'), 1),
      _plan(_own('200 g chicken breast\n1 lemon'), 2, day: 2),
    ];
    final old = buildShoppingList(plans, _week);
    final chickenLines = [old[0].lines.single.id, old[1].lines.first.id];
    final chicken = _row(_receipt(plans), 'chicken_breast');
    expect(
      chicken.id,
      _identity([
        'merged',
        'chicken_breast',
        [...chickenLines]..sort(),
      ]),
    );
    expect(chicken.id, matches(_serverId));
    expect(chickenLines, isNot(contains(chicken.id)));
    // The lemon is alone and keeps its line's id.
    expect(_row(_receipt(plans), 'lemon').id, old[1].lines.last.id);

    // Input order does not matter; another meal with chicken is a new
    // requirement, an unrelated one is not.
    expect(
      _row(_receipt(plans.reversed.toList()), 'chicken_breast').id,
      chicken.id,
    );
    expect(
      _row(_receipt([...plans, _plan(_own('2 Eier'), 3)]), 'chicken_breast').id,
      chicken.id,
    );
    expect(
      _row(
        _receipt([...plans, _plan(_own('100 g Hähnchenbrust'), 3)]),
        'chicken_breast',
      ).id,
      isNot(chicken.id),
    );
  });

  test('ein Haken von früher bleibt: Zeile, ganzes Rezept, geteilte Zeile', () {
    final plans = [
      _plan(_own('180 g Hähnchenbrust\nSalz, Pfeffer'), 1),
      _plan(_own('200 g Hähnchenbrust'), 2, day: 1),
    ];
    final old = buildShoppingList(plans, _week);
    final [itemA, itemB] = old;
    final [chickenA, seasoningA] = itemA.lines;
    final chickenB = itemB.lines.single;
    final receipt = _receipt(plans);
    final chicken = _row(receipt, 'chicken_breast');
    final salt = _row(receipt, 'salt');
    final pepper = _row(receipt, 'pepper');
    expect(salt.id, _identity(['split', seasoningA.id, 0]));
    expect(pepper.id, _identity(['split', seasoningA.id, 1]));
    expect(salt.parts.single.legacyIds, [seasoningA.id, itemA.id]);

    // Line checks of the old receipt.
    expect(chicken.isChecked({chickenA.id: true}), isFalse);
    expect(chicken.isChecked({chickenA.id: true, chickenB.id: true}), isTrue);
    expect(salt.isChecked({seasoningA.id: true}), isTrue);
    expect(pepper.isChecked({seasoningA.id: true}), isTrue);
    // Whole recipes checked by an even older receipt.
    final recipes = {itemA.id: true, itemB.id: true};
    expect(chicken.isChecked(recipes), isTrue);
    expect(salt.isChecked(recipes), isTrue);
    // The row's own check wins over everything earlier.
    expect(
      chicken.isChecked({
        chickenA.id: true,
        chickenB.id: true,
        chicken.id: false,
      }),
      isFalse,
    );
    expect(salt.isChecked({seasoningA.id: true, salt.id: false}), isFalse);
    expect(salt.isChecked({itemA.id: true, seasoningA.id: false}), isFalse);

    // One tap writes exactly one check: the row's.
    final checks = <String, bool>{chickenA.id: true};
    final write = chicken.toggle(checks);
    expect((write.id, write.checked), (chicken.id, true));
    checks[write.id] = write.checked;
    expect(_all(receipt).where((r) => r.isChecked(checks)).map((r) => r.id), [
      chicken.id,
    ]);
    expect(chicken.toggle(checks).checked, isFalse);
  });

  test('jede Zeile hat genau eine eigene ID; ein Tipp ändert genau sie', () {
    final receipt = _receipt([
      _plan(_own('Salz, Pfeffer\n1/2 Zwiebel, 1 Knoblauchzehe\n2 Eier'), 1),
      _plan(_own('1 Zwiebel\nZimt'), 2, day: 1),
    ]);
    final rows = _all(receipt);
    // Salz and Pfeffer stay rows of one item each, the onion is merged.
    expect(rows, hasLength(6));
    expect(rows.where((r) => r.merged).map((r) => r.label), ['Zwiebel']);
    expect(rows.map((r) => r.id).toSet(), hasLength(rows.length));
    for (final row in rows) {
      expect(row.id, matches(_serverId));
      final write = row.toggle(const {});
      final checks = {write.id: write.checked};
      expect(rows.where((r) => r.isChecked(checks)).map((r) => r.id), [
        row.id,
      ], reason: row.label);
    }
  });

  test('Gewürze & Vorrat: eigener Abschnitt und eigener Fortschritt; '
      'Wasser fällt weg', () {
    final receipt = _receipt([
      _plan(
        _own(
          '180 g Hähnchenbrust\n1 TL Paprikapulver\nSalz, Pfeffer\n'
          '8 g Olivenöl\n500 ml Wasser\nWasser, Salz',
        ),
        1,
      ),
    ], l10n: deL10n);
    expect(receipt.rows.map((r) => r.label), ['Hähnchenbrust']);
    expect(receipt.pantry.map((r) => r.label), [
      'Olivenöl',
      'Paprikapulver',
      'Pfeffer',
      'Salz',
    ]);
    expect(
      _all(receipt).where((r) => r.parts.any((p) => p.key.isWater)),
      isEmpty,
    );
    expect(receipt.progress(const {}), (done: 0, total: 1));
    expect(receipt.pantryProgress(const {}), (done: 0, total: 4));
    final salt = receipt.pantry.last;
    expect(receipt.progress({salt.id: true}), (done: 0, total: 1));
    expect(receipt.pantryProgress({salt.id: true}), (done: 1, total: 4));
    final chicken = receipt.rows.single;
    expect(receipt.progress({chicken.id: true}), (done: 1, total: 1));
  });

  test('Kleinzeug zählt nach der Wochensumme', () {
    bool pantry(List<String> lines, String key) => _row(
      _receipt([
        for (var i = 0; i < lines.length; i++) _plan(_own(lines[i]), i + 1),
      ]),
      key,
    ).pantry;

    expect(
      pantry(['30 g Olivenöl', '30 g Olivenöl', '40 g Olivenöl'], 'olive_oil'),
      isTrue,
    );
    expect(
      pantry(['30 g Olivenöl', '30 g Olivenöl', '41 g Olivenöl'], 'olive_oil'),
      isFalse,
    );
    expect(pantry(['60 g Öl', '60 ml Öl'], 'oil'), isTrue);
    expect(pantry(['20 g Butter', '30 g Butter'], 'butter'), isTrue);
    expect(pantry(['20 g Butter', '40 g Butter'], 'butter'), isFalse);
    expect(pantry(['1 Packung Butter'], 'butter'), isFalse);
    expect(
      pantry(['2 EL Zucker', '2 EL Zucker', '3 EL Zucker'], 'sugar'),
      isTrue,
    );
    expect(pantry(['Zucker nach Geschmack'], 'sugar'), isTrue);
    expect(pantry(['500 g Mehl'], 'flour'), isFalse);
    expect(pantry(['1.000 g Mehl'], 'flour'), isFalse);
    expect(pantry(['40 ml Sojasauce'], 'soy_sauce'), isTrue);
    expect(
      pantry(['40 ml Sojasauce', '20 ml Sojasauce'], 'soy_sauce'),
      isFalse,
    );
    expect(pantry(['80 ml Apfelessig'], 'apfelessig'), isTrue);
    expect(pantry(['120 ml Apfelessig'], 'apfelessig'), isFalse);
    expect(pantry(['2 TL Honig', '30 g Honig'], 'honey'), isTrue);
    expect(pantry(['2 TL Honig', '60 g Honig'], 'honey'), isFalse);
    // Spices stay in the pantry whatever the amount.
    expect(pantry(['100 g Paprikapulver'], 'paprika_powder'), isTrue);
    // Fresh herbs are bought.
    expect(pantry(['2 EL gehackte Petersilie'], 'parsley|fresh'), isFalse);
    expect(pantry(['1 Zweig Rosmarin'], 'rosemary|fresh'), isFalse);
    expect(pantry(['1 TL Rosmarin'], 'rosemary|dried'), isTrue);
  });

  test('aufgeteilt wird eine Zeile nur, wenn jedes Stück bekannt ist', () {
    final cases = <String, List<(String, ShoppingAmount?)>?>{
      'Salz, schwarzer Pfeffer, Petersilie nach Geschmack': [
        ('Salz', null),
        ('Schwarzer Pfeffer', null),
        ('Petersilie nach Geschmack', null),
      ],
      'Salz und Pfeffer': [('Salz', null), ('Pfeffer', null)],
      'Salz & Pfeffer': [('Salz', null), ('Pfeffer', null)],
      'Salt, pepper to taste': [('Salt', null), ('Pepper to taste', null)],
      '1/2 Zwiebel, 1 Knoblauchzehe, 1 cm Ingwer': [
        ('Zwiebel', _a(ShoppingUnit.piece, .5)),
        ('Knoblauchzehe', _a(ShoppingUnit.clove, 1)),
        ('Ingwer', _a(ShoppingUnit.centimetre, 1)),
      ],
      '1,5 EL Sojasauce, 1 TL Sesamöl': [
        ('Sojasauce', _a(ShoppingUnit.tbsp, 1.5)),
        ('Sesamöl', _a(ShoppingUnit.tsp, 1)),
      ],
      'Zimt, 1 TL Ahornsirup optional': [
        ('Zimt', null),
        ('Ahornsirup optional', _a(ShoppingUnit.tsp, 1)),
      ],
      'Spring onion, pepper, chili, optional': [
        ('Spring onion', null),
        ('Pepper', null),
        ('Chili, optional', null),
      ],
      'Salz (grob, aus der Mühle), Pfeffer': [
        ('Salz (grob, aus der Mühle)', null),
        ('Pfeffer', null),
      ],
      // One ingredient, described; or not safely separable.
      '1 Scheibe Vollkornbrot, ca. 50 g': null,
      '180 g Hähnchenbrustfilet, roh': null,
      '220 g Brokkoli, frisch oder TK': null,
      'Sesam, Frühlingszwiebel, Xyzwurzel': null,
      '250 g Gemüse: Brokkoli, Zucchini': null,
      '120 g Blattsalat und Rucola': null,
      'Salz': null,
    };
    for (final MapEntry(key: text, value: expected) in cases.entries) {
      final plans = [_plan(_own(text), 1)];
      final item = buildShoppingList(plans, _week).single;
      final line = item.lines.single;
      final parts = [for (final row in _all(_receipt(plans))) ...row.parts];
      if (expected == null) {
        expect(parts.map((p) => p.id), [line.id], reason: text);
        expect(parts.single.legacyIds, [item.id], reason: text);
        continue;
      }
      parts.sort((a, b) => a.id.compareTo(b.id));
      final ids = [
        for (var i = 0; i < expected.length; i++)
          _identity(['split', line.id, i]),
      ];
      final byId = {for (final part in parts) part.id: part};
      expect(byId.keys.toSet(), ids.toSet(), reason: text);
      for (var i = 0; i < expected.length; i++) {
        final part = byId[ids[i]]!;
        expect(
          (part.label, part.uses.single.amount),
          expected[i],
          reason: text,
        );
        expect(part.legacyIds, [line.id, item.id], reason: text);
      }
    }
  });

  test('mehrdeutige Wörter in einer Gewürzliste sind das Gewürz', () {
    final spiced = _receipt([_plan(_own('1 TL Kräuter, Chili optional'), 1)]);
    expect(spiced.rows, isEmpty);
    expect(
      spiced.pantry.map((r) => r.parts.single.key.id),
      unorderedEquals(['chili_spice', 'herbs|dried']),
    );
    final vegetables = _receipt([_plan(_own('Frühlingszwiebel, Paprika'), 1)]);
    expect(
      vegetables.rows.map((r) => r.parts.single.key.id),
      unorderedEquals(['spring_onion', 'bell_pepper']),
    );
  });

  test('Mengen werden je Zeile auf die geplanten Portionen gerechnet', () {
    // The projection converted every line.
    var receipt = _receipt([
      _plan(_imported('400 g Mehl\n2 Eier'), 1, servings: 2),
    ]);
    expect(_row(receipt, 'flour').total, [_a(ShoppingUnit.mass, 200)]);
    expect(_row(receipt, 'egg').total, [_a(ShoppingUnit.piece, 1)]);
    expect(_row(receipt, 'flour').hasUnscaled, isFalse);

    // A written amount keeps the projection at the original; each line is
    // converted on its own, an unreadable one is marked.
    receipt = _receipt([
      _plan(
        _imported('eine Zwiebel\n400 g Mehl\n1.000 g Zucker'),
        1,
        servings: 2,
      ),
    ]);
    expect(_row(receipt, 'onion').total, [_a(ShoppingUnit.piece, .5)]);
    expect(_row(receipt, 'onion').label, 'Zwiebel');
    expect(_row(receipt, 'flour').total, [_a(ShoppingUnit.mass, 200)]);
    final sugar = _row(receipt, 'sugar');
    expect(sugar.total, isEmpty);
    expect(sugar.texts, isEmpty);
    final use = sugar.uses.single;
    expect(
      (use.text, use.scale, use.batchServings),
      ('1.000 g', ShoppingScale.batch, 4.0),
    );
    expect(sugar.hasUnscaled, isTrue);
    expect(sugar.showsDetail, isTrue);
    expect(sugar.pantry, isFalse);

    // Per serving: the factor is the planned servings.
    receipt = _receipt([
      _plan(
        _imported('100 g Reis\nÖl zum Braten', basis: 'per_serving', batch: 1),
        1,
        servings: 3,
      ),
    ]);
    expect(_row(receipt, 'rice').total, [_a(ShoppingUnit.mass, 300)]);

    // No confirmed basis: every amount stays as written, outside the sum,
    // but still tells a spoon from a bag.
    receipt = _receipt([
      _plan(
        _imported('400 g Mehl\n2 EL Öl', basis: 'unspecified'),
        1,
        servings: 2,
      ),
    ]);
    final flour = _row(receipt, 'flour');
    expect(flour.total, isEmpty);
    expect(
      (flour.uses.single.text, flour.uses.single.scale),
      ('400 g', ShoppingScale.unknown),
    );
    expect(flour.pantry, isFalse);
    expect(_row(receipt, 'oil').pantry, isTrue);

    // Catalog recipes are written for one serving.
    receipt = _receipt([_plan(recipeCatalogDe.first, 1, servings: 2)]);
    expect(_row(receipt, 'chicken_breast').total, [_a(ShoppingUnit.mass, 360)]);

    // Own recipes: as written for one serving, unconverted for more.
    receipt = _receipt([_plan(_own('100 g Reis\n2 Stangen Lauch'), 1)]);
    expect(_row(receipt, 'rice').total, [_a(ShoppingUnit.mass, 100)]);
    final leek = _row(receipt, 'leek');
    expect(leek.label, 'Lauch');
    expect(leek.total, isEmpty);
    expect(leek.texts, ['2 Stangen']);
    receipt = _receipt([_plan(_own('100 g Reis'), 1, servings: 2)]);
    expect(_row(receipt, 'rice').total, isEmpty);
    expect(_row(receipt, 'rice').uses.single.scale, ShoppingScale.unknown);

    // Computed amounts carry the locale's separator: "1,125" is a decimal.
    for (final separator in [',', '.']) {
      receipt = _receipt([
        _plan(_imported('9 EL Öl\n800 g Mehl', batch: 8), 1),
      ], separator: separator);
      expect(_row(receipt, 'oil').total, [_a(ShoppingUnit.tbsp, 1.125)]);
    }
  });

  test('gewogene Zutaten zeigen jede Mahlzeit und verbinden sich mit '
      'Freitext', () {
    final oats = _own(
      '',
    ).copyWith(structuredIngredients: [_weighed('Oats', 100)]);
    final plans = [_plan(oats, 1), _plan(oats, 2, day: 2, servings: 2)];
    final weighed = _receipt(plans).rows.single;
    expect(weighed.id, buildShoppingList(plans, _week).single.id);
    expect(weighed.uses.map((u) => (u.day, u.amount)), [
      ('2026-10-05', _a(ShoppingUnit.mass, 100)),
      ('2026-10-07', _a(ShoppingUnit.mass, 200)),
    ]);
    expect(weighed.showsDetail, isTrue);

    final mixed = _receipt([
      ...plans,
      _plan(_own('50 g Haferflocken'), 3, day: 4),
    ], l10n: deL10n).rows.single;
    expect(mixed.merged, isTrue);
    expect(mixed.total, [_a(ShoppingUnit.mass, 350)]);
    expect(mixed.label, 'Haferflocken');
    expect(mixed.uses, hasLength(3));
  });

  test('Reihenfolge nach Name, gewogen und Freitext gemischt', () {
    final receipt = _receipt([
      _plan(
        _own(
          '2 Äpfel\n1 Banane',
        ).copyWith(structuredIngredients: [_weighed('Zucchini', 200)]),
        1,
      ),
      _plan(_own('1 Avocado'), 2),
    ]);
    expect(receipt.rows.map((r) => r.label), [
      'Äpfel',
      'Avocado',
      'Banane',
      'Zucchini',
    ]);
  });

  test('zusammengelegte Namen: kurz, ohne "optional", mit dem, was das '
      'Produkt ausmacht', () {
    String label(List<String> lines, String key) => _row(
      _receipt([
        for (var i = 0; i < lines.length; i++) _plan(_own(lines[i]), i + 1),
      ], l10n: deL10n),
      key,
    ).label;

    expect(
      label(['1 TL Ahornsirup optional', '1 TL Ahornsirup'], 'maple_syrup'),
      'Ahornsirup',
    );
    expect(
      label([
        '280 g Kartoffeln, festkochend',
        '300 g Kartoffeln, festkochend',
      ], 'waxy+potato'),
      'Kartoffeln, festkochend',
    );
    expect(
      label(['1 TL Paprikapulver', 'Salz, Pfeffer, Paprika'], 'paprika_powder'),
      'Paprikapulver',
    );
  });

  test('Rezepte ohne Zutatenliste werden genannt, nicht gezählt', () {
    final receipt = _receipt([
      _plan(_own('', title: 'Pizza'), 1, day: 4, slot: MealSlot.lunch),
      _plan(_own('Zutaten:', title: 'Suppe'), 2),
    ]);
    expect(receipt.emptyRecipes.map((r) => (r.title, r.day, r.slot)), [
      ('Suppe', '2026-10-05', MealSlot.dinner),
      ('Pizza', '2026-10-09', MealSlot.lunch),
    ]);
    expect(_all(receipt), isEmpty);
    expect(receipt.isEmpty, isFalse);
    expect(receipt.progress(const {}), (done: 0, total: 0));
    expect(_receipt(const []).isEmpty, isTrue);
  });
}
