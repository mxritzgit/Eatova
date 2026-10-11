// The dictionary and matcher behind the receipt's price estimate
// (docs/SHOPPING-PRICES.md): real recipe lines from the catalog in German
// and English, compounds and cuts, false friends, seasoning, and the
// dictionary's own integrity.

import 'package:eatova/src/models/fitness_recipe.dart'
    show foldRecipeSearchText;
import 'package:eatova/src/models/shopping_price.dart';
import 'package:eatova/src/models/shopping_price_amount.dart';
import 'package:eatova/src/models/shopping_price_dictionary.dart';
import 'package:flutter_test/flutter_test.dart';

PriceMatch _match(String label, [String? amount]) =>
    matchPriceEntry(label, quantity: parsePriceQuantity(amount));

void main() {
  test('catalog lines find their entry through cuts, compounds and '
      'alternatives', () {
    const cases = {
      'Hähnchenbrustfilet, roh': 'chickenBreast',
      'Hähnchenbrustfilets': 'chickenBreast',
      'Vollkornreis oder Naturreis, roh': 'rice',
      'Kleine Knoblauchzehe, fein gerieben': 'garlic',
      'Weiße Zwiebel': 'onion',
      'Rote Zwiebeln, gewürfelt': 'onion',
      'Kirschtomaten': 'tomato',
      'Passierte Tomaten': 'passata',
      'Mozzarella, gerieben': 'mozzarella',
      'Nuss-Nougat-Creme': 'hazelnutSpread',
      'Lachsfilet': 'salmon',
      'Paprikaschote, rot': 'bellPepper',
      'Rinderhackfleisch': 'mince',
      'Zarte Haferflocken': 'oats',
      'Natives Olivenöl extra': 'oliveOil',
      'Salatgurke': 'cucumber',
      'Vollmilch 3,5 %': 'milk',
      'Ei': 'egg',
      'Eier (Größe M)': 'egg',
      'Salzkartoffeln': 'potato',
      'Brötchen': 'breadRoll',
      'Vollkornbrot': 'bread',
      'Barilla Spaghetti n.5': 'spaghetti',
      'Gouda, in Scheiben': 'gouda',
      'Griechischer Joghurt': 'yogurt',
      'Bananen': 'banana',
      'Pizzateig (Kühlregal)': 'pizzaDough',
      'Weizenmehl Type 405': 'flour',
      'Zucchini': 'zucchini',
    };
    for (final MapEntry(key: label, value: id) in cases.entries) {
      final match = _match(label);
      expect(match.entry?.id, id, reason: label);
      expect(match.skipped || match.blocked, isFalse, reason: label);
    }
  });

  test('English lines match whole words', () {
    const cases = {
      'Chicken breast fillets': 'chickenBreast',
      'Brown rice': 'rice',
      'Greek yogurt': 'yogurt',
      'Whole milk': 'milk',
      'All-purpose flour': 'flour',
      'Red bell pepper': 'bellPepper',
      'Bananas': 'banana',
      'Large eggs': 'egg',
      'Minced beef': 'mince',
    };
    for (final MapEntry(key: label, value: id) in cases.entries) {
      expect(_match(label).entry?.id, id, reason: label);
    }
  });

  test('decomposed umlauts read like composed ones', () {
    expect(_match('Hähnchenbrust').entry?.id, 'chickenBreast');
    expect(_match('Äpfel').entry?.id, 'apple');
    expect(normalizePriceLabel('Süßkartoffel'), 'suesskartoffel');
  });

  test('false friends are blocked, not priced as what they contain', () {
    for (final label in const [
      'Kokosmilch',
      'Tomatenmark',
      'Knoblauchpulver',
      'Granatapfel',
      'Frühlingszwiebel',
      'Gehackte Tomaten',
      'Paprikapulver edelsüß',
      'Erdnussbutter',
      'Buttermilch',
      'Süßkartoffeln',
      'Essiggurken',
      'Röstzwiebeln',
      'Coconut milk',
      'Diced tomatoes',
      'Spring onions',
      'Peanut butter',
    ]) {
      final match = _match(label);
      expect(match.entry, isNull, reason: label);
      expect(match.blocked, isTrue, reason: label);
    }
  });

  test('English never matches inside a word, short keys only exactly', () {
    for (final label in const ['Licorice', 'Brei', 'Speiseeis']) {
      final match = _match(label);
      expect(match.entry, isNull, reason: label);
      expect(match.blocked || match.skipped, isFalse, reason: label);
    }
  });

  test('seasoning is skipped, never priced', () {
    const skipped = <(String, String?)>[
      ('Salz, schwarzer Pfeffer, Petersilie nach Geschmack', null),
      ('Salz', null),
      ('Etwas Salz', null),
      ('Meersalz', null),
      ('Salt and pepper', null),
      ('Wasser', null),
      ('Olivenöl nach Belieben', null),
      ('Salz', '1 Prise'),
      ('Mehl', '1 Msp'),
      ('Paprika', '1 TL'),
      ('paprika', '1 tsp'),
    ];
    for (final (label, amount) in skipped) {
      expect(_match(label, amount).skipped, isTrue, reason: '$amount $label');
    }
    // The vegetable, not the spice: a count is no spoon.
    expect(_match('Paprika', '1').entry?.id, 'bellPepper');
  });

  test('a line without a dictionary entry has no match', () {
    for (final label in const [
      'Brokkoli, frisch oder TK',
      'Backpulver',
      'Thunfisch im eigenen Saft',
      'Körniger Frischkäse',
    ]) {
      final match = _match(label);
      expect(match.entry, isNull, reason: label);
      expect(match.blocked || match.skipped, isFalse, reason: label);
    }
  });

  test('the longest key wins, a tie goes to the rightmost word', () {
    expect(_match('Hähnchenbrust mit Paprika').entry?.id, 'chickenBreast');
    expect(_match('Tomaten-Mozzarella').entry?.id, 'mozzarella');
    expect(_match('Reis Brot').entry?.id, 'bread');
    expect(_match('Brot Reis').entry?.id, 'rice');
    // The explicit longer key beats the one it contains.
    expect(_match('Passierte Tomaten').entry?.id, 'passata');
    expect(_match('Vollmilch').entry?.id, 'milk');
  });

  test('a clove or slice is implied by the word', () {
    expect(_match('Knoblauchzehen').impliedUnit, PriceUnit.clove);
    expect(_match('Kleine Knoblauchzehe').impliedUnit, PriceUnit.clove);
    expect(_match('Garlic cloves').impliedUnit, PriceUnit.clove);
    expect(_match('Knoblauch').impliedUnit, isNull);
  });

  test('normalisation folds, drops parentheses and cuts at alternatives', () {
    expect(normalizePriceLabel('Mozzarella, gerieben'), 'mozzarella');
    expect(
      normalizePriceLabel('Hähnchenbrust (bio) oder Pute'),
      'haehnchenbrust',
    );
    expect(normalizePriceLabel('Milch / Hafermilch'), 'milch');
    expect(normalizePriceLabel('Butter; weich'), 'butter');
    expect(normalizePriceLabel('Rice or quinoa'), 'rice');
  });

  test('categories walk from the most specific tag', () {
    expect(
      priceEntryForCategories(const [
        'en:dairies',
        'en:fermented-dairy-desserts',
        'en:yogurts',
        'en:fruit-yogurts',
      ])?.id,
      'yogurt',
    );
    // Broad tags never price a product.
    expect(priceEntryForCategories(const ['en:dairies', 'en:meals']), isNull);
    // Nutella's record carries en:sweet-spreads, not en:hazelnut-spreads;
    // that is why the name is read first.
    expect(priceEntryForCategories(const ['en:sweet-spreads']), isNull);
    expect(_match('Nutella').entry?.id, 'hazelnutSpread');
  });

  group('dictionary integrity', () {
    final words = RegExp(r'^[a-z]+( [a-z]+)*$');
    final tag = RegExp(r'^[a-z]{2}:[a-z0-9-]+$');

    test('keys are folded and point at entries', () {
      for (final MapEntry(key: key, value: id) in kPriceKeys.entries) {
        expect(words.hasMatch(key), isTrue, reason: key);
        expect(foldRecipeSearchText(key), key, reason: key);
        if (id != null) expect(kPriceEntries, contains(id), reason: key);
      }
    });

    test('every entry is reachable and carries its own id', () {
      final reachable = kPriceKeys.values.whereType<String>().toSet();
      for (final MapEntry(key: id, value: entry) in kPriceEntries.entries) {
        expect(entry.id, id);
        expect(reachable, contains(id), reason: id);
      }
    });

    test('compound heads are German keys of at least four characters', () {
      for (final head in kPriceCompoundHeads) {
        expect(head.length, greaterThanOrEqualTo(4), reason: head);
        expect(kPriceKeys[head], isNotNull, reason: head);
      }
    });

    test('every tag carries a language prefix', () {
      for (final entry in kPriceEntries.values) {
        for (final value in [
          ...entry.productTags,
          ...entry.categoryTags,
          ...entry.requireTags,
          ...entry.excludeTags,
        ]) {
          expect(tag.hasMatch(value), isTrue, reason: '${entry.id}: $value');
        }
      }
    });

    test('piece entries know a piece, category entries a matching basis', () {
      for (final entry in kPriceEntries.values) {
        if (entry.basis == PriceBasis.piece) {
          expect(entry.units[PriceUnit.piece], isNotNull, reason: entry.id);
        }
        if (entry.categoryPrices) {
          // Category prices exist per kilogram or per piece, never per litre.
          expect(entry.basis, isNot(PriceBasis.volume), reason: entry.id);
        }
      }
    });

    test('descriptors and skip words are folded', () {
      for (final word in [...kPriceDescriptors, ...kPriceSkipWords]) {
        expect(words.hasMatch(word), isTrue, reason: word);
      }
    });
  });
}
