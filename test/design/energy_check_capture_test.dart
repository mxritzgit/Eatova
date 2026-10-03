// Visual evidence for the weekly energy check (docs/WEIGHT-TREND.md, stage 2):
// the Today card in both directions and the offset row on the goals screen.
//
// With --dart-define=DARK_REDESIGN_CAPTURE=true the PNGs land in
// build/dark-redesign/energy-check-*.png; without it the suite still checks
// that both render without an exception or overflow.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/settings/goals_screen.dart';
import 'package:eatova/src/screens/today/today_energy_check.dart';
import 'package:eatova/src/services/energy_check.dart';
import 'package:eatova/src/services/kcal_calculator.dart';

import '../support/design_capture.dart';
import '../support/harness.dart';

const EnergyCheckProposal _lower = EnergyCheckProposal(
  stepKcal: -150,
  newAdjustmentKcal: -150,
  currentGoalKcal: 2100,
  newGoalKcal: 1950,
  observedKcal: 2454,
  modelledKcal: 2850,
  weeklyRateKg: -0.14,
  loggedDays: 19,
  weighInDays: 8,
);

Future<void> _pump(WidgetTester tester, Widget child, Locale locale) async {
  pinDesignViewport(tester);
  await tester.pumpWidget(
    designCaptureBoundary(
      localizedApp(
        child,
        locale: locale,
        safeArea: false,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadDesignFonts);

  for (final locale in const [Locale('de'), Locale('en')]) {
    testWidgets('today card ${locale.languageCode}', (tester) async {
      await _pump(
        tester,
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 90, 20, 0),
          child: TodayEnergyCheckCard(
            proposal: _lower,
            onAccept: () async {},
            onDismiss: () async {},
          ),
        ),
        locale,
      );
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'energy-check-card-${locale.languageCode}');
    });
  }

  testWidgets('goals offset row', (tester) async {
    final profile = const KcalCalculator().applyLiveGoals(
      const UserProfile(
        weightKg: 84,
        heightCm: 182,
        ageYears: 31,
        sex: BiologicalSex.male,
        activityLevel: ActivityLevel.light,
        targetWeightKg: 76,
        weightGoal: WeightGoal.lose05kg,
        onboardingCompleted: true,
        energyAdjustmentKcal: -150,
      ),
    );
    await _pump(tester, GoalsScreen(profile: profile), const Locale('de'));
    final row = find.byKey(const ValueKey('settings-energy-adjustment'));
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await scrollDesignTabBy(tester, 200);
    expect(tester.takeException(), isNull);
    await captureDesignShot(tester, 'energy-check-goals');
  });
}
