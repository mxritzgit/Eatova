import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/favorite_meal.dart';
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
  group('pinnedFavoritesByRecency', () {
    test('nur gepinnte kommen durch, Auto-Recents fallen raus', () {
      final all = [
        _fav('Recent A', pinned: false, addedAt: DateTime(2026, 8, 20)),
        _fav('Pinned B', addedAt: DateTime(2026, 8, 10)),
        _fav('Recent C', pinned: false, addedAt: DateTime(2026, 8, 25)),
        _fav('Pinned D', addedAt: DateTime(2026, 8, 5)),
      ];

      expect(_names(pinnedFavoritesByRecency(all)), ['Pinned B', 'Pinned D']);
    });

    test('neueste zuerst', () {
      final all = [
        _fav('Alt', addedAt: DateTime(2026, 8, 1)),
        _fav('Neu', addedAt: DateTime(2026, 8, 20)),
        _fav('Mittel', addedAt: DateTime(2026, 8, 10)),
      ];

      expect(_names(pinnedFavoritesByRecency(all)), ['Neu', 'Mittel', 'Alt']);
    });

    test('bei gleichem addedAt bleibt die Eingabereihenfolge (stabil)', () {
      final t = DateTime(2026, 8, 15, 12);
      // More than a handful so an unstable sort would actually show.
      final all = List.generate(
        12,
        (i) => _fav('Gleich $i', addedAt: t),
      );

      expect(
        _names(pinnedFavoritesByRecency(all)),
        List.generate(12, (i) => 'Gleich $i'),
      );
    });

    test('Gleichstand-Gruppen bleiben intern geordnet, Gruppen nach Zeit', () {
      final alt = DateTime(2026, 8, 1);
      final neu = DateTime(2026, 8, 20);
      final all = [
        _fav('Alt 1', addedAt: alt),
        _fav('Neu 1', addedAt: neu),
        _fav('Alt 2', addedAt: alt),
        _fav('Neu 2', addedAt: neu),
        _fav('Alt 3', addedAt: alt),
        _fav('Neu 3', addedAt: neu),
      ];

      expect(
        _names(pinnedFavoritesByRecency(all)),
        ['Neu 1', 'Neu 2', 'Neu 3', 'Alt 1', 'Alt 2', 'Alt 3'],
      );
    });

    test('leere Eingabe und nur Auto-Recents ergeben leere Liste', () {
      expect(pinnedFavoritesByRecency(const []), isEmpty);
      expect(
        pinnedFavoritesByRecency([
          _fav('A', pinned: false),
          _fav('B', pinned: false),
        ]),
        isEmpty,
      );
    });

    test('veraendert die Eingabe nicht', () {
      final all = [
        _fav('Alt', addedAt: DateTime(2026, 8, 1)),
        _fav('Recent', pinned: false),
        _fav('Neu', addedAt: DateTime(2026, 8, 20)),
      ];
      final vorher = List.of(all);

      pinnedFavoritesByRecency(all);

      expect(all, orderedEquals(vorher));
    });
  });

  group('inlineFavorites', () {
    test('kInlineFavoritesCount ist 3', () {
      expect(kInlineFavoritesCount, 3);
    });

    test('maximal 3, die neuesten gepinnten in Recency-Reihenfolge', () {
      final all = [
        _fav('Tag 3', addedAt: DateTime(2026, 8, 3)),
        _fav('Tag 9', addedAt: DateTime(2026, 8, 9)),
        _fav('Recent', pinned: false, addedAt: DateTime(2026, 8, 30)),
        _fav('Tag 1', addedAt: DateTime(2026, 8, 1)),
        _fav('Tag 7', addedAt: DateTime(2026, 8, 7)),
        _fav('Tag 5', addedAt: DateTime(2026, 8, 5)),
      ];

      expect(_names(inlineFavorites(all)), ['Tag 9', 'Tag 7', 'Tag 5']);
    });

    test('bei weniger als 3 gepinnten kommen alle', () {
      final all = [
        _fav('B', addedAt: DateTime(2026, 8, 2)),
        _fav('Recent', pinned: false, addedAt: DateTime(2026, 8, 30)),
        _fav('A', addedAt: DateTime(2026, 8, 1)),
      ];

      expect(_names(inlineFavorites(all)), ['B', 'A']);
    });

    test('genau 3 gepinnte kommen alle', () {
      final all = [
        _fav('A', addedAt: DateTime(2026, 8, 1)),
        _fav('B', addedAt: DateTime(2026, 8, 2)),
        _fav('C', addedAt: DateTime(2026, 8, 3)),
      ];

      expect(_names(inlineFavorites(all)), ['C', 'B', 'A']);
    });

    test('ohne gepinnte leer', () {
      expect(inlineFavorites(const []), isEmpty);
      expect(inlineFavorites([_fav('Recent', pinned: false)]), isEmpty);
    });
  });

  group('filterFavoritesByQuery', () {
    final favoriten = [
      _fav('Haferdrink', brand: 'Alpro'),
      _fav('Skyr Natur', brand: 'Arla'),
      _fav('Proteinriegel'),
      _fav('Haferflocken', brand: 'Koelln'),
    ];

    test('leere Query gibt die Liste unveraendert zurueck', () {
      expect(filterFavoritesByQuery(favoriten, ''), same(favoriten));
      expect(_names(filterFavoritesByQuery(favoriten, '')), _names(favoriten));
    });

    test('Whitespace-Query gibt die Liste unveraendert zurueck', () {
      expect(filterFavoritesByQuery(favoriten, '   '), same(favoriten));
      expect(filterFavoritesByQuery(favoriten, ' \t\n '), same(favoriten));
    });

    test('Gross-/Kleinschreibung ist egal', () {
      expect(_names(filterFavoritesByQuery(favoriten, 'SKYR')), ['Skyr Natur']);
      expect(_names(filterFavoritesByQuery(favoriten, 'skyr')), ['Skyr Natur']);
      expect(_names(filterFavoritesByQuery(favoriten, 'sKyR')), ['Skyr Natur']);
    });

    test('Teilwort im Namen trifft', () {
      expect(
        _names(filterFavoritesByQuery(favoriten, 'hafer')),
        ['Haferdrink', 'Haferflocken'],
      );
      expect(_names(filterFavoritesByQuery(favoriten, 'riegel')),
          ['Proteinriegel']);
    });

    test('Brand trifft, auch als Teilwort', () {
      expect(_names(filterFavoritesByQuery(favoriten, 'alpro')), ['Haferdrink']);
      expect(_names(filterFavoritesByQuery(favoriten, 'arl')), ['Skyr Natur']);
    });

    test('Mehrwort-Query: alle Terme muessen matchen', () {
      // Both terms in the name.
      expect(
        _names(filterFavoritesByQuery(favoriten, 'skyr natur')),
        ['Skyr Natur'],
      );
      // Reversed order still matches — terms are independent.
      expect(
        _names(filterFavoritesByQuery(favoriten, 'natur skyr')),
        ['Skyr Natur'],
      );
      // One term matches, the other does not -> no hit.
      expect(filterFavoritesByQuery(favoriten, 'skyr alpro'), isEmpty);
    });

    test('Mehrwort-Query verteilt auf Name und Brand', () {
      expect(
        _names(filterFavoritesByQuery(favoriten, 'hafer alpro')),
        ['Haferdrink'],
      );
      expect(
        _names(filterFavoritesByQuery(favoriten, 'koelln flocken')),
        ['Haferflocken'],
      );
    });

    test('mehrfacher Whitespace zwischen Termen stoert nicht', () {
      expect(
        _names(filterFavoritesByQuery(favoriten, '  hafer   alpro  ')),
        ['Haferdrink'],
      );
    });

    test('kein Treffer ergibt leere Liste', () {
      expect(filterFavoritesByQuery(favoriten, 'pizza'), isEmpty);
    });

    test('brand == null crasht nicht und wird nicht als Text gematcht', () {
      final ohneBrand = [_fav('Proteinriegel')];

      expect(_names(filterFavoritesByQuery(ohneBrand, 'protein')),
          ['Proteinriegel']);
      // "null" must not leak into the haystack.
      expect(filterFavoritesByQuery(ohneBrand, 'null'), isEmpty);
    });

    test('leere Eingabeliste bleibt leer', () {
      expect(filterFavoritesByQuery(const [], 'hafer'), isEmpty);
      expect(filterFavoritesByQuery(const [], ''), isEmpty);
    });

    test('veraendert die Eingabe nicht', () {
      final eingabe = List.of(favoriten);
      final vorher = List.of(eingabe);

      final treffer = filterFavoritesByQuery(eingabe, 'hafer');

      expect(eingabe, orderedEquals(vorher));
      expect(treffer, isNot(same(eingabe)));
      expect(eingabe, hasLength(4));
    });

    test('Reihenfolge der Eingabe bleibt im Ergebnis erhalten', () {
      final sortiert = [
        _fav('Hafer C', addedAt: DateTime(2026, 8, 3)),
        _fav('Hafer A', addedAt: DateTime(2026, 8, 1)),
        _fav('Hafer B', addedAt: DateTime(2026, 8, 2)),
      ];

      expect(
        _names(filterFavoritesByQuery(sortiert, 'hafer')),
        ['Hafer C', 'Hafer A', 'Hafer B'],
      );
    });
  });
}
