import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/recipe_import_result.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> conflictJson() => {
  'id': 'kaiserschmarrn',
  'title': 'Kaiserschmarrn',
  'description': 'Original caption',
  'portion': '2 portions',
  'ingredients': '100 g flour',
  'preparation': 'Fry slowly.',
  'servings': 2,
  'ingredients_basis': 'per_recipe',
  'calories_kcal': 650,
  'protein_g': null,
  'carbs_g': null,
  'fat_g': 20,
  'nutrition_estimated': false,
  'nutrition_basis': 'unspecified',
  'nutrition_conflicts': ['protein_g'],
};
FitnessRecipe recipeFor(RecipeImportCandidate candidate) =>
    candidate.toRecipe(slug: candidate.stableSlug(), sourceLabel: 'Source');

void main() {
  test(
    'source conflict and absent values remain distinct across persistence',
    () {
      final candidate = RecipeImportCandidate.fromJson(conflictJson());
      final recipe = FitnessRecipe.fromRow(recipeFor(candidate).toRow());
      expect(candidate.nutritionConflicts, ['protein_g']);
      expect(recipe.nutritionConflicts, ['protein_g']);
      expect(recipe.displayNutrition.caloriesKcal, 650);
      expect(recipe.displayNutrition.fatG, 20);
      expect(recipe.displayNutrition.proteinG, isNull);
      expect(recipe.displayNutrition.carbsG, isNull);
      expect(
        recipe.displayCategories.any(
          (c) => c.startsWith(recipeNutritionConflictPrefix),
        ),
        isFalse,
      );
      expect(
        recipe.nutritionReviewHint(enL10n),
        contains('Conflicting caption values: Protein.'),
      );
      expect(
        recipe.nutritionReviewHint(enL10n),
        contains('Missing values: Carbs.'),
      );
      expect(recipe.nutritionReviewHint(deL10n), contains('Kohlenhydrate'));
      expect(recipe.canLogServings(1), isFalse);
      expect(
        () => recipe.withConfirmedNutritionBasis(2),
        throwsFormatException,
      );
    },
  );

  test('legacy server and saved record still treat unknowns as missing', () {
    final json = conflictJson()..remove('nutrition_conflicts');
    final candidate = RecipeImportCandidate.fromJson(json);
    expect(candidate.nutritionConflicts, isEmpty);
    final recipe = FitnessRecipe.fromRow(recipeFor(candidate).toRow());
    expect(recipe.displayNutrition.proteinG, isNull);
    expect(
      recipe.nutritionReviewHint(enL10n),
      enL10n.recipeNutritionIncompleteBasisHint,
    );
    expect(recipe.canLogServings(1), isFalse);
  });

  test(
    'conflict marker cannot be overridden by a known-field marker or missing pending marker',
    () {
      final recipe = recipeFor(RecipeImportCandidate.fromJson(conflictJson()))
          .copyWith(
            categories: [
              'Eigene',
              '${recipeNutritionConflictPrefix}protein_g',
              '${recipeNutritionKnownPrefix}protein_g',
            ],
            proteinG: 47,
          );
      expect(recipe.hasPendingNutrition, isTrue);
      expect(recipe.displayNutrition.proteinG, isNull);
      expect(recipe.canLogServings(1), isFalse);
    },
  );

  test(
    'title edits retain conflict evidence while changed ingredients discard stale nutrition',
    () {
      final candidate = RecipeImportCandidate.fromJson(conflictJson());
      expect(candidate.copyWith(title: 'Mine').nutritionConflicts, [
        'protein_g',
      ]);
      final changed = candidate.copyWith(
        ingredients: '200 g flour',
        clearNutrition: true,
      );
      expect(changed.nutritionConflicts, isEmpty);
      expect(changed.caloriesKcal, isNull);
    },
  );

  test(
    'only a complete reviewed draft can replace nutrition without changing source identity',
    () {
      final candidate = RecipeImportCandidate.fromJson({
        ...conflictJson(),
        'estimated_g': 300,
      });
      final original = recipeFor(candidate);
      expect(
        () => candidate.withReviewedNutrition(original),
        throwsFormatException,
      );
      final reviewed = original.copyWith(
        categories: original.categories
            .where((c) => !isRecipeNutritionMetadata(c))
            .toList(),
        caloriesKcal: 325,
        proteinG: 24,
        carbsG: 34,
        fatG: 10,
        ingredients: 'Unrelated replacement',
        title: 'Other name',
        estimatedGrams: 999,
      );
      final updated = candidate.withReviewedNutrition(reviewed);
      expect(updated.title, candidate.title);
      expect(updated.ingredients, candidate.ingredients);
      expect(updated.preparation, candidate.preparation);
      expect(updated.servings, 2);
      expect(updated.estimatedGrams, isNull);
      final knownBasis = RecipeImportCandidate.fromJson({
        ...conflictJson(),
        'estimated_g': 300,
        'nutrition_basis': 'per_serving',
      });
      expect(knownBasis.withReviewedNutrition(reviewed).estimatedGrams, 300);
      expect(updated.ingredientsBasis, RecipeIngredientsBasis.perRecipe);
      expect(updated.stableSlug(), candidate.stableSlug());
      expect(updated.nutritionConflicts, isEmpty);
      expect(updated.nutritionBasisUnclear, isFalse);
      expect(recipeFor(updated).toMealResultForServings(2).caloriesKcal, 650);
    },
  );

  test('known zero is preserved alongside missing and conflicting fields', () {
    final candidate = RecipeImportCandidate.fromJson({
      ...conflictJson(),
      'fat_g': 0,
    });
    expect(recipeFor(candidate).displayNutrition.fatG, 0);
    expect(recipeFor(candidate).displayNutrition.proteinG, isNull);
  });

  for (final conflicts in [
    true,
    'protein_g',
    ['sodium_g'],
    ['protein_g', 'protein_g'],
    [null],
    ['fat_g'],
  ]) {
    test(
      'malformed or contradictory conflict metadata is rejected: $conflicts',
      () {
        expect(
          () => RecipeImportCandidate.fromJson({
            ...conflictJson(),
            'nutrition_conflicts': conflicts,
          }),
          throwsFormatException,
        );
      },
    );
  }
}
