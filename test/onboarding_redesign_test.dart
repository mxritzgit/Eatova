import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/onboarding_screen.dart';
import 'package:eatova/src/services/kcal_calculator.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';
import 'support/onboarding_harness.dart';

// Every step in both palettes, both languages and at 1.0 and 2.0 text, plus
// the plan's edit loop. The PNG evidence of the 2026-10-04 redesign lives in
// test/design/onboarding_capture_test.dart.

Finder _key(String value) => find.byKey(ValueKey(value));

Future<void> _mount(
  WidgetTester tester, {
  Brightness brightness = Brightness.light,
  String locale = 'de',
  double scale = 1,
  UserProfile profile = const UserProfile(weightGoal: WeightGoal.lose05kg),
  ValueChanged<UserProfile>? onComplete,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = scale == 1
      ? const Size(390, 844)
      : const Size(320, 568);
  tester.view.viewPadding = const FakeViewPadding(top: 44, bottom: 24);
  tester.view.padding = const FakeViewPadding(top: 44, bottom: 24);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    localizedApp(
      OnboardingScreen(
        firstName: 'Alex',
        initialProfile: profile,
        onComplete: onComplete ?? (_) {},
      ),
      brightness: brightness,
      locale: Locale(locale),
      textScale: scale,
      safeArea: false,
      scaffold: false,
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String key) async {
  final finder = _key(key);
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    for (final family in {
      'Figtree': [
        'Figtree-Regular.ttf',
        'Figtree-Medium.ttf',
        'Figtree-SemiBold.ttf',
        'Figtree-Bold.ttf',
      ],
      'BricolageGrotesque': [
        'BricolageGrotesque-Bold.ttf',
        'BricolageGrotesque-ExtraBold.ttf',
      ],
      'MaterialIcons': ['MaterialIcons-Regular.otf'],
    }.entries) {
      final loader = FontLoader(family.key);
      for (final file in family.value) {
        loader.addFont(
          rootBundle.load(
            family.key == 'MaterialIcons'
                ? 'fonts/$file'
                : 'assets/fonts/$file',
          ),
        );
      }
      await loader.load();
    }
  });

  for (final brightness in Brightness.values) {
    for (final locale in ['de', 'en']) {
      for (final scale in [1.0, 2.0]) {
        testWidgets('eight steps ${brightness.name} $locale at $scale', (
          tester,
        ) async {
          await _mount(
            tester,
            brightness: brightness,
            locale: locale,
            scale: scale,
          );
          // The profile loses weight, so every step of the flow is asked.
          for (final step in onboardingGroups) {
            expect(_key('onboarding-step-$step'), findsOneWidget, reason: step);
            expect(tester.takeException(), isNull);
            if (step == 'summary') {
              await tester.ensureVisible(_key('onboarding-edit-diet'));
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull);
              break;
            }
            await _tap(tester, 'onboarding-next');
          }
          expect(_key('onboarding-finish'), findsOneWidget);
        });
      }
    }
  }

  testWidgets(
    'summary edits update the plan without committing or repeating questions',
    (tester) async {
      final saved = <UserProfile>[];
      await _mount(tester, profile: const UserProfile(), onComplete: saved.add);
      await goToOnboarding(tester, 'summary');
      final prior = tester.widget<Text>(_key('onboarding-summary-kcal')).data;
      await _tap(tester, 'onboarding-edit-body');
      expect(_key('onboarding-step-body'), findsOneWidget);
      tester.widget<Slider>(_key('onboarding-weight-slider')).onChanged!(95);
      await tester.pumpAndSettle();
      await _tap(tester, 'onboarding-next');
      expect(_key('onboarding-step-summary'), findsOneWidget);
      expect(saved, isEmpty);
      expect(
        tester.widget<Text>(_key('onboarding-summary-kcal')).data,
        isNot(prior),
      );

      // Editing an answer keeps system Back inside this review session.
      await _tap(tester, 'onboarding-edit-basics');
      expect(
        tester.widget<PopScope<Object?>>(find.byType(PopScope<Object?>).last)
            .canPop,
        isFalse,
      );
      await _tap(tester, 'onboarding-back');
      expect(_key('onboarding-step-summary'), findsOneWidget);
      await _tap(tester, 'onboarding-finish');
      expect(saved, hasLength(1));
      expect(saved.single.weightKg, 95);
      expect(saved.single.diet, DietPreference.none);
      expect(saved.single.onboardingCompleted, isTrue);
      expect(
        saved.single.dailyKcalGoal,
        const KcalCalculator().calculate(saved.single).kcal,
      );
    },
  );

  testWidgets(
    'goal reselection and direction changes preserve custom targets and pace',
    (tester) async {
      await _mount(tester, profile: const UserProfile(weightKg: 80));
      await _tap(tester, 'onboarding-goal-lose');
      await goToOnboarding(tester, 'target');
      tester.widget<Slider>(_key('onboarding-target-slider')).onChanged!(70);
      await tester.pumpAndSettle();
      await _tap(tester, 'onboarding-next');
      await _tap(tester, 'onboarding-pace-lose025kg');

      // Reselecting the same direction keeps the custom target.
      await goToOnboarding(tester, 'goal');
      await _tap(tester, 'onboarding-goal-lose');
      await goToOnboarding(tester, 'target');
      expect(tester.widget<Text>(_key('onboarding-target-value')).data, '70');

      await goToOnboarding(tester, 'goal');
      await _tap(tester, 'onboarding-goal-gain');
      await goToOnboarding(tester, 'target');
      tester.widget<Slider>(_key('onboarding-target-slider')).onChanged!(90);
      await tester.pumpAndSettle();

      // Maintain asks neither target nor pace.
      await goToOnboarding(tester, 'goal');
      await _tap(tester, 'onboarding-goal-maintain');
      await goToOnboarding(tester, 'activity');
      await _tap(tester, 'onboarding-next');
      expect(_key('onboarding-step-diet'), findsOneWidget);
      expect(_key('onboarding-target-section'), findsNothing);

      await goToOnboarding(tester, 'goal');
      await _tap(tester, 'onboarding-goal-lose');
      await goToOnboarding(tester, 'target');
      expect(tester.widget<Text>(_key('onboarding-target-value')).data, '70');
      await _tap(tester, 'onboarding-next');
      expect(
        tester.getSemantics(_key('onboarding-pace-lose025kg')),
        isSemantics(isSelected: true),
      );

      await goToOnboarding(tester, 'goal');
      await _tap(tester, 'onboarding-goal-gain');
      await goToOnboarding(tester, 'target');
      expect(tester.widget<Text>(_key('onboarding-target-value')).data, '90');
    },
  );

  testWidgets('optional diet is kept when returning from summary', (
    tester,
  ) async {
    final saved = <UserProfile>[];
    await _mount(
      tester,
      profile: const UserProfile(diet: DietPreference.vegan),
      onComplete: saved.add,
    );
    await goToOnboarding(tester, 'summary');
    await _tap(tester, 'onboarding-edit-diet');
    expect(
      tester.getSemantics(_key('onboarding-diet-vegan')),
      isSemantics(isSelected: true),
    );
    await _tap(tester, 'onboarding-next');
    await _tap(tester, 'onboarding-finish');
    expect(saved.single.diet, DietPreference.vegan);
  });
}
