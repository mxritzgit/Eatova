// E3 (improvement review 2026-10-18): the add sheet's search only asked the
// product database, so a meal logged five times could not be found again.
// `FoodHistoryIndex` searches the user's own favorites, recents, diary rows
// and recipes. These tests pin matching, dedupe, ranking and the cost bound.

import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/favorite_meal.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/food_history_search.dart';

MealAnalysisResult _meal(
  String name, {
  int kcal = 300,
  int grams = 200,
  double? density,
  String? brand,
  bool explicitZero = false,
}) => MealAnalysisResult(
  mealName: name,
  caloriesKcal: kcal,
  estimatedGrams: grams,
  kcalPer100G: density ?? (grams > 0 ? kcal * 100 / grams : 0),
  protein: '10 g',
  carbs: '20 g',
  fat: '5 g',
  confidence: 'manual',
  portionNotes: '',
  sourceLabel: 'manual',
  brand: brand,
  explicitZeroKcal: explicitZero,
);

int _ids = 0;

LoggedMeal _log(MealAnalysisResult result, DateTime at) =>
    LoggedMeal(id: 'meal-${_ids++}', result: result, loggedAt: at);

FavoriteMeal _fav(
  MealAnalysisResult result,
  DateTime at, {
  bool pinned = false,
}) => FavoriteMeal(
  id: FavoriteMeal.idFor(result),
  result: result,
  addedAt: at,
  pinned: pinned,
);

FitnessRecipe _recipe(String slug, String title, {int kcal = 450}) =>
    FitnessRecipe(
      slug: slug,
      title: title,
      description: '',
      portion: '',
      ingredients: '',
      preparation: '',
      professionalHint: '',
      imageAsset: '',
      caloriesKcal: kcal,
      proteinG: 30,
      carbsG: 40,
      fatG: 12,
      estimatedGrams: 400,
      categories: const <String>[],
      userCreated: true,
    );

DateTime _day(int day, [int hour = 12]) => DateTime(2026, 10, day, hour);

List<String> _names(List<FoodHistoryHit> hits) =>
    hits.map((h) => h.result.mealName).toList();

void main() {
  group('Anfrage', () {
    final index = FoodHistoryIndex(
      diary: [_log(_meal('Overnight Oats'), _day(1))],
    );

    test('leere oder nur Leerzeichen-Anfrage findet nichts', () {
      expect(index.search(''), isEmpty);
      expect(index.search('   '), isEmpty);
    });

    test('Gross-/Kleinschreibung ist egal', () {
      expect(_names(index.search('OVERNIGHT')), ['Overnight Oats']);
      expect(_names(index.search('oats')), ['Overnight Oats']);
    });

    test('nichts Passendes ergibt eine leere Liste', () {
      expect(index.search('pizza'), isEmpty);
    });
  });

  group('Umlaute', () {
    final index = FoodHistoryIndex(
      diary: [
        _log(_meal('Käsebrot'), _day(1)),
        _log(_meal('Müsli mit Beeren'), _day(1)),
        _log(_meal('Joghurt', brand: 'Mueller'), _day(1)),
        // Decomposed umlaut, as some keyboards and pasted texts deliver it.
        _log(_meal('Grüner Tee', kcal: 2, grams: 250), _day(1)),
      ],
    );

    test('ä, ae und a finden denselben Eintrag', () {
      for (final query in ['käse', 'kaese', 'kase', 'KÄSE']) {
        expect(_names(index.search(query)), ['Käsebrot'], reason: query);
      }
    });

    test('ü und ue treffen auch in der Marke', () {
      expect(_names(index.search('muesli')), ['Müsli mit Beeren']);
      expect(_names(index.search('müller')), ['Joghurt']);
    });

    test('zerlegte Umlaute zählen wie zusammengesetzte', () {
      expect(_names(index.search('grüner')), ['Grüner Tee']);
      expect(_names(index.search('gruener')), ['Grüner Tee']);
      expect(_names(index.search('gruner')), ['Grüner Tee']);
    });

    test('mehrere Wörter müssen alle passen, egal ob Name oder Marke', () {
      final both = FoodHistoryIndex(
        favorites: [_fav(_meal('Haferdrink', brand: 'Alpro'), _day(2))],
      );
      expect(_names(both.search('hafer alpro')), ['Haferdrink']);
      expect(both.search('hafer oatly'), isEmpty);
    });
  });

  group('Dedupe', () {
    test('gleicher Name und gleiche Dichte zählen einmal, der neueste '
        'Eintrag gewinnt mit seiner Portion', () {
      final older = _meal('Overnight Oats', kcal: 375, grams: 250);
      final newest = _meal('Overnight Oats', kcal: 450, grams: 300);
      final middle = _meal('overnight oats ', kcal: 300, grams: 200);
      final index = FoodHistoryIndex(
        diary: [
          _log(older, _day(1)),
          _log(newest, _day(5)),
          _log(middle, _day(3)),
        ],
      );

      final hits = index.search('oats');
      expect(hits, hasLength(1));
      expect(identical(hits.single.result, newest), isTrue);
      expect(hits.single.result.estimatedGrams, 300);
      expect(hits.single.uses, 3);
      expect(hits.single.lastUsed, _day(5));
    });

    test('Recent und Tagebuch-Eintrag derselben Mahlzeit sind ein Treffer', () {
      final logged = _meal('Skyr', kcal: 126, grams: 200);
      final recent = _meal('Skyr', kcal: 158, grams: 250);
      final index = FoodHistoryIndex(
        favorites: [_fav(recent, _day(6, 8))],
        diary: [_log(logged, _day(6, 7)), _log(logged, _day(4))],
      );

      final hits = index.search('skyr');
      expect(hits, hasLength(1));
      expect(
        identical(hits.single.result, recent),
        isTrue,
        reason: 'der Recent ist der neueste Eintrag',
      );
      expect(hits.single.uses, 2, reason: 'nur Tagebuchzeilen zählen');
    });

    test('bei gleicher Zeit gewinnt der Favorit vor dem Tagebuch', () {
      final diary = _meal('Banane', kcal: 105, grams: 120);
      final pinned = _meal('Banane', kcal: 105, grams: 120);
      final index = FoodHistoryIndex(
        diary: [_log(diary, _day(2))],
        favorites: [_fav(pinned, _day(2), pinned: true)],
      );
      expect(identical(index.search('banane').single.result, pinned), isTrue);
    });

    test('andere Dichte oder andere Marke bleiben eigene Treffer', () {
      final index = FoodHistoryIndex(
        diary: [
          _log(_meal('Skyr', kcal: 126, grams: 200), _day(1)),
          _log(_meal('Skyr', kcal: 180, grams: 200), _day(2)),
          _log(_meal('Skyr', kcal: 126, grams: 200, brand: 'Arla'), _day(3)),
        ],
      );
      expect(index.search('skyr'), hasLength(3));
      expect(index.groupCount, 3);
    });

    test('ohne Dichte entscheidet die Portion', () {
      final index = FoodHistoryIndex(
        diary: [
          _log(_meal('Bowl', kcal: 520, grams: 0, density: 0), _day(1)),
          _log(_meal('Bowl', kcal: 520, grams: 0, density: 0), _day(2)),
          _log(_meal('Bowl', kcal: 640, grams: 0, density: 0), _day(3)),
        ],
      );
      expect(index.search('bowl').map((h) => h.result.caloriesKcal), [
        520,
        640,
      ], reason: 'zwei Einträge à 520 kcal sind einer, öfter gegessen');
    });
  });

  group('Ranking', () {
    test('Namensanfang vor Wortanfang vor Teiltreffer', () {
      final index = FoodHistoryIndex(
        diary: [
          // Many uses and the newest: the tier still decides first.
          for (var i = 0; i < 5; i++)
            _log(_meal('Protein-Boats'), _day(10 + i)),
          _log(_meal('Overnight Oats'), _day(2)),
          _log(_meal('Oatly Barista', brand: 'Oatly'), _day(1)),
        ],
      );
      expect(_names(index.search('oat')), [
        'Oatly Barista',
        'Overnight Oats',
        'Protein-Boats',
      ]);
    });

    test('im selben Rang zuerst Häufigkeit, dann Aktualität', () {
      final index = FoodHistoryIndex(
        favorites: [_fav(_meal('Apfel Zimt Porridge'), _day(20))],
        diary: [
          for (var i = 0; i < 3; i++) _log(_meal('Apfelmus'), _day(1 + i)),
          _log(_meal('Apfelschorle'), _day(15)),
          _log(_meal('Apfelstrudel'), _day(9)),
        ],
      );
      expect(_names(index.search('apfel')), [
        'Apfelmus',
        'Apfelschorle',
        'Apfelstrudel',
        'Apfel Zimt Porridge',
      ]);
    });

    test('die Grenze kürzt nach dem Sortieren', () {
      final index = FoodHistoryIndex(
        diary: [
          for (var i = 0; i < 50; i++)
            _log(_meal('Reis $i', kcal: 100 + i), _day(1 + i % 28)),
        ],
      );
      expect(index.search('reis'), hasLength(foodHistoryMaxHits));
      expect(index.search('reis', limit: 3), hasLength(3));
      expect(index.search('reis', limit: 0), isEmpty);
    });
  });

  group('Eintragbarkeit', () {
    test('Altzeilen mit 0 kcal fehlen, gemessene 0 kcal bleiben', () {
      final index = FoodHistoryIndex(
        favorites: [_fav(_meal('Wasser alt', kcal: 0), _day(1))],
        diary: [
          _log(
            _meal('Wasser still', kcal: 0, grams: 500, explicitZero: true),
            _day(2),
          ),
        ],
      );
      expect(_names(index.search('wasser')), ['Wasser still']);
    });
  });

  group('eigene Rezepte', () {
    test('ein Rezept wird über seinen Titel gefunden', () {
      final index = FoodHistoryIndex(
        recipes: [_recipe('user_chili', 'Chili sin Carne')],
      );
      final hit = index.search('chili').single;
      expect(hit.result.mealName, 'Chili sin Carne');
      expect(hit.uses, 0);
      expect(hit.lastUsed, isNull);
    });

    test('ein schon eingetragenes Rezept erscheint nur einmal', () {
      final recipe = _recipe('user_chili', 'Chili sin Carne');
      final logged = recipe.toMealResultForServings(1);
      final index = FoodHistoryIndex(
        diary: [_log(logged, _day(3))],
        recipes: [recipe],
      );
      final hits = index.search('chili');
      expect(hits, hasLength(1));
      expect(identical(hits.single.result, logged), isTrue);
      expect(hits.single.uses, 1);
    });

    test('zwei gleiche Rezepte erscheinen einmal', () {
      final index = FoodHistoryIndex(
        recipes: [
          _recipe('user_chili', 'Chili sin Carne'),
          _recipe('user_chili_copy', 'Chili sin Carne'),
        ],
      );
      expect(index.search('chili'), hasLength(1));
      expect(index.search('carne'), hasLength(1));
    });

    test('ohne Nährwerte nicht eintragbar -> kein Treffer', () {
      final index = FoodHistoryIndex(
        recipes: [_recipe('user_x', 'Linsencurry')],
        recipeResult: (_) => null,
      );
      expect(index.search('linsen'), isEmpty);
    });

    test('umgerechnet wird nur, was zum Titel passt, und nur einmal', () {
      final converted = <String>[];
      final index = FoodHistoryIndex(
        recipes: [
          for (var i = 0; i < 200; i++) _recipe('user_$i', 'Rezept $i'),
          _recipe('user_curry', 'Kichererbsen Curry'),
        ],
        recipeResult: (recipe) {
          converted.add(recipe.slug);
          return recipe.toMealResultForServings(1);
        },
      );
      expect(converted, isEmpty, reason: 'der Aufbau rechnet nichts um');
      expect(_names(index.search('curry')), ['Kichererbsen Curry']);
      expect(_names(index.search('kicher')), ['Kichererbsen Curry']);
      expect(converted, ['user_curry']);
    });
  });

  group('Aufwand bei 5.000 Einträgen', () {
    test('jede Zeichenkette wird beim Aufbau einmal gefaltet, eine Suche '
        'faltet nur die Anfrage', () {
      const distinct = 120;
      final diary = <LoggedMeal>[
        for (var i = 0; i < 5000; i++)
          _log(
            _meal('Gericht ${i % distinct}', kcal: 200 + i % distinct),
            DateTime(2026, 9, 1).add(Duration(minutes: i * 7)),
          ),
      ];
      final index = FoodHistoryIndex(diary: diary);

      // 120 names plus the empty brand.
      expect(index.foldCount, distinct + 1);
      expect(index.groupCount, distinct);

      final before = index.foldCount;
      final hits = index.search('gericht 7');
      expect(index.foldCount, before + 1);
      // Every name with a 7 matches: 7 and 70..79 by prefix, then 17, 27,
      // ..., 117 as substrings.
      expect(hits, hasLength(21));
      expect(
        hits.take(11).map((h) => h.result.mealName),
        everyElement(startsWith('Gericht 7')),
      );
      expect(hits[11].result.mealName, isNot(startsWith('Gericht 7')));
      // All eleven were logged 42 times; the newest leads.
      expect(hits.first.uses, 42);
      expect(hits.first.result.mealName, 'Gericht 79');
    });

    test('5.000 verschiedene Namen: linear aufgebaut, alle durchsuchbar', () {
      final index = FoodHistoryIndex(
        diary: [
          for (var i = 0; i < 5000; i++)
            _log(_meal('Speise $i', kcal: 100 + i % 900), _day(1 + i % 28)),
        ],
      );
      expect(index.foldCount, 5000 + 1);
      expect(index.groupCount, 5000);
      expect(_names(index.search('speise 4999')), ['Speise 4999']);
      expect(index.search('speise'), hasLength(foodHistoryMaxHits));
    });
  });
}
