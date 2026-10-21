// F7-05: "goal hit" on the trends page counts against goal plus step bonus,
// like Today. The arithmetic is pinned at screen level in
// fixlauf_g_trends_bonus_test.dart; this pins the SHELL route the Food tab
// really takes: its trends button calls EatovaHomePage._openTrends, which
// must hand TrendsScreen the store's burnedKcalForFoodDate. (The Food tab's
// own trendBurnedKcalFor fallback is unused in the shell, because the shell
// also passes onOpenTrends.)

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/day_math.dart';
import 'package:eatova/src/services/local_day.dart';

import '../flows/flow_test_helpers.dart' show settleFrames, storeOf;
import '../support/harness.dart';

final DateTime _noon = DateTime(2026, 8, 27, 12);

DateTime _daysAgo(int n) => addDays(startOfDay(_noon), -n);

LoggedMeal _meal(int daysAgo, int kcal) {
  final day = _daysAgo(daysAgo);
  return LoggedMeal(
    id: 'meal-$daysAgo',
    result: MealAnalysisResult(
      mealName: 'Day $daysAgo',
      caloriesKcal: kcal,
      estimatedGrams: 500,
      kcalPer100G: kcal / 5,
      protein: '0 g',
      carbs: '0 g',
      fat: '0 g',
      confidence: 'database',
      portionNotes: '',
    ),
    loggedAt: DateTime(day.year, day.month, day.day, 11),
    forcedSlot: MealSlot.lunch,
    localDay: localDayKey(day),
  );
}

void main() {
  testWidgetsRobust('the Food tab opens Trends with the store\'s step bonus', (
    tester,
  ) async {
    await withClock(Clock.fixed(_noon), () async {
      await pumpLocalized(
        tester,
        // The server window is empty; the preview store owns its days.
        EatovaHomePage(trendTotalsLoader: () async => const []),
        locale: const Locale('en'),
        scaffold: false,
        safeArea: false,
      );
      await settleFrames(tester);
      // Goal 2200, two completed days at 2450: without the bonus both miss
      // the ±10 % corridor (2420); with 230 kcal of steps each (goal 2430)
      // both hit.
      final store = storeOf(tester)
        ..profile = const UserProfile(dailyKcalGoal: 2200)
        ..loggedMeals = [_meal(2, 2450), _meal(1, 2450), _meal(0, 500)]
        ..dailyActivity = {
          for (final ago in [2, 1])
            localDayKey(_daysAgo(ago)): (steps: 8000, kcal: 230),
        };
      store.setTab(1);
      await settleFrames(tester);

      await tester.tap(find.byKey(const ValueKey('food-trends')));
      await settleFrames(tester);

      expect(find.byKey(const ValueKey('screen-trends')), findsOneWidget);
      expect(find.text(enL10n.trendsStatGoalRateSub(2, 2)), findsOneWidget);
      expect(
        find.byKey(const ValueKey('trends-goal-bonus-note')),
        findsOneWidget,
      );
    });
  });
}
