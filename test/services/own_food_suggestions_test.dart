// Own-food suggestions of the add sheet (2026-11-01): "Often at breakfast"
// (a food on three days of the slot within 35 days), "Your usual breakfast"
// (the same set of foods on three days) and "What still fits?" (own foods
// within the calories left, most protein first, once ten own foods state
// their protein). The sheet's rendering is in
// test/widgets/kcal/add_meal_own_food_sections_test.dart.

import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/favorite_meal.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/food_history_search.dart';
import 'package:eatova/src/services/own_food_suggestions.dart';

// Frozen: the window is the 35 days before this evening.
final DateTime _now = DateTime(2026, 11, 1, 19);
const String _today = '2026-11-01';

MealAnalysisResult _food(
  String name, {
  int kcal = 200,
  int grams = 100,
  String protein = '10 g',
}) => MealAnalysisResult(
  mealName: name,
  caloriesKcal: kcal,
  estimatedGrams: grams,
  kcalPer100G: kcal * 100 / grams,
  protein: protein,
  carbs: '10 g',
  fat: '5 g',
  confidence: 'manual',
  portionNotes: '',
  sourceLabel: 'manual',
);

int _ids = 0;

LoggedMeal _log(
  MealAnalysisResult result,
  DateTime at, {
  MealSlot slot = MealSlot.breakfast,
}) => LoggedMeal(
  id: 'meal-${_ids++}',
  result: result,
  loggedAt: at,
  forcedSlot: slot,
);

DateTime _oct(int day, [int hour = 8, int minute = 0]) =>
    DateTime(2026, 10, day, hour, minute);

List<String> _names(Iterable<FoodHistoryHit> hits) => [
  for (final hit in hits) hit.result.mealName,
];

void main() {
  test('Oft zum Frühstück: drei Tage im Slot innerhalb von 35 Tagen, die '
      'meisten Tage zuerst, mit der neuesten Portion', () {
    final skyr = _food('Skyr', kcal: 100, grams: 150);
    final kaffee = _food('Kaffee', kcal: 30, grams: 200);
    for (final (label, diary, expected)
        in <(String, List<LoggedMeal>, List<String>)>[
          (
            'drei Tage',
            [_log(skyr, _oct(1)), _log(skyr, _oct(2)), _log(skyr, _oct(3))],
            ['Skyr'],
          ),
          (
            'zwei Tage sind nicht oft',
            [_log(skyr, _oct(1)), _log(skyr, _oct(2))],
            [],
          ),
          (
            'drei an einem Morgen zählen einen Tag',
            [
              _log(skyr, _oct(1, 7)),
              _log(skyr, _oct(1, 8)),
              _log(skyr, _oct(1, 9)),
            ],
            [],
          ),
          (
            'ein anderer Slot zählt nicht',
            [
              _log(skyr, _oct(1)),
              _log(skyr, _oct(2)),
              _log(skyr, _oct(3, 13), slot: MealSlot.lunch),
            ],
            [],
          ),
          (
            'älter als 35 Tage zählt nicht',
            [
              _log(skyr, DateTime(2026, 9, 26, 8)),
              _log(skyr, _oct(2)),
              _log(skyr, _oct(3)),
            ],
            [],
          ),
          (
            'der Tag des Sheets zählt nicht',
            [
              _log(skyr, _oct(1)),
              _log(skyr, _oct(2)),
              _log(skyr, DateTime(2026, 11, 1, 8)),
            ],
            [],
          ),
          (
            'mehr Tage vor neuer',
            [
              for (var d = 1; d <= 4; d++) _log(kaffee, _oct(d)),
              for (var d = 10; d <= 12; d++) _log(skyr, _oct(d)),
            ],
            ['Kaffee', 'Skyr'],
          ),
          (
            'bei gleich vielen Tagen die neuere zuerst',
            [
              for (var d = 1; d <= 3; d++) _log(kaffee, _oct(d)),
              for (var d = 10; d <= 12; d++) _log(skyr, _oct(d)),
            ],
            ['Skyr', 'Kaffee'],
          ),
        ]) {
      expect(
        _names(
          frequentFoodsInSlot(
            diary,
            slot: MealSlot.breakfast,
            now: _now,
            skipDay: _today,
          ),
        ),
        expected,
        reason: label,
      );
    }

    final hits = frequentFoodsInSlot(
      [
        _log(skyr, _oct(1)),
        _log(skyr.adjustedToGrams(250), _oct(3)),
        _log(skyr, _oct(2)),
      ],
      slot: MealSlot.breakfast,
      now: _now,
    );
    expect(hits.single.result.estimatedGrams, 250, reason: 'neueste Portion');
  });

  test('Dein übliches Frühstück: dieselbe Kombination an drei Tagen, die '
      'Einträge des neuesten Tages', () {
    final oats = _food('Haferflocken', kcal: 150, grams: 40);
    final milk = _food('Milch', kcal: 100, grams: 200);
    final banana = _food('Banane', kcal: 90, grams: 100);
    List<LoggedMeal> day(int d, List<MealAnalysisResult> foods) => [
      for (var i = 0; i < foods.length; i++) _log(foods[i], _oct(d, 8, i)),
    ];
    final newest = day(3, [oats, milk]);
    for (final (label, diary, expected)
        in <(String, List<LoggedMeal>, List<String>?)>[
          (
            'drei Tage',
            [
              ...day(1, [oats, milk]),
              ...day(2, [milk, oats]),
              ...newest,
            ],
            [for (final m in newest) m.id],
          ),
          (
            'zwei Tage',
            [
              ...day(1, [oats, milk]),
              ...newest,
            ],
            null,
          ),
          (
            'ein Lebensmittel ist keine Kombination',
            [
              ...day(1, [oats]),
              ...day(2, [oats]),
              ...day(3, [oats]),
            ],
            null,
          ),
          (
            'ein Teil mehr ist eine andere Kombination',
            [
              ...day(1, [oats, milk]),
              ...day(2, [oats, milk, banana]),
              ...newest,
            ],
            null,
          ),
          (
            'der Tag des Sheets zählt nicht',
            [
              ...day(1, [oats, milk]),
              ...newest,
              _log(oats, DateTime(2026, 11, 1, 8)),
              _log(milk, DateTime(2026, 11, 1, 8)),
            ],
            null,
          ),
        ]) {
      final usual = usualMealInSlot(
        diary,
        slot: MealSlot.breakfast,
        now: _now,
        skipDay: _today,
      );
      expect(usual?.meals.map((m) => m.id).toList(), expected, reason: label);
    }
  });

  test('Was passt noch: ins Restbudget, unbekanntes Protein zählt nie, erst '
      'ab zehn bekannten, das meiste Protein zuerst', () {
    FavoriteMeal fav(String name, int kcal, String protein) {
      final result = _food(name, kcal: kcal, protein: protein);
      return FavoriteMeal(
        id: FavoriteMeal.idFor(result),
        result: result,
        addedAt: _oct(20),
        pinned: true,
      );
    }

    final known = [
      fav('Hähnchen', 250, '40 g'),
      fav('Lachs', 400, '40 g'),
      fav('Thunfisch', 120, '26 g'),
      fav('Skyr', 150, '25 g'),
      fav('Käse', 300, '25 g'),
      fav('Pasta', 600, '20 g'),
      fav('Ei', 160, '13 g'),
      fav('Brot', 250, '8 g'),
      fav('Joghurt', 120, '5 g'),
      fav('Apfel', 80, '0 g'),
    ];
    final shake = fav('Shake', 90, '-');
    final chicken = FoodHistoryIndex().keyOf(known.first.result)!;
    for (final (label, favorites, remaining, exclude, expected)
        in <(String, List<FavoriteMeal>, int, Set<String>, List<String>)>[
          (
            'passt ins Budget',
            [...known, shake],
            300,
            {},
            ['Hähnchen', 'Thunfisch', 'Skyr'],
          ),
          (
            'mehr Budget, mehr passt',
            [...known, shake],
            450,
            {},
            ['Hähnchen', 'Lachs', 'Thunfisch'],
          ),
          (
            'unbekanntes Protein wird nie vorgeschlagen',
            [...known, shake],
            100,
            {},
            ['Apfel'],
          ),
          ('nichts mehr offen', [...known, shake], 0, {}, []),
          (
            'neun bekannte reichen nicht',
            [...known.take(9), shake],
            300,
            {},
            [],
          ),
          (
            'schon gezeigte bleiben weg',
            [...known, shake],
            300,
            {chicken},
            ['Thunfisch', 'Skyr', 'Käse'],
          ),
        ]) {
      expect(
        _names(
          foodsThatFit(
            favorites: favorites,
            diary: const <LoggedMeal>[],
            remainingKcal: remaining,
            exclude: exclude,
          ),
        ),
        expected,
        reason: label,
      );
    }
  });

  test('das Sheet zeigt „Was passt noch“ nur heute nach dem ersten Eintrag '
      'und die übliche Mahlzeit nur im leeren Slot', () {
    final oats = _food('Haferflocken', kcal: 150, grams: 40);
    final milk = _food('Milch', kcal: 100, grams: 200);
    final diary = [
      for (var d = 1; d <= 3; d++) ...[
        _log(oats, _oct(d, 8)),
        _log(milk, _oct(d, 8, 1)),
      ],
    ];
    final favorites = [
      for (var i = 0; i < 10; i++)
        FavoriteMeal(
          id: 'name:f$i',
          result: _food('F$i', kcal: 100 + i, protein: '${i + 1} g'),
          addedAt: _oct(20),
        ),
    ];
    final lunch = _log(
      _food('Suppe'),
      DateTime(2026, 11, 1, 12),
      slot: MealSlot.lunch,
    );
    final breakfast = _log(oats, DateTime(2026, 11, 1, 8));
    for (final (label, day, dayMeals, usual, fits)
        in <(String, DateTime, List<LoggedMeal>, bool, bool)>[
          ('heute nach dem Mittagessen', _now, [lunch], true, true),
          ('heute noch nichts eingetragen', _now, [], true, false),
          ('ein vergangener Tag', DateTime(2026, 10, 31), [lunch], true, false),
          ('der Slot hat schon etwas', _now, [lunch, breakfast], false, true),
        ]) {
      final s = ownFoodSuggestions(
        diary: diary,
        favorites: favorites,
        slot: MealSlot.breakfast,
        day: day,
        dayMeals: dayMeals,
        now: _now,
        remainingKcal: 500,
      );
      expect(_names(s.frequent), ['Milch', 'Haferflocken'], reason: label);
      expect(s.usual != null, usual, reason: label);
      expect(s.fitting.isNotEmpty, fits, reason: label);
      expect(
        _names(s.fitting).toSet().intersection(_names(s.frequent).toSet()),
        isEmpty,
        reason: '$label: nichts doppelt',
      );
    }
  });
}
