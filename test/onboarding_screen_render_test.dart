import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/onboarding_screen.dart';

import 'support/harness.dart';

/// The screen brings its own Scaffold and uses `context.l10n` throughout.
Future<void> _pumpOnboarding(
  WidgetTester tester,
  Widget screen, {
  required Brightness brightness,
  double textScale = 1.0,
}) =>
    pumpLocalized(
      tester,
      screen,
      reducedMotion: false,
      brightness: brightness,
      textScale: textScale,
      scaffold: false,
      safeArea: false,
    );

// DESIGN_REFACTOR §7.2 / §5: every screen renders in both brightnesses and at
// 200 % system text without RenderFlex overflow. All eleven onboarding steps
// are walked because several are layout edge cases. Unlike the behaviour
// tests, overflows are not swallowed here: they are the subject.
void main() {
  /// A weight-loss goal makes the target and pace steps visible, so the flow
  /// has all 11 steps. The 1 % deficit cap applies (858 instead of 1100
  /// kcal/day), so the summary also carries the warning line.
  const vollerFlow = UserProfile(
    weightGoal: WeightGoal.lose1kg,
    targetWeightKg: 68,
  );

  Future<void> pumpAlleSchritte(
    WidgetTester tester,
    String fall, {
    required Brightness brightness,
    double textScale = 1.0,
  }) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3.0;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    final overflows = <String>[];
    final prior = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception.toString().contains('overflowed')) {
        overflows.add(details.summary.toString());
        return;
      }
      prior?.call(details);
    };

    const schritte = <String>[
      'intro',
      'sex',
      'age',
      'height',
      'weight',
      'activity',
      'goal',
      'target',
      'pace',
      'diet',
      'summary',
    ];
    final gesehen = <String>[];

    try {
      await _pumpOnboarding(
        tester,
        OnboardingScreen(
          firstName: 'Moritz',
          initialProfile: vollerFlow,
          onComplete: (_) {},
        ),
        brightness: brightness,
        textScale: textScale,
      );
      await tester.pumpAndSettle();

      for (final schritt in schritte) {
        if (find.byKey(ValueKey('onboarding-step-$schritt')).evaluate().isEmpty) {
          continue;
        }
        gesehen.add(schritt);
        if (schritt == 'summary') break;
        await tester.tap(find.byKey(const ValueKey('onboarding-next')));
        await tester.pumpAndSettle();
      }
    } finally {
      FlutterError.onError = prior;
    }

    expect(gesehen, schritte,
        reason: '$fall hat nicht alle elf Schritte durchlaufen');
    expect(tester.takeException(), isNull);
    expect(
      overflows,
      isEmpty,
      reason: '$fall overflowt:\n${overflows.join('\n')}',
    );
  }

  testWidgets('alle Schritte rendern im Hellmodus', (tester) async {
    await pumpAlleSchritte(tester, 'hell', brightness: Brightness.light);
  });

  testWidgets('alle Schritte rendern im Dunkelmodus', (tester) async {
    await pumpAlleSchritte(tester, 'dunkel', brightness: Brightness.dark);
  });

  testWidgets('alle Schritte rendern bei textScale 2.0 (hell)', (tester) async {
    await pumpAlleSchritte(
      tester,
      'hell @2.0',
      brightness: Brightness.light,
      textScale: 2.0,
    );
  });

  testWidgets('alle Schritte rendern bei textScale 2.0 (dunkel)',
      (tester) async {
    await pumpAlleSchritte(
      tester,
      'dunkel @2.0',
      brightness: Brightness.dark,
      textScale: 2.0,
    );
  });

  testWidgets('Weiter-Knopf und Zurueck-Pfeil bleiben Knoepfe',
      (tester) async {
    // [PrimaryActionButton] and [SquareIconButton] are InkWells, not material
    // buttons: without explicit semantics a screen reader announces the only
    // two navigation controls of the onboarding as plain text.
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pumpOnboarding(
      tester,
      OnboardingScreen(
        firstName: 'Moritz',
        initialProfile: vollerFlow,
        onComplete: (_) {},
      ),
      brightness: Brightness.light,
    );
    await tester.pumpAndSettle();

    expect(
      tester.getSemantics(find.byKey(const ValueKey('onboarding-next'))),
      isSemantics(isButton: true),
    );

    // One step further, where the back arrow exists.
    await tester.tap(find.byKey(const ValueKey('onboarding-next')));
    await tester.pumpAndSettle();
    // The label is spoken aloud, so it must carry the real umlaut; the ASCII
    // transliteration would be mispronounced by TalkBack.
    expect(
      tester.getSemantics(find.byKey(const ValueKey('onboarding-back'))),
      isSemantics(isButton: true, label: 'Zurück'),
    );
  });

  testWidgets('die Zusammenfassung bleibt auch ohne Warnsatz heil',
      (tester) async {
    // Without a safety clamp or deficit cap the warning box disappears: a
    // different branch with a different height distribution. At −0.75 kg/week
    // on the default profile no limit applies (−825 under the 858 cap, 1500
    // above the 1350 floor).
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3.0;
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

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
      await _pumpOnboarding(
        tester,
        OnboardingScreen(
          firstName: 'Moritz',
          initialProfile: const UserProfile(
            weightGoal: WeightGoal.lose075kg,
            targetWeightKg: 68,
          ),
          onComplete: (_) {},
        ),
        brightness: Brightness.light,
        textScale: 2.0,
      );
      await tester.pumpAndSettle();
      for (var i = 0; i < 10; i++) {
        await tester.tap(find.byKey(const ValueKey('onboarding-next')));
        await tester.pumpAndSettle();
      }
    } finally {
      FlutterError.onError = prior;
    }

    expect(find.byKey(const ValueKey('onboarding-summary-kcal')),
        findsOneWidget);
    expect(
      find.byKey(const ValueKey('onboarding-summary-pace-warning')),
      findsNothing,
    );
    expect(overflows, isEmpty, reason: overflows.join('\n'));
  });
}
