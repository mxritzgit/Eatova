// The weekly check's offset on the goals screen (docs/WEIGHT-TREND.md,
// stage 2): visible in live mode, part of the computed goals, resettable.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/settings/goals_screen.dart';
import 'package:eatova/src/screens/settings/settings_plan_hero.dart';
import 'package:eatova/src/services/kcal_calculator.dart';
import 'package:eatova/src/widgets/shared/settings_sheet.dart';

import '../support/harness.dart';

/// Male, 182 cm, light, −0.5 kg/week: 2100 kcal, 1950 with −150.
UserProfile _profile({int adjustment = -150, bool manual = false}) =>
    const KcalCalculator().applyLiveGoals(
      UserProfile(
        weightKg: 84,
        heightCm: 182,
        ageYears: 31,
        sex: BiologicalSex.male,
        activityLevel: ActivityLevel.light,
        targetWeightKg: 76,
        weightGoal: WeightGoal.lose05kg,
        onboardingCompleted: true,
        manualEnergy: manual,
        energyAdjustmentKcal: adjustment,
      ),
    );

Future<Future<SettingsResult?>> _open(
  WidgetTester tester,
  UserProfile profile,
) async {
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
                builder: (_) => GoalsScreen(profile: profile),
              ),
            );
          },
          child: const Text('open'),
        ),
      ),
    ),
    safeArea: false,
  );
  await tester.tap(find.byKey(const ValueKey('open-goals')));
  await tester.pumpAndSettle();
  return result;
}

int _heroKcal(WidgetTester tester) =>
    tester.widget<SettingsPlanHero>(find.byType(SettingsPlanHero)).kcal;

final Finder _row = find.byKey(const ValueKey('settings-energy-adjustment'));

void main() {
  testWidgets('live mode shows the offset, and the goal includes it', (
    tester,
  ) async {
    await _open(tester, _profile());
    await tester.ensureVisible(_row);
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: _row, matching: find.text('−150 kcal')),
      findsOneWidget,
    );
    expect(_heroKcal(tester), 1950);
  });

  testWidgets('reset brings the plain goal back and saves offset 0', (
    tester,
  ) async {
    final result = await _open(tester, _profile());
    final reset = find.byKey(
      const ValueKey('settings-energy-adjustment-reset'),
    );
    await tester.ensureVisible(reset);
    await tester.pumpAndSettle();
    await tester.tap(reset);
    await tester.pumpAndSettle();
    expect(_row, findsNothing);
    expect(_heroKcal(tester), 2100);

    final save = find.byKey(const ValueKey('settings-save'));
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();
    final saved = (await result)!.profile;
    expect(saved.energyAdjustmentKcal, 0);
    expect(saved.dailyKcalGoal, 2100);
  });

  testWidgets('a reset is an unsaved change: leaving asks first', (
    tester,
  ) async {
    await _open(tester, _profile());
    final reset = find.byKey(
      const ValueKey('settings-energy-adjustment-reset'),
    );
    await tester.ensureVisible(reset);
    await tester.pumpAndSettle();
    await tester.tap(reset);
    await tester.pumpAndSettle();
    // System back: the same PopScope path as the page's own back button.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('discard-changes-dialog')), findsOneWidget);
  });

  // The first layout put value and reset button side by side and overflowed
  // by 15 px at phone width; this pins the stacked layout at 2x text too.
  renderMatrix(
    'the offset row fits at phone width and 2x text',
    (tester, c) async {
      pinPhoneViewport(tester);
      await c.pump(
        tester,
        GoalsScreen(profile: _profile()),
        scaffold: false,
        safeArea: false,
      );
      await tester.ensureVisible(_row);
      await tester.pumpAndSettle();
      expect(_row, findsOneWidget);
    },
    locales: const [Locale('de'), Locale('en')],
    textScales: const [1.0, 2.0],
  );

  testWidgets('no offset or manual mode: no row', (tester) async {
    await _open(tester, _profile(adjustment: 0));
    expect(_row, findsNothing);
  });

  testWidgets('manual mode keeps its own goals and hides the row', (
    tester,
  ) async {
    await _open(tester, _profile(manual: true));
    expect(_row, findsNothing);
  });
}
