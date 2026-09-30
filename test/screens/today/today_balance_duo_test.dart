import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eatova/src/models/day_nutrition.dart';
import 'package:eatova/src/models/macro_progress.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/today/today_hero.dart';
import 'package:eatova/src/screens/today/today_macros.dart';
import 'package:eatova/src/screens/today/today_progress.dart';
import 'package:eatova/src/theme/app_tokens.dart';
import '../../support/harness.dart';

double contrast(Color a, Color b) {
  final x = a.computeLuminance(), y = b.computeLuminance();
  return x > y ? (x + .05) / (y + .05) : (y + .05) / (x + .05);
}

void main() {
  for (final brightness in Brightness.values) {
    final t = brightness == Brightness.light ? AppTokens.light : AppTokens.dark;
    test('pastel contrast contract in $brightness', () {
      for (final tone in [
        t.progressAccent,
        t.proteinProgress,
        t.carbsProgress,
        t.fatProgress,
      ]) {
        expect(contrast(tone, t.surf), greaterThanOrEqualTo(3));
      }
      for (final surface in [t.proteinSurface, t.carbsSurface, t.fatSurface]) {
        expect(contrast(t.ink, surface), greaterThanOrEqualTo(4.5));
      }
      expect(
        contrast(t.onBrandSurface, t.brandSurface),
        greaterThanOrEqualTo(4.5),
      );
      expect(t.onImage, Colors.white);
      expect(t.copyWith().progressAccent, t.progressAccent);
      expect(t.lerp(t, .5).progressAccent, t.progressAccent);
    });
    testWidgets(
      'macro tiles preserve quantities and clamp their bars in $brightness',
      (tester) async {
        final semantics = tester.ensureSemantics();
        await pumpLocalized(
          tester,
          SingleChildScrollView(
            child: TodayMacros(
              summary: DayNutritionSummary(
                profile: const UserProfile(
                  proteinGoalG: 130,
                  carbsGoalG: 240,
                  fatGoalG: 0,
                ),
                burnedKcal: 0,
                consumed: const MacroProgress(
                  proteinG: 160,
                  carbsG: 0,
                  fatG: 20,
                  kcal: 500,
                ),
              ),
            ),
          ),
          brightness: brightness,
          surfaceSize: const Size(320, 852),
          textScale: 2,
          padding: const EdgeInsets.all(20),
          settle: true,
        );
        expect(tester.takeException(), isNull);
        final bars = tester.widgetList<LinearProgressIndicator>(
          find.byType(LinearProgressIndicator),
        );
        expect(bars.map((bar) => bar.value).toList(), [1.0, 0.0, 0.0]);
        final protein = find.bySemanticsLabel('Protein');
        expect(
          tester.getSemantics(protein).value,
          '160 von 130 Gramm, 30 g drüber',
        );
        expect(find.text('160'), findsOneWidget);
        expect(find.text('/130 g'), findsOneWidget);
        semantics.dispose();
      },
    );
  }

  for (final (eaten, burned, goal, expected, remaining) in [
    (1210, 320, 2100, .5, '1.210'),
    (0, 0, 2100, 0.0, '2.100'),
    (2600, 0, 2100, 1.0, '500'),
    (10, 0, 0, 1.0, '9'),
  ]) {
    testWidgets(
      'calorie arc uses the activity-adjusted budget: $eaten/$goal+$burned',
      (tester) async {
        await pumpLocalized(
          tester,
          SingleChildScrollView(
            child: TodayCalorieCard(
              summary: DayNutritionSummary(
                profile: UserProfile(dailyKcalGoal: goal),
                burnedKcal: burned,
                consumed: MacroProgress(
                  proteinG: 0,
                  carbsG: 0,
                  fatG: 0,
                  kcal: eaten,
                ),
              ),
            ),
          ),
          settle: true,
        );
        expect(
          tester.widget<TodayCalorieArc>(find.byType(TodayCalorieArc)).progress,
          expected,
        );
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('today-kcal-remaining')))
              .data,
          remaining,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
