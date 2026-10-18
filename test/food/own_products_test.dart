// E5: own products are favorites entered by hand for a barcode; the scan asks
// them before the product database. FOOD-6: both UPC-A spellings meet, also
// in the "Frequent" counts of the favorites sheet.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/favorite_meal.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/favorites_view.dart';
import 'package:eatova/src/services/open_food_facts_product_service.dart';
import 'package:eatova/src/services/own_products.dart';
import 'package:eatova/src/widgets/kcal/saved_meal_presentation.dart'
    show mealTitleAndBrand;

const _upcA = '036000291452';
const _gtin13 = '0036000291452';

MealAnalysisResult _own(String code, {String name = 'Hofmilch'}) =>
    MealAnalysisResult.manualEntry(
      name: name,
      kcalPer100G: 64,
      grams: 250,
      barcode: code,
    );

MealAnalysisResult _database(String code) => MealAnalysisResult(
  mealName: 'Milch',
  caloriesKcal: 160,
  estimatedGrams: 250,
  kcalPer100G: 64,
  protein: '8 g',
  carbs: '12 g',
  fat: '9 g',
  confidence: 'database',
  portionNotes: '',
  sourceLabel: 'OpenFoodFacts',
  barcode: code,
);

FavoriteMeal _favorite(MealAnalysisResult result, {bool pinned = true}) =>
    FavoriteMeal(
      id: FavoriteMeal.idFor(result),
      result: result,
      addedAt: DateTime(2026, 10, 1),
      pinned: pinned,
    );

void main() {
  group('ownProductFor', () {
    test('findet das eigene Produkt in beiden Schreibweisen', () {
      final favorites = [_favorite(_own(_gtin13))];
      expect(ownProductFor(favorites, _gtin13)?.mealName, 'Hofmilch');
      expect(ownProductFor(favorites, _upcA)?.mealName, 'Hofmilch');
      final legacy = [_favorite(_own(_upcA))];
      expect(ownProductFor(legacy, _gtin13)?.mealName, 'Hofmilch');
    });

    test(
      'ein Datenbank-Favorit mit demselben Code ist kein eigenes Produkt',
      () {
        expect(ownProductFor([_favorite(_database(_gtin13))], _gtin13), isNull);
      },
    );

    test('angeheftet vor Zuletzt-Eintrag', () {
      final favorites = [
        _favorite(_own(_upcA, name: 'Alt'), pinned: false),
        _favorite(_own(_gtin13, name: 'Gemerkt')),
      ];
      expect(ownProductFor(favorites, _gtin13)?.mealName, 'Gemerkt');
      expect(
        ownProductFor([favorites.first], _gtin13)?.mealName,
        'Alt',
        reason:
            'ein Zuletzt-Eintrag zaehlt, solange nichts Angeheftetes da ist',
      );
    });

    test('ohne Treffer und bei leerem Code nichts', () {
      expect(
        ownProductFor([_favorite(_own(_gtin13))], '4006381333931'),
        isNull,
      );
      expect(ownProductFor([_favorite(_own(_gtin13))], ''), isNull);
      expect(ownProductFor(const <FavoriteMeal>[], _gtin13), isNull);
    });
  });

  group('barcodeLookupMissedProduct', () {
    test('nur "unbekannt" und "ohne Energiewert" lohnen das Merken', () async {
      expect(
        await barcodeLookupMissedProduct(
          Future<MealAnalysisResult>.error(
            const ProductNotFoundException(_gtin13),
          ),
        ),
        isTrue,
      );
      expect(
        await barcodeLookupMissedProduct(
          Future<MealAnalysisResult>.error(const SocketException('offline')),
        ),
        isFalse,
      );
      expect(
        await barcodeLookupMissedProduct(
          Future<MealAnalysisResult>.value(_database(_gtin13)),
        ),
        isFalse,
      );
    });
  });

  test('die Zeilen nennen ein eigenes Produkt an der Stelle der Marke', () {
    expect(mealTitleAndBrand(_own(_gtin13), deL10n), (
      'Hofmilch',
      'Eigenes Produkt',
    ));
    expect(mealTitleAndBrand(_own(_gtin13), enL10n).$2, 'Own product');
    final noBarcode = MealAnalysisResult.manualEntry(
      name: 'Hofmilch',
      kcalPer100G: 64,
      grams: 250,
    );
    expect(mealTitleAndBrand(noBarcode, deL10n).$2, isNull);
  });

  test('"Haeufig" zaehlt beide Schreibweisen fuer denselben Favoriten', () {
    final now = DateTime(2026, 10, 18, 12);
    final meals = [
      LoggedMeal(id: 'a', result: _database(_upcA), loggedAt: now),
      LoggedMeal(id: 'b', result: _database(_gtin13), loggedAt: now),
      LoggedMeal(id: 'c', result: _database(_gtin13), loggedAt: now),
    ];
    final counts = favoriteUseCounts(meals, now: now);
    final legacy = _favorite(_database(_upcA));
    final other = FavoriteMeal(
      id: 'name:brot',
      result: _database('4006381333931'),
      addedAt: DateTime(2026, 10, 2),
      pinned: true,
    );
    final sorted = sortFavorites(
      [other, legacy],
      FavoriteSort.frequent,
      useCounts: {...counts, 'name:brot': 2},
      nameOf: (f) => f.result.mealName,
    );
    expect(sorted.first, same(legacy), reason: '3 Eintraege schlagen 2');
  });
}
