// Copying meals end to end through the real shell (EatovaHomePage over a
// fake PostgREST): the food tab offers "Repeat yesterday" from the store's
// previous day, the toast's undo removes the copy again, and "Copy to…" in
// the edit sheet reaches the store through MealEditScope and the server
// through the outbox. Runs in English, the shell helpers' locale.

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
