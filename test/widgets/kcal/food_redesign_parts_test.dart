// The redesigned Food tab's building blocks (dark redesign, Task 3): the
// shared slot tile, the stacked macro bar and the two text rules of the diary
// (the pick row's eyebrow, a row's amount).

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/day_nutrition.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/macro_progress.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/recipe_pick.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/meal_analysis_screen.dart';
import 'package:eatova/src/theme/app_tokens.dart';
import 'package:eatova/src/widgets/design/design.dart';
import 'package:eatova/src/widgets/kcal/diary_meal_card.dart';
import 'package:eatova/src/widgets/kcal/food_page_chrome.dart';

import '../../support/food_design_fixture.dart';
import '../../support/harness.dart';

RecipePick _pick({
  MealSlot slot = MealSlot.dinner,
  RecipePickSource source = RecipePickSource.suggested,
  int? kcal = 610,
}) => RecipePick(
  recipe: recipeCatalogForLocale('en').first,
  slot: slot,
  source: source,
  servings: 1,
  kcal: kcal,
  proteinG: 58,
  remainingKcalBefore: 902,
);

MealAnalysisResult _result({int grams = 250, String source = 'manual'}) =>
    MealAnalysisResult(
      mealName: 'Skyr',
      caloriesKcal: 158,
      estimatedGrams: grams,
      kcalPer100G: 63,
      protein: '27 g',
      carbs: '10 g',
      fat: '1 g',
      confidence: '',
      portionNotes: '',
      sourceLabel: source,
    );

void main() {
  // The slot colours themselves are design tokens (theme/app_tokens_test.dart
  // checks their hues); here only that they travel through the theme, and
  // that the tile stays decoration for screen readers.
  group('SlotIconTile', () {
    testWidgets('is decorative: the slot name next to it carries the meaning',
        (tester) async {
      await pumpLocalized(tester, const SlotIconTile(slot: MealSlot.dinner));
      expect(
        find.descendant(
          of: find.byType(SlotIconTile),
          matching: find.byType(ExcludeSemantics),
        ),
        findsWidgets,
      );
    });

    test('slot tokens survive copyWith and lerp', () {
      final other = AppTokens.dark.copyWith(slotSnackInk: Colors.transparent);
      expect(other.slotSnackInk, Colors.transparent);
      expect(other.slotLunchTint, AppTokens.dark.slotLunchTint);
      final half = AppTokens.dark.lerp(AppTokens.light, 0.5);
      expect(
        half.slotBreakfastInk,
        Color.lerp(
          AppTokens.dark.slotBreakfastInk,
          AppTokens.light.slotBreakfastInk,
          0.5,
        ),
      );
    });
  });

  group('FoodMacroBar', () {
    testWidgets('segments follow the kcal shares; an empty day is the bare '
        'track', (tester) async {
      await pumpLocalized(
        tester,
        const SizedBox(
          width: 300,
          child: FoodMacroBar(proteinKcal: 444, carbsKcal: 576, fatKcal: 180),
        ),
      );
      double width(String macro) =>
          tester.getSize(find.byKey(ValueKey('food-macro-bar-$macro'))).width;
      // 300 px minus two 2 px gaps, split 37 : 48 : 15.
      expect(width('protein'), closeTo(296 * 0.37, 1));
      expect(width('carbs'), closeTo(296 * 0.48, 1));
      expect(width('fat'), closeTo(296 * 0.15, 1));

      await pumpLocalized(
        tester,
        const SizedBox(
          width: 300,
          child: FoodMacroBar(proteinKcal: 0, carbsKcal: 0, fatKcal: 0),
        ),
      );
      expect(
        find.byKey(const ValueKey('food-macro-bar-protein')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('food-macro-bar')), findsOneWidget);
    });
  });

  test('foodPickEyebrow: dinner fits tonight, other slots fit the day, a '
      'planned meal says planned even when it does not fit', () {
    expect(
      foodPickEyebrow(_pick(), enL10n),
      enL10n.foodPickFitsTonight('610'),
    );
    expect(
      foodPickEyebrow(_pick(slot: MealSlot.lunch), enL10n),
      enL10n.foodPickFitsDay('610'),
    );
    expect(
      foodPickEyebrow(
        _pick(source: RecipePickSource.planned, kcal: 1250),
        enL10n,
      ),
      enL10n.foodPickPlanned('1,250'),
    );
    expect(
      foodPickEyebrow(
        _pick(source: RecipePickSource.planned, kcal: null),
        enL10n,
      ),
      enL10n.foodPickPlannedNoKcal,
    );
  });

  test('diaryAmountLabel: measured grams stay plain, AI estimates keep their '
      '"~", no grams name a portion', () {
    expect(diaryAmountLabel(_result(), enL10n), '250 g');
    expect(diaryAmountLabel(_result(source: 'OpenFoodFacts'), enL10n), '250 g');
    expect(diaryAmountLabel(_result(source: 'photoAi'), enL10n), '~250 g');
    expect(diaryAmountLabel(_result(source: 'KI-Schätzung'), enL10n), '~250 g');
    expect(
      diaryAmountLabel(_result(grams: 0), enL10n),
      enL10n.foodPortionFallback,
    );
  });

  group('FoodDaySummaryCard', () {
    testWidgets('fits 1.3x text at 390 px and 1.0x at 320 px', (tester) async {
      for (final (width, scale) in [(390.0, 1.3), (320.0, 1.0)]) {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 700);
        addTearDown(tester.view.reset);
        final overflows = await collectOverflows(() async {
          await pumpLocalized(
            tester,
            FoodDaySummaryCard(
              summary: DayNutritionSummary(
                profile: const UserProfile(dailyKcalGoal: 2123),
                burnedKcal: 0,
                consumed: const MacroProgress(
                  proteinG: 111,
                  carbsG: 144,
                  fatG: 20,
                  kcal: 12221,
                ),
              ),
              loading: false,
              onTap: () {},
            ),
            textScale: scale,
            locale: const Locale('de'),
            padding: const EdgeInsets.symmetric(horizontal: 20),
          );
        });
        expect(overflows, isEmpty, reason: describeOverflows(overflows));
        // Five digits and "OVER" still render (scaled down, not clipped).
        expect(find.text('12.221'), findsOneWidget);
        expect(find.text('ZU VIEL'), findsOneWidget);
      }
    });

    testWidgets('a macro with unknown entries reads as a lower bound', (
      tester,
    ) async {
      await pumpLocalized(
        tester,
        FoodDaySummaryCard(
          summary: DayNutritionSummary(
            profile: const UserProfile(dailyKcalGoal: 2123),
            burnedKcal: 0,
            consumed: const MacroProgress(
              proteinG: 48,
              carbsG: 144,
              fatG: 20,
              kcal: 1221,
              proteinMissing: 1,
              entriesMissingMacros: 1,
            ),
          ),
          loading: false,
          onTap: () {},
        ),
      );
      expect(find.text('≥48 g'), findsOneWidget);
      expect(find.text('144 g'), findsOneWidget);
      expect(find.text(deL10n.foodMacrosMissingEntries(1)), findsOneWidget);
    });
  });

  group('Food screen text scale', () {
    for (final (width, scale) in [(390.0, 1.3), (320.0, 1.0)]) {
      for (final locale in const [Locale('de'), Locale('en')]) {
        testWidgets('no overflow at ${width.round()} px and ${scale}x '
            '($locale)', (tester) async {
          await withClock(Clock.fixed(foodDesignNow), () async {
            tester.view.devicePixelRatio = 1;
            tester.view.physicalSize = Size(width, 844);
            addTearDown(tester.view.reset);
            final overflows = await collectOverflows(() async {
              await pumpLocalized(
                tester,
                MealAnalysisScreen(
                  dailyConsumedKcal: 1221,
                  profile: foodDesignProfile,
                  loggedMeals: foodDesignMeals(),
                  recipePick: _pick(),
                ),
                textScale: scale,
                locale: locale,
                settle: true,
              );
              // Scroll through the whole diary.
              final scroll = find.descendant(
                of: find.byKey(const ValueKey('food-diary-scroll')),
                matching: find.byType(Scrollable),
              );
              final position = tester.state<ScrollableState>(scroll).position;
              position.jumpTo(position.maxScrollExtent);
              await tester.pumpAndSettle();
            });
            expect(overflows, isEmpty, reason: describeOverflows(overflows));
            expect(find.byKey(const ValueKey('food-pick-row')), findsOneWidget);
          });
        });
      }
    }
  });
}
