import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/onboarding_screen.dart';
import 'package:eatova/src/services/kcal_calculator.dart';
import 'package:eatova/src/widgets/common/lively.dart';
import 'package:eatova/src/widgets/design/design.dart';

import 'support/harness.dart';
import 'support/onboarding_harness.dart';

// The onboarding redesign of 2026-10-04 (docs/ONBOARDING-2026-10-04.md):
// goal first, target and pace as their own steps after the activity, a
// target default that follows the weight, plan edits that walk the goal's
// follow-up questions, and a plan that shows the target BMI hint.

Finder _key(String value) => find.byKey(ValueKey(value));

Future<void> _pump(
  WidgetTester tester, {
  UserProfile profile = const UserProfile(),
  ValueChanged<UserProfile>? onComplete,
  bool reducedMotion = true,
}) async {
  pinPhoneViewport(tester);
  await pumpLocalized(
    tester,
    OnboardingScreen(
      key: UniqueKey(),
      firstName: 'Moritz',
      initialProfile: profile,
      onComplete: onComplete ?? (_) {},
    ),
    brightness: Brightness.dark,
    reducedMotion: reducedMotion,
    scaffold: false,
    safeArea: false,
    settle: true,
  );
}

Future<void> _next(WidgetTester tester) => tapOnboarding(tester, 'onboarding-next');

String _value(WidgetTester tester, String field) =>
    tester.widget<Text>(_key('onboarding-$field-value')).data!;

void _slide(WidgetTester tester, String field, int value) => tester
    .widget<Slider>(_key('onboarding-$field-slider'))
    .onChanged!(value.toDouble());

/// Walks Next to the plan and returns the steps on the way.
Future<List<String>> _walk(WidgetTester tester) async {
  final seen = <String>[];
  for (var i = 0; i < onboardingGroups.length; i++) {
    final step = onboardingGroups[currentOnboardingGroup()];
    seen.add(step);
    if (step == 'summary') break;
    await _next(tester);
  }
  return seen;
}

String _cta(WidgetTester tester) {
  final button = find.byWidgetPredicate(
    (w) =>
        w.key == const ValueKey('onboarding-next') ||
        w.key == const ValueKey('onboarding-finish'),
  );
  return tester
      .widget<Text>(find.descendant(of: button, matching: find.byType(Text)))
      .data!;
}

void main() {
  group('Reihenfolge', () {
    testWidgets('das Ziel ist die erste Frage, mit Begruessung', (tester) async {
      await _pump(tester);

      expect(_key('onboarding-step-goal'), findsOneWidget);
      expect(find.text('Hallo, Moritz. Was ist dein Ziel?'), findsOneWidget);
      for (final direction in ['lose', 'maintain', 'gain']) {
        expect(_key('onboarding-goal-$direction'), findsOneWidget);
      }
      expect(_key('onboarding-back'), findsNothing);

      await _next(tester);
      expect(_key('onboarding-step-basics'), findsOneWidget);
    });

    testWidgets('Zielgewicht und Tempo sind eigene Schritte nach dem Alltag', (
      tester,
    ) async {
      await _pump(tester);
      await tapOnboarding(tester, 'onboarding-goal-lose');
      // Not inline on the goal step any more: one decision per screen.
      expect(_key('onboarding-target-section'), findsNothing);
      expect(_key('onboarding-pace-lose05kg'), findsNothing);

      expect(await _walk(tester), [
        'goal',
        'basics',
        'body',
        'activity',
        'target',
        'pace',
        'diet',
        'summary',
      ]);
    });

    testWidgets('wer sein Gewicht haelt, bekommt keine Ziel-Fragen', (
      tester,
    ) async {
      await _pump(tester);
      expect(await _walk(tester), [
        'goal',
        'basics',
        'body',
        'activity',
        'diet',
        'summary',
      ]);
    });

    testWidgets('der Fortschritt zaehlt nur die gestellten Fragen', (
      tester,
    ) async {
      await _pump(tester);
      expect(find.text('1 / 6'), findsOneWidget);
      expect(find.bySemanticsLabel('Dein Ziel, Schritt 1 von 6'), findsOneWidget);

      await tapOnboarding(tester, 'onboarding-goal-lose');
      expect(find.text('1 / 8'), findsOneWidget);
      expect(find.bySemanticsLabel('Dein Ziel, Schritt 1 von 8'), findsOneWidget);
    });
  });

  group('Zielgewicht-Startwert', () {
    testWidgets('ein noch nicht gewaehltes Zielgewicht folgt dem Gewicht', (
      tester,
    ) async {
      // The goal is asked before the weight, so a default fixed when the
      // direction is chosen would describe the starting 78 kg, not the user.
      await _pump(tester);
      await tapOnboarding(tester, 'onboarding-goal-lose');
      await goToOnboarding(tester, 'body');
      _slide(tester, 'weight', 80);
      await tester.pumpAndSettle();
      await goToOnboarding(tester, 'target');
      expect(_value(tester, 'target'), '75');
      expect(find.text('5 kg abnehmen'), findsOneWidget);

      await goToOnboarding(tester, 'body');
      _slide(tester, 'weight', 60);
      await tester.pumpAndSettle();
      await goToOnboarding(tester, 'target');
      expect(_value(tester, 'target'), '55',
          reason: 'untouched, the target keeps its distance to the weight');
      expect(find.text('5 kg abnehmen'), findsOneWidget);
    });

    testWidgets('ein gespeichertes Ziel auf der falschen Seite ist kein Startwert',
        (tester) async {
      // The model default carries 78 kg as target AND weight. "Lose" with
      // that used to open on the window edge: 77 kg, a one-kilo plan.
      await _pump(
        tester,
        profile: const UserProfile(weightGoal: WeightGoal.lose05kg),
      );
      await goToOnboarding(tester, 'target');
      expect(_value(tester, 'target'), '73');
      expect(find.text('5 kg abnehmen'), findsOneWidget);
    });

    testWidgets('ein gespeichertes Ziel auf der richtigen Seite bleibt', (
      tester,
    ) async {
      await _pump(
        tester,
        profile: const UserProfile(
          weightGoal: WeightGoal.lose05kg,
          targetWeightKg: 70,
        ),
      );
      await goToOnboarding(tester, 'target');
      expect(_value(tester, 'target'), '70');
    });
  });

  group('Aenderungen aus dem Plan', () {
    testWidgets(
      'eine Zielaenderung fragt Zielgewicht und Tempo, bevor sie zurueckkehrt',
      (tester) async {
        final saved = <UserProfile>[];
        await _pump(tester, onComplete: saved.add);
        await goToOnboarding(tester, 'summary');
        expect(_key('onboarding-edit-target'), findsNothing);
        expect(_key('onboarding-edit-pace'), findsNothing);

        await tapOnboarding(tester, 'onboarding-edit-goal');
        expect(_key('onboarding-step-goal'), findsOneWidget);
        expect(
          tester.widget<PopScope<Object?>>(find.byType(PopScope<Object?>).last)
              .canPop,
          isFalse,
          reason: 'editing the first question keeps system Back in the plan',
        );
        await tapOnboarding(tester, 'onboarding-goal-lose');
        expect(_cta(tester), 'Weiter',
            reason: 'two questions follow before the plan');

        await _next(tester);
        expect(_key('onboarding-step-target'), findsOneWidget,
            reason: 'a new direction needs its target, not a silent default');
        await _next(tester);
        expect(_key('onboarding-step-pace'), findsOneWidget);
        expect(_cta(tester), 'Zurück zum Plan');
        await _next(tester);

        expect(_key('onboarding-step-summary'), findsOneWidget);
        expect(_key('onboarding-edit-target'), findsOneWidget);
        expect(_key('onboarding-edit-pace'), findsOneWidget);
        expect(saved, isEmpty);

        await tapOnboarding(tester, 'onboarding-finish');
        expect(saved.single.weightGoal, WeightGoal.lose05kg);
        expect(saved.single.targetWeightKg, 73);
      },
    );

    testWidgets('Zurueck geht die Kette rueckwaerts und dann zum Plan', (
      tester,
    ) async {
      await _pump(
        tester,
        profile: const UserProfile(
          weightGoal: WeightGoal.lose05kg,
          targetWeightKg: 70,
        ),
      );
      await goToOnboarding(tester, 'summary');
      await tapOnboarding(tester, 'onboarding-edit-goal');
      await _next(tester);
      expect(_key('onboarding-step-target'), findsOneWidget);

      await tapOnboarding(tester, 'onboarding-back');
      expect(_key('onboarding-step-goal'), findsOneWidget);
      await tapOnboarding(tester, 'onboarding-back');
      expect(_key('onboarding-step-summary'), findsOneWidget);
    });

    testWidgets('jede andere Aenderung kehrt nach einer Frage zurueck', (
      tester,
    ) async {
      await _pump(
        tester,
        profile: const UserProfile(
          weightGoal: WeightGoal.lose05kg,
          targetWeightKg: 70,
        ),
      );
      await goToOnboarding(tester, 'summary');
      await tapOnboarding(tester, 'onboarding-edit-target');
      expect(_key('onboarding-step-target'), findsOneWidget);
      expect(_cta(tester), 'Zurück zum Plan');
      await _next(tester);
      expect(_key('onboarding-step-summary'), findsOneWidget,
          reason: 'the pace was not asked to change');
    });

    testWidgets('der Plan zaehlt vom Erhaltungsbedarf, nach einer Aenderung '
        'vom alten Ziel', (tester) async {
      await _pump(tester, profile: const UserProfile(weightGoal: WeightGoal.lose05kg));
      await goToOnboarding(tester, 'summary');
      CountingText counter() => tester.widget<CountingText>(
        find.ancestor(
          of: _key('onboarding-summary-kcal'),
          matching: find.byType(CountingText),
        ),
      );
      // 78 kg / 178 cm / 30 y / neutral / sedentary: maintenance 2164.
      expect(counter().from, 2164,
          reason: 'the first reveal counts the deficit down from maintenance');
      expect(counter().value, 1600);

      await tapOnboarding(tester, 'onboarding-edit-pace');
      await tapOnboarding(tester, 'onboarding-pace-lose025kg');
      await _next(tester);
      expect(counter().from, 1600,
          reason: 'after an edit it counts from the number shown before');
      expect(counter().value, 1900);
    });
  });

  group('Prognose', () {
    testWidgets('der Tempo-Schritt nennt die Prognose fuer das gewaehlte Tempo',
        (tester) async {
      const base = UserProfile(
        weightGoal: WeightGoal.lose05kg,
        targetWeightKg: 68,
      );
      String expected(WeightGoal goal) {
        final profile = base.copyWith(weightGoal: goal);
        return timelineEstimateText(
          deL10n,
          targetWeightKg: 68,
          weeks: const KcalCalculator().weeksToGoalRange(profile)!,
        );
      }

      await _pump(tester, profile: base);
      await goToOnboarding(tester, 'pace');
      Finder forecast(String text) => find.descendant(
        of: _key('onboarding-pace-forecast'),
        matching: find.text(text),
      );
      expect(forecast(expected(WeightGoal.lose05kg)), findsOneWidget);

      await tapOnboarding(tester, 'onboarding-pace-lose025kg');
      expect(expected(WeightGoal.lose025kg), isNot(expected(WeightGoal.lose05kg)));
      expect(forecast(expected(WeightGoal.lose025kg)), findsOneWidget);
    });

    testWidgets('der Plan zeigt den BMI-Hinweis zum Zielgewicht', (
      tester,
    ) async {
      // 50 kg at 178 cm: BMI 15.8, below 18.5.
      await _pump(
        tester,
        profile: const UserProfile(
          weightKg: 60,
          weightGoal: WeightGoal.lose025kg,
          targetWeightKg: 50,
        ),
      );
      await goToOnboarding(tester, 'summary');
      expect(
        find.descendant(
          of: _key('onboarding-step-summary'),
          matching: _key('target-bmi-hint'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('ein Plan ohne Ziel zeigt keinen BMI-Hinweis', (tester) async {
      // Maintaining at 50 kg / 178 cm has a low BMI too, but no target was
      // chosen, so there is nothing to hint at.
      await _pump(tester, profile: const UserProfile(weightKg: 50));
      await goToOnboarding(tester, 'summary');
      expect(_key('target-bmi-hint'), findsNothing);
    });
  });

  group('Antworten im Plan', () {
    testWidgets('Zielgewicht und Tempo stehen nur bei einer Richtung da', (
      tester,
    ) async {
      await _pump(
        tester,
        profile: const UserProfile(
          weightGoal: WeightGoal.lose1kg,
          targetWeightKg: 68,
        ),
      );
      await goToOnboarding(tester, 'summary');
      String subtitle(String step) => tester
          .widget<SettingsRow>(_key('onboarding-edit-$step'))
          .subtitle!;
      expect(subtitle('goal'), 'Abnehmen');
      expect(subtitle('target'), '68 kg');
      expect(subtitle('pace'), 'Ambitioniert · −1 kg/Woche');
      expect(subtitle('basics'), 'Keine Angabe · 30 Jahre');
      expect(subtitle('body'), '178 cm · 78 kg');
    });
  });

  group('Zahlenwahl', () {
    testWidgets('ein Stepper am Rand ist gesperrt, nicht tot', (tester) async {
      await _pump(tester, profile: const UserProfile(ageYears: 16));
      await goToOnboarding(tester, 'basics');
      expect(
        tester.getSemantics(_key('onboarding-age-dec')),
        isSemantics(isButton: true, isEnabled: false, hasEnabledState: true),
      );
      expect(
        tester.getSemantics(_key('onboarding-age-inc')),
        isSemantics(isButton: true, isEnabled: true, hasEnabledState: true),
      );
      await tapOnboarding(tester, 'onboarding-age-dec');
      expect(_value(tester, 'age'), '16');
    });

    testWidgets('Halten wiederholt den Schritt, Loslassen stoppt ihn', (
      tester,
    ) async {
      await _pump(tester);
      await goToOnboarding(tester, 'body');
      final inc = _key('onboarding-weight-inc');
      await tester.ensureVisible(inc);
      await tester.pumpAndSettle();

      final gesture = await tester.startGesture(tester.getCenter(inc));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 400));
      await gesture.up();
      await tester.pump();
      final held = int.parse(_value(tester, 'weight'));
      expect(held, greaterThan(80),
          reason: 'one step on the press, then one every 90 ms');

      await tester.pump(const Duration(milliseconds: 500));
      expect(int.parse(_value(tester, 'weight')), held,
          reason: 'releasing stops the repeat');
    });
  });
}
