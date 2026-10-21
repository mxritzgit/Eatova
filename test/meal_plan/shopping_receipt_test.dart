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
import 'package:eatova/src/models/persisted_labels.dart';
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

  test(
    'eine gegessene Mahlzeit öffnet nicht wieder, was schon gekauft ist',
    () {
      PlannedMeal eat(PlannedMeal plan) =>
          plan.copyWith(eatenAt: DateTime(2026, 10, 5, 19));
      Map<String, bool> tickAll(ShoppingReceipt receipt) => {
        for (final row in _all(receipt)) row.id: true,
      };

      // Monday and Thursday share chicken; everything bought on Monday.
      final a = _plan(_own('180 g Hähnchenbrust\n1 Zitrone'), 1);
      final b = _plan(_own('250 g Hähnchenbrust\n1 Zwiebel'), 2, day: 3);
      final checks = tickAll(_receipt([a, b]));
      expect(_receipt([a, b]).progress(checks), (done: 3, total: 3));
      // Monday eaten: one chicken part is left and the row stays ticked.
      var receipt = _receipt([eat(a), b]);
      expect(receipt.progress(checks), (done: 2, total: 2));
      final chicken = _row(receipt, 'chicken_breast');
      expect(chicken.merged, isFalse);
      expect(chicken.total, [_a(ShoppingUnit.mass, 250)]);
      expect(chicken.isChecked(checks), isTrue);

      // Three meals: Monday eaten, then bought, then Thursday eaten.
      final c = _plan(_own('200 g Hähnchenbrust'), 3, day: 4);
      final bought = tickAll(_receipt([eat(a), b, c]));
      receipt = _receipt([eat(a), eat(b), c]);
      expect(_row(receipt, 'chicken_breast').isChecked(bought), isTrue);
      expect(receipt.progress(bought), (done: 1, total: 1));

      // A meal added later still needs chicken again.
      final d = _plan(_own('150 g Hähnchenbrust'), 4, day: 5);
      expect(
        _row(_receipt([eat(a), b, c, d]), 'chicken_breast').isChecked(bought),
        isFalse,
      );
      // Removing a meal is an edit of the plan: its merged rows reopen.
      expect(
        _row(
          _receipt([b, c]),
          'chicken_breast',
        ).isChecked(tickAll(_receipt([a, b, c]))),
        isFalse,
      );

      // Weighed items the same; a tick from the receipt without the eaten
      // meal also counts.
      final oats = _own(
        '',
      ).copyWith(structuredIngredients: [_weighed('Oats', 80)]);
      final mon = _plan(oats, 5);
      final wed = _plan(oats, 6, day: 2);
      final weighed = _receipt([mon, wed]).rows.single;
      final eatenWeek = _receipt([eat(mon), wed]).rows.single;
      expect(eatenWeek.total, [_a(ShoppingUnit.mass, 80)]);
      expect(eatenWeek.isChecked({weighed.id: true}), isTrue);
      final openOnly = buildShoppingList([eat(mon), wed], _week).single.id;
      expect(openOnly, isNot(weighed.id));
      expect(eatenWeek.isChecked({openOnly: true}), isTrue);
      expect(eatenWeek.isChecked(const {}), isFalse);
      // Also when the weighed part, eaten whole, names a pack size.
      final pack = _plan(
        _own('').copyWith(
          structuredIngredients: [_weighed('Haferflocken (500 g)', 80)],
        ),
        8,
      );
      final later = _plan(_own('50 g Haferflocken'), 9, day: 2);
      final both = _row(_receipt([pack, later]), 'oats');
      expect(both.merged, isTrue);
      expect(
        _row(_receipt([eat(pack), later]), 'oats').isChecked({both.id: true}),
        isTrue,
      );

      // A meal eaten whole leaves no row and no note.
      expect(_all(_receipt([eat(a)])), isEmpty);
      expect(
        _receipt([eat(_plan(_own('', title: 'Pizza'), 7))]).isEmpty,
        isTrue,
      );
    },
  );

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
    // A splash or a dash is measured like a spoon; a bottle is bought.
    expect(
      pantry(['2 EL Sojasauce', '1 Schuss Sojasauce'], 'soy_sauce'),
      isTrue,
    );
    expect(pantry(['1 Spritzer Zitronensaft'], 'lemon_juice'), isTrue);
    expect(pantry(['A splash of soy sauce'], 'soy_sauce'), isTrue);
    expect(pantry(['Ein paar Tropfen Sesamöl'], 'sesame_oil'), isTrue);
    expect(pantry(['Drizzle of olive oil'], 'olive_oil'), isTrue);
    expect(pantry(['1 Flasche Sojasauce'], 'soy_sauce'), isFalse);
    // An amount left in the name could be a kilo.
    expect(pantry(['Olivenöl 200ml'], 'olive_oil'), isFalse);
    expect(pantry(['Olivenöl (eine 500-ml-Flasche)'], 'olive_oil'), isFalse);
    expect(pantry(['Mehl Type 405'], 'type405+flour'), isTrue);
    // The amount keeps its own case, not the line's capital.
    final splash = _receipt([
      _plan(_own('A splash of soy sauce\nEin Schuss Essig\n1 Dash Tabasco'), 1),
    ]);
    expect(_row(splash, 'soy_sauce').texts, ['a splash']);
    expect(_row(splash, 'essig').texts, ['ein Schuss']);
    expect(_row(splash, 'tabasco').texts, ['1 dash']);
  });

  test(
    'Mengen hinter dem Namen und nach einem Aufzählungszeichen zählen mit',
    () {
      var receipt = _receipt([
        _plan(_own('Hähnchenbrust 150g\nSkyr 200g\nHaferflocken 50g'), 1),
        _plan(
          _own('Hähnchenbrust (150 g)\nSkyr: 150 g\nHaferflocken – 40 g'),
          2,
          day: 1,
        ),
        _plan(
          _own('200 g Hähnchenbrust\n150 g Skyr\n60 g Haferflocken'),
          3,
          day: 2,
        ),
        _plan(_own('✅ 150 g Hähnchenbrust\n✅ 1/2 Gurke\n🔸 2 Eier'), 4, day: 3),
        _plan(_own('1/2 Gurke\n1 Ei\nTomaten, 2 Stück'), 5, day: 4),
      ], l10n: deL10n);
      final chicken = _row(receipt, 'chicken_breast');
      expect(chicken.label, 'Hähnchenbrust');
      expect(chicken.total, [_a(ShoppingUnit.mass, 650)]);
      expect(_row(receipt, 'skyr').total, [_a(ShoppingUnit.mass, 500)]);
      expect(_row(receipt, 'oats').total, [_a(ShoppingUnit.mass, 150)]);
      expect(_row(receipt, 'cucumber').total, [_a(ShoppingUnit.piece, 1)]);
      expect(_row(receipt, 'egg').total, [_a(ShoppingUnit.piece, 3)]);
      expect(_row(receipt, 'tomato').label, 'Tomaten');
      expect(_row(receipt, 'tomato').total, [_a(ShoppingUnit.piece, 2)]);

      // What is still unread stays on a row of its own, as written.
      receipt = _receipt([
        _plan(_own('Reis (300 g gekocht)\n200 g Hähnchenbrust'), 1),
        _plan(_own('100 g Reis'), 2, day: 1),
      ]);
      final rice = _all(receipt).where((r) => r.label.startsWith('Reis'));
      expect(rice.map((r) => r.label), ['Reis', 'Reis (300 g gekocht)']);
      expect(rice.map((r) => r.merged), [false, false]);
      expect(rice.map((r) => r.total), [
        [_a(ShoppingUnit.mass, 100)],
        isEmpty,
      ]);

      // An import for four planned for one: the amount after the name is
      // converted; one left in the name is marked as the recipe's.
      receipt = _receipt([
        _plan(_imported('Hähnchenbrust 600g\nReis (300 g gekocht)'), 1),
        _plan(_own('200 g Hähnchenbrust'), 2, day: 1),
      ]);
      expect(_row(receipt, 'chicken_breast').total, [
        _a(ShoppingUnit.mass, 350),
      ]);
      final cooked = _row(receipt, 'cooked+rice');
      expect(
        (cooked.uses.single.scale, cooked.uses.single.batchServings),
        (ShoppingScale.batch, 4.0),
      );
      expect(cooked.showsDetail, isTrue);
    },
  );

  test('zusammengelegt wird nichts, dessen Menge im Namen steckt', () {
    // The same unsplittable line in two meals: each keeps its own row, or
    // the onion would be summed as cloves.
    final listed = [
      _plan(_own('1 Zwiebel, 1 Zehe, Xyzwurzel'), 1),
      _plan(_own('1 Zwiebel, 1 Zehe, Xyzwurzel'), 2, day: 1),
    ];
    final lineIds = [
      for (final item in buildShoppingList(listed, _week)) item.lines.single.id,
    ];
    final rows = _all(_receipt(listed));
    expect(rows.map((r) => r.merged), [false, false]);
    expect(rows.map((r) => r.id).toSet(), lineIds.toSet());
    for (final row in rows) {
      expect(row.total, hasLength(1));
      expect(row.total.single.low, 1);
    }
    // Without an amount, the same line merges with itself.
    final plain = _all(
      _receipt([
        _plan(_own('Sesam, Frühlingszwiebel, Xyzwurzel'), 1),
        _plan(_own('Sesam, Frühlingszwiebel, Xyzwurzel'), 2, day: 1),
      ]),
    );
    expect(plain.single.parts, hasLength(2));
  });

  test('Zehen zählt nur, wer Knoblauch heißt', () {
    final receipt = _receipt([
      _plan(
        _own(
          '2 Tomaten mit Knoblauchzehe\n'
          '2 Brotscheiben, mit Knoblauchzehe eingerieben',
        ),
        1,
      ),
      _plan(_own('2 Knoblauchzehen\n1 kleine Knoblauchzehe, gehackt'), 2),
    ]);
    final totals = {for (final row in _all(receipt)) row.label: row.total};
    expect(totals['Tomaten mit Knoblauchzehe'], [_a(ShoppingUnit.piece, 2)]);
    expect(totals['Brotscheiben, mit Knoblauchzehe eingerieben'], [
      _a(ShoppingUnit.piece, 2),
    ]);
    expect(_row(receipt, 'garlic').total, [_a(ShoppingUnit.clove, 3)]);
  });

  test('Beispiele und Alternativen sind keine eigene Zeile', () {
    final receipt = _receipt([
      _plan(_own('300 g Fischfilet, z.B. Lachs\n150 g rice, or quinoa'), 1),
      _plan(_own('200 g Lachs'), 2, day: 1),
    ]);
    expect(_row(receipt, 'salmon').parts, hasLength(1));
    expect(_row(receipt, 'salmon').total, [_a(ShoppingUnit.mass, 200)]);
    expect(_row(receipt, 'rice').label, 'Rice, or quinoa');
    expect(_all(receipt), hasLength(3));
  });

  test('Produkte ohne Namen bleiben getrennt, in jeder Sprache gleich', () {
    RecipeIngredient product(String code, double grams) => RecipeIngredient(
      name: PersistedLabels.productName(code),
      grams: grams,
      per100g: const RecipeNutrition(
        caloriesKcal: 100,
        proteinG: 5,
        carbsG: 10,
        fatG: 2,
      ),
      source: IngredientSource.openFoodFacts,
      productCode: code,
    );
    final plans = [
      _plan(
        _own(
          '',
        ).copyWith(structuredIngredients: [product('4001234567890', 100)]),
        1,
      ),
      _plan(
        _own(
          '',
        ).copyWith(structuredIngredients: [product('5009876543210', 250)]),
        2,
        day: 2,
      ),
    ];
    final de = _receipt(plans, l10n: deL10n).rows;
    final en = _receipt(plans, l10n: enL10n).rows;
    expect(de.map((r) => r.merged), [false, false]);
    expect(de.map((r) => r.label), [
      'Produkt 4001234567890',
      'Produkt 5009876543210',
    ]);
    expect(en.map((r) => r.label), [
      'Product 4001234567890',
      'Product 5009876543210',
    ]);
    expect(en.map((r) => r.id), de.map((r) => r.id));
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
      // An example or an alternative describes the item before.
      '250 g Nudeln, z. B. Spaghetti': null,
      '300 g Fischfilet, z.B. Lachs': null,
      '150 g Reis, oder Quinoa': null,
      '150 g rice, or quinoa': null,
      'Kräuter, z. B. Petersilie': null,
      'Salz, oder Kräutersalz': null,
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
    // Without an amount and among vegetables it stays in the main list, on
    // a row of its own: it might be either.
    final vegetables = _receipt([_plan(_own('Frühlingszwiebel, Paprika'), 1)]);
    expect(
      vegetables.rows.map((r) => r.parts.single.key.id),
      unorderedEquals(['spring_onion', 'paprika?']),
    );
  });

  test('was verschieden ist, bleibt getrennt; was dasselbe ist, nicht', () {
    List<ShoppingRow> rows(List<String> recipes, {AppLocalizations? l10n}) =>
        _all(
          _receipt([
            for (var i = 0; i < recipes.length; i++)
              _plan(_own(recipes[i]), i + 1, day: i),
          ], l10n: l10n ?? deL10n),
        );
    String describe(ShoppingRow row) =>
        '${row.pantry ? 'pantry' : 'main'} ${row.label} '
        '${row.total.join(' + ')} parts=${row.parts.length}';

    // Grated ginger is the fresh root, ground ginger the spice.
    var receipt = _receipt([
      _plan(_own('1 tbsp grated ginger'), 1),
      _plan(_own('1/2 tsp ground ginger'), 2, day: 1),
      _plan(_own('1 TL Ingwer, gerieben'), 3, day: 2),
    ], l10n: enL10n);
    expect(_row(receipt, 'ginger').pantry, isFalse);
    expect(_row(receipt, 'ginger').parts, hasLength(2));
    expect(_row(receipt, 'ginger_ground').pantry, isTrue);
    expect(_row(receipt, 'ginger_ground').total, [_a(ShoppingUnit.tsp, .5)]);
    receipt = _receipt([
      _plan(_own('1 TL geriebener Ingwer'), 1),
      _plan(_own('1 TL Ingwerpulver'), 2, day: 1),
    ], l10n: deL10n);
    expect(receipt.rows.map((r) => r.label), ['Geriebener Ingwer']);
    expect(receipt.pantry.map((r) => r.label), ['Ingwerpulver']);

    // Two diced tomatoes are fresh; a can is a can.
    expect(
      rows(['2 diced tomatoes', '1 can diced tomatoes'], l10n: enL10n),
      hasLength(2),
    );
    // Canned anyway: one row with both amounts.
    final corn = rows(['80 g Mais', '1 Dose Mais']);
    expect(corn.map(describe), [
      'main Mais ${_a(ShoppingUnit.mass, 80)} + '
          '${_a(ShoppingUnit.can, 1)} parts=2',
    ]);

    // Tuna or dried tomatoes in oil are bought, not oil from the cupboard.
    receipt = _receipt([
      _plan(_own('70 g Thunfisch in Öl\n30 g Olivenöl'), 1),
      _plan(_own('50 g getrocknete Tomaten in Öl\n60 g Thunfisch'), 2, day: 1),
    ]);
    expect(receipt.rows.map((r) => r.label), [
      'Getrocknete Tomaten in Öl',
      'Thunfisch',
      'Thunfisch in Öl',
    ]);
    expect(receipt.pantry.map((r) => r.label), ['Olivenöl']);

    // Fat levels and flour types in brackets keep their products apart.
    expect(
      rows([
        '200 g Griechischer Joghurt (10%)',
        '200 g Griechischer Joghurt (0,2%)',
      ]).map((r) => r.total),
      [
        [_a(ShoppingUnit.mass, 200)],
        [_a(ShoppingUnit.mass, 200)],
      ],
    );
    expect(rows(['500 g Mehl Type 405', '300 g Mehl Type 1050']), hasLength(2));

    // A flavour after "mit" is another product.
    expect(
      rows(['200 g Frischkäse mit Kräutern', '200 g Frischkäse']),
      hasLength(2),
    );

    // Paprika to garnish is the powder, never the bell pepper.
    final garnish = rows([
      '1/2 bell pepper',
      '6 eggs\nPaprika, for garnish',
    ], l10n: enL10n);
    expect(
      garnish.singleWhere((r) => r.label == 'Bell pepper').parts,
      hasLength(1),
    );
    expect(
      garnish.singleWhere((r) => r.label == 'Paprika, for garnish').pantry,
      isTrue,
    );
    // A bare one stays apart from a counted bell pepper.
    expect(rows(['1 Paprika', 'Paprika']).where((r) => r.merged), isEmpty);
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
    // Not an alternative only one recipe allows.
    expect(
      label(['1 EL Olivenöl oder Butter', '8 g olive oil'], 'olive_oil'),
      'Olivenöl',
    );

    // The app language by the name as written: "Sesam" is German.
    String english(List<String> lines, String key) => _row(
      _receipt([
        for (var i = 0; i < lines.length; i++) _plan(_own(lines[i]), i + 1),
      ], l10n: enL10n),
      key,
    ).label;
    expect(
      english(['1 EL Sesam', '1 tbsp sesame seeds'], 'sesame'),
      'Sesame seeds',
    );
    expect(
      english([
        '1 handful cilantro or parsley',
        '1 Bund Koriander',
      ], 'coriander_leaf|fresh'),
      'Cilantro',
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
