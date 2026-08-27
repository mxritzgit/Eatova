// Shared fixtures for the sync/outbox/cache test cluster.
//
// The same meal, recipe and favorite fixtures were copied into
// local_cache_offline_state_test, local_cache_debounce_test,
// local_cache_durable_write_test and sync_outbox_test. They live here so a
// model change costs one edit, not four. Every field a test asserts on is a
// named parameter with the value the copies used, so call sites keep reading
// as their own fixture.
//
// NOT a _test.dart file on purpose: the runner must not pick it up.

import 'package:eatova/src/models/favorite_meal.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/meal_component.dart';
import 'package:eatova/src/services/local_cache.dart';

/// Analysis result of a logged meal. Defaults match the "Bowl / 300 kcal"
/// fixture the cache tests use; [portionNotes] carries the PII marker the
/// leakage assertions look for.
MealAnalysisResult testResult({
  String name = 'Bowl',
  int kcal = 300,
  int estimatedGrams = 350,
  double kcalPer100G = 85.7,
  String protein = '30 g',
  String carbs = '40 g',
  String fat = '10 g',
  String confidence = 'Hoch',
  String portionNotes = 'Testportion.',
  List<MealComponent> items = const <MealComponent>[],
  String sourceLabel = 'Foto-KI',
  String? barcode,
  String? brand,
}) =>
    MealAnalysisResult(
      mealName: name,
      caloriesKcal: kcal,
      estimatedGrams: estimatedGrams,
      kcalPer100G: kcalPer100G,
      protein: protein,
      carbs: carbs,
      fat: fat,
      confidence: confidence,
      portionNotes: portionNotes,
      items: items,
      sourceLabel: sourceLabel,
      barcode: barcode,
      brand: brand,
    );

/// A logged meal on 2026-08-05, 12:30, lunch slot — the fixture date the cache
/// and outbox tests assert against.
LoggedMeal testMeal(
  String id, {
  MealAnalysisResult? result,
  int kcal = 300,
  DateTime? loggedAt,
  MealSlot? forcedSlot = MealSlot.lunch,
  String? localDay = '2026-08-05',
}) =>
    LoggedMeal(
      id: id,
      result: result ?? testResult(kcal: kcal),
      loggedAt: loggedAt ?? DateTime(2026, 8, 5, 12, 30),
      forcedSlot: forcedSlot,
      localDay: localDay,
    );

/// A user-created recipe as `FitnessRecipe.fromRow` would build it.
FitnessRecipe testRecipe(
  String slug, {
  String title = 'Eigene Bowl',
  String ingredients = 'Reis\nHaehnchen',
  String preparation = 'Eigenes Rezept — keine Zubereitung hinterlegt.',
  String professionalHint =
      'Selbst angelegt. Werte beruhen auf deinen Angaben.',
  int caloriesKcal = 600,
  int proteinG = 50,
  int carbsG = 60,
  int fatG = 15,
  int estimatedGrams = 400,
  List<String> categories = const <String>['Eigene'],
}) =>
    FitnessRecipe(
      slug: slug,
      title: title,
      description: 'Eigenes Rezept',
      portion: '1 Teller',
      ingredients: ingredients,
      preparation: preparation,
      professionalHint: professionalHint,
      imageAsset: '',
      caloriesKcal: caloriesKcal,
      proteinG: proteinG,
      carbsG: carbsG,
      fatG: fatG,
      estimatedGrams: estimatedGrams,
      categories: categories,
      userCreated: true,
    );

/// A favorite meal; [pinned] false is the auto-recents case.
FavoriteMeal testFavorite(
  String id, {
  MealAnalysisResult? result,
  DateTime? addedAt,
  bool pinned = false,
}) =>
    FavoriteMeal(
      id: id,
      result: result ?? testResult(),
      addedAt: addedAt ?? DateTime(2026, 8, 5, 13),
      pinned: pinned,
    );

/// [KeyValueStore] counting `setString` per slot — the proxy for "encrypt the
/// whole blob once" in the debounce tests.
class CountingKeyValueStore implements KeyValueStore {
  final Map<String, String> _data = <String, String>{};
  final Map<String, int> _writes = <String, int>{};

  int writesFuer(String key) => _writes[key] ?? 0;
  Map<String, String> get snapshot => Map.unmodifiable(_data);

  @override
  Future<String?> getString(String key) async => _data[key];

  @override
  Future<void> setString(String key, String value) async {
    _writes[key] = (_writes[key] ?? 0) + 1;
    _data[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    _data.remove(key);
  }
}
