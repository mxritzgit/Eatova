import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The onboarding's steps in flow order (2026-10-04). `target` and `pace`
/// exist only for a direction with a reachable target; navigation by meaning
/// skips them when they are not on screen.
const onboardingGroups = [
  'goal',
  'basics',
  'body',
  'activity',
  'target',
  'pace',
  'diet',
  'summary',
];

Future<void> tapOnboarding(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// The step currently on screen, as its [onboardingGroups] index.
int currentOnboardingGroup() => onboardingGroups.indexWhere(
  (group) =>
      find.byKey(ValueKey('onboarding-step-$group')).evaluate().isNotEmpty,
);

/// Navigate by meaning so grouping changes do not weaken behavior assertions.
Future<void> goToOnboarding(WidgetTester tester, String step) async {
  final target = onboardingGroups.indexOf(step);
  expect(target, greaterThanOrEqualTo(0));
  for (var attempt = 0; attempt < onboardingGroups.length; attempt++) {
    final current = currentOnboardingGroup();
    expect(current, greaterThanOrEqualTo(0));
    if (current == target) return;
    await tapOnboarding(
      tester,
      current < target ? 'onboarding-next' : 'onboarding-back',
    );
  }
  fail('Could not reach onboarding group $step');
}
