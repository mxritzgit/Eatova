// Favorites keep the product photo they were saved with (owner request
// 2026-10-03): a protein bar hearted from the search shows its photo in the
// favorites, also after a restart and in what syncs to the account.

import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:flutter_test/flutter_test.dart';

import 'outbox_test_helpers.dart';

const _photo =
    'https://images.openfoodfacts.org/images/products/400/054/000/0108/front_de.273.200.jpg';
const _id = 'barcode:4000540000108';

MealAnalysisResult _bar({String? image = _photo, int grams = 60}) =>
    MealAnalysisResult(
      mealName: 'Proteinriegel Cookie · Bodylab',
      caloriesKcal: 212 * grams ~/ 60,
      estimatedGrams: grams,
      kcalPer100G: 353,
      protein: '20 g',
      carbs: '18 g',
      fat: '7 g',
      confidence: 'database',
      portionNotes: '',
      sourceLabel: 'open_food_facts',
      barcode: '4000540000108',
      brand: 'Bodylab',
      imageUrl: image,
    );

String? _storedPhoto(FakeServer server) =>
    (server.favoriteRows[_id]?['payload'] as Map?)?['imageUrl'] as String?;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a hearted search hit keeps its photo in store, sync and restart',
    () async {
      final kv = InMemoryKeyValueStore();
      final a = setup(kv: kv);
      await bootUntilIdle(a.store);

      await a.store.toggleFavorite(_bar());
      await settle();

      final favorite = a.store.favorites.single;
      expect(favorite.pinned, isTrue);
      expect(favorite.result.imageUrl, _photo);
      expect(_storedPhoto(a.server), _photo);

      final b = setup(kv: kv)..server.offline = true;
      await bootUntilIdle(b.store);
      expect(b.store.favorites.single.result.imageUrl, _photo);
    },
  );

  test('unpin and re-pin from a photo-less result keep the photo', () async {
    final a = setup();
    await bootUntilIdle(a.store);

    await a.store.toggleFavorite(_bar());
    await a.store.toggleFavorite(_bar(image: null));
    expect(a.store.favorites.single.pinned, isFalse);
    expect(a.store.favorites.single.result.imageUrl, _photo);

    await a.store.toggleFavorite(_bar(image: null));
    await settle();
    expect(a.store.favorites.single.pinned, isTrue);
    expect(a.store.favorites.single.result.imageUrl, _photo);
    expect(_storedPhoto(a.server), _photo);
  });

  test(
    'an old favorite without photo takes the photo of a search hit',
    () async {
      final a = setup();
      await bootUntilIdle(a.store);
      await a.store.toggleFavorite(_bar(image: null));
      expect(a.store.favorites.single.result.imageUrl, isNull);
      final saved = a.store.favorites.single.result;

      // Unpinned from the search: the stored portion stays, the photo arrives.
      await a.store.toggleFavorite(_bar(grams: 120));
      final favorite = a.store.favorites.single;
      expect(favorite.result.imageUrl, _photo);
      expect(favorite.result.estimatedGrams, saved.estimatedGrams);
    },
  );

  test('logging a photo-less result keeps the favorite photo', () async {
    final a = setup();
    await bootUntilIdle(a.store);
    await a.store.toggleFavorite(_bar());

    await a.store.addResultToDailyTotal(_bar(image: null, grams: 90));
    await settle();

    final favorite = a.store.favorites.single;
    expect(favorite.pinned, isTrue);
    expect(favorite.result.estimatedGrams, 90, reason: 'the log refreshes it');
    expect(favorite.result.imageUrl, _photo);
    expect(_storedPhoto(a.server), _photo);
    // The diary row keeps exactly what was logged.
    expect(a.store.loggedMeals.single.result.imageUrl, isNull);
  });

  test(
    'a photo-less favorite stays the same instance when nothing changes',
    () async {
      final a = setup();
      await bootUntilIdle(a.store);
      await a.store.toggleFavorite(_bar(image: null));
      final before = a.store.favorites.single.result;
      await a.store.toggleFavorite(_bar(image: null));
      expect(identical(a.store.favorites.single.result, before), isTrue);
    },
  );

  test('a photo never moves to another food of the same name', () async {
    final a = setup();
    await bootUntilIdle(a.store);
    // A product without barcode is keyed by its name, like an AI scan.
    const product = MealAnalysisResult(
      mealName: 'Banane',
      caloriesKcal: 105,
      estimatedGrams: 118,
      kcalPer100G: 89,
      protein: '1 g',
      carbs: '27 g',
      fat: '0 g',
      confidence: 'database',
      portionNotes: '',
      sourceLabel: 'open_food_facts',
      imageUrl: _photo,
    );
    await a.store.toggleFavorite(product);
    await a.store.addResultToDailyTotal(
      const MealAnalysisResult(
        mealName: 'Banane',
        caloriesKcal: 120,
        estimatedGrams: 130,
        kcalPer100G: 92,
        protein: '1 g',
        carbs: '30 g',
        fat: '0 g',
        confidence: 'medium',
        portionNotes: '',
      ),
    );
    final favorite = a.store.favorites.single;
    expect(favorite.result.caloriesKcal, 120);
    expect(favorite.result.imageUrl, isNull);
  });
}
