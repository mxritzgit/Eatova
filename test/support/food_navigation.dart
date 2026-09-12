import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/screens/meal_analysis_screen.dart';
import 'package:eatova/src/services/day_math.dart';

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Walk the visible day controls; no store mutation bypasses navigation.
Future<void> selectFoodDayOffset(WidgetTester tester, int offset) async {
  final target = addDays(DateUtils.dateOnly(clock.now()), -offset);
  for (var step = 0; step < 40; step++) {
    final screen = tester.widget<MealAnalysisScreen>(
      find.byType(MealAnalysisScreen),
    );
    final difference = daysBetween(screen.selectedDate, target);
    if (difference == 0) return;
    final arrow = find.byKey(
      ValueKey(difference > 0 ? 'food-date-previous' : 'food-date-next'),
    );
    await tester.ensureVisible(arrow);
    await tester.tap(arrow);
    await _frames(tester);
  }
  fail('The visible diary controls did not reach $target');
}

/// Reveal populated meal sections before reading or editing their entries.
Future<void> expandFoodEntries(WidgetTester tester, {MealSlot? slot}) async {
  for (final mealSlot in slot == null ? MealSlot.values : [slot]) {
    final toggle = find.byKey(ValueKey('food-slot-toggle-${mealSlot.name}'));
    if (toggle.evaluate().isEmpty) continue;
    final semantics = tester
        .widgetList<Semantics>(
          find.ancestor(of: toggle, matching: find.byType(Semantics)),
        )
        .firstWhere((node) => node.properties.expanded != null);
    if (semantics.properties.expanded!) continue;
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await _frames(tester);
  }
}

Future<void> tapFoodHeaderAction(WidgetTester tester, String key) async {
  final action = find.byKey(ValueKey(key));
  if (action.evaluate().isEmpty) {
    await tester.ensureVisible(find.byKey(const ValueKey('food-options')));
    await tester.tap(find.byKey(const ValueKey('food-options')));
    await _frames(tester);
  }
  await tester.ensureVisible(action);
  await tester.tap(action);
  await _frames(tester);
}
