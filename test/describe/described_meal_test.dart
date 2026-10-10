import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/described_meal.dart';
import 'package:eatova/src/models/logged_meal.dart';

Map<String, dynamic> _result({
  List<Object?>? items,
  Object? slotHint = 'breakfast',
}) => <String, dynamic>{
  'mode': 'describe',
  'mealName': 'Nutella-Toast',
  'caloriesKcal': 146,
  'estimatedGrams': 40,
  'kcalPer100G': 365,
  'proteinG': 3,
  'carbsG': 21,
  'fatG': 6,
  'confidence': 'medium',
  'explanation': '',
  'slotHint': slotHint,
  'items':
      items ??
      <Object?>[
        <String, Object?>{
          'name': 'Nutella',
          'grams': 15,
          'caloriesKcal': 81,
          'kcalPer100G': 539,
          'proteinG': 0.9,
          'carbsG': 8.6,
          'fatG': 4.6,
          'searchQuery': 'Nutella',
          'brand': 'Ferrero',
          'amountText': null,
          'gramsSource': 'estimated',
        },
        <String, Object?>{
          'name': 'Toastbrot',
          'grams': 25,
          'caloriesKcal': 65,
          'kcalPer100G': 260,
          'proteinG': 2.0,
          'carbsG': 12.3,
          'fatG': 1.0,
          'searchQuery': 'Toastbrot',
          'brand': 'Lidl',
          'amountText': '1 Scheibe',
          'gramsSource': 'stated',
        },
      ],
};

Map<String, Object?> _item(Map<String, Object?> overrides) => <String, Object?>{
  'name': 'Apfel',
  'grams': 150,
  'caloriesKcal': 78,
  'kcalPer100G': 52,
  'proteinG': 0.5,
  'carbsG': 21,
  'fatG': 0.3,
  'searchQuery': 'Apfel',
  'brand': null,
  'amountText': null,
  'gramsSource': 'estimated',
  ...overrides,
};

void main() {
  group('DescribedMeal.fromJson', () {
    test('liest den Vertrag aus docs/MEAL-DESCRIBE.md', () {
      final meal = DescribedMeal.fromJson(_result());

      expect(meal.slotHint, MealSlot.breakfast);
      expect(meal.base.mealName, 'Nutella-Toast');
      expect(meal.base.caloriesKcal, 146);
      expect(meal.items, hasLength(2));

      final nutella = meal.items.first;
      expect(nutella.name, 'Nutella');
      expect(nutella.grams, 15);
      expect(nutella.caloriesKcal, 81);
      expect(nutella.kcalPer100G, 539);
      expect(nutella.proteinG, 0.9);
      expect(nutella.brand, 'Ferrero');
      expect(nutella.amountText, isNull);
      expect(nutella.gramsSource, DescribedGramsSource.estimated);

      final toast = meal.items.last;
      expect(toast.amountText, '1 Scheibe');
      expect(toast.brand, 'Lidl');
      expect(toast.gramsSource, DescribedGramsSource.stated);
    });

    test('slotHint: nur die vier Slots, alles andere null', () {
      for (final (raw, slot) in <(Object?, MealSlot?)>[
        ('lunch', MealSlot.lunch),
        ('dinner', MealSlot.dinner),
        ('snack', MealSlot.snack),
        (null, null),
        ('brunch', null),
        ('Breakfast', null),
        (3, null),
      ]) {
        expect(
          DescribedMeal.fromJson(_result(slotHint: raw)).slotHint,
          slot,
          reason: '$raw',
        );
      }
    });

    test('Posten ohne Name, ohne Gramm oder ohne Energie fallen weg', () {
      final meal = DescribedMeal.fromJson(
        _result(
          items: <Object?>[
            _item({'name': '   '}),
            _item({'name': 42}),
            _item({'grams': 0}),
            _item({'grams': null}),
            _item({'grams': -5}),
            _item({'grams': 'viel'}),
            _item({'caloriesKcal': null, 'kcalPer100G': null}),
            _item({'caloriesKcal': -10, 'kcalPer100G': 2500}),
            'kein Objekt',
            null,
            _item({'name': 'Birne'}),
          ],
        ),
      );
      expect(meal.items.map((item) => item.name), <String>['Birne']);
    });

    test('kein brauchbarer Posten -> FormatException', () {
      expect(
        () => DescribedMeal.fromJson(_result(items: <Object?>[])),
        throwsFormatException,
      );
      expect(
        () => DescribedMeal.fromJson(<String, dynamic>{'mealName': 'X'}),
        throwsFormatException,
      );
      expect(
        () => DescribedMeal.fromJson(_result()..['items'] = 'Nutella'),
        throwsFormatException,
      );
      expect(
        () => DescribedMeal.fromJson(
          _result(
            items: <Object?>[
              _item({'grams': 0}),
            ],
          ),
        ),
        throwsFormatException,
      );
    });

    test('klemmt Zahlen und kuerzt Texte; nie dem Server vertrauen', () {
      final meal = DescribedMeal.fromJson(
        _result(
          items: <Object?>[
            _item({
              'name': '  Riesen\nPortion   Apfel ',
              'grams': 25000.7,
              'caloriesKcal': 99999,
              'kcalPer100G': 2180,
              'proteinG': -3,
              'carbsG': 5000,
              'fatG': 'viel',
              'searchQuery': 'x' * 200,
              'brand': 'B' * 100,
              'amountText': 'A' * 100,
              'gramsSource': 'STATED',
            }),
          ],
        ),
      );
      final item = meal.items.single;
      expect(item.name, 'Riesen Portion Apfel');
      expect(item.grams, 10000);
      expect(item.caloriesKcal, 10000);
      expect(item.kcalPer100G, isNull, reason: 'kJ-Zahl im kcal-Feld');
      expect(item.proteinG, isNull);
      expect(item.carbsG, 1000);
      expect(item.fatG, isNull);
      expect(item.searchQuery, hasLength(80));
      expect(item.brand, hasLength(60));
      expect(item.amountText, hasLength(40));
      expect(item.gramsSource, DescribedGramsSource.estimated);
    });

    test('Zahlen als Text werden gelesen, nur als Ganzes', () {
      final item = DescribedMeal.fromJson(
        _result(
          items: <Object?>[
            _item({'grams': ' 120 ', 'caloriesKcal': '62,4', 'fatG': '0,3'}),
          ],
        ),
      ).items.single;
      expect(item.grams, 120);
      expect(item.caloriesKcal, 62);
      expect(item.fatG, closeTo(0.3, 1e-9));

      // '120 g' is no number as a whole: no grams, so the item is unusable.
      expect(
        () => DescribedMeal.fromJson(
          _result(
            items: <Object?>[
              _item({'grams': '120 g'}),
            ],
          ),
        ),
        throwsFormatException,
      );
    });

    test('searchQuery faellt auf den Namen zurueck', () {
      final item = DescribedMeal.fromJson(
        _result(
          items: <Object?>[
            _item({'name': 'Skyr', 'searchQuery': '  '}),
          ],
        ),
      ).items.single;
      expect(item.searchQuery, 'Skyr');
      expect(item.brand, isNull);
    });

    test('Energie: Kalorien oder Dichte genuegen, 0 ist eine Aussage', () {
      final items = DescribedMeal.fromJson(
        _result(
          items: <Object?>[
            _item({'name': 'A', 'caloriesKcal': null, 'kcalPer100G': 52}),
            _item({'name': 'B', 'caloriesKcal': 78, 'kcalPer100G': null}),
            _item({'name': 'Wasser', 'caloriesKcal': 0, 'kcalPer100G': 0}),
          ],
        ),
      ).items;
      expect(items.map((item) => item.name), <String>['A', 'B', 'Wasser']);
      expect(items.last.caloriesKcal, 0);
      expect(items.last.kcalPer100G, 0);
    });

    test('hoechstens maxItems Posten', () {
      final meal = DescribedMeal.fromJson(
        _result(
          items: <Object?>[
            for (var i = 0; i < 30; i++) _item({'name': 'Posten $i'}),
          ],
        ),
      );
      expect(meal.items, hasLength(DescribedMeal.maxItems));
      expect(meal.items.last.name, 'Posten 19');
    });
  });
}
