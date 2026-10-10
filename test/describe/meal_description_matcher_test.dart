import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/described_meal.dart';
import 'package:eatova/src/models/favorite_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/meal_description_matcher.dart';
import 'package:eatova/src/services/open_food_facts_product_service.dart';

typedef _Answer = Future<List<ProductSearchResult>> Function();

/// Answers by exact query; unknown queries find nothing. Records every query.
class _FakeProducts implements ProductLookupService {
  _FakeProducts(this.answers);

  final Map<String, _Answer> answers;
  final List<String> queries = <String>[];

  @override
  Future<MealAnalysisResult> lookupBarcode(String barcode) =>
      throw UnimplementedError();

  @override
  Future<List<ProductSearchResult>> searchProducts(String query) {
    queries.add(query);
    final answer = answers[query];
    return answer == null
        ? Future<List<ProductSearchResult>>.value(const [])
        : answer();
  }
}

_Answer _hits(List<ProductSearchResult> hits) =>
    () => Future<List<ProductSearchResult>>.value(hits);

_Answer _after(Duration delay, List<ProductSearchResult> hits) =>
    () => Future<List<ProductSearchResult>>.delayed(delay, () => hits);

Map<String, dynamic> _off(
  String code,
  String name, {
  String? brand,
  double? kcal = 100,
  double protein = 5,
  String? servingSize,
  num? servingQuantity,
}) => <String, dynamic>{
  'code': code,
  'product_name': name,
  'brands': ?brand,
  'serving_size': ?servingSize,
  'serving_quantity': ?servingQuantity,
  'nutrition_data_per': '100g',
  'nutriments': <String, dynamic>{
    'energy-kcal_100g': ?kcal,
    'proteins_100g': protein,
    'carbohydrates_100g': 50,
    'fat_100g': 10,
  },
};

ProductSearchResult _product(
  String code,
  String name, {
  String? brand,
  double? kcal = 100,
  String? servingSize,
  num? servingQuantity,
}) => ProductSearchResult.fromOpenFoodFacts(
  _off(
    code,
    name,
    brand: brand,
    kcal: kcal,
    servingSize: servingSize,
    servingQuantity: servingQuantity,
  ),
);

DescribedFoodItem _food(
  String name, {
  required int grams,
  required int kcal,
  String? query,
  String? brand,
  String? amount,
  bool stated = false,
}) => DescribedFoodItem(
  name: name,
  searchQuery: query ?? name,
  grams: grams,
  gramsSource: stated
      ? DescribedGramsSource.stated
      : DescribedGramsSource.estimated,
  brand: brand,
  amountText: amount,
  caloriesKcal: kcal,
  proteinG: 1,
  carbsG: 2,
  fatG: 3,
);

DescribedMeal _meal(List<DescribedFoodItem> items) => DescribedMeal(
  base: MealAnalysisResult.fromEdgeFunction(<String, dynamic>{
    'mealName': 'Frühstück',
    'caloriesKcal': 300,
    'confidence': 'medium',
    'explanation': '',
  }),
  items: items,
);

ProductMealDescriptionMatcher _matcher(
  ProductLookupService products, {
  List<FavoriteMeal> Function()? favorites,
}) => ProductMealDescriptionMatcher(
  products: products,
  favorites: favorites ?? () => const <FavoriteMeal>[],
);

FavoriteMeal _favorite(MealAnalysisResult result, {required int day}) =>
    FavoriteMeal(
      id: FavoriteMeal.idFor(result),
      result: result,
      addedAt: DateTime.utc(2026, 10, day),
    );

MealAnalysisResult _scan(String name, {int grams = 200, int kcal = 400}) =>
    MealAnalysisResult(
      mealName: name,
      caloriesKcal: kcal,
      estimatedGrams: grams,
      kcalPer100G: kcal * 100 / grams,
      protein: '10 g',
      carbs: '-',
      fat: '8 g',
      confidence: 'medium',
      portionNotes: '',
      sourceLabel: MealResultSource.photoAi.code,
    );

void main() {
  final nutella = _food('Nutella', grams: 15, kcal: 81, brand: null);
  final toast = _food('Toastbrot', grams: 25, kcal: 65);

  group('Favoriten', () {
    final nutellaProduct = _off(
      '3017620422003',
      'Nutella',
      brand: 'Ferrero',
      kcal: 539,
      servingSize: '15 g',
      servingQuantity: 15,
    );
    // A recent is rewritten with the logged portion: here 20 g.
    final usual = MealAnalysisResult.fromOpenFoodFacts(
      nutellaProduct,
      '3017620422003',
    ).adjustedToGrams(20);

    test(
      'ein passender Favorit schlaegt das Produkt, mit seiner Portion',
      () async {
        final products = _FakeProducts({
          'Nutella': _hits([
            ProductSearchResult.fromOpenFoodFacts(nutellaProduct),
            _product(
              '8000500310427',
              'Nutella Biscuits',
              brand: 'Ferrero',
              kcal: 511,
            ),
          ]),
        });
        final draft = await _matcher(
          products,
          favorites: () => [_favorite(usual, day: 9)],
        ).match(_meal([nutella]));

        final line = draft.items.single;
        expect(line.selected.origin, DraftItemOrigin.favorite);
        expect(line.selected.barcode, '3017620422003');
        expect(line.grams, 20, reason: 'geschaetzte Menge -> uebliche Portion');
        expect(line.candidates.map((c) => c.origin), [
          DraftItemOrigin.favorite,
          DraftItemOrigin.product,
          DraftItemOrigin.estimate,
        ], reason: 'das Produkt mit demselben Barcode faellt als Dublette weg');
        expect(line.candidates[1].title, 'Nutella Biscuits · Ferrero');
      },
    );

    test(
      'ein Gericht-Favorit muss dasselbe Essen nennen, nicht nur enthalten',
      () async {
        final products = _FakeProducts({});
        final draft = await _matcher(
          products,
          favorites: () => [
            _favorite(_scan('Toast Hawaii'), day: 9),
            _favorite(_scan('Toast', grams: 50, kcal: 130), day: 8),
          ],
        ).match(_meal([_food('Toast', grams: 25, kcal: 65)]));

        final line = draft.items.single;
        expect(line.selected.title, 'Toast');
        expect(line.selected.origin, DraftItemOrigin.favorite);
        expect(line.grams, 50);
        expect(
          line.candidates.map((c) => c.title),
          isNot(contains('Toast Hawaii')),
        );
      },
    );

    test('eine angegebene Menge bleibt, auch mit Favorit', () async {
      final stated = _food(
        'Nutella',
        grams: 30,
        kcal: 162,
        amount: '30 g',
        stated: true,
      );
      final draft = await _matcher(
        _FakeProducts({}),
        favorites: () => [_favorite(usual, day: 9)],
      ).match(_meal([stated]));
      expect(draft.items.single.selected.origin, DraftItemOrigin.favorite);
      expect(draft.items.single.grams, 30);
    });

    test('Favoriten werfen -> Abgleich laeuft ohne sie weiter', () async {
      final draft = await _matcher(
        _FakeProducts({}),
        favorites: () => throw StateError('store gone'),
      ).match(_meal([nutella]));
      expect(draft.items.single.isEstimate, isTrue);
    });
  });

  group('Marke', () {
    test('ein Treffer mit der genannten Marke rankt nach oben', () async {
      final products = _FakeProducts({
        'Toastbrot': _hits([
          _product('1', 'Toastbrot', brand: 'K-Classic', kcal: 265),
          _product('2', 'American Toastbrot', brand: 'Golden Toast', kcal: 270),
        ]),
      });
      final draft = await _matcher(products).match(
        _meal([_food('Toastbrot', grams: 25, kcal: 65, brand: 'Golden Toast')]),
      );
      expect(draft.items.single.selected.barcode, '2');
      expect(products.queries, ['Toastbrot'], reason: 'Marke unter den Top');
    });

    test(
      'ohne die Marke unter den Top-Treffern: eine Suche mit Marke',
      () async {
        final products = _FakeProducts({
          'Toastbrot': _hits([
            _product('1', 'Toastbrot', brand: 'K-Classic', kcal: 265),
          ]),
          'Lidl Toastbrot': _hits([
            _product(
              '3',
              'Butter Toastbrot',
              brand: 'Grafschafter, Lidl',
              kcal: 280,
            ),
          ]),
        });
        final draft = await _matcher(products).match(
          _meal([_food('Toastbrot', grams: 25, kcal: 65, brand: 'Lidl')]),
        );
        expect(products.queries, ['Toastbrot', 'Lidl Toastbrot']);
        expect(draft.items.single.selected.barcode, '3');
        expect(draft.items.single.candidates.map((c) => c.barcode), [
          '3',
          '1',
          null,
        ]);
      },
    );

    test('ohne Marke: der naechste Titel vor der Suchreihenfolge', () async {
      final products = _FakeProducts({
        'Skyr': _hits([
          _product('1', 'Skyr Natur Vanille', brand: 'Milbona', kcal: 70),
          _product('2', 'Skyr', brand: 'Arla', kcal: 63),
        ]),
      });
      final draft = await _matcher(
        products,
      ).match(_meal([_food('Skyr', grams: 150, kcal: 95)]));
      expect(draft.items.single.selected.barcode, '2');
    });
  });

  group('Annahme', () {
    test('unplausible Produkte werden nie automatisch gewaehlt', () async {
      final products = _FakeProducts({
        'Cola': _hits([
          _product('1', 'Coca-Cola Zero', brand: 'Coca-Cola', kcal: 0.2),
          _product('2', 'Cola Bonbons', brand: 'Haribo', kcal: 350),
          // No energy at all: unknown is not 0 kcal, so it is never listed.
          _product('3', 'Cola', brand: 'Discount', kcal: null),
        ]),
      });
      final draft = await _matcher(
        products,
      ).match(_meal([_food('Cola', grams: 330, kcal: 139)]));
      final line = draft.items.single;
      expect(line.isEstimate, isTrue);
      expect(line.caloriesKcal, 139);
      expect(line.candidates.map((c) => c.barcode), [null, '1', '2']);
    });

    test('der Titel muss die Hauptwoerter der Suche tragen', () async {
      final products = _FakeProducts({
        'Toastbrot': _hits([_product('1', 'Butterkekse', kcal: 450)]),
        'Ei': _hits([
          _product('2', 'Eis Vanille', kcal: 200),
          _product('3', 'Bio Eier', brand: 'Gutfried', kcal: 155),
        ]),
        'Bananen': _hits([_product('4', 'Banane', kcal: 89)]),
      });
      final draft = await _matcher(products).match(
        _meal([
          toast,
          _food('Ei', grams: 60, kcal: 93),
          _food('Bananen', grams: 120, kcal: 107),
        ]),
      );
      expect(draft.items[0].isEstimate, isTrue);
      expect(draft.items[0].candidates, hasLength(1));
      expect(draft.items[1].selected.barcode, '3');
      expect(draft.items[1].candidates.map((c) => c.barcode), ['3', null]);
      expect(draft.items[2].selected.barcode, '4');
    });

    test('hoechstens vier Kandidaten, die Schaetzung immer dabei', () async {
      final products = _FakeProducts({
        'Apfel': _hits([
          for (var i = 0; i < 6; i++) _product('$i', 'Apfel', kcal: 52),
        ]),
      });
      final draft = await _matcher(
        products,
      ).match(_meal([_food('Apfel', grams: 150, kcal: 78)]));
      final candidates = draft.items.single.candidates;
      expect(
        candidates,
        hasLength(ProductMealDescriptionMatcher.maxCandidates),
      );
      expect(candidates.last.origin, DraftItemOrigin.estimate);
      expect(candidates.map((c) => c.barcode).take(3), ['0', '1', '2']);
    });
  });

  group('Fehler und Zeit', () {
    // Key guarantee: a failed search never fails the match, and every line
    // keeps numbers.
    test(
      'Suchfehler (async und sync) -> die Zeile bleibt bei der Schaetzung',
      () async {
        final products = _FakeProducts({
          'Nutella': () => Future<List<ProductSearchResult>>.error(
            const SocketException('offline'),
          ),
          'Toastbrot': () => throw const SocketException('offline'),
        });
        final draft = await _matcher(products).match(_meal([nutella, toast]));

        expect(draft.items, hasLength(2));
        for (final line in draft.items) {
          expect(line.isEstimate, isTrue);
          expect(line.candidates, [line.selected]);
          expect(line.caloriesKcal, greaterThan(0));
        }
        expect(draft.items.first.caloriesKcal, 81);
        expect(draft.items.last.grams, 25);
      },
    );

    test('eine haengende Suche endet nach dem Budget bei der Schaetzung', () {
      fakeAsync((async) {
        final never = Completer<List<ProductSearchResult>>();
        final products = _FakeProducts({'Nutella': () => never.future});
        MealDescriptionDraft? draft;
        Object? error;
        _matcher(products)
            .match(_meal([nutella]))
            .then<void>(
              (value) => draft = value,
              onError: (Object e) => error = e,
            );

        async.elapse(const Duration(seconds: 7));
        expect(draft, isNull, reason: 'noch im Budget');

        async.elapse(const Duration(seconds: 1));
        expect(error, isNull);
        expect(draft, isNotNull, reason: 'nach 8 s ist Schluss');
        expect(draft!.items.single.isEstimate, isTrue);
        expect(draft!.items.single.caloriesKcal, 81);
        expect(async.pendingTimers, isEmpty, reason: 'Frist aufgeraeumt');
      });
    });

    test('Zeilen laufen parallel unter einem gemeinsamen Budget', () {
      fakeAsync((async) {
        const fiveSeconds = Duration(seconds: 5);
        final products = _FakeProducts({
          'Nutella': _after(fiveSeconds, [
            _product('1', 'Nutella', brand: 'Ferrero', kcal: 539),
          ]),
          'Toastbrot': _after(fiveSeconds, [
            _product('2', 'Toastbrot', brand: 'Harry', kcal: 255),
          ]),
          'Apfel': _after(const Duration(seconds: 20), [
            _product('3', 'Apfel', kcal: 52),
          ]),
        });
        MealDescriptionDraft? draft;
        _matcher(products)
            .match(
              _meal([nutella, toast, _food('Apfel', grams: 150, kcal: 78)]),
            )
            .then((value) => draft = value);

        async.flushMicrotasks();
        expect(products.queries, [
          'Nutella',
          'Toastbrot',
          'Apfel',
        ], reason: 'alle Suchen starten sofort');

        async.elapse(const Duration(seconds: 6));
        expect(draft, isNull, reason: 'die Apfel-Suche haengt noch');

        async.elapse(const Duration(seconds: 2));
        expect(draft, isNotNull, reason: 'nach 8 s ist Schluss');
        // Two 5 s searches one after the other would have missed 8 s.
        expect(draft!.items[0].selected.barcode, '1');
        expect(draft!.items[1].selected.barcode, '2');
        expect(draft!.items[2].isEstimate, isTrue);
      });
    });

    test('nach Ablauf des Budgets startet keine Marken-Suche mehr', () {
      fakeAsync((async) {
        final products = _FakeProducts({
          'Toastbrot': _after(const Duration(seconds: 9), const []),
        });
        MealDescriptionDraft? draft;
        _matcher(products)
            .match(
              _meal([_food('Toastbrot', grams: 25, kcal: 65, brand: 'Lidl')]),
            )
            .then((value) => draft = value);
        async.elapse(const Duration(seconds: 10));
        expect(draft!.items.single.isEstimate, isTrue);
        expect(products.queries, ['Toastbrot']);
      });
    });
  });

  group('Gramm', () {
    final twoSlices = _food(
      'Toastbrot',
      grams: 50,
      kcal: 130,
      amount: '2 Scheiben',
      stated: true,
    );

    test(
      'eine angegebene Stueckzahl folgt der Portionsgroesse des Produkts',
      () async {
        final products = _FakeProducts({
          'Toastbrot': _hits([
            _product(
              '1',
              'Toastbrot',
              brand: 'Harry',
              kcal: 255,
              servingSize: '1 Scheibe (28 g)',
              servingQuantity: 28,
            ),
            _product(
              '2',
              'Vollkorntoastbrot',
              brand: 'Golden Toast',
              kcal: 240,
              servingSize: '2 Scheiben (56 g)',
              servingQuantity: 56,
            ),
            _product(
              '3',
              'Toastbrot hell',
              brand: 'Ja',
              kcal: 260,
              servingSize: '100 g',
              servingQuantity: 100,
            ),
          ]),
        });
        final line = (await _matcher(
          products,
        ).match(_meal([twoSlices]))).items.single;

        expect(line.selected.barcode, '1');
        expect(line.selected.servingGrams, 28);
        expect(line.grams, 56);
        final golden = line.candidates.firstWhere((c) => c.barcode == '2');
        expect(golden.servingGrams, 28, reason: '56 g fuer zwei Scheiben');
        final plain = line.candidates.firstWhere((c) => c.barcode == '3');
        expect(plain.servingGrams, isNull, reason: '100 g ist keine Scheibe');

        expect(line.withCandidate(plain).grams, 56, reason: 'bleibt');
        final estimate = line.candidates.firstWhere(
          (c) => c.origin == DraftItemOrigin.estimate,
        );
        expect(line.withCandidate(estimate).grams, 50, reason: 'Modell-Gramm');
      },
    );

    test(
      'ein angegebenes Gewicht und eine Schaetzung behalten Modell-Gramm',
      () async {
        final products = _FakeProducts({
          'Haferflocken': _hits([
            _product(
              '1',
              'Haferflocken',
              brand: 'Koelln',
              kcal: 372,
              servingSize: '40 g',
              servingQuantity: 40,
            ),
          ]),
        });
        final draft = await _matcher(products).match(
          _meal([
            _food(
              'Haferflocken',
              grams: 60,
              kcal: 220,
              amount: '60 g',
              stated: true,
            ),
            _food('Haferflocken', grams: 50, kcal: 185),
          ]),
        );
        expect(draft.items[0].selected.barcode, '1');
        expect(draft.items[0].grams, 60);
        expect(draft.items[1].selected.barcode, '1');
        expect(draft.items[1].grams, 50);
        expect(draft.items[1].selected.servingGrams, 40);
      },
    );

    test('Makros pro 100 g kommen vom Produkt', () async {
      final products = _FakeProducts({
        'Nutella': _hits([
          _product('1', 'Nutella', brand: 'Ferrero', kcal: 539),
        ]),
      });
      final line = (await _matcher(
        products,
      ).match(_meal([nutella]))).items.single;
      expect(line.selected.proteinPer100G, 5);
      expect(line.selected.carbsPer100G, 50);
      expect(line.selected.fatPer100G, 10);
      expect(line.proteinG, closeTo(0.75, 1e-9));
    });
  });

  // German compounds put the food last. A title that names the food (same
  // word, a cut of it, words run together) may be chosen; a compound around
  // the word is in doubt and only listed; another food is dropped. The
  // product's density equals the estimate's, so only the title decides.
  group('Titel und Komposita', () {
    const rows = <(String, String, _Expect)>[
      ('Toastbrot', 'Butter Toast', _Expect.chosen),
      ('Toastbrot', 'Vollkorn Toastbrot', _Expect.chosen),
      ('Toastbrot', 'Buttertoast', _Expect.listed),
      ('Toastbrot', 'Butterkekse', _Expect.dropped),
      ('Toast', 'Sandwich Toastbrot', _Expect.chosen),
      ('Hähnchenbrust', 'Hähnchenbrustfilet', _Expect.chosen),
      ('Hähnchenbrust', 'Hähnchen Brustfilet', _Expect.chosen),
      ('Hähnchenbrust', 'Hähnchenbrust-Aufschnitt', _Expect.chosen),
      ('Hähnchenbrust', 'Hähnchenschenkel', _Expect.dropped),
      ('Nutella', 'Nutella Nuss-Nougat-Creme', _Expect.chosen),
      ('Nuss-Nougat-Creme', 'Nussnougatcreme', _Expect.chosen),
      ('Nuss-Nougat-Creme', 'Nutella', _Expect.dropped),
      ('Haferflocken', 'Haferflocken zart', _Expect.chosen),
      ('Haferflocken', 'Hafer Flocken', _Expect.chosen),
      ('Haferflocken', 'Zarte Haferflocken', _Expect.chosen),
      ('Skyr', 'Skyr Natur', _Expect.chosen),
      ('Skyr Natur', 'Skyr', _Expect.listed),
      ('Milch', 'Fettarme Milch 1,5 %', _Expect.chosen),
      ('Milch', 'Vollmilch', _Expect.listed),
      ('Milch', 'Hafermilch', _Expect.listed),
      ('Milch', 'Milchreis', _Expect.listed),
      ('Vollmilch', 'Frische Milch', _Expect.listed),
      ('Apfel', 'Apfelsaft', _Expect.listed),
      ('Reis', 'Basmati Reis', _Expect.chosen),
      ('Reis', 'Reiswaffeln', _Expect.listed),
      ('Butter', 'Erdnussbutter', _Expect.listed),
      ('Käse', 'Käsekuchen', _Expect.listed),
      ('Bananen', 'Banane', _Expect.chosen),
      ('Ei', 'Eier Größe M', _Expect.chosen),
      ('Ei', 'Eis Vanille', _Expect.dropped),
    ];

    for (final (query, title, expected) in rows) {
      test('"$query" -> "$title": ${expected.name}', () async {
        final products = _FakeProducts({
          query: _hits([_product('1', title, kcal: 250)]),
        });
        final line = (await _matcher(
          products,
        ).match(_meal([_food(query, grams: 100, kcal: 250)]))).items.single;
        final barcodes = line.candidates.map((c) => c.barcode);
        switch (expected) {
          case _Expect.chosen:
            expect(line.selected.barcode, '1');
          case _Expect.listed:
            expect(line.isEstimate, isTrue);
            expect(barcodes, [null, '1']);
          case _Expect.dropped:
            expect(barcodes, [null]);
        }
      });
    }

    test('a title that names the food ranks before a related one', () async {
      final products = _FakeProducts({
        'Milch': _hits([
          _product('1', 'Milchreis', kcal: 64),
          _product('2', 'Vollmilch', kcal: 64),
          _product('3', 'Frische Milch', kcal: 64),
          _product('4', 'Milch', kcal: 400),
        ]),
      });
      final line = (await _matcher(
        products,
      ).match(_meal([_food('Milch', grams: 200, kcal: 128)]))).items.single;
      expect(line.selected.barcode, '3');
      expect(line.candidates.map((c) => c.barcode), [
        '3',
        null,
        '4',
        '1',
      ], reason: 'implausible but named before compounds around the word');
    });

    test('a manual favorite is chosen only for the same food', () async {
      final draft =
          await _matcher(
            _FakeProducts({}),
            favorites: () => [
              _favorite(_scan('Milchreis', grams: 200, kcal: 220), day: 9),
              _favorite(_scan('Toast', grams: 50, kcal: 130), day: 8),
            ],
          ).match(
            _meal([
              _food('Milch', grams: 200, kcal: 128),
              _food('Toastbrot', grams: 50, kcal: 130),
            ]),
          );
      expect(draft.items[0].isEstimate, isTrue);
      expect(draft.items[0].candidates, hasLength(1));
      expect(draft.items[1].selected.origin, DraftItemOrigin.favorite);
      expect(draft.items[1].selected.title, 'Toast');
    });
  });
}

enum _Expect { chosen, listed, dropped }
