// FOOD-6 in the store: favorites written before the normalization keep their
// 12-digit `favorite_key` (no migration), and the 13-digit form every scan
// now delivers must still find, bump and toggle them. E5: an own product is
// remembered (pinned) with the same single favorite upsert as any log.
// 2026-10-22: a log only refreshes the entry of the same food; a pinned
// favorite keeps what the user saved.

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/meals_sync.dart' show mealResultToJson;

import '../outbox/outbox_test_helpers.dart';

const _upcA = '036000291452';
const _gtin13 = '0036000291452';
const _legacyKey = 'barcode:$_upcA';

final DateTime _now = DateTime(2026, 10, 18, 12);

MealAnalysisResult _milk(String barcode, {int grams = 250}) =>
    MealAnalysisResult(
      mealName: 'Frische Milch',
      caloriesKcal: 64 * grams ~/ 100,
      estimatedGrams: grams,
      kcalPer100G: 64,
      protein: '8,5 g',
      carbs: '12 g',
      fat: '9 g',
      confidence: 'database',
      portionNotes: '',
      sourceLabel: 'OpenFoodFacts',
      barcode: barcode,
    );

/// A favorite row as an Android build stored it before FOOD-6.
void _seedLegacyFavorite(FakeServer server) {
  server.favoriteRows[_legacyKey] = <String, dynamic>{
    'favorite_key': _legacyKey,
    'added_at': DateTime(2026, 9, 1).toUtc().toIso8601String(),
    'payload': mealResultToJson(_milk(_upcA)),
    'pinned': true,
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'der 13-stellige Scan erkennt den alten 12-stelligen Favoriten',
    () async {
      await withClock(Clock.fixed(_now), () async {
        final env = setup();
        _seedLegacyFavorite(env.server);
        await bootUntilIdle(env.store);
        expect(env.store.favorites.single.id, _legacyKey);

        expect(env.store.isFavorite(_milk(_gtin13)), isTrue);
        expect(env.store.isFavorite(_milk(_upcA)), isTrue);
      });
    },
  );

  test('Eintragen in der neuen Form frischt den alten Schluessel auf, ohne '
      'zweite Zeile und ohne Migration', () async {
    await withClock(Clock.fixed(_now), () async {
      final env = setup();
      _seedLegacyFavorite(env.server);
      await bootUntilIdle(env.store);

      await env.store.addResultToDailyTotal(_milk(_gtin13, grams: 300));
      await settle();

      final favorite = env.store.favorites.single;
      expect(favorite.id, _legacyKey);
      expect(favorite.pinned, isTrue, reason: 'der Stern bleibt');
      expect(favorite.result.estimatedGrams, 250, reason: 'gespeicherte Portion');
      expect(favorite.addedAt, _now, reason: 'zuletzt benutzt');
      expect(env.server.favoriteRows.keys, <String>[_legacyKey]);
      expect(env.server.operations('favoriteUpsert'), hasLength(1));
      expect(env.server.operations('favoriteDelete'), isEmpty);
    });
  });

  test('das Herz am 13-stelligen Treffer loest den alten Favoriten', () async {
    await withClock(Clock.fixed(_now), () async {
      final env = setup();
      _seedLegacyFavorite(env.server);
      await bootUntilIdle(env.store);

      await env.store.toggleFavorite(_milk(_gtin13));
      await settle();

      final favorite = env.store.favorites.single;
      expect(favorite.id, _legacyKey);
      expect(favorite.pinned, isFalse);
      expect(env.store.isFavorite(_milk(_gtin13)), isFalse);
      expect(env.server.favoriteRows[_legacyKey]?['pinned'], isFalse);
    });
  });

  test('ein gleichnamiges anderes Essen ueberschreibt keinen Favoriten', () {
    MealAnalysisResult coffee(int kcal, {int grams = 250}) =>
        MealAnalysisResult(
          mealName: 'Kaffee',
          caloriesKcal: kcal,
          estimatedGrams: grams,
          kcalPer100G: kcal * 100 / grams,
          protein: '1 g',
          carbs: '1 g',
          fat: '1 g',
          confidence: 'high',
          portionNotes: '',
          sourceLabel: 'photoAi',
        );
    MealAnalysisResult quick(int kcal) =>
        MealAnalysisResult.quickEntry(name: '', caloriesKcal: kcal);
    Map<String, int> kcalByKey(HomeStore store) => {
      for (final f in store.favorites) f.id: f.result.caloriesKcal,
    };

    return withClock(Clock.fixed(_now), () async {
      final env = setup();
      await bootUntilIdle(env.store);
      final store = env.store;
      await store.addResultToDailyTotal(coffee(45));
      await store.toggleFavorite(coffee(45));

      final later = _now.add(const Duration(hours: 1));
      await withClock(Clock.fixed(later), () async {
        for (final result in [
          coffee(2), // a black coffee: another food of the same name
          coffee(3, grams: 300), // the same black coffee again
          coffee(54, grams: 300), // the pinned latte at another portion
          quick(300), // two unnamed quick entries and a repeat
          quick(500),
          quick(300),
        ]) {
          await store.addResultToDailyTotal(result);
        }
      });
      await settle();

      final pinned = store.favorites.singleWhere((f) => f.pinned);
      expect(pinned.id, 'name:kaffee');
      expect(pinned.result.caloriesKcal, 45);
      expect(pinned.result.estimatedGrams, 250);
      expect(pinned.addedAt, later);
      expect(kcalByKey(store), {
        'name:kaffee': 45,
        'name:kaffee#2': 3,
        'name:schnell-eintrag': 300,
        'name:schnell-eintrag#2': 500,
      });
      expect(
        env.server.favoriteRows.keys.toSet(),
        kcalByKey(store).keys.toSet(),
      );
    });
  });

  group('eigenes Produkt (E5)', () {
    MealAnalysisResult own({int kcal100 = 70}) =>
        MealAnalysisResult.manualEntry(
          name: 'Hofmilch',
          kcalPer100G: kcal100,
          grams: 200,
          barcode: _gtin13,
        );

    test('wird beim Eintragen gemerkt: ein Upsert, angeheftet', () async {
      await withClock(Clock.fixed(_now), () async {
        final env = setup();
        await bootUntilIdle(env.store);

        await env.store.addResultToDailyTotal(own());
        await settle();

        final favorite = env.store.favorites.single;
        expect(favorite.id, 'barcode:$_gtin13');
        expect(favorite.pinned, isTrue);
        expect(favorite.result.isOwnProduct, isTrue);
        expect(env.server.operations('favoriteUpsert'), hasLength(1));
        expect(env.server.operations('mealInsert'), hasLength(1));
        expect(env.server.favoriteRows['barcode:$_gtin13']?['pinned'], isTrue);
      });
    });

    test('geänderte Werte überschreiben dasselbe Produkt', () async {
      await withClock(Clock.fixed(_now), () async {
        final env = setup();
        await bootUntilIdle(env.store);

        await env.store.addResultToDailyTotal(own());
        await env.store.addResultToDailyTotal(own(kcal100: 80));
        await settle();

        final favorite = env.store.favorites.single;
        expect(favorite.pinned, isTrue);
        expect(favorite.result.kcalPer100G, 80);
      });
    });

    test('ein vom Nutzer gelöster Stern bleibt gelöst', () async {
      await withClock(Clock.fixed(_now), () async {
        final env = setup();
        await bootUntilIdle(env.store);

        await env.store.addResultToDailyTotal(own());
        await env.store.toggleFavorite(own());
        await env.store.addResultToDailyTotal(own());
        await settle();

        expect(env.store.favorites.single.pinned, isFalse);
      });
    });

    test(
      'ein Eintrag ohne Barcode bleibt ein gewöhnlicher Zuletzt-Eintrag',
      () async {
        await withClock(Clock.fixed(_now), () async {
          final env = setup();
          await bootUntilIdle(env.store);

          await env.store.addResultToDailyTotal(
            MealAnalysisResult.manualEntry(
              name: 'Hofmilch',
              kcalPer100G: 70,
              grams: 200,
            ),
          );
          await settle();

          expect(env.store.favorites.single.pinned, isFalse);
        });
      },
    );
  });
}
