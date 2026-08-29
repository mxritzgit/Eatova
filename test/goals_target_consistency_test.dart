import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/settings/goals_screen.dart';
import 'package:eatova/src/widgets/design/design.dart';
import 'package:eatova/src/widgets/shared/settings_sheet.dart';

import 'support/harness.dart';

// P9-08 — the goals page checked the target weight against the DB range
// (30..300) only, never against the chosen weight goal. "Lose weight" with a
// HIGHER target saved happily; the plan card then showed "80 -> 90" under a
// trending_down icon and `home_store` shipped the contradiction to the coach
// model as "Körpergewicht: 80 kg (Ziel 90 kg)" on a deficit plan.
//
// The onboarding has enforced the rule since day one (`_targetMin`/`_targetMax`
// with the explicit "consistency bound, not a range" comment); this suite pins
// the same rule for the settings page.
//
// REJECT, not clamp (model_limits.dart): bending 90 down to 79 would write a
// target weight nobody asked for. "Maintain" stays deliberately free — every
// target near today's weight is plausible there.
void main() {
  /// 80 kg, target 80 kg, goal "maintain" — the consistent starting point.
  const basis = UserProfile(weightKg: 80, targetWeightKg: 80);

  Future<Future<SettingsResult?>> openSettings(
    WidgetTester tester, {
    UserProfile profile = basis,
    Locale locale = const Locale('de'),
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

    late Future<SettingsResult?> result;
    await pumpLocalized(
      tester,
      Builder(
        builder: (context) => Center(
          child: FilledButton(
            key: const ValueKey('open-settings'),
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
      locale: locale,
      brightness: Brightness.light,
    );
    await tester.tap(find.byKey(const ValueKey('open-settings')));
    await tester.pumpAndSettle();
    return result;
  }

  VoidCallback? saveHandler(WidgetTester tester) => tester
      .widget<PrimaryActionButton>(find.byKey(const ValueKey('settings-save')))
      .onTap;

  Future<void> tippe(WidgetTester tester, String key, String text) async {
    await tester.enterText(find.byKey(ValueKey(key)), text);
    await tester.pump();
  }

  /// Picks [goalName] in the weight-goal sheet. The row sits far down the
  /// scroll, so without [WidgetController.ensureVisible] the tap misses.
  Future<void> waehleZiel(WidgetTester tester, String goalName) async {
    await tester
        .ensureVisible(find.byKey(const ValueKey('settings-weight-goal')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-weight-goal')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('settings-weight-goal-$goalName')));
    await tester.pumpAndSettle();
  }

  Future<SettingsResult?> speichere(
    WidgetTester tester,
    Future<SettingsResult?> result,
  ) async {
    await tester.ensureVisible(find.byKey(const ValueKey('settings-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-save')));
    await tester.pumpAndSettle();
    return result;
  }

  const abnehmFehler =
      'Beim Abnehmen muss das Wunschgewicht unter deinem Gewicht (80 kg) '
      'liegen — oder wähle ein anderes Gewichtsziel.';
  const zunehmFehler =
      'Beim Zunehmen muss das Wunschgewicht über deinem Gewicht (80 kg) '
      'liegen — oder wähle ein anderes Gewichtsziel.';

  group('Ziele-Seite: Wunschgewicht und Gewichtsziel', () {
    testWidgets(
        'Abnehmen mit hoeherem Wunschgewicht laesst sich nicht speichern',
        (tester) async {
      // Exactly the reported trigger: target 90 typed at 80 kg, then the goal
      // switched to "Abnehmen · −0,5 kg/Woche".
      await openSettings(tester);
      await tippe(tester, 'settings-target-weight', '90');
      expect(saveHandler(tester), isNotNull,
          reason: '90 kg passt zu "Halten" — erst das Ziel macht es falsch');

      await waehleZiel(tester, 'lose05kg');

      expect(find.text(abnehmFehler), findsOneWidget);
      expect(saveHandler(tester), isNull,
          reason: 'ein Defizit-Plan mit Ziel ueber dem Gewicht darf die App '
              'nicht verlassen');
      expect(
        find.byKey(const ValueKey('settings-validation-note')),
        findsOneWidget,
      );
    });

    testWidgets('Abnehmen auf das aktuelle Gewicht sperrt ebenfalls',
        (tester) async {
      // Same bound as the onboarding (`_targetMax = weight - 1`): losing down
      // to today's weight is no goal, it is "maintain" under another name.
      await openSettings(tester);
      await waehleZiel(tester, 'lose025kg');

      expect(find.text(abnehmFehler), findsOneWidget);
      expect(saveHandler(tester), isNull);
    });

    testWidgets(
        'Zunehmen mit niedrigerem Wunschgewicht laesst sich nicht speichern',
        (tester) async {
      await openSettings(tester);
      await tippe(tester, 'settings-target-weight', '70');
      await waehleZiel(tester, 'gain025kg');

      expect(find.text(zunehmFehler), findsOneWidget);
      expect(saveHandler(tester), isNull);
    });

    testWidgets('passende Abnehm-Kombination bleibt speicherbar',
        (tester) async {
      final resultFuture = await openSettings(tester);
      await tippe(tester, 'settings-target-weight', '72');
      await waehleZiel(tester, 'lose05kg');

      expect(find.text(abnehmFehler), findsNothing);
      expect(saveHandler(tester), isNotNull);

      final result = (await speichere(tester, resultFuture))!.profile;
      expect(result.targetWeightKg, 72);
      expect(result.weightGoal, WeightGoal.lose05kg);
    });

    testWidgets('passende Zunehm-Kombination bleibt speicherbar',
        (tester) async {
      final resultFuture = await openSettings(tester);
      await tippe(tester, 'settings-target-weight', '86');
      await waehleZiel(tester, 'gain05kg');

      expect(find.text(zunehmFehler), findsNothing);
      expect(saveHandler(tester), isNotNull);

      final result = (await speichere(tester, resultFuture))!.profile;
      expect(result.targetWeightKg, 86);
      expect(result.weightGoal, WeightGoal.gain05kg);
    });

    testWidgets('Halten laesst jedes Wunschgewicht im DB-Bereich zu',
        (tester) async {
      // "Maintain" has no direction, so it cannot contradict a target weight.
      // A stricter rule would lock out saved profiles for nothing.
      final resultFuture = await openSettings(tester);

      await tippe(tester, 'settings-target-weight', '60');
      expect(saveHandler(tester), isNotNull);
      await tippe(tester, 'settings-target-weight', '95');
      expect(saveHandler(tester), isNotNull);
      expect(find.text(abnehmFehler), findsNothing);
      expect(find.text(zunehmFehler), findsNothing);

      final result = (await speichere(tester, resultFuture))!.profile;
      expect(result.targetWeightKg, 95);
      expect(result.weightGoal, WeightGoal.maintain);
    });

    testWidgets(
        'Bestandsprofil mit Widerspruch: das Wunschgewicht loest ihn auf',
        (tester) async {
      // Profiles saved BEFORE this rule existed open straight into the error.
      // The page must show the way out, not lock the user in.
      final resultFuture = await openSettings(
        tester,
        profile: basis.copyWith(
          targetWeightKg: 90,
          weightGoal: WeightGoal.lose05kg,
        ),
      );

      expect(find.text(abnehmFehler), findsOneWidget);
      expect(saveHandler(tester), isNull);

      await tippe(tester, 'settings-target-weight', '75');
      expect(find.text(abnehmFehler), findsNothing);
      expect(saveHandler(tester), isNotNull);

      final result = (await speichere(tester, resultFuture))!.profile;
      expect(result.targetWeightKg, 75);
      expect(result.weightGoal, WeightGoal.lose05kg);
    });

    testWidgets(
        'Bestandsprofil mit Widerspruch: das Gewichtsziel loest ihn auch auf',
        (tester) async {
      final resultFuture = await openSettings(
        tester,
        profile: basis.copyWith(
          targetWeightKg: 70,
          weightGoal: WeightGoal.gain025kg,
        ),
      );

      expect(find.text(zunehmFehler), findsOneWidget);
      expect(saveHandler(tester), isNull);

      // The second way out: keep the target, change the direction.
      await waehleZiel(tester, 'lose05kg');
      expect(find.text(zunehmFehler), findsNothing);
      expect(saveHandler(tester), isNotNull);

      final result = (await speichere(tester, resultFuture))!.profile;
      expect(result.targetWeightKg, 70);
      expect(result.weightGoal, WeightGoal.lose05kg);
    });

    testWidgets(
        'ungueltiges Gewicht erzeugt keinen Konsistenzfehler am Wunschgewicht',
        (tester) async {
      // "75,5" -> 755 via digitsOnly. The weight field carries its own range
      // error; a second, contradictory message at the target weight would only
      // confuse — there is no current weight to compare against.
      await openSettings(tester);
      await waehleZiel(tester, 'lose05kg');
      await tippe(tester, 'settings-target-weight', '72');
      await tippe(tester, 'settings-weight', '755');

      expect(find.text('30–300 kg (ganze Zahl)'), findsOneWidget,
          reason: 'nur der Bereichsfehler am Gewicht');
      expect(saveHandler(tester), isNull);
    });

    testWidgets('die Bereichsgrenze hat Vorrang vor der Konsistenzregel',
        (tester) async {
      await openSettings(tester);
      await waehleZiel(tester, 'lose05kg');
      await tippe(tester, 'settings-target-weight', '755');

      expect(find.text('30–300 kg (ganze Zahl)'), findsOneWidget);
      expect(find.text(abnehmFehler), findsNothing,
          reason: '755 kg ist zuerst ausserhalb der Spalte, dann erst falsch '
              'herum');
      expect(saveHandler(tester), isNull);
    });

    testWidgets('die englische Fassung nennt denselben Widerspruch',
        (tester) async {
      await openSettings(
        tester,
        profile: basis.copyWith(
          targetWeightKg: 90,
          weightGoal: WeightGoal.lose05kg,
        ),
        locale: const Locale('en'),
      );

      expect(
        find.text('To lose weight your target has to be below your current '
            'weight (80 kg) — or pick a different weight goal.'),
        findsOneWidget,
      );
      expect(saveHandler(tester), isNull);
    });
  });
}
