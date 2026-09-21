import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/planned_meal.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/recipe_import_result.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> candidateJson({String id = 'pasta'}) => {
  'id': id,
  'title': 'Tomatenpasta',
  'description': 'Schnell gekocht',
  'portion': '2 Portionen',
  'ingredients': '200 g Pasta\n400 g Tomaten',
  'preparation': 'Pasta kochen. Tomaten erhitzen und unterheben.',
  'variant_label': '',
  'nutrition_estimated': false,
  'calories_kcal': null,
  'protein_g': null,
  'carbs_g': null,
  'fat_g': null,
  'estimated_g': null,
  'servings': 2,
};

Map<String, dynamic> responseJson() => {
  'status': 'ready',
  'source': {'url': 'https://www.tiktok.com/@cook/video/12345'},
  'candidates': [candidateJson()],
  'warnings': ['nutrition_missing'],
};

void main() {
  test(
    'fractional source nutrition maps to the existing whole-unit recipe model',
    () {
      final candidate = RecipeImportCandidate.fromJson({
        ...candidateJson(),
        'calories_kcal': 450.5,
        'protein_g': 20.5,
        'carbs_g': 40.2,
        'fat_g': 9.8,
      });
      expect(candidate.hasNutrition, isTrue);
      expect(candidate.caloriesKcal, 451);
      expect(candidate.proteinG, 21);
      expect(candidate.carbsG, 40);
      expect(candidate.fatG, 10);
    },
  );
  test(
    'missing imported nutrition stays missing through persistence and meal planning',
    () {
      final result = RecipeImportResult.fromJson(responseJson());
      final candidate = result.candidates.single;
      expect(candidate.hasNutrition, isFalse);
      final recipe = candidate.toRecipe(
        slug: candidate.stableSlug(result.sourceUrl),
        sourceUrl: result.sourceUrl,
        sourceLabel: 'Quelle',
      );
      final restored = FitnessRecipe.fromRow(recipe.toRow());
      expect(restored.hasPendingNutrition, isTrue);
      expect(restored.description, contains(result.sourceUrl));
      expect(restored.ingredients, candidate.ingredients);
      expect(restored.structuredIngredients, isEmpty);
      for (final servings in [.5, 1.0, 2.0]) {
        expect(restored.canLogServings(servings), isFalse);
        expect(
          () => restored.toMealResultForServings(servings),
          throwsFormatException,
        );
      }
      final planned = PlannedMeal.create(
        recipe: restored,
        day: DateTime(2026, 9, 21),
        slot: MealSlot.lunch,
      );
      expect(
        PlannedMeal.fromJson(planned.toJson()).recipe.hasPendingNutrition,
        isTrue,
      );
      expect(planned.recipe.canLogServings(1), isFalse);
    },
  );

  test(
    'repeating a share yields the same identity but vegan variant stays separate',
    () {
      final original = RecipeImportCandidate.fromJson(candidateJson());
      final variant = RecipeImportCandidate.fromJson({
        ...candidateJson(id: 'vegan'),
        'variant_label': 'Vegan',
        'ingredients': '200 g vegane Pasta\n400 g Tomaten',
      });
      expect(
        original.stableSlug(),
        RecipeImportCandidate.fromJson(candidateJson()).stableSlug(),
      );
      expect(original.stableSlug(), isNot(variant.stableSlug()));
      expect(original.stableSlug().length, lessThanOrEqualTo(200));
    },
  );

  test('explicit zero differs from absent source nutrition', () {
    final candidate = RecipeImportCandidate.fromJson({
      ...candidateJson(),
      'calories_kcal': 0,
      'protein_g': 0,
      'carbs_g': 0,
      'fat_g': 0,
      'estimated_g': 250,
    });
    expect(candidate.hasNutrition, isTrue);
    expect(
      candidate
          .toRecipe(slug: candidate.stableSlug(), sourceLabel: 'Source')
          .toMealResult()
          .explicitZeroKcal,
      isTrue,
    );
    expect(
      candidate
          .toRecipe(slug: candidate.stableSlug(), sourceLabel: 'Source')
          .hasPendingNutrition,
      isFalse,
    );
    expect(
      candidate
          .copyWith(ingredients: 'Andere Zutaten', clearNutrition: true)
          .hasNutrition,
      isFalse,
    );
  });

  test('rejects malformed responses instead of partially importing', () {
    for (final bad in <Map<String, dynamic>>[
      {...responseJson(), 'status': 'ready', 'candidates': []},
      {...responseJson(), 'status': 'no_recipe'},
      {
        ...responseJson(),
        'candidates': [candidateJson(), candidateJson()],
      },
      {
        ...responseJson(),
        'source': {'url': 'http://127.0.0.1/admin'},
      },
      {
        ...responseJson(),
        'source': {'url': 'https://tiktok.com@evil.test/video'},
      },
      {
        ...responseJson(),
        'source': {'url': 'https://www.tiktok.com:444/video'},
      },
      {
        ...responseJson(),
        'candidates': [
          {...candidateJson(), 'calories_kcal': -1},
        ],
      },
      {
        ...responseJson(),
        'candidates': [
          {...candidateJson(), 'ingredients': ''},
        ],
      },
      {
        ...responseJson(),
        'warnings': ['arbitrary_provider_error'],
      },
    ]) {
      expect(() => RecipeImportResult.fromJson(bad), throwsFormatException);
    }
  });

  test('valid empty results require no invented recipe', () {
    for (final status in ['needs_text', 'no_recipe']) {
      final result = RecipeImportResult.fromJson({
        'status': status,
        'source': {'url': null},
        'candidates': [],
      });
      expect(result.candidates, isEmpty);
    }
  });

  test('persistent source attribution respects recipe storage limit', () {
    final candidate = RecipeImportCandidate.fromJson({
      ...candidateJson(),
      'description': 'x' * 2000,
    });
    final source = 'https://www.tiktok.com/${'x' * 2020}';
    final recipe = candidate.toRecipe(
      slug: candidate.stableSlug(source),
      sourceUrl: source,
      sourceLabel: 'Quelle',
    );
    expect(recipe.description.runes.length, lessThanOrEqualTo(4000));
    expect(recipe.description, endsWith(source));
  });
}
