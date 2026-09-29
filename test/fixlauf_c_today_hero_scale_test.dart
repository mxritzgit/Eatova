// Regression for system text scaling: detail text must never be shrunk.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eatova/src/models/day_nutrition.dart';
import 'package:eatova/src/models/macro_progress.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/today/today_hero.dart';
import 'support/harness.dart';

void main() {
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 1.3, 2.0]) {
      testWidgets('calorie card remains readable at $scale / $brightness', (
        tester,
      ) async {
        await pumpLocalized(
          tester,
          SingleChildScrollView(
            child: TodayCalorieCard(
              summary: DayNutritionSummary(
                profile: const UserProfile(dailyKcalGoal: 2000),
                burnedKcal: 1234,
                consumed: const MacroProgress(
                  proteinG: 0,
                  carbsG: 0,
                  fatG: 0,
                  kcal: 12345,
                ),
              ),
            ),
          ),
          surfaceSize: const Size(320, 852),
          padding: const EdgeInsets.all(20),
          brightness: brightness,
          textScale: scale,
          settle: true,
        );
        expect(tester.takeException(), isNull);
        // The stats keep the user's size: no FittedBox, full scale.
        for (final key in [
          'today-stat-eaten',
          'today-kcal-goal',
          'today-stat-burned',
        ]) {
          final text = find.byKey(ValueKey(key));
          expect(
            find.ancestor(of: text, matching: find.byType(FittedBox)),
            findsNothing,
          );
          final style = tester.widget<Text>(text).style!;
          expect(
            MediaQuery.textScalerOf(
              tester.element(text),
            ).scale(style.fontSize!),
            style.fontSize! * scale,
          );
        }
        // Only the arc's centre may scale down, to stay inside the ring.
        final number = find.byKey(const ValueKey('today-kcal-remaining'));
        final fitted = find.ancestor(
          of: number,
          matching: find.byType(FittedBox),
        );
        expect(tester.widget<FittedBox>(fitted).fit, BoxFit.scaleDown);
        final ring = tester.getRect(
          find.byKey(const ValueKey('today-kcal-ring')),
        );
        expect(tester.getRect(fitted).width, lessThanOrEqualTo(ring.width));
        // The stats sit below the arc.
        final eaten = tester.getRect(
          find.byKey(const ValueKey('today-stat-eaten')),
        );
        expect(eaten.top, greaterThan(ring.bottom));
        expect(find.text('100 % gegessen'), findsOneWidget);
      });
    }
  }
}
