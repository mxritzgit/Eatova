import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/onboarding_screen.dart';
import 'package:eatova/src/widgets/kcal/manual_meal_sheet.dart';

import 'support/harness.dart';
import 'support/onboarding_harness.dart';

Finder key(String value) => find.byKey(ValueKey(value));

void main() {
  testWidgets('pending onboarding commit keeps summary on system back', (
    tester,
  ) async {
    pinPhoneViewport(tester);
    final commit = Completer<void>();
    await pumpLocalized(
      tester,
      OnboardingScreen(
        firstName: 'Test',
        initialProfile: const UserProfile(),
        onComplete: (_) => commit.future,
      ),
      settle: true,
    );
    await goToOnboarding(tester, 'summary');
    await tapOnboarding(tester, 'onboarding-finish');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    final summaryStillShown = key(
      'onboarding-step-summary',
    ).evaluate().isNotEmpty;
    commit.completeError(StateError('synthetic local commit failure'));
    await tester.pumpAndSettle();
    expect(summaryStillShown, isTrue);
    expect(key('onboarding-step-summary'), findsOneWidget);
  });

  testWidgets('pending manual commit blocks already focused keyboard editing', (
    tester,
  ) async {
    pinPhoneViewport(tester);
    final commit = Completer<void>();
    MealAnalysisResult? committed;
    await pumpLocalized(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => showManualMealSheet(
            context,
            onSave: (result) {
              committed = result;
              return commit.future;
            },
          ),
          child: const Text('open'),
        ),
      ),
      settle: true,
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(key('manual-meal-name'), 'Draft');
    await tester.enterText(key('manual-meal-kcal100'), '123');
    await tester.pumpAndSettle();
    await tester.ensureVisible(key('manual-meal-save'));
    await tester.pumpAndSettle();
    await tester.tap(key('manual-meal-save'));
    await tester.pump();
    expect(committed, isNotNull);
    final controller = tester
        .widget<TextField>(key('manual-meal-kcal100'))
        .controller!;
    final hadInputClient = tester.testTextInput.hasAnyClients;
    if (hadInputClient) tester.testTextInput.enterText('999');
    await tester.pump();
    final textWhileSaving = controller.text;
    commit.completeError(StateError('synthetic local commit failure'));
    await tester.pumpAndSettle();
    expect(committed?.kcalPer100G, 123);
    expect(
      textWhileSaving,
      '123',
      reason: 'The keyboard must not change a draft after its commit snapshot.',
    );
  });
}
