import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/favorite_meal.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/favorites_view.dart';

// Favorites sheet (feature 2026-08-27): the add-meal sheet shows the three
// most recently used pinned favorites inline, the sheet shows all of them
// with a local name/brand search. The pure helpers in favorites_view.dart do
// the ordering, cutting and filtering; these tests pin their contract so the
// widgets can rely on it without re-checking.

MealAnalysisResult _result(String name, {String? brand}) => MealAnalysisResult(
      mealName: name,
      caloriesKcal: 100,
      estimatedGrams: 100,
      kcalPer100G: 100,
      protein: '1 g',
      carbs: '1 g',
      fat: '1 g',
      confidence: 'Datenbank',
      portionNotes: '',
      brand: brand,
    );

FavoriteMeal _fav(
  String name, {
  String? brand,
  bool pinned = true,
  DateTime? addedAt,
}) =>
    FavoriteMeal(
      id: 'name:${name.toLowerCase()}',
      result: _result(name, brand: brand),
      addedAt: addedAt ?? DateTime(2026, 8, 1),
      pinned: pinned,
    );

List<String> _names(List<FavoriteMeal> list) =>
    list.map((f) => f.result.mealName).toList();

void main() {
  test('pinnedFavoritesByRecency: nur gepinnte, neueste zuerst, Gleichstand '
      'stabil in Eingabereihenfolge, Eingabe unveraendert', () {
    final alt = DateTime(2026, 8, 1);
    final neu = DateTime(2026, 8, 20);
    final all = [
      _fav('Recent A', pinned: false, addedAt: DateTime(2026, 8, 25)),
      // Tie groups of more than a handful, so an unstable sort would show.
      for (var i = 1; i <= 6; i++) ...[
        _fav('Alt $i', addedAt: alt),
        _fav('Neu $i', addedAt: neu),
      ],
      _fav('Mittel', addedAt: DateTime(2026, 8, 10)),
    ];
    final vorher = List.of(all);

    expect(_names(pinnedFavoritesByRecency(all)), [
      for (var i = 1; i <= 6; i++) 'Neu $i',
      'Mittel',
      for (var i = 1; i <= 6; i++) 'Alt $i',
    ]);
    expect(all, orderedEquals(vorher));
    expect(pinnedFavoritesByRecency([_fav('B', pinned: false)]), isEmpty);
  });

  group('filterFavoritesByQuery', () {
    final favoriten = [
      _fav('Haferdrink', brand: 'Alpro'),
      _fav('Skyr Natur', brand: 'Arla'),
      _fav('Proteinriegel'),
      _fav('Haferflocken', brand: 'Koelln'),
    ];

    test('leere oder reine Whitespace-Query gibt die Liste unveraendert zurueck',
        () {
      for (final query in const ['', '   ', ' \t\n ']) {
        expect(filterFavoritesByQuery(favoriten, query), same(favoriten),
            reason: '"$query"');
      }
    });

    test('Teilwort in Name oder Marke, Gross-/Kleinschreibung egal; jeder Term '
        'muss irgendwo treffen, in beliebiger Reihenfolge', () {
      for (final (query, erwartet) in <(String, List<String>)>[
        ('sKyR', ['Skyr Natur']),
        ('hafer', ['Haferdrink', 'Haferflocken']),
        ('arl', ['Skyr Natur']), // brand, as a part of a word
        ('natur skyr', ['Skyr Natur']),
        ('  hafer   alpro  ', ['Haferdrink']), // name + brand
        ('koelln flocken', ['Haferflocken']),
        ('skyr alpro', []), // one term misses
        ('pizza', []),
        ('null', []), // a missing brand is not the text "null"
      ]) {
        expect(_names(filterFavoritesByQuery(favoriten, query)), erwartet,
            reason: '"$query"');
      }
    });

    test('die Eingabe bleibt unveraendert und ihre Reihenfolge erhalten', () {
      final sortiert = [
        _fav('Hafer C', addedAt: DateTime(2026, 8, 3)),
        _fav('Hafer A', addedAt: DateTime(2026, 8, 1)),
        _fav('Riegel'),
        _fav('Hafer B', addedAt: DateTime(2026, 8, 2)),
      ];
      final vorher = List.of(sortiert);

      expect(
        _names(filterFavoritesByQuery(sortiert, 'hafer')),
        ['Hafer C', 'Hafer A', 'Hafer B'],
      );
      expect(sortiert, orderedEquals(vorher));
    });
  });

  // Sorting of the favorites sheet (lively list, 2026-10-03).
  group('favoriteUseCounts', () {
    final now = DateTime(2026, 10, 3, 19);
    LoggedMeal log(String name, DateTime at) => LoggedMeal(
      id: '$name-${at.toIso8601String()}',
      result: _result(name),
      loggedAt: at,
    );

    test('counts logs of the last 35 days by favorite id', () {
      final counts = favoriteUseCounts([
        log('Skyr', DateTime(2026, 10, 3, 8)),
        log('Skyr', DateTime(2026, 9, 20, 8)),
        log('skyr ', DateTime(2026, 8, 29, 8)), // the window's first day
        log('Skyr', DateTime(2026, 8, 28, 23)), // one day too old
        log('Hafer', DateTime(2026, 10, 1, 8)),
      ], now: now);
      expect(counts, {'name:skyr': 3, 'name:hafer': 1});
    });

    test('a barcode product counts under its barcode', () {
      final bar = _result('Riegel');
      const scanned = MealAnalysisResult(
        mealName: 'Riegel · Marke',
        caloriesKcal: 200,
        estimatedGrams: 60,
        kcalPer100G: 333,
        protein: '-',
        carbs: '-',
        fat: '-',
        confidence: 'database',
        portionNotes: '',
        barcode: '4000540000108',
      );
      final counts = favoriteUseCounts([
        LoggedMeal(id: 'a', result: scanned, loggedAt: now),
        LoggedMeal(id: 'b', result: bar, loggedAt: now),
      ], now: now);
      expect(counts['barcode:4000540000108'], 1);
      expect(counts['name:riegel'], 1);
    });
  });

  group('sortFavorites', () {
    final byRecency = [
      _fav('Zucchini', addedAt: DateTime(2026, 10, 3)),
      _fav('Äpfel', addedAt: DateTime(2026, 10, 2)),
      _fav('apfelmus', addedAt: DateTime(2026, 10, 1)),
      _fav('Banane', addedAt: DateTime(2026, 9, 30)),
    ];
    String nameOf(FavoriteMeal f) => f.result.mealName;

    test('recent keeps the recency order', () {
      expect(
        _names(sortFavorites(byRecency, FavoriteSort.recent, nameOf: nameOf)),
        ['Zucchini', 'Äpfel', 'apfelmus', 'Banane'],
      );
    });

    test('frequent orders by count, ties keep recency', () {
      final sorted = sortFavorites(
        byRecency,
        FavoriteSort.frequent,
        useCounts: {'name:banane': 4, 'name:apfelmus': 4, 'name:zucchini': 1},
        nameOf: nameOf,
      );
      expect(_names(sorted), ['apfelmus', 'Banane', 'Zucchini', 'Äpfel']);
    });

    test('A–Z ignores case and umlauts', () {
      expect(
        _names(
          sortFavorites(byRecency, FavoriteSort.alphabetical, nameOf: nameOf),
        ),
        ['Äpfel', 'apfelmus', 'Banane', 'Zucchini'],
      );
    });
  });
}
