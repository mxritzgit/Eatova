// The product photo travels in the meal result (2026-10-03): favorites and
// diary rows keep the photo the product was found with, and only Open Food
// Facts image addresses are ever loaded from a payload.

import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/meals_sync.dart';
import 'package:eatova/src/services/open_food_facts_product_service.dart';
import 'package:flutter_test/flutter_test.dart';

const _small =
    'https://images.openfoodfacts.org/images/products/400/054/000/0108/front_de.273.200.jpg';
const _large =
    'https://images.openfoodfacts.org/images/products/400/054/000/0108/front_de.273.400.jpg';

Map<String, dynamic> _product({Map<String, dynamic> images = const {}}) => {
  'code': '4000540000108',
  'product_name': 'Haferflocken',
  'brands': 'Kölln',
  'serving_quantity': 40,
  'nutrition_data_per': '100g',
  'nutriments': {
    'energy-kcal_100g': 372,
    'proteins_100g': 13.5,
    'carbohydrates_100g': 58.7,
    'fat_100g': 7,
  },
  ...images,
};

void main() {
  group('sanitizeProductImageUrl', () {
    test('accepts the Open Food Facts image hosts over https', () {
      expect(sanitizeProductImageUrl(_small), _small);
      expect(
        sanitizeProductImageUrl(
          'https://static.openfoodfacts.org/images/products/1/front.200.jpg',
        ),
        isNotNull,
      );
      expect(sanitizeProductImageUrl('  $_small  '), _small);
    });

    test('rejects everything a tampered payload could smuggle in', () {
      for (final raw in <Object?>[
        null,
        '',
        42,
        'http://images.openfoodfacts.org/images/products/1/front.200.jpg',
        'https://evil.example/images/products/1/front.200.jpg',
        'https://images.openfoodfacts.org.evil.example/x.jpg',
        'https://user@images.openfoodfacts.org/x.jpg',
        'https://images.openfoodfacts.org:8443/x.jpg',
        'javascript:alert(1)',
        'https://images.openfoodfacts.org/${'a' * 490}.jpg',
      ]) {
        expect(sanitizeProductImageUrl(raw), isNull, reason: '$raw');
      }
    });
  });

  group('fromOpenFoodFacts', () {
    test('takes the small front photo first', () {
      final result = MealAnalysisResult.fromOpenFoodFacts(
        _product(
          images: {'image_small_url': _large, 'image_front_small_url': _small},
        ),
        '4000540000108',
      );
      expect(result.imageUrl, _small);
    });

    test('skips a candidate that fails the host check', () {
      final result = MealAnalysisResult.fromOpenFoodFacts(
        _product(
          images: {
            'image_front_small_url': 'https://evil.example/x.jpg',
            'image_small_url': _large,
          },
        ),
        '4000540000108',
      );
      expect(result.imageUrl, _large);
    });

    test('a product without photo has none', () {
      final result = MealAnalysisResult.fromOpenFoodFacts(
        _product(),
        '4000540000108',
      );
      expect(result.imageUrl, isNull);
    });

    test('the search hit reads the photo from its result', () {
      final hit = ProductSearchResult.fromOpenFoodFacts(
        _product(images: {'image_small_url': _small}),
      );
      expect(hit.result.imageUrl, _small);
      expect(hit.imageUrl, _small);
    });
  });

  group('derived results', () {
    final base = MealAnalysisResult.fromOpenFoodFacts(
      _product(images: {'image_small_url': _small}),
      '4000540000108',
    );

    test('a new portion keeps the photo', () {
      expect(base.adjustedToGrams(120).imageUrl, _small);
    });

    test('confirmed components keep the photo', () {
      final adjusted = base.adjustedToItems([
        base.asSingleComponent.adjustedToGrams(80),
      ]);
      expect(adjusted.imageUrl, _small);
    });

    test('withImageUrl changes only the photo', () {
      final other = base.withImageUrl(_large);
      expect(other.imageUrl, _large);
      final without = base.withImageUrl(null);
      expect(without.imageUrl, isNull);
      expect(mealResultToJson(without), {
        ...mealResultToJson(base)..remove('imageUrl'),
      });
    });

    test('manual entries have no photo', () {
      expect(
        MealAnalysisResult.manualEntry(
          name: 'Brot',
          kcalPer100G: 250,
          grams: 80,
        ).imageUrl,
        isNull,
      );
    });
  });

  group('payload', () {
    final base = MealAnalysisResult.fromOpenFoodFacts(
      _product(images: {'image_small_url': _small}),
      '4000540000108',
    );

    test('round trip keeps the photo', () {
      final json = mealResultToJson(base);
      expect(json['imageUrl'], _small);
      expect(mealResultFromJson(json).imageUrl, _small);
    });

    test('a row written before the photo field loads without one', () {
      final json = mealResultToJson(base)..remove('imageUrl');
      final read = mealResultFromJson(json);
      expect(read.imageUrl, isNull);
      expect(mealResultToJson(read).containsKey('imageUrl'), isFalse);
    });

    test('a tampered photo address is dropped on read', () {
      final json = mealResultToJson(base)
        ..['imageUrl'] = 'https://tracker.example/pixel.gif';
      expect(mealResultFromJson(json).imageUrl, isNull);
      final number = mealResultToJson(base)..['imageUrl'] = 7;
      expect(mealResultFromJson(number).imageUrl, isNull);
    });
  });
}
