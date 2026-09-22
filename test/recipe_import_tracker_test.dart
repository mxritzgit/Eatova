import 'dart:async';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/recipe_import_result.dart';
import 'package:eatova/src/screens/recipes/recipes_screen.dart';
import 'package:eatova/src/services/recipe_save_result.dart';
import 'package:eatova/src/services/sync_error_messages.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

FitnessRecipe pizza({bool complete = true, bool unclear = true}) {
  final imported = RecipeImportCandidate(
    id: 'pizza',
    title: 'High-Protein Pizza',
    ingredients: '125 g Magerquark\n75 g Dinkelmehl\n20 g Mozzarella',
    preparation: 'Bei 200 °C backen.',
    caloriesKcal: 507,
    proteinG: 50,
    carbsG: complete ? 61 : null,
    fatG: 6,
    nutritionBasisUnclear: unclear,
  ).toRecipe(slug: 'user_import_pizza', sourceLabel: 'Source');
  // Existing imports persisted the generic marker even with all four values.
  return imported.copyWith(
    serverRevision: 7,
    categories: {
      ...imported.categories,
      if (unclear) recipeNutritionPendingCategory,
    }.toList(),
  );
}

Future<void> tap(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> open(
  WidgetTester tester, {
  FitnessRecipe? recipe,
  Future<RecipeSaveResult> Function(FitnessRecipe)? save,
  FutureOr<void> Function(MealAnalysisResult, MealSlot)? log,
  bool Function()? session,
  Locale locale = const Locale('en'),
  double textScale = 1,
}) => pumpLocalized(
  tester,
  RecipeDetailScreen(
    recipe: recipe ?? pizza(),
    onEdit:
        save ??
        (r) async => RecipeSaveResult.detached(r, SyncDelivery.delivered),
    onAddMeal: log ?? (_, _) {},
    isSessionCurrent: session,
  ),
  locale: locale,
  textScale: textScale,
  surfaceSize: const Size(390, 844),
);

void main() {
  testWidgets('complete caption values never show a missing-nutrition badge', (
    tester,
  ) async {
    await open(tester);
    expect(find.text(enL10n.recipeImportNutritionPendingLabel), findsNothing);
    expect(find.text('507'), findsOneWidget);
    expect(find.text('50 g'), findsOneWidget);
    expect(
      pizza().displayCategories,
      isNot(contains(recipeNutritionPendingCategory)),
    );
    expect(pizza().canLogServings(1), isFalse);
  });

  testWidgets(
    'add action confirms the basis, persists it, then logs the chosen slot',
    (tester) async {
      final saved = <FitnessRecipe>[];
      final logged = <(MealAnalysisResult, MealSlot)>[];
      await open(
        tester,
        save: (r) async {
          saved.add(r);
          return RecipeSaveResult.detached(r, SyncDelivery.queuedOffline);
        },
        log: (r, slot) => logged.add((r, slot)),
      );
      await tap(tester, 'recipe-add-button');
      expect(
        find.byKey(const ValueKey('recipe-nutrition-basis-sheet')),
        findsOneWidget,
      );
      expect(saved, isEmpty);
      expect(logged, isEmpty);
      await tap(tester, 'recipe-nutrition-basis-confirm');
      expect(saved, hasLength(1));
      expect(saved.single.serverRevision, 7);
      expect(saved.single.hasPendingNutrition, isFalse);
      expect(
        find.byKey(const ValueKey('recipe-meal-picker-sheet')),
        findsOneWidget,
      );
      await tap(tester, 'recipe-meal-picker-lunch');
      expect(logged.single.$1.caloriesKcal, 507);
      expect(logged.single.$1.protein, '50 g');
      expect(logged.single.$1.carbs, '61 g');
      expect(logged.single.$1.fat, '6 g');
      expect(logged.single.$2, MealSlot.lunch);
      await tap(tester, 'recipe-add-button');
      expect(
        find.byKey(const ValueKey('recipe-nutrition-basis-sheet')),
        findsNothing,
      );
      expect(saved, hasLength(1));
    },
  );

  testWidgets(
    'missing values lead directly to the editor and then to the tracker',
    (tester) async {
      final saved = <FitnessRecipe>[];
      MealAnalysisResult? logged;
      await open(
        tester,
        recipe: pizza(complete: false, unclear: false),
        save: (r) async {
          saved.add(r);
          return RecipeSaveResult.detached(r, SyncDelivery.delivered);
        },
        log: (r, _) => logged = r,
      );
      await tap(tester, 'recipe-add-button');
      final carbs = find.byKey(const ValueKey('recipe-create-carbs'));
      expect(carbs, findsOneWidget);
      expect(tester.widget<TextField>(carbs).controller!.text, isEmpty);
      await tester.ensureVisible(carbs);
      await tester.enterText(carbs, '61');
      await tap(tester, 'recipe-create-save');
      expect(saved.single.proteinG, 50);
      await tap(tester, 'recipe-meal-picker-breakfast');
      expect(logged!.caloriesKcal, 507);
    },
  );
  test(
    'basis confirmation scales every value and rejects missing data or invalid amounts',
    () {
      final confirmed = pizza().withConfirmedNutritionBasis(2);
      expect(confirmed.caloriesKcal, 254);
      expect(confirmed.proteinG, 25);
      expect(confirmed.carbsG, 31);
      expect(confirmed.fatG, 3);
      expect(confirmed.batchServings, pizza().batchServings);
      expect(confirmed.hasPendingNutrition, isFalse);
      for (final amount in [0.0, -1.0, double.nan, double.infinity, 101.0]) {
        expect(
          () => pizza().withConfirmedNutritionBasis(amount),
          throwsFormatException,
        );
      }
      expect(
        () => pizza(complete: false).withConfirmedNutritionBasis(1),
        throwsFormatException,
      );
      expect(
        () => pizza(unclear: false).withConfirmedNutritionBasis(1),
        throwsFormatException,
      );
    },
  );

  testWidgets('every meal slot accepts a confirmed imported recipe', (
    tester,
  ) async {
    final slots = <MealSlot>[];
    await open(
      tester,
      recipe: pizza(unclear: false),
      log: (_, slot) => slots.add(slot),
    );
    for (final slot in [
      MealSlot.breakfast,
      MealSlot.lunch,
      MealSlot.dinner,
      MealSlot.snack,
    ]) {
      await tap(tester, 'recipe-add-button');
      await tap(tester, 'recipe-meal-picker-${slot.name}');
      expect(slots.last, slot);
    }
    expect(slots.length, 4);
  });

  testWidgets(
    'cancel and invalid basis leave the saved recipe and diary unchanged',
    (tester) async {
      var writes = 0;
      await open(
        tester,
        save: (r) async {
          writes++;
          return RecipeSaveResult.detached(r, SyncDelivery.delivered);
        },
        log: (_, _) => writes++,
      );
      await tap(tester, 'recipe-add-button');
      final field = find.byKey(const ValueKey('recipe-portion-field'));
      await tester.ensureVisible(field);
      await tester.enterText(field, '0');
      await tap(tester, 'recipe-nutrition-basis-confirm');
      expect(writes, 0);
      await tap(tester, 'recipe-nutrition-basis-cancel');
      expect(
        find.byKey(const ValueKey('recipe-meal-picker-sheet')),
        findsNothing,
      );
      expect(writes, 0);
    },
  );

  testWidgets(
    'confirmation save failure keeps the chosen basis and retries before logging',
    (tester) async {
      var attempts = 0;
      final saved = <FitnessRecipe>[];
      MealAnalysisResult? logged;
      await open(
        tester,
        save: (r) async {
          if (++attempts == 1) throw StateError('private runtime detail');
          saved.add(r);
          return RecipeSaveResult.detached(r, SyncDelivery.delivered);
        },
        log: (r, _) => logged = r,
      );
      await tap(tester, 'recipe-add-button');
      final field = find.byKey(const ValueKey('recipe-portion-field'));
      await tester.ensureVisible(field);
      await tester.enterText(field, '2');
      await tap(tester, 'recipe-nutrition-basis-confirm');
      expect(find.text(enL10n.recipeEditSaveFailed), findsOneWidget);
      expect(find.textContaining('private runtime'), findsNothing);
      expect(logged, isNull);
      expect(tester.widget<TextField>(field).controller!.text, '2');
      await tap(tester, 'recipe-nutrition-basis-confirm');
      expect(saved.single.caloriesKcal, 254);
      await tap(tester, 'recipe-meal-picker-dinner');
      expect(logged!.caloriesKcal, 254);
      expect(logged!.protein, '25 g');
    },
  );

  testWidgets(
    'pending confirmation is single flight and stale session results cannot open logging',
    (tester) async {
      final pending = Completer<RecipeSaveResult>();
      var current = true;
      var writes = 0;
      FitnessRecipe? draft;
      await open(
        tester,
        session: () => current,
        save: (r) {
          writes++;
          draft = r;
          return pending.future;
        },
        log: (_, _) => fail('Stale session logged a meal'),
      );
      await tap(tester, 'recipe-add-button');
      await tap(tester, 'recipe-nutrition-basis-confirm');
      await tap(tester, 'recipe-nutrition-basis-confirm');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(writes, 1);
      expect(
        find.byKey(const ValueKey('recipe-nutrition-basis-sheet')),
        findsOneWidget,
      );
      current = false;
      final receipt = RecipeSaveResult.detached(draft!, SyncDelivery.delivered);
      pending.complete(receipt);
      await tester.pumpAndSettle();
      expect(receipt.handle.isDisposed, isTrue);
      expect(
        find.byKey(const ValueKey('recipe-meal-picker-sheet')),
        findsNothing,
      );
      expect(find.text(enL10n.recipeEditSessionChanged), findsOneWidget);
    },
  );

  for (final locale in [const Locale('de'), const Locale('en')]) {
    testWidgets(
      'basis review remains actionable with large ${locale.languageCode} text',
      (tester) async {
        await open(tester, locale: locale, textScale: 2);
        await tap(tester, 'recipe-add-button');
        await tap(tester, 'recipe-nutrition-basis-confirm');
        expect(
          find.byKey(const ValueKey('recipe-meal-picker-sheet')),
          findsOneWidget,
        );
        await tap(tester, 'recipe-meal-picker-snack');
        expect(tester.takeException(), isNull);
      },
    );
  }
}
