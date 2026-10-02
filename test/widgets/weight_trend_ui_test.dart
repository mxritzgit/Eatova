// One current weight on screen (docs/WEIGHT-TREND.md): the plan card's
// "current" pole, the weight card's trend line and goal progress, the BMI and
// the goals screen all read the weight trend. The weight card's big number
// stays the latest weigh-in, which is what the user typed.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/models/weight_log.dart';
import 'package:eatova/src/screens/settings/goals_screen.dart';
import 'package:eatova/src/widgets/profile/profile_widgets.dart';
import 'package:eatova/src/widgets/shared/settings_sheet.dart';

import '../support/harness.dart';

const UserProfile _profile = UserProfile(
  weightKg: 84,
  heightCm: 182,
  ageYears: 31,
  sex: BiologicalSex.male,
  activityLevel: ActivityLevel.light,
  targetWeightKg: 76,
  weightGoal: WeightGoal.lose05kg,
  onboardingCompleted: true,
);

/// 80 kg, then 82 kg the next day: 2.5 % off, so smoothed to a trend of
/// 80.2 kg while the latest weigh-in reads 82.
final WeightLog _log = WeightLog.capped([
  WeightLogEntry(timestamp: DateTime(2026, 9, 30, 7), weightKg: 80),
  WeightLogEntry(timestamp: DateTime(2026, 10, 1, 7), weightKg: 82),
]);

Future<void> _pump(WidgetTester tester, Widget child) => pumpLocalized(
  tester,
  SingleChildScrollView(child: child),
  surfaceSize: const Size(390, 1600),
);

void main() {
  test('precondition: trend 80.2, latest 82', () {
    expect(_log.trendKg, closeTo(80.2, 1e-9));
    expect(_log.latest!.weightKg, 82);
  });

  group('plan card', () {
    testWidgets('the current pole shows the trend', (tester) async {
      await _pump(
        tester,
        GoalPlanCard(profile: _profile, currentWeightKg: _log.trendKg),
      );
      expect(find.text('80,2'), findsOneWidget);
      expect(find.text('84'), findsNothing);
      // Gap and forecast come from the same weight: 80 → 76, not 84 → 76.
      expect(find.textContaining('Noch 4 kg'), findsOneWidget);
    });

    testWidgets('without weigh-ins the profile weight stands in', (
      tester,
    ) async {
      await _pump(tester, const GoalPlanCard(profile: _profile));
      expect(find.text('84'), findsOneWidget);
    });
  });

  group('weight card', () {
    testWidgets('the big number is the latest weigh-in, the trend below it', (
      tester,
    ) async {
      await _pump(
        tester,
        WeightCard(profile: _profile, log: _log, onLogWeight: (_) {}),
      );
      // The 40 pt display number; the chart caption repeats the value small.
      final big = tester
          .widgetList<Text>(find.text('82'))
          .where((text) => text.style?.fontSize == 40);
      expect(big, hasLength(1));
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('profile-weight-trend')))
            .data,
        'Trend 80,2 kg',
      );
    });

    testWidgets('one weigh-in has no separate trend line', (tester) async {
      await _pump(
        tester,
        WeightCard(
          profile: _profile,
          log: WeightLog.capped([_log.entries.first]),
          onLogWeight: (_) {},
        ),
      );
      expect(find.byKey(const ValueKey('profile-weight-trend')), findsNothing);
    });

    testWidgets('goal progress counts from baseline to the trend', (
      tester,
    ) async {
      // Baseline 80, target 76: the trend (about 79.06) reads 23 %, the
      // latest weigh-in (79.4) would read 15 %.
      final log = WeightLog.capped([
        WeightLogEntry(timestamp: DateTime(2026, 9, 1, 7), weightKg: 80),
        WeightLogEntry(timestamp: DateTime(2026, 9, 11, 7), weightKg: 78.5),
        WeightLogEntry(timestamp: DateTime(2026, 9, 12, 7), weightKg: 79.4),
      ]);
      final trend = log.trendKg!;
      expect(trend, lessThan(80), reason: 'precondition');
      await _pump(
        tester,
        WeightCard(profile: _profile, log: log, onLogWeight: (_) {}),
      );
      final expected = ((80 - trend) / (80 - 76) * 100).round();
      expect(expected, greaterThan(0), reason: 'precondition');
      expect(
        find.byWidgetPredicate(
          (w) => w is Semantics && w.properties.value == '$expected %',
        ),
        findsOneWidget,
      );
    });
  });

  testWidgets('BMI uses the trend, not the latest weigh-in', (tester) async {
    await _pump(tester, BmiCard(profile: _profile, log: _log));
    // 80.2 / 1.82² = 24.2; the latest 82 kg would read 24.8.
    expect(find.text('24,2'), findsOneWidget);
    expect(find.text('24,8'), findsNothing);
  });

  group('goals screen', () {
    Future<Future<SettingsResult?>> open(
      WidgetTester tester, {
      double? trend,
    }) async {
      pinPhoneViewport(tester);
      late Future<SettingsResult?> result;
      await pumpLocalized(
        tester,
        Builder(
          builder: (context) => Center(
            child: FilledButton(
              key: const ValueKey('open-goals'),
              onPressed: () {
                result = Navigator.of(context).push<SettingsResult>(
                  MaterialPageRoute<SettingsResult>(
                    builder: (_) =>
                        GoalsScreen(profile: _profile, weightTrendKg: trend),
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
        scaffold: true,
        safeArea: false,
      );
      await tester.tap(find.byKey(const ValueKey('open-goals')));
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets('with weigh-ins the weight is the read-only trend', (
      tester,
    ) async {
      final result = await open(tester, trend: 81.6);
      expect(find.byKey(const ValueKey('settings-weight')), findsNothing);
      final row = find.byKey(const ValueKey('settings-weight-trend'));
      expect(row, findsOneWidget);
      expect(
        find.descendant(of: row, matching: find.text('81,6 kg')),
        findsOneWidget,
      );

      // Any save carries the rounded trend, the value the store re-anchors to.
      final steps = find.byKey(const ValueKey('settings-steps-goal'));
      await tester.ensureVisible(steps);
      await tester.pumpAndSettle();
      await tester.enterText(steps, '9000');
      await tester.pumpAndSettle();
      final save = find.byKey(const ValueKey('settings-save'));
      await tester.ensureVisible(save);
      await tester.pumpAndSettle();
      await tester.tap(save);
      await tester.pumpAndSettle();
      final saved = await result;
      expect(saved!.profile.weightKg, 82);
      expect(saved.profile.dailyStepsGoal, 9000);
    });

    testWidgets('without weigh-ins the weight stays editable', (tester) async {
      await open(tester);
      expect(find.byKey(const ValueKey('settings-weight')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('settings-weight-trend')),
        findsNothing,
      );
    });
  });
}
