import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/settings/goals_screen.dart';
import 'package:eatova/src/services/kcal_calculator.dart';

import 'support/harness.dart';

// B2 — the goals page promised the CHOSEN pace although the 1 % deficit cap
// and the safety floor change the daily target ("maintenance 1997 · −1
// kg/week" above "1200", which is −0.72 kg/week), and showed two different
// pace strings (plan hero vs. weight-goal row) with nothing explaining them.
//
// Rule under test: if a screen shows more than one pace string, a third must
// connect them. The chosen pace stays on the control (it is the selection,
// not the promise); what it turns into is stated in the line right below it
// and in each option's subtitle.
//
// Numbers per the calorie review 2026-08-21 (PAL ladder without walking
// 1.3/1.45/1.6/1.75/1.9, 1 % deficit cap kg × 11 kcal/day rounded down to
// 0.05 kg/week, sex-dependent floor, pace labels on the 0.05 grid): default
// profile 78 kg / 178 cm / 30 y / neutral / sedentary -> BMR 1665,
// maintenance 2164, cap 858 -> 825 kcal/day, floor 1350.
void main() {
  /// Profile whose stored energy goals match the calculation exactly; only
  /// then does the screen start in live mode (manual switch off).
  UserProfile autoProfil(
    WeightGoal goal, {
    UserProfile basis = const UserProfile(),
  }) {
    // Ein Wunschgewicht, das zur Richtung passt. Seit P9-08e faellt eine
    // Richtung ohne Rest-Weg (Ziel == Gewicht, wie im Standardprofil) auf
    // "Halten" zurueck — diese Suite misst aber genau die Defizit-Plaene.
    final p = basis.copyWith(
      weightGoal: goal,
      targetWeightKg: goal.isGain ? basis.weightKg + 8 : basis.weightKg - 8,
    );
    final t = const KcalCalculator().calculate(p);
    return p.copyWith(
      dailyKcalGoal: t.kcal,
      proteinGoalG: t.proteinG,
      carbsGoalG: t.carbsG,
      fatGoalG: t.fatG,
    );
  }

  /// Profile where cap AND floor both bite: 55 kg / 160 cm / 35 y / female /
  /// sedentary -> BMR 1214, maintenance 1578, cap 605 kcal/day, floor 1200.
  /// All three deficit paces clamp up to 1200, i.e. -378 kcal/day ≙
  /// -0.35 kg/week.
  const klemmProfil = UserProfile(
    weightKg: 55,
    heightCm: 160,
    ageYears: 35,
    sex: BiologicalSex.female,
    targetWeightKg: 55,
  );

  Future<void> openSettings(
    WidgetTester tester, {
    required UserProfile profile,
  }) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final prior = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception.toString().contains('overflowed')) return;
      prior?.call(details);
    };
    addTearDown(() => FlutterError.onError = prior);

    await pumpLocalized(
      tester,
      Builder(
        builder: (context) => Center(
          child: FilledButton(
            key: const ValueKey('open-settings'),
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => GoalsScreen(profile: profile),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
      brightness: Brightness.light,
    );
    await tester.tap(find.byKey(const ValueKey('open-settings')));
    await tester.pumpAndSettle();
  }

  /// Opens the weight-goal picker sheet. The row sits far down the scroll, so
  /// without [WidgetController.ensureVisible] the tap misses.
  Future<void> openGoalPicker(WidgetTester tester) async {
    await tester.ensureVisible(find.byKey(const ValueKey('settings-weight-goal')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-weight-goal')));
    await tester.pumpAndSettle();
  }

  /// An option's subtitle, searched inside its own row so the identical line
  /// below the field does not count.
  Finder optionText(String goalName, String text) => find.descendant(
        of: find.byKey(ValueKey('settings-weight-goal-$goalName')),
        matching: find.text(text),
      );

  testWidgets(
      'Plan-Karte, Deckel-Satz und Gewichtsziel-Zeile nennen das effektive '
      'Tempo', (tester) async {
    await openSettings(tester, profile: autoProfil(WeightGoal.lose1kg));

    // Plan card in the same scroll: the 1 % cap allows only -825 instead of
    // -1100 kcal/day -> 1350 kcal (exactly on the floor); 2164 - 1350 = 814
    // ≙ -0.74 -> -0.75 kg/week on the grid. The chosen pace is not promised.
    expect(find.text('Erhaltung 2.164 · −0,75 kg/Woche'), findsOneWidget);
    expect(find.text('Erhaltung 2.164 · −1 kg/Woche'), findsNothing);
    // The hero number carries the thousands separator like Today and Food.
    expect(find.text('1.350'), findsOneWidget);

    // The floor does not bind — the target lands exactly ON it and
    // `floorApplied` needs a real undershoot. The cap sentence names the
    // deficit the plan runs after rounding (814), as the onboarding does.
    expect(find.byKey(const ValueKey('settings-pace-warning')), findsOneWidget);
    expect(
      find.text(
        'Schneller als 1 % deines Körpergewichts pro Woche empfehlen wir '
        'nicht: Dein Defizit ist auf 814 kcal/Tag begrenzt. Dein tatsächliches '
        'Tempo ist damit −0,75 kg/Woche statt −1 kg/Woche.',
      ),
      findsOneWidget,
    );

    // The control still shows the selection, or the user would see something
    // other than what they tapped.
    expect(find.text('−1 kg/Woche'), findsOneWidget);

    // …and right below it the line connecting both numbers.
    expect(
      find.byKey(const ValueKey('settings-weight-goal-effective')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('settings-weight-goal-effective')),
          )
          .data,
      'Ergibt 1.350 kcal/Tag · −0,75 kg/Woche',
    );
  });

  testWidgets(
      'ohne abweichendes Tempo bleibt die Zeile ohne Zusatzzeile',
      (tester) async {
    // -0.75 kg/week: maintenance 2164, goal 1350, real -814 kcal ≙ -0.74 ->
    // -0.75 on the grid. Promise and plan carry the same label, so an
    // explaining line would be noise.
    await openSettings(tester, profile: autoProfil(WeightGoal.lose075kg));

    expect(find.text('Erhaltung 2.164 · −0,75 kg/Woche'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('settings-weight-goal-effective')),
      findsNothing,
    );
  });

  testWidgets('ohne Klemme bleibt die Plan-Karte ohne Hinweis', (tester) async {
    await openSettings(tester, profile: autoProfil(WeightGoal.maintain));

    // 2163.85 → 2150 kcal; −14 kcal/day is inside the 0.05 noise band.
    expect(find.byKey(const ValueKey('settings-pace-warning')), findsNothing);
    expect(find.text('Erhaltung 2.164 · Gewicht stabil'), findsOneWidget);
  });

  testWidgets(
      'die 50er-Rundung allein loest keine Zusatzzeile mehr aus',
      (tester) async {
    // -0.5 kg/week yields 1600 kcal, i.e. -564 kcal/day ≙ -0.5127 kg/week:
    // the 50-kcal rounding pushes the pace slightly OVER the promise. Since
    // the pace label snaps to 0.05 it reads "-0,5" either way, so the extra
    // line (which compares strings, not numbers) stays away.
    await openSettings(tester, profile: autoProfil(WeightGoal.lose05kg));

    expect(find.text('Erhaltung 2.164 · −0,5 kg/Woche'), findsOneWidget);
    expect(find.text('−0,5 kg/Woche'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('settings-weight-goal-effective')),
      findsNothing,
    );
  });

  testWidgets(
      'jede Option im Ziel-Picker nennt den Plan, den sie ergibt',
      (tester) async {
    await openSettings(tester, profile: autoProfil(WeightGoal.lose1kg));
    await openGoalPicker(tester);

    // The most ambitious pace is capped at -825 for this profile and lands on
    // the same plan as the next one down (both 1350 kcal); the subtitle says
    // so BEFORE the selection.
    expect(
      optionText('lose1kg', 'Ergibt 1.350 kcal/Tag · −0,75 kg/Woche'),
      findsOneWidget,
    );
    expect(
      optionText('lose075kg', 'Ergibt 1.350 kcal/Tag · −0,75 kg/Woche'),
      findsOneWidget,
    );

    // Where neither cap nor clamp bites, the same line carries a different
    // number; the 50-kcal rounding vanishes in the label's 0.05 grid.
    expect(
      optionText('lose05kg', 'Ergibt 1.600 kcal/Tag · −0,5 kg/Woche'),
      findsOneWidget,
    );
    expect(
      optionText('maintain', 'Ergibt 2.150 kcal/Tag · Gewicht stabil'),
      findsOneWidget,
    );

    // The uncapped kcal promise (WeightGoal.deltaLabel) is gone.
    expect(find.text('−1.100 kcal'), findsNothing);
    expect(find.text('−825 kcal'), findsNothing);
  });

  testWidgets(
      'in der Klemme nennen Plan-Karte und drei Optionen denselben Plan',
      (tester) async {
    await openSettings(
      tester,
      profile: autoProfil(WeightGoal.lose1kg, basis: klemmProfil),
    );

    // Plan card: maintenance 1578, target 1200 (raised from 950) →
    // −0.35 kg/week. The floor binds harder than the cap, so the sentence
    // names the floor.
    expect(find.text('Erhaltung 1.578 · −0,35 kg/Woche'), findsOneWidget);
    expect(
      find.text(
        'Aus Sicherheitsgründen liegt dein Tagesziel bei 1.200 kcal statt '
        '950 kcal. Dein tatsächliches Tempo ist damit −0,35 kg/Woche statt '
        '−1 kg/Woche.',
      ),
      findsOneWidget,
    );

    await openGoalPicker(tester);

    // All three deficit paces land on 1200 kcal for this profile (cap 605,
    // floor 1200; 1578 - 1200 = 378 ≙ -0.35 kg/week) — the subtitles say so
    // verbatim before the selection.
    expect(
      optionText('lose1kg', 'Ergibt 1.200 kcal/Tag · −0,35 kg/Woche'),
      findsOneWidget,
    );
    expect(
      optionText('lose075kg', 'Ergibt 1.200 kcal/Tag · −0,35 kg/Woche'),
      findsOneWidget,
    );
    expect(
      optionText('lose05kg', 'Ergibt 1.200 kcal/Tag · −0,35 kg/Woche'),
      findsOneWidget,
    );
  });

  testWidgets(
      'Manuell-Modus: das Tempo folgt dem eigenen Tagesziel, der Picker '
      'sagt, dass er es nicht bewegt',
      (tester) async {
    // Default profile with 2500 kcal stored and the persisted manual flag
    // (F7-01) starts the screen in manual mode, where the daily goal no
    // longer follows the pace.
    //
    // Deliberately not the 2200 default: +36 kcal/day over maintenance stays
    // below the 0.05 noise floor, so there would be no extra line to check.
    await openSettings(
      tester,
      profile: const UserProfile()
          .copyWith(dailyKcalGoal: 2500, manualEnergy: true),
    );

    // Goal "maintain", but 2500 kcal over a maintenance of 2164:
    // +336 kcal/day ≙ +0.305 kg/week, "+0,3 kg/Woche" on the 0.05 grid —
    // on the plan card and below the goal row.
    expect(find.text('Erhaltung 2.164 · +0,3 kg/Woche'), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-pace-warning')), findsNothing);
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('settings-weight-goal-effective')),
          )
          .data,
      'Ergibt 2.500 kcal/Tag · +0,3 kg/Woche',
    );

    await openGoalPicker(tester);
    expect(
      find.text('Ändert dein manuelles Tagesziel nicht'),
      findsNWidgets(WeightGoal.values.length),
    );
  });
}
