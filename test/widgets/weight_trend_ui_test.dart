// One current weight on screen (docs/WEIGHT-TREND.md): the plan card's
// trend pole, the weight card's trend line and goal progress, the BMI and
// the goals screen all read the weight trend. The weight card's big number
// stays the latest weigh-in, which is what the user typed; the plan card and
// the goals row name it when it differs.

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/lifetime_stats.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/models/weight_log.dart';
import 'package:eatova/src/screens/profile_screen.dart';
import 'package:eatova/src/screens/settings/goals_screen.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/kcal_calculator.dart';
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

/// The trend counts only while the latest weigh-in is at most 28 days old,
/// so every case runs at this fixed "now".
final DateTime _now = DateTime(2026, 10, 3, 12);

void _testAt(String description, WidgetTesterCallback body) => testWidgets(
  description,
  (tester) => withClock(Clock.fixed(_now), () => body(tester)),
);

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
    _testAt('the current pole shows the trend', (tester) async {
      await _pump(
        tester,
        GoalPlanCard(profile: _profile, currentWeightKg: _log.trendKg),
      );
      expect(find.text('80,2'), findsOneWidget);
      expect(find.text('84'), findsNothing);
      // Gap and forecast come from the same weight: 80 → 76, not 84 → 76.
      expect(find.textContaining('Noch 4 kg'), findsOneWidget);
    });

    _testAt('without weigh-ins the profile weight stands in', (
      tester,
    ) async {
      await _pump(tester, const GoalPlanCard(profile: _profile));
      expect(find.text('84'), findsOneWidget);
    });
  });

  // Owner report 2026-10-04: logged 117 kg, the plan card said "Current
  // 119.1". The pole shows the trend on purpose, so it has to SAY trend and
  // name the weigh-in it differs from.
  group('plan card labels the trend', () {
    Widget profileWith(WeightLog log) => ProfileScreen(
      name: 'Moritz',
      profile: _profile,
      weightLog: log,
      stats: LifetimeStats(sessionStart: _now),
      dailyConsumedKcal: 0,
      dailySteps: null,
      healthAuthState: HealthAuthState.unknown,
      healthLastFetch: null,
      onLogWeight: (_) {},
      onEditProfile: () {},
      onOpenSettings: () {},
      onConnectHealth: () {},
      onRefreshHealth: () {},
    );

    Finder inPlan(String text) => find.descendant(
      of: find.byType(GoalPlanCard),
      matching: find.text(text),
    );

    Future<void> pumpProfile(WidgetTester tester, WeightLog log) =>
        pumpLocalized(
          tester,
          profileWith(log),
          surfaceSize: const Size(390, 3200),
          scaffold: false,
          safeArea: false,
          settle: true,
        );

    _testAt('the pole reads Trend, with the last weigh-in under it', (
      tester,
    ) async {
      await pumpProfile(tester, _log);
      expect(inPlan('80,2'), findsOneWidget);
      expect(inPlan('TREND'), findsOneWidget);
      expect(inPlan('AKTUELL'), findsNothing);
      expect(inPlan('Zuletzt gewogen 82 kg'), findsOneWidget);
    });

    _testAt('no caption when the last weigh-in reads like the trend', (
      tester,
    ) async {
      final log = WeightLog.capped([
        WeightLogEntry(timestamp: DateTime(2026, 10, 1, 7), weightKg: 80),
      ]);
      await pumpProfile(tester, log);
      expect(inPlan('TREND'), findsOneWidget);
      expect(find.textContaining('Zuletzt gewogen'), findsNothing);
    });

    _testAt('without a trend the profile weight keeps "Aktuell"', (
      tester,
    ) async {
      await pumpProfile(tester, const WeightLog());
      expect(inPlan('84'), findsOneWidget);
      expect(inPlan('AKTUELL'), findsOneWidget);
      expect(inPlan('TREND'), findsNothing);
    });
  });

  group('weight card', () {
    _testAt('the big number is the latest weigh-in, the trend below it', (
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

    _testAt('stale weigh-ins show no trend line', (tester) async {
      // The latest weigh-in is two months old: the plan uses the profile
      // weight, and the card does not pretend to know a current trend.
      await _pump(
        tester,
        WeightCard(
          profile: _profile,
          log: WeightLog.capped([
            WeightLogEntry(timestamp: DateTime(2026, 7, 30, 7), weightKg: 80),
            WeightLogEntry(timestamp: DateTime(2026, 7, 31, 7), weightKg: 82),
          ]),
          onLogWeight: (_) {},
        ),
      );
      expect(find.byKey(const ValueKey('profile-weight-trend')), findsNothing);
    });

    _testAt('one weigh-in has no separate trend line', (tester) async {
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

    _testAt('goal progress counts from baseline to the trend', (
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

  _testAt('BMI uses the trend, not the latest weigh-in', (tester) async {
    await _pump(tester, BmiCard(profile: _profile, log: _log));
    // 80.2 / 1.82² = 24.2; the latest 82 kg would read 24.8.
    expect(find.text('24,2'), findsOneWidget);
    expect(find.text('24,8'), findsNothing);
  });

  group('goals screen', () {
    Future<Future<SettingsResult?>> open(
      WidgetTester tester, {
      double? trend,
      double? latest,
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
                    builder: (_) => GoalsScreen(
                      profile: _profile,
                      weightTrendKg: trend,
                      latestWeighInKg: latest,
                    ),
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

    _testAt('with weigh-ins the weight is the read-only trend', (
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

    _testAt('the trend row says trend and names the last weigh-in', (
      tester,
    ) async {
      await open(tester, trend: 80.2, latest: 82);
      final row = find.byKey(const ValueKey('settings-weight-trend'));
      expect(
        find.descendant(of: row, matching: find.text('Gewichtstrend')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: row,
          matching: find.textContaining('Zuletzt gewogen 82 kg'),
        ),
        findsOneWidget,
      );
    });

    _testAt('a last weigh-in that reads like the trend is not repeated', (
      tester,
    ) async {
      await open(tester, trend: 82.04, latest: 82);
      expect(find.textContaining('Zuletzt gewogen'), findsNothing);
    });

    _testAt('switching to manual starts from the trend-based goals', (
      tester,
    ) async {
      // Profile 84 kg, trend 81.6: the hidden energy fields must come from
      // the same 82 kg as the hero, not from the stale profile weight.
      await open(tester, trend: 81.6);
      final manual = find.byKey(const ValueKey('settings-manual-energy'));
      await tester.ensureVisible(manual);
      await tester.pumpAndSettle();
      await tester.tap(manual);
      await tester.pumpAndSettle();
      final kcal = tester.widget<TextField>(
        find.byKey(const ValueKey('settings-kcal')),
      );
      final at82 = const KcalCalculator().calculate(
        _profile.copyWith(weightKg: 82),
      );
      final at84 = const KcalCalculator().calculate(_profile);
      expect(at82.kcal, isNot(at84.kcal), reason: 'precondition');
      expect(kcal.controller!.text, '${at82.kcal}');
    });

    _testAt('without weigh-ins the weight stays editable', (tester) async {
      await open(tester);
      expect(find.byKey(const ValueKey('settings-weight')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('settings-weight-trend')),
        findsNothing,
      );
    });
  });
}
