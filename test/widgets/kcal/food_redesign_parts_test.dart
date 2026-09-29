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
import 'package:eatova/src/theme/meal_slot_style.dart';
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
  group('SlotIconTile', () {
    testWidgets('each slot has its design tint and ink, 44 px, radius 14', (
      tester,
    ) async {
      const t = AppTokens.dark;
      final expected = <MealSlot, (Color, Color)>{
        MealSlot.breakfast: (const Color(0x294697E2), const Color(0xFF8CC4FF)),
        MealSlot.lunch: (const Color(0x291DB071), const Color(0xFF6FDCA4)),
        MealSlot.dinner: (const Color(0x2ED57C11), const Color(0xFFFFB866)),
        MealSlot.snack: (const Color(0x29B9A5FF), const Color(0xFFC8B8FF)),
      };
      for (final MapEntry(key: slot, value: (tint, ink)) in expected.entries) {
        expect(slot.tileTint(t), tint, reason: '$slot tint');
        expect(slot.tileInk(t), ink, reason: '$slot ink');
      }
      await pumpLocalized(
        tester,
        const Row(
          children: [
            SlotIconTile(slot: MealSlot.dinner),
            SlotIconTile(slot: MealSlot.lunch, size: 32),
          ],
        ),
      );
      final tiles = tester.widgetList<Container>(
        find.descendant(
          of: find.byType(SlotIconTile),
          matching: find.byType(Container),
        ),
      );
      final dinner = tiles.first.decoration! as BoxDecoration;
      expect(dinner.color, t.slotDinnerTint);
      expect(dinner.borderRadius, BorderRadius.circular(14));
      expect(
        tester.getSize(find.byType(SlotIconTile).first),
        const Size(44, 44),
      );
      expect(
        tester.getSize(find.byType(SlotIconTile).last),
        const Size(32, 32),
      );
      // Decorative: the slot name next to it carries the meaning.
      expect(
        find.descendant(
          of: find.byType(SlotIconTile).first,
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
      expect(
        tester.getSize(find.byKey(const ValueKey('food-macro-bar'))).height,
        10,
      );

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

  group('foodPickEyebrow', () {
    test('a dinner suggestion fits tonight, others fit the day', () {
      expect(foodPickEyebrow(_pick(), enL10n), 'Fits tonight · 610 kcal');
      expect(
        foodPickEyebrow(_pick(slot: MealSlot.lunch), enL10n),
        'Fits your day · 610 kcal',
      );
      expect(foodPickEyebrow(_pick(), deL10n), 'Passt heute Abend · 610 kcal');
    });

    test('a planned meal says planned, even when it does not fit', () {
      expect(
        foodPickEyebrow(
          _pick(source: RecipePickSource.planned, kcal: 1250),
          enL10n,
        ),
        'Planned · 1,250 kcal',
      );
      expect(
        foodPickEyebrow(
          _pick(source: RecipePickSource.planned, kcal: null),
          enL10n,
        ),
        'Planned',
      );
    });
  });

  group('diaryAmountLabel', () {
    test('measured grams stay plain, AI estimates keep their "~"', () {
      expect(diaryAmountLabel(_result(), enL10n), '250 g');
      expect(
        diaryAmountLabel(_result(source: 'OpenFoodFacts'), enL10n),
        '250 g',
      );
      expect(diaryAmountLabel(_result(source: 'photoAi'), enL10n), '~250 g');
      expect(
        diaryAmountLabel(_result(source: 'KI-Schätzung'), enL10n),
        '~250 g',
      );
    });

    test('without grams the row names a portion', () {
      expect(diaryAmountLabel(_result(grams: 0), enL10n), '1 portion');
    });
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
        expect(find.text('DRÜBER'), findsOneWidget);
      }
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
