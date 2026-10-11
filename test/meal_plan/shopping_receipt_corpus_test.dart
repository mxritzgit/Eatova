// The weekly receipt against real recipe text (2026-10-11): all 60 catalog
// recipes planned as one week, per language and mixed. No main row is salt,
// pepper, a powder or water; chicken breast from several recipes is one row;
// every ingredient line is still on the receipt; ids stay valid and unique.

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/planned_meal.dart';
import 'package:eatova/src/models/shopping_list.dart';
import 'package:eatova/src/models/shopping_receipt.dart';
import 'package:flutter_test/flutter_test.dart';

final _week = DateTime(2026, 10, 5);
final _serverId = RegExp(r'^2026-10-05:[a-f0-9]{64}$');

/// Salt, pepper, powders and water by name, in both languages.
final _staple = RegExp(
  r'^(?:salz|salt|pfeffer|pepper|schwarzer pfeffer|black pepper)\b'
  r'|pulver|powder|wasser\b|water\b',
  caseSensitive: false,
);

/// A label that still carries another ingredient's amount ("Zwiebel, 1
/// Knoblauchzehe"); "Greek yogurt, 2%" and "ca. 50 g" are descriptions.
final _embeddedAmount = RegExp(
  r',\s*\d+(?:[.,/]\d+)?\s*(?:[^\s%]+\s+)?[A-Za-zÄÖÜäöüß]{3,}',
);

List<PlannedMeal> _planned(List<FitnessRecipe> recipes, {int offset = 0}) => [
  for (var i = 0; i < recipes.length; i++)
    PlannedMeal.create(
      recipe: recipes[i],
      day: DateTime(2026, 10, 5 + i % 7),
      slot: MealSlot.values[(i ~/ 7) % MealSlot.values.length],
      id: '00000000-0000-4000-8000-${(offset + i + 1).toString().padLeft(12, '0')}',
    ),
];

void _expectSound(List<PlannedMeal> plans, AppLocalizations l10n) {
  final receipt = buildShoppingReceipt(
    plans,
    _week,
    decimalSeparator: l10n.localeName == 'de' ? ',' : '.',
    l10n: l10n,
  );
  final rows = [...receipt.rows, ...receipt.pantry];
  final reason = l10n.localeName;

  // Valid, unique ids; one row per ingredient.
  expect(rows.map((r) => r.id), everyElement(matches(_serverId)));
  expect(rows.map((r) => r.id).toSet(), hasLength(rows.length));
  expect(
    rows.map((r) => r.parts.first.key.id).toSet(),
    hasLength(rows.length),
    reason: reason,
  );
  for (final row in rows) {
    expect(row.label.trim(), isNotEmpty);
    expect(
      row.parts.map((p) => p.key.id).toSet(),
      hasLength(1),
      reason: row.label,
    );
  }

  // The main list is what to buy.
  for (final row in receipt.rows) {
    // The ingredient is the name before any alternative ("Currypaste oder
    // Currypulver" is curry paste).
    final head = row.label.split(RegExp(r',| oder | or ')).first;
    expect(head, isNot(matches(_staple)), reason: row.label);
    expect(
      row.parts.first.key.staple,
      isNot(anyOf(ShoppingStaple.always, ShoppingStaple.water)),
      reason: row.label,
    );
    expect(row.label, isNot(matches(_embeddedAmount)), reason: row.label);
  }
  for (final key in ['salt', 'pepper']) {
    expect(
      receipt.pantry.where((r) => r.parts.first.key.id == key),
      hasLength(1),
      reason: '$key $reason',
    );
  }
  expect(rows.where((r) => r.parts.any((p) => p.key.isWater)), isEmpty);

  // Chicken breast from several recipes is one row.
  final chicken = receipt.rows.singleWhere(
    (r) => r.parts.first.key.id == 'chicken_breast',
  );
  expect(chicken.uses.map((u) => u.planId).toSet().length, greaterThan(1));
  expect(chicken.total.single.unit, ShoppingUnit.mass);

  // Every ingredient line is still there, as a part or split into parts.
  final partIds = {
    for (final row in rows)
      for (final part in row.parts) ...[part.id, ...part.legacyIds],
  };
  for (final item in buildShoppingList(plans, _week)) {
    if (item.grams != null) {
      expect(partIds, contains(item.id));
      continue;
    }
    for (final line in item.lines.where((l) => !l.heading)) {
      expect(partIds, contains(line.id), reason: line.label);
    }
  }
}

void main() {
  test('deutscher Katalog als eine Woche', () {
    _expectSound(_planned(recipeCatalogDe), deL10n);
  });

  test('englischer Katalog als eine Woche', () {
    _expectSound(_planned(recipeCatalogEn), enL10n);
  });

  test('beide Kataloge in einer Woche: dieselbe Zutat bleibt eine Zeile', () {
    final plans = [
      ..._planned(recipeCatalogDe),
      ..._planned(recipeCatalogEn, offset: 100),
    ];
    _expectSound(plans, deL10n);
    _expectSound(plans, enL10n);
    final receipt = buildShoppingReceipt(plans, _week, l10n: deL10n);
    final chicken = receipt.rows.singleWhere(
      (r) => r.parts.first.key.id == 'chicken_breast',
    );
    expect(chicken.label, 'Hähnchenbrustfilet');
    expect(
      buildShoppingReceipt(
        plans,
        _week,
        l10n: enL10n,
      ).rows.singleWhere((r) => r.id == chicken.id).label,
      'Chicken breast fillet',
    );
  });

  test('beide Sprachen ergeben dieselbe Liste', () {
    // The catalogs are translations of each other; so are their receipts.
    final de = buildShoppingReceipt(_planned(recipeCatalogDe), _week);
    final en = buildShoppingReceipt(_planned(recipeCatalogEn), _week);
    expect(
      [en.rows.length, en.pantry.length],
      [de.rows.length, de.pantry.length],
    );
    final keys = {
      for (final row in [...de.rows, ...de.pantry])
        if (!row.parts.first.key.id.startsWith('~')) row.parts.first.key.id,
    };
    expect(
      keys.intersection({
        for (final row in [...en.rows, ...en.pantry]) row.parts.first.key.id,
      }).length,
      greaterThan(keys.length * 3 ~/ 4),
    );
  });
}
