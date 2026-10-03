// Visual evidence for the 2026-10-03 meal-sheet slice of the redesign: the
// recipe detail's add card and soft edit/history pills, the adjust sheet with
// a removed item and its add dialog, the scan result's actions and the manual
// sheet — at the reference phone, at 320 px and at 2x text.
//
// With --dart-define=DARK_REDESIGN_CAPTURE=true the PNGs land in
// build/dark-redesign/meal-sheets-*.png; without it the suite still checks that
// every surface renders without an exception or overflow.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/meal_component.dart';
import 'package:eatova/src/screens/recipes/recipes_screen.dart';
import 'package:eatova/src/services/recipe_save_result.dart';
import 'package:eatova/src/widgets/design/design.dart';
import 'package:eatova/src/widgets/kcal/manual_meal_sheet.dart';
import 'package:eatova/src/widgets/kcal/meal_analysis_sheet.dart';
import 'package:eatova/src/widgets/meal/meal_widgets.dart';

import '../support/design_capture.dart';
import '../support/harness.dart';

const _bowl = MealAnalysisResult(
  mealName: 'Chicken rice bowl',
  caloriesKcal: 612,
  estimatedGrams: 430,
  kcalPer100G: 142,
  protein: '44 g',
  carbs: '68 g',
  fat: '16 g',
  confidence: '',
  portionNotes: '',
  items: [
    MealComponent(
      name: 'Grilled chicken breast',
      grams: 150,
      caloriesKcal: 248,
      kcalPer100G: 165,
    ),
    MealComponent(
      name: 'Basmati rice, cooked',
      grams: 200,
      caloriesKcal: 260,
      kcalPer100G: 130,
    ),
    MealComponent(
      name: 'Broccoli',
      grams: 80,
      caloriesKcal: 28,
      kcalPer100G: 35,
    ),
  ],
);

const _poke = FitnessRecipe(
  slug: 'user_salmon_poke',
  title: 'Salmon & Greens Poke',
  description: 'Rice, salmon and edamame with a sesame dressing.',
  portion: '1 bowl (about 420 g)',
  ingredients:
      '120 g salmon\n150 g cooked rice\n60 g edamame\n'
      '1 tbsp soy sauce\n1 tsp sesame oil',
  preparation:
      '1. Cook the rice and let it cool.\n2. Dice the salmon.\n'
      '3. Arrange everything in a bowl and add the dressing.',
  professionalHint: 'Day-old rice holds the dressing better.',
  imageAsset: '',
  caloriesKcal: 480,
  proteinG: 36,
  carbsG: 48,
  fatG: 14,
  estimatedGrams: 420,
  categories: ['Fisch'],
  userCreated: true,
);

/// The reference phone, optionally narrowed to [width] logical pixels.
void _viewport(WidgetTester tester, {double width = 390}) {
  pinDesignViewport(tester);
  tester.view.physicalSize =
      Size(width, kDesignViewport.height) * kDesignPixelRatio;
}

/// Pumps a launcher button and taps it.
Future<void> _host(
  WidgetTester tester,
  void Function(BuildContext context) open, {
  double width = 390,
  double textScale = 1,
}) async {
  _viewport(tester, width: width);
  await tester.pumpWidget(
    designCaptureBoundary(
      localizedApp(
        Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => open(context),
              child: const Text('open'),
            ),
          ),
        ),
        locale: const Locale('en'),
        safeArea: false,
        textScale: textScale,
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Future<void> _detail(
  WidgetTester tester, {
  double width = 390,
  double textScale = 1,
}) async {
  _viewport(tester, width: width);
  await tester.pumpWidget(
    designCaptureBoundary(
      localizedApp(
        RecipeDetailScreen(
          recipe: _poke,
          onAddMeal: (_, _) {},
          onEdit: (_) => Completer<RecipeSaveResult>().future,
          onOpenHistory: (_) async => false,
        ),
        locale: const Locale('en'),
        safeArea: false,
        scaffold: false,
        textScale: textScale,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _reveal(WidgetTester tester, String key) async {
  await tester.ensureVisible(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadDesignFonts);

  group('recipe detail', () {
    testWidgets('pinned add card and soft pills', (tester) async {
      await _detail(tester);
      expect(
        tester.widget(find.byKey(const ValueKey('recipe-add-button'))),
        isA<PrimaryActionButton>(),
      );
      for (final key in ['recipe-detail-edit', 'recipe-detail-history']) {
        expect(
          tester.widget(find.byKey(ValueKey(key))),
          isA<SoftPillButton>(),
          reason: key,
        );
      }
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'meal-sheets-recipe-detail');

      // The ingredient lines: spacing instead of hairlines.
      await scrollDesignTabBy(tester, 620);
      expect(find.byType(Divider), findsNothing);
      await captureDesignShot(tester, 'meal-sheets-recipe-detail-01');
    });

    testWidgets('inline add card at 320 px and 2x text', (tester) async {
      await _detail(tester, width: 320, textScale: 2);
      await _reveal(tester, 'recipe-detail-history');
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'meal-sheets-recipe-detail-320-x2');
      await _reveal(tester, 'recipe-add-card');
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'meal-sheets-recipe-add-320-x2');
    });
  });

  group('adjust sheet', () {
    testWidgets('removed item with its undo pill', (tester) async {
      await _host(
        tester,
        (context) => showWeightAdjustmentSheet(context, _bowl),
      );
      await tester.tap(find.byKey(const ValueKey('analyse-item-remove-1')));
      await tester.pumpAndSettle();
      expect(find.text('Undo'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'meal-sheets-adjust-removed');
    });

    testWidgets('add dialog with the macros toggle', (tester) async {
      await _host(
        tester,
        (context) => showWeightAdjustmentSheet(context, _bowl),
      );
      await _reveal(tester, 'analyse-item-add-button');
      await tester.tap(find.byKey(const ValueKey('analyse-item-add-button')));
      await tester.pumpAndSettle();
      await captureDesignShot(tester, 'meal-sheets-add-item');
      await tester.tap(
        find.byKey(const ValueKey('analyse-add-item-macros-toggle')),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'meal-sheets-add-item-macros');
    });

    testWidgets('320 px and 2x text', (tester) async {
      await _host(
        tester,
        (context) => showWeightAdjustmentSheet(context, _bowl),
        width: 320,
        textScale: 2,
      );
      await _reveal(tester, 'analyse-item-remove-1');
      await tester.tap(find.byKey(const ValueKey('analyse-item-remove-1')));
      await tester.pumpAndSettle();
      expect(find.text('Undo'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'meal-sheets-adjust-removed-320-x2');
      await _reveal(tester, 'analyse-save-weight-button');
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'meal-sheets-adjust-320-x2');
    });
  });

  group('scan result', () {
    Future<void> open(
      WidgetTester tester, {
      double width = 390,
      double textScale = 1,
    }) => _host(
      tester,
      (context) => showMealAnalysisSheet(
        context,
        slot: MealSlot.lunch,
        resultFuture: Future<MealAnalysisResult>.value(_bowl),
        previewImage: null,
        onAdd: (_, _) => 'id',
        onUpdateMeal: (_, _) {},
        failureMessage: 'failed',
      ),
      width: width,
      textScale: textScale,
    );

    testWidgets('added state', (tester) async {
      await open(tester);
      final add = find.byKey(const ValueKey('analyse-add-daily-button'));
      await tester.ensureVisible(add);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'meal-sheets-analysis');
      await tester.tap(add);
      await tester.pumpAndSettle();
      expect(tester.widget<PrimaryActionButton>(add).onTap, isNull);
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'meal-sheets-analysis-added');
      // Let the success toast run out before the tree goes.
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
    });

    testWidgets('320 px and 2x text', (tester) async {
      await open(tester, width: 320, textScale: 2);
      await _reveal(tester, 'analyse-add-daily-button');
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'meal-sheets-analysis-320-x2');
    });
  });

  group('manual sheet', () {
    for (final (suffix, scale) in [('', 1.0), ('-x2', 2.0)]) {
      testWidgets('save at 320 px$suffix', (tester) async {
        await _host(
          tester,
          (context) => showManualMealSheet(
            context,
            initialSlot: MealSlot.snack,
            contextLabel: 'Adds to Monday, Sep 28',
          ),
          width: 320,
          textScale: scale,
        );
        await captureDesignShot(tester, 'meal-sheets-manual-320$suffix');
        await _reveal(tester, 'manual-meal-save');
        expect(tester.takeException(), isNull);
        await captureDesignShot(tester, 'meal-sheets-manual-320$suffix-01');
      });
    }
  });
}
