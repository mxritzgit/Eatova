// Today's weight chip in the real shell (docs/WEIGHT-TREND.md, stage 2): a
// weigh-in through the chip goes through the store, and the weekly check's
// progress line and the chip follow it; answering the card brings the line
// back with the pause.

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/models/weight_log.dart';
import 'package:eatova/src/screens/today/today_energy_check.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/kcal_calculator.dart';

import '../support/design_capture.dart' show pinDesignViewport;
import '../support/harness.dart';
import '../support/today_design_fixture.dart' show designMeal;
import 'flow_test_helpers.dart' show storeOf;

/// Noon on Saturday, 3 October; the check's window is 12 Sep .. 2 Oct.
final DateTime _now = DateTime(2026, 10, 3, 12);

/// Male, 182 cm, light, −0.5 kg/week: goal 2100 kcal.
final UserProfile _live = const KcalCalculator().applyLiveGoals(
  const UserProfile(
    weightKg: 84,
    heightCm: 182,
    ageYears: 31,
    sex: BiologicalSex.male,
    activityLevel: ActivityLevel.light,
    targetWeightKg: 70,
    weightGoal: WeightGoal.lose05kg,
    onboardingCompleted: true,
  ),
);

DateTime _daysAgo(int n, {int hour = 12, DateTime? now}) {
  final t = now ?? _now;
  return DateTime(t.year, t.month, t.day - n, hour);
}

/// The real shell without a backend or step source, with 21 logged days of
/// [kcal] and weigh-ins on [weighInDaysAgo] moving [kgPerDay] (by default
/// 2100 kcal while losing 0.02 kg a day).
Future<HomeStore> _pumpShell(
  WidgetTester tester,
  List<int> weighInDaysAgo, {
  DateTime? now,
  int kcal = 2100,
  double kgPerDay = -0.02,
}) async {
  pinDesignViewport(tester);
  await tester.pumpWidget(
    localizedApp(
      EatovaHomePage(healthService: const NoopHealthService()),
      safeArea: false,
      scaffold: false,
    ),
  );
  await tester.pumpAndSettle();
  final store = storeOf(tester);
  store
    ..profile = _live
    ..loggedMeals = <LoggedMeal>[
      for (var n = 1; n <= 21; n++)
        designMeal(
          'm$n',
          'Essen',
          MealSlot.lunch,
          _daysAgo(n, now: now),
          kcal: kcal,
        ),
    ]
    ..weightLog = WeightLog.capped([
      for (final n in weighInDaysAgo)
        WeightLogEntry(
          timestamp: _daysAgo(n, hour: 7, now: now),
          weightKg: 84 + kgPerDay * (21 - n),
        ),
    ]);
  store.setTab(0);
  await tester.pumpAndSettle();
  return store;
}

String _text(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(ValueKey<String>(key))).data!;

Future<void> _tap(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey<String>(key));
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a weigh-in through the chip updates the chip and the line', (
    tester,
  ) async {
    await withClock(Clock.fixed(_now), () async {
      final store = await _pumpShell(tester, [20, 14, 1]);
      // Yesterday's weigh-in: 84 − 0.02 × 20.
      expect(_text(tester, 'today-weigh-value'), '83,6 kg');
      expect(
        _text(tester, 'today-weigh-progress'),
        'Wochen-Check frühestens morgen · noch 1 Wiegung',
      );

      await _tap(tester, 'today-weigh-chip');
      await tester.enterText(
        find.byKey(const ValueKey('profile-weight-input')),
        '82,9',
      );
      await tester.pump();
      await _tap(tester, 'profile-weight-save');

      expect(store.weightLog.latest!.weightKg, 82.9);
      expect(find.byKey(const ValueKey('profile-weight-input')), findsNothing);
      expect(_text(tester, 'today-weigh-value'), '82,9 kg');
      // Today's weigh-in counts from tomorrow's window on.
      expect(
        _text(tester, 'today-weigh-progress'),
        'Wochen-Check frühestens morgen',
      );
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('the card replaces the line; "not now" brings it back with '
      'the pause', (tester) async {
    await withClock(Clock.fixed(_now), () async {
      await _pumpShell(tester, [for (var n = 1; n <= 21; n++) n]);
      expect(find.byType(TodayEnergyCheckCard), findsOneWidget);
      expect(find.byKey(const ValueKey('today-weigh-chip')), findsOneWidget);
      expect(find.byKey(const ValueKey('today-weigh-progress')), findsNothing);

      await _tap(tester, 'today-energy-check-dismiss');

      expect(find.byType(TodayEnergyCheckCard), findsNothing);
      // In seven days the window keeps the weigh-ins of the last 14 days,
      // 13 days apart: one more is needed.
      expect(
        _text(tester, 'today-weigh-progress'),
        'Wochen-Check frühestens in 7 Tagen · noch 1 Wiegung',
      );
    });
  });

  testWidgets('"Verstanden" takes the result of the week off Today', (
    tester,
  ) async {
    // Monday 5 October: 2700 kcal at a steady weight fit the 2650 modelled,
    // so the check shows its result instead of a proposal.
    final monday = DateTime(2026, 10, 5, 12);
    await withClock(Clock.fixed(monday), () async {
      await _pumpShell(
        tester,
        [for (var n = 1; n <= 21; n++) n],
        now: monday,
        kcal: 2700,
        kgPerDay: 0,
      );
      expect(find.byKey(const ValueKey('today-weekly-result')), findsOneWidget);

      await _tap(tester, 'today-weekly-result-seen');

      expect(find.byKey(const ValueKey('today-weekly-result')), findsNothing);
    });
  });
}
