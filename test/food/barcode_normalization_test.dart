// FOOD-6: the same UPC-A product arrives as 12 digits on Android and as a
// 13-digit EAN with a leading 0 on iOS. Scanner and typed entry hand on one
// GTIN-13 form; stored keys keep their spelling and still match.

import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/barcode.dart';
import 'package:eatova/src/models/favorite_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';

// Published examples with valid check digits.
const _upcA = '036000291452'; // UPC-A, as Android delivers it
const _upcAsEan13 = '0036000291452'; // the same product, as iOS delivers it
const _ean13 = '4006381333931';
const _ean8 = '96385074';

MealAnalysisResult _product(String barcode) => MealAnalysisResult(
  mealName: 'Milch',
  caloriesKcal: 160,
  estimatedGrams: 250,
  kcalPer100G: 64,
  protein: '8,5 g',
  carbs: '12 g',
  fat: '9 g',
  confidence: 'database',
  portionNotes: '',
  sourceLabel: 'OpenFoodFacts',
  barcode: barcode,
);

void main() {
  group('normalizeBarcode', () {
    test('ein 12-stelliger UPC-A bekommt die fuehrende 0 (GTIN-13)', () {
      expect(normalizeBarcode(_upcA), _upcAsEan13);
    });

    test('die 13-stellige iOS-Form bleibt, wie sie ist', () {
      expect(normalizeBarcode(_upcAsEan13), _upcAsEan13);
      expect(normalizeBarcode(_ean13), _ean13);
    });

    test('EAN-8 bleibt achtstellig', () {
      expect(normalizeBarcode(_ean8), _ean8);
    });

    test('eine falsche Pruefziffer wird abgelehnt, in jeder Laenge', () {
      expect(normalizeBarcode('036000291453'), isNull);
      expect(normalizeBarcode('4006381333932'), isNull);
      expect(normalizeBarcode('96385075'), isNull);
      // The fixture code the older tests typed: one digit off.
      expect(normalizeBarcode('4001724012345'), isNull);
      expect(normalizeBarcode('4001724012344'), '4001724012344');
    });

    test('Leerzeichen fallen weg, auch zwischen den Ziffern', () {
      expect(normalizeBarcode(' 036000 291452 '), _upcAsEan13);
      expect(normalizeBarcode('4 006381 333931\n'), _ean13);
    });

    test('falsche Laenge und Fremdzeichen sind kein Barcode', () {
      expect(normalizeBarcode(''), isNull);
      expect(normalizeBarcode('1234567'), isNull);
      expect(normalizeBarcode('00036000291452'), isNull);
      expect(normalizeBarcode('03600029145a'), isNull);
      expect(normalizeBarcode('036-000-291452'), isNull);
    });
  });

  test('hasValidGtinCheckDigit rechnet fuer alle drei Laengen', () {
    for (final code in [_upcA, _upcAsEan13, _ean13, _ean8]) {
      expect(hasValidGtinCheckDigit(code), isTrue, reason: code);
    }
    expect(hasValidGtinCheckDigit('4006381333930'), isFalse);
    expect(hasValidGtinCheckDigit('7'), isFalse);
  });

  test('canonicalBarcode bringt beide gespeicherten Formen zusammen', () {
    expect(canonicalBarcode(_upcA), canonicalBarcode(_upcAsEan13));
    expect(canonicalBarcode(_ean8), _ean8);
    expect(canonicalBarcode(_ean13), _ean13);
    // Keys from the product index can be anything; only 12 digits move.
    expect(canonicalBarcode('4001234'), '4001234');
  });

  group('FavoriteMeal ueber beide Schreibweisen', () {
    final legacy = FavoriteMeal(
      id: 'barcode:$_upcA',
      result: _product(_upcA),
      addedAt: DateTime(2026, 9, 1),
      pinned: true,
    );

    test('ein alter 12-stelliger Schluessel trifft den 13-stelligen Scan', () {
      final found = FavoriteMeal.findFor([legacy], _product(_upcAsEan13));
      expect(found, same(legacy));
      expect(found!.id, 'barcode:$_upcA', reason: 'kein Umschreiben');
    });

    test('der eigene Schluessel gewinnt vor der anderen Schreibweise', () {
      final exact = FavoriteMeal(
        id: 'barcode:$_upcAsEan13',
        result: _product(_upcAsEan13),
        addedAt: DateTime(2026, 9, 2),
      );
      expect(
        FavoriteMeal.findFor([legacy, exact], _product(_upcAsEan13)),
        same(exact),
      );
      expect(
        FavoriteMeal.findFor([exact, legacy], _product(_upcA)),
        same(legacy),
      );
    });

    test('Namensschluessel und fremde Codes treffen nicht', () {
      expect(FavoriteMeal.findFor([legacy], _product(_ean13)), isNull);
      expect(FavoriteMeal.canonicalId('name:milch'), 'name:milch');
      expect(
        FavoriteMeal.canonicalId('barcode:$_upcA'),
        'barcode:$_upcAsEan13',
      );
    });

    test('das Produktfoto wandert ueber beide Schreibweisen', () {
      const photo =
          'https://images.openfoodfacts.org/images/products/003/600/029/1452/front.jpg';
      final withPhoto = _product(_upcA).withImageUrl(photo);
      final kept = FavoriteMeal.keepImage(_product(_upcAsEan13), withPhoto);
      expect(kept.imageUrl, photo);
    });
  });
}
