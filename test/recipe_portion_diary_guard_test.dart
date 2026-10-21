import 'package:clock/clock.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/widgets/design/design.dart' show PrimaryActionButton;
import 'package:eatova/src/widgets/kcal/edit_meal_sheet.dart';
import 'package:eatova/src/widgets/kcal/meal_analysis_sheet.dart';
import 'package:eatova/src/widgets/kcal/meal_suggestion_item.dart';
import 'package:eatova/src/widgets/meal/meal_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

MealAnalysisResult _portion() => FitnessRecipe(
  slug: 'user_weighed',
  title: 'Weighed recipe',
  description: '',
  portion: '',
  ingredients: '',
  preparation: '',
  professionalHint: '',
  imageAsset: '',
  caloriesKcal: 999,
  proteinG: 999,
  carbsG: 999,
  fatG: 999,
  estimatedGrams: 999,
  categories: const [],
  batchServings: 4,
  structuredIngredients: [
    RecipeIngredient(
      name: 'Oats',
      grams: 400,
      per100g: const RecipeNutrition(caloriesKcal: 350, proteinG: 10, fatG: 0),
    ),
  ],
).toMealResultForServings(0.5);

void main() {
  test('unknown cooked mass never replaces saved nutrition with zero', () {
    final original = _portion();
    expect(original.caloriesKcal, 175);
    expect(original.isRecipeWithoutCookedWeight, isTrue);
    final adjusted = original.adjustedToGrams(200);
    expect(adjusted.caloriesKcal, 175);
    expect(identical(adjusted, original), isTrue);
    expect(
      mealPortionAdjustment(original, [
        original.asSingleComponent.adjustedToGrams(200),
      ]),
      isNull,
    );
    expect(original.carbs, '-');
    expect(original.fat, '0 g');
  });

  testWidgets(
    'diary edit keeps recipe snapshot and explains the servings',
    (tester) async {
      await withClock(Clock.fixed(DateTime(2026, 9, 10, 12)), () async {
        pinPhoneViewport(tester);
        final original = _portion();
        var saved = LoggedMeal(
          id: 'fixed-recipe',
          result: original,
          loggedAt: DateTime(2026, 9, 10, 12),
          forcedSlot: MealSlot.lunch,
          localDay: '2026-09-10',
        );
        MealAnalysisResult? replaced;
        await pumpLocalized(
          tester,
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showEditMealSheet(
                context,
                meal: saved,
                onUpdateMeal: (id, {result, slot, day}) {
                  replaced = result;
                  saved = saved.copyWith(result: result, forcedSlot: slot);
                  return saved;
                },
              ),
              child: const Text('Open'),
            ),
          ),
          locale: const Locale('en'),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('edit-meal-adjust-button')),
          findsNothing,
        );
        expect(find.text(enL10n.foodServingsNoWeightHint), findsOneWidget);
        expect(find.textContaining('175\u00a0kcal'), findsOneWidget);
        await tester.ensureVisible(
          find.byKey(const ValueKey('edit-slot-select-dinner')),
        );
        await tester.tap(
          find.byKey(const ValueKey('edit-slot-select-dinner')),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const ValueKey('edit-meal-save-button')),
        );
        await tester.tap(find.byKey(const ValueKey('edit-meal-save-button')));
        await tester.pumpAndSettle();
        expect(replaced, isNull);
        expect(identical(saved.result, original), isTrue);
        expect(saved.result.caloriesKcal, 175);
        expect(saved.slot, MealSlot.dinner);
      });
    },
  );

  testWidgets(
    'the servings stepper rescales in half steps from the logged entry',
    (tester) async {
      await withClock(Clock.fixed(DateTime(2026, 9, 10, 12)), () async {
        pinPhoneViewport(tester);
        final original = _portion();
        final meal = LoggedMeal(
          id: 'fixed-recipe',
          result: original,
          loggedAt: DateTime(2026, 9, 10, 12),
          forcedSlot: MealSlot.lunch,
          localDay: '2026-09-10',
        );
        MealAnalysisResult? replaced;
        await pumpLocalized(
          tester,
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showEditMealSheet(
                context,
                meal: meal,
                onUpdateMeal: (id, {result, slot, day}) {
                  replaced = result;
                  return meal.copyWith(result: result);
                },
              ),
              child: const Text('Open'),
            ),
          ),
          locale: const Locale('en'),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();

        final less = find.byKey(const ValueKey('edit-meal-servings-less'));
        final more = find.byKey(const ValueKey('edit-meal-servings-more'));
        final save = find.byKey(const ValueKey('edit-meal-save-button'));
        String figure() => tester
            .widget<Text>(find.byKey(const ValueKey('edit-meal-summary-figure')))
            .data!;
        bool enabled(Finder button) =>
            tester.widget<InkWell>(button).onTap != null;

        expect(figure(), '175 kcal · 0.5 portions');
        expect(enabled(less), isFalse, reason: 'half a serving is the floor');
        for (final (tap, expected) in [
          (more, '350 kcal · 1 portion'),
          (more, '525 kcal · 1.5 portions'),
          (less, '350 kcal · 1 portion'),
          (less, '175 kcal · 0.5 portions'),
        ]) {
          await tester.tap(tap);
          await tester.pump();
          expect(figure(), expected);
        }
        await tester.ensureVisible(save);
        expect(
          tester.widget<PrimaryActionButton>(save).onTap,
          isNull,
          reason: 'back at the logged servings nothing is left to save',
        );

        await tester.ensureVisible(more);
        await tester.tap(more);
        await tester.tap(more);
        await tester.pump();
        await tester.ensureVisible(save);
        await tester.tap(save);
        await tester.pumpAndSettle();

        expect(replaced!.servings, 1.5);
        expect(replaced!.caloriesKcal, 525);
        expect(replaced!.protein, '15 g');
        expect(replaced!.carbs, '-', reason: 'unknown stays unknown');
        expect(replaced!.portionNotes, startsWith('1,5 Portionen · '));
      });
    },
  );

  testWidgets(
    'saved recipe recent uses unchanged portion without gram controls',
    (tester) async {
      pinPhoneViewport(tester);
      final original = _portion();
      MealAnalysisResult? added;
      await pumpLocalized(
        tester,
        SingleChildScrollView(
          child: MealSuggestionItem(
            result: original,
            expanded: true,
            onTap: () {},
            onAdd: (value) {
              added = value;
            },
            addButtonKey: const ValueKey('readd-recipe'),
          ),
        ),
        locale: const Locale('en'),
      );
      expect(find.byType(Slider), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(find.text(enL10n.recipeCalcNoCookedWeight), findsOneWidget);
      // The recent row names the saved portion, not a gram amount.
      expect(
        find.textContaining(enL10n.recipeCalcSavedPortion),
        findsOneWidget,
      );
      // Header and panel preview both show the unchanged portion kcal.
      expect(find.text('175 kcal'), findsNWidgets(2));
      await tester.ensureVisible(find.byKey(const ValueKey('readd-recipe')));
      await tester.tap(find.byKey(const ValueKey('readd-recipe')));
      expect(identical(added, original), isTrue);
    },
  );

  testWidgets(
    'shared weight sheet guard has explanation and no mutating controls',
    (tester) async {
      final original = _portion();
      await pumpLocalized(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showWeightAdjustmentSheet(context, original),
            child: const Text('Adjust'),
          ),
        ),
        locale: const Locale('en'),
      );
      await tester.tap(find.text('Adjust'));
      await tester.pumpAndSettle();
      expect(find.text(enL10n.recipeCalcNoCookedWeight), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.text(enL10n.commonClose));
      await tester.pumpAndSettle();
      expect(original.caloriesKcal, 175);
    },
  );
}
