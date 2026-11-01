// Copying meals end to end through the real shell (EatovaHomePage over a
// fake PostgREST): the food tab offers "Repeat yesterday" from the store's
// previous day, the toast's undo removes the copy again, and "Copy to…" in
// the edit sheet reaches the store through MealEditScope and the server
// through the outbox. The add sheet's "Your usual lunch" (2026-11-01) copies
// through the same path and reads the day's budget from the shell. Runs in
// English, the shell helpers' locale.

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';

import '../support/fixlauf_a_helpers.dart';
import '../flows/flow_test_helpers.dart';
import '../support/food_navigation.dart';

/// A plain Wednesday midday, far from midnight and DST edges.
final DateTime _now = DateTime(2026, 10, 14, 12, 30);
final DateTime _today = DateTime(2026, 10, 14);
final DateTime _yesterday = DateTime(2026, 10, 13);

const MealAnalysisResult _porridge = MealAnalysisResult(
  mealName: 'Porridge',
  caloriesKcal: 380,
  estimatedGrams: 300,
  kcalPer100G: 126.7,
  protein: '14 g',
  carbs: '60 g',
  fat: '9 g',
  confidence: 'manual',
  portionNotes: '',
  sourceLabel: 'manual',
);

Finder _key(String key) => find.byKey(ValueKey(key));

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await settleFrames(tester);
  await tester.tap(finder);
  await settleFrames(tester);
}

void main() {
  testWidgetsRobust(
    'Gestern wiederholen, Rueckgaengig und Kopieren nach … in der echten Shell',
    (WidgetTester tester) async {
      await withClock(Clock.fixed(_now), () async {
        final server = FixlaufServer()
          ..profileRow = serverProfileRow(completedProfile);
        final store = await pumpSignedIn(tester, server);
        final original = await store.addResultToDailyTotal(
          _porridge,
          slot: MealSlot.breakfast,
          foodDate: _yesterday,
        );
        await tester.tap(_key('nav-Food'));
        await settleFrames(tester);

        // ---- Repeat yesterday ---------------------------------------------
        expect(_key('food-slot-repeat-breakfast'), findsOneWidget);
        expect(_key('food-slot-repeat-lunch'), findsNothing);
        expect(find.text('Repeat yesterday'), findsOneWidget);

        await _tap(tester, _key('food-slot-repeat-breakfast'));

        final repeated = store.mealsForFoodDate(_today);
        expect(repeated, hasLength(1));
        expect(repeated.single.id, isNot(original));
        expect(repeated.single.slot, MealSlot.breakfast);
        expect(repeated.single.result.caloriesKcal, 380);
        expect(
          _key('food-slot-repeat-breakfast'),
          findsNothing,
          reason: 'the slot is no longer empty',
        );
        expect(find.text('1 item from yesterday added.'), findsOneWidget);
        await pumpUntil(
          tester,
          () => server.mealRows.containsKey(repeated.single.id),
          'the copy reaches the server',
        );

        await tester.tap(find.text('Undo'));
        await settleFrames(tester);
        expect(store.mealsForFoodDate(_today), isEmpty);
        expect(store.mealsForFoodDate(_yesterday).single.id, original);
        expect(_key('food-slot-repeat-breakfast'), findsOneWidget);
        await pumpUntil(
          tester,
          () => !server.mealRows.containsKey(repeated.single.id),
          'the undo deletes the copy on the server',
        );
        // Let the toast go before the next step.
        await tester.pump(const Duration(seconds: 6));
        await settleFrames(tester);

        // ---- Copy to… from yesterday's entry ------------------------------
        await selectFoodDayOffset(tester, 1);
        await settleFrames(tester);
        await expandFoodEntries(tester, slot: MealSlot.breakfast);
        await _tap(tester, _key('food-history-entry-0'));
        expect(_key('edit-meal-sheet'), findsOneWidget);

        await _tap(tester, _key('edit-meal-copy-button'));
        await _tap(tester, _key('copy-slot-select-snack'));
        await _tap(tester, _key('meal-copy-confirm'));

        expect(_key('edit-meal-sheet'), findsNothing);
        final copied = store.mealsForFoodDate(_today);
        expect(copied, hasLength(1));
        expect(copied.single.slot, MealSlot.snack);
        expect(store.mealsForFoodDate(_yesterday).single.id, original);
        expect(find.text('Meal copied to today.'), findsOneWidget);
        await pumpUntil(
          tester,
          () => server.mealRows[copied.single.id]?['forced_slot'] == 'snack',
          'the copy reaches the server in its new slot',
        );
        expect(server.mealRows[original]?['forced_slot'], 'breakfast');
      });
    },
  );

  testWidgetsRobust(
    'Dein übliches Mittagessen im Add-Sheet kopiert über die Shell, und '
    '„Was passt noch?“ nennt das Restbudget des Tages',
    (WidgetTester tester) async {
      await withClock(Clock.fixed(_now), () async {
        final server = FixlaufServer()
          ..profileRow = serverProfileRow(completedProfile);
        final store = await pumpSignedIn(tester, server);
        MealAnalysisResult food(String name, int kcal) => MealAnalysisResult(
          mealName: name,
          caloriesKcal: kcal,
          estimatedGrams: 100,
          kcalPer100G: kcal.toDouble(),
          protein: '20 g',
          carbs: '20 g',
          fat: '5 g',
          confidence: 'manual',
          portionNotes: '',
          sourceLabel: 'manual',
        );
        for (final day in [10, 11, 12]) {
          for (final part in [food('Rice', 180), food('Curry', 420)]) {
            await store.addResultToDailyTotal(
              part,
              slot: MealSlot.lunch,
              foodDate: DateTime(2026, 10, day),
            );
          }
        }
        // Ten own foods with protein, so "What still fits?" has data.
        for (var i = 1; i <= 10; i++) {
          await store.addResultToDailyTotal(
            food('Snack $i', 100 + i),
            slot: MealSlot.snack,
            foodDate: DateTime(2026, 10, i),
          );
        }
        await store.addResultToDailyTotal(_porridge, slot: MealSlot.breakfast);
        await tester.tap(_key('nav-Food'));
        await settleFrames(tester);

        await _tap(tester, _key('food-slot-add-lunch'));
        final left = store.nutritionSummaryForFoodDate(_today).remainingKcal;
        expect(
          find.text(
            '${NumberFormat.decimalPattern('en').format(left)} kcal left',
          ),
          findsOneWidget,
        );

        await _tap(tester, _key('own-food-usual'));
        final lunch = [
          for (final meal in store.mealsForFoodDate(_today))
            if (meal.slot == MealSlot.lunch) meal.result.mealName,
        ];
        expect(lunch, unorderedEquals(['Rice', 'Curry']));
        expect(find.text('2 meals copied to today.'), findsOneWidget);
        expect(
          _key('own-food-usual'),
          findsNothing,
          reason: 'the slot is no longer empty',
        );
        expect(
          find.descendant(
            of: _key('analyse-existing-meals'),
            matching: find.text('Curry'),
          ),
          findsOneWidget,
          reason: 'the copies show as already added',
        );
        await tester.pump(const Duration(seconds: 6));
        await settleFrames(tester);
      });
    },
  );
}
