import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const onboardingGroups = [
  'basics',
  'body',
  'activity',
  'goal',
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

/// Navigate by meaning so grouping changes do not weaken behavior assertions.
Future<void> goToOnboarding(WidgetTester tester, String step) async {
  final target = onboardingGroups.indexOf(step);
  expect(target, greaterThanOrEqualTo(0));
  for (var attempt = 0; attempt < onboardingGroups.length; attempt++) {
    final current = onboardingGroups.indexWhere(
      (group) =>
          find.byKey(ValueKey('onboarding-step-$group')).evaluate().isNotEmpty,
    );
    expect(current, greaterThanOrEqualTo(0));
    if (current == target) return;
    await tapOnboarding(
      tester,
      current < target ? 'onboarding-next' : 'onboarding-back',
    );
  }
  fail('Could not reach onboarding group $step');
}
