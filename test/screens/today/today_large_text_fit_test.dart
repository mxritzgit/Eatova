// Large system text on the Today cards (review 2026-10-11, DSA-1/DSA-2):
// the calorie block stays inside the ring and a macro number never splits
// its digits over two lines.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eatova/src/models/day_nutrition.dart';
import 'package:eatova/src/models/macro_progress.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/today/today_hero.dart';
import 'package:eatova/src/screens/today/today_macros.dart';

import '../../support/harness.dart';

DayNutritionSummary _summary() => DayNutritionSummary(
  profile: const UserProfile(
    dailyKcalGoal: 2050,
    proteinGoalG: 162,
    carbsGoalG: 222,
    fatGoalG: 57,
  ),
  burnedKcal: 73,
  consumed: const MacroProgress(
    proteinG: 111,
    carbsG: 144,
    fatG: 20,
    kcal: 1221,
  ),
);

void main() {
  for (final scale in [1.0, 1.5, 2.0]) {
    for (final width in [320.0, 390.0]) {
      testWidgets('calorie block stays inside the ring at $scale / $width', (
        tester,
      ) async {
        await pumpLocalized(
          tester,
          SingleChildScrollView(child: TodayCalorieCard(summary: _summary())),
          surfaceSize: Size(width, 900),
          padding: const EdgeInsets.all(20),
          textScale: scale,
          settle: true,
        );
        expect(tester.takeException(), isNull);
        final ring = tester.getRect(
          find.byKey(const ValueKey('today-kcal-ring')),
        );
        // The ring's circle is the top square of the box (design r 100,
        // stroke 18 on a 240 px box): inner edge at r 91.
        final centre = Offset(ring.center.dx, ring.top + ring.width / 2);
        final inner = 91 * ring.width / 240;
        for (final line in [
          find.text('HEUTE ÜBRIG'),
          find.byKey(const ValueKey('today-kcal-remaining')),
          find.byKey(const ValueKey('today-kcal-budget')),
        ]) {
          final box = tester.getRect(line);
          for (final corner in [
            box.topLeft,
            box.topRight,
            box.bottomLeft,
            box.bottomRight,
          ]) {
            expect(
              (corner - centre).distance,
              lessThanOrEqualTo(inner + 0.5),
              reason: '$line pokes into the ring at $corner',
            );
          }
        }
      });
    }
  }

  testWidgets('macro numbers stay on one line at 2x on a small phone', (
    tester,
  ) async {
    await pumpLocalized(
      tester,
      SingleChildScrollView(child: TodayMacros(summary: _summary())),
      surfaceSize: const Size(360, 900),
      padding: const EdgeInsets.all(20),
      textScale: 2,
      settle: true,
    );
    expect(tester.takeException(), isNull);
    // One line of the 24 px value at 2x is 24 * 2 * 1.2 px tall.
    const oneLine = 24 * 2 * 1.2;
    for (final value in ['111', '144', '20']) {
      final height = tester.getSize(find.text(value)).height;
      expect(
        height,
        lessThan(oneLine * 1.5),
        reason: '"$value" wrapped (height $height)',
      );
    }
  });
}
