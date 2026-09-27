import 'dart:convert';
import 'dart:io';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/export_document.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/services/recipe_import_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final fixtures =
      (jsonDecode(
                File(
                  'test/fixtures/recipe_import/nutrition_conflict_contract.json',
                ).readAsStringSync(),
              )
              as List)
          .cast<Map<String, dynamic>>();

  for (final fixture in fixtures) {
    test('server response survives recipe roundtrip: ${fixture['name']}', () {
      final imported = parseRecipeImportResponse(
        200,
        jsonEncode(fixture['expected']),
      ).candidates.single;
      final recipe = imported.toRecipe(
        slug: imported.stableSlug(),
        sourceLabel: 'Source',
      );
      final restored = FitnessRecipe.fromRow(
        (jsonDecode(jsonEncode(recipe.toRow())) as Map).cast<String, dynamic>(),
      );
      final conflicted =
          fixture['name'] != 'unambiguous corrected source label';
      expect(restored.displayNutrition.caloriesKcal, 650);
      expect(restored.displayNutrition.fatG, 20);
      expect(restored.displayNutrition.proteinG, conflicted ? null : 47);
      expect(restored.displayNutrition.carbsG, conflicted ? null : 68);
      expect(restored.nutritionConflicts, conflicted ? ['protein_g'] : isEmpty);
      expect(
        restored.displayCategories.any(
          (c) => c.startsWith('Nutrition conflict: '),
        ),
        isFalse,
      );
      expect(restored.canLogServings(1), isFalse);
      final export = ExportDocument.parse(
        jsonEncode({
          'user_recipes': [restored.toRow()],
        }),
      );
      expect(jsonDecode(export.json), {
        'user_recipes': [restored.toRow()],
      });
      expect(
        export
            .sections
            .single
            .records
            .single['eatova_serving_projection']['nutrition_complete'],
        !conflicted,
      );

      if (conflicted) {
        // Assigning a serving count cannot repair contradictory or absent macros.
        expect(
          () => restored.withConfirmedNutritionBasis(2),
          throwsFormatException,
        );
        expect(
          () => imported.withReviewedNutrition(restored),
          throwsFormatException,
        );
        final inconsistent = restored.copyWith(
          proteinG: 68,
          categories: [
            ...restored.categories,
            '${recipeNutritionKnownPrefix}protein_g',
          ],
        );
        expect(inconsistent.displayNutrition.proteinG, isNull);
        expect(inconsistent.canLogServings(1), isFalse);

        // These are explicit user corrections, not inferred caption numbers.
        final reviewed = restored.copyWith(
          proteinG: 47,
          carbsG: 68,
          categories: restored.categories
              .where((c) => !isRecipeNutritionMetadata(c))
              .toList(),
        );
        final corrected = imported.withReviewedNutrition(reviewed);
        expect(corrected.id, imported.id);
        expect(corrected.stableSlug(), imported.stableSlug());
        expect(corrected.ingredients, imported.ingredients);
        expect(corrected.preparation, imported.preparation);
        expect(corrected.servings, imported.servings);
        expect(corrected.ingredientsBasis, imported.ingredientsBasis);
        expect(corrected.nutritionConflicts, isEmpty);
        final saved = corrected.toRecipe(
          slug: recipe.slug,
          sourceLabel: 'Source',
        );
        expect(saved.canLogServings(2), isTrue);
        expect(saved.toMealResultForServings(2, enL10n).caloriesKcal, 1300);
        expect(saved.toMealResultForServings(2, enL10n).protein, '94 g');
      } else {
        final confirmed = restored.withConfirmedNutritionBasis(2);
        expect(confirmed.toMealResultForServings(1).caloriesKcal, 325);
        expect(confirmed.nutritionConflicts, isEmpty);
      }
    });
  }
}
