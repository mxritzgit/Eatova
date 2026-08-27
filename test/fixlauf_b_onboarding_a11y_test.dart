import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/onboarding_screen.dart';

import 'support/harness.dart';

// Fix run 2026-08-27, package B:
//  * F2-04 — stepper buttons carry a label, the slider speaks "75 kg" instead
//    of a percentage, selection cards announce button + selected.
//  * F8-09 — the sex tiles and the picker unit no longer shrink their text
//    with FittedBox; the tiles stack at large system fonts instead.
//  * F2-08 — the intro names the real number of questions.

Future<void> _pump(
  WidgetTester tester, {
  required UserProfile profile,
  double textScale = 1.0,
}) async {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await pumpLocalized(
    tester,
    OnboardingScreen(
      // Fresh state per pump: without a new key a second pump in the same
      // test would keep the first profile's state.
      key: UniqueKey(),
      firstName: 'Moritz',
      initialProfile: profile,
      onComplete: (_) {},
    ),
    brightness: Brightness.light,
    textScale: textScale,
    scaffold: false,
    safeArea: false,
  );
  await tester.pumpAndSettle();
}

/// The Slider's own node sits below the nearest ancestor node that
/// `getSemantics` returns; search the subtree for the spoken value.
bool _subtreeHasValue(SemanticsNode node, String value) {
  if (node.value == value) return true;
  var found = false;
  node.visitChildren((child) {
    if (_subtreeHasValue(child, value)) found = true;
    return !found;
  });
  return found;
}

Future<void> _next(WidgetTester tester, [int times = 1]) async {
  for (var i = 0; i < times; i++) {
    await tester.tap(find.byKey(const ValueKey('onboarding-next')));
    await tester.pumpAndSettle();
  }
}

void main() {
  testWidgets('F2-08: die Intro nennt die echte Zahl der Fragen',
      (tester) async {
    await _pump(tester, profile: const UserProfile());
    expect(find.text(deL10n.onboardingWelcomeBody(7)), findsOneWidget,
        reason: 'Halten: 7 Fragen zwischen Intro und Zusammenfassung');

    await _pump(
      tester,
      profile: const UserProfile(
        weightGoal: WeightGoal.lose05kg,
        targetWeightKg: 68,
      ),
    );
    expect(find.text(deL10n.onboardingWelcomeBody(9)), findsOneWidget,
        reason: 'Abnehmen: Zielgewicht und Tempo kommen dazu');
  });

  testWidgets('F2-04: Auswahlkarten sind Knoepfe mit selected-Status',
      (tester) async {
    await _pump(tester, profile: const UserProfile());
    await _next(tester); // sex

    await tester.tap(find.byKey(const ValueKey('onboarding-sex-male')));
    await tester.pumpAndSettle();
    expect(
      tester.getSemantics(find.byKey(const ValueKey('onboarding-sex-male'))),
      isSemantics(isButton: true, isSelected: true),
    );
    expect(
      tester.getSemantics(find.byKey(const ValueKey('onboarding-sex-female'))),
      isSemantics(isButton: true, isSelected: false),
    );

    await _next(tester, 4); // age, height, weight -> activity
    await tester.tap(find.byKey(const ValueKey('onboarding-activity-moderate')));
    await tester.pumpAndSettle();
    expect(
      tester.getSemantics(
          find.byKey(const ValueKey('onboarding-activity-moderate'))),
      isSemantics(isButton: true, isSelected: true),
    );
  });

  testWidgets('F2-04: Stepper haben Labels, der Slider spricht den Wert',
      (tester) async {
    await _pump(tester, profile: const UserProfile(weightKg: 75));
    await _next(tester, 4); // -> weight

    expect(
      tester.getSemantics(find.byKey(const ValueKey('onboarding-weight-dec'))),
      isSemantics(isButton: true, label: deL10n.onboardingStepDownSemanticLabel),
    );
    expect(
      tester.getSemantics(find.byKey(const ValueKey('onboarding-weight-inc'))),
      isSemantics(isButton: true, label: deL10n.onboardingStepUpSemanticLabel),
    );
    final slider =
        tester.getSemantics(find.byKey(const ValueKey('onboarding-weight-slider')));
    expect(_subtreeHasValue(slider, '75 ${deL10n.commonUnitKg}'), isTrue,
        reason: 'ein Screenreader muss "75 kg" hoeren, nicht Prozent');
  });

  testWidgets('F8-09: keine FittedBox um Beschriftungen, Kacheln stapeln '
      'bei 2.0 ohne Overflow', (tester) async {
    final overflows = <String>[];
    final prior = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception.toString().contains('overflowed')) {
        overflows.add(details.summary.toString());
        return;
      }
      prior?.call(details);
    };
    try {
      await _pump(tester, profile: const UserProfile(), textScale: 2.0);
      await _next(tester); // sex
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('onboarding-step-sex')),
          matching: find.byType(FittedBox),
        ),
        findsNothing,
        reason: 'FittedBox neutralisiert die Textskalierung',
      );
      // At 200 % a third of the row cannot hold the label: the tiles stack.
      final male = tester.getRect(find.byKey(const ValueKey('onboarding-sex-male')));
      final female =
          tester.getRect(find.byKey(const ValueKey('onboarding-sex-female')));
      expect(female.top, greaterThan(male.bottom - 1),
          reason: 'gestapelt statt eingedampft');

      await _next(tester); // age
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('onboarding-step-age')),
          matching: find.byType(FittedBox),
        ),
        findsOneWidget,
        reason: 'nur die Hero-Zahl darf noch schrumpfen, die Einheit nicht',
      );
    } finally {
      FlutterError.onError = prior;
    }
    expect(overflows, isEmpty, reason: overflows.join('\n'));
  });

  testWidgets('bei 1.0 stehen die drei Kacheln nebeneinander', (tester) async {
    await _pump(tester, profile: const UserProfile());
    await _next(tester);
    final male = tester.getRect(find.byKey(const ValueKey('onboarding-sex-male')));
    final female =
        tester.getRect(find.byKey(const ValueKey('onboarding-sex-female')));
    expect(female.top, male.top);
  });
}
