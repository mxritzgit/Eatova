import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/onboarding_screen.dart';

import 'support/harness.dart';

// P9-07 — the target step showed one number and said another.
//
// `_NumberPicker` clamps the value it DRAWS but cannot write it back, so the
// footnote read the raw state. Lower the weight after a direction was picked
// and the step showed "59 kg" over "15 kg abnehmen": 59 = clamp(75, 30, 59),
// 15 = |60 − 75|. The saved plan was always right (it clamped too) — only the
// sentence lied.
//
// Counterpart to goals_target_consistency_test.dart, which pins the same
// promise for the settings side.
void main() {
  /// Mounts the onboarding and returns the profile the flow finally hands out.
  Future<UserProfile?> Function() leseProfil = () async => null;

  Future<void> starte(WidgetTester tester) async {
    pinPhoneViewport(tester);

    // The 52-px hero digits overflow the pinned viewport at some steps; that
    // is a layout case of its own (text_scale_stress_test) and not the
    // subject here.
    final prior = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception.toString().contains('overflowed')) return;
      prior?.call(details);
    };
    addTearDown(() => FlutterError.onError = prior);

    UserProfile? fertig;
    leseProfil = () async => fertig;
    await pumpLocalized(
      tester,
      OnboardingScreen(
        firstName: 'Moritz',
        initialProfile: const UserProfile(),
        onComplete: (p) => fertig = p,
      ),
      brightness: Brightness.light,
      scaffold: false,
      safeArea: false,
      settle: true,
    );
  }

  Future<void> weiter(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('onboarding-next')));
    await tester.pumpAndSettle();
  }

  Future<void> zurueck(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('onboarding-back')));
    await tester.pumpAndSettle();
  }

  /// Sets a picker to [wert] through its own slider callback — deterministic
  /// where a drag is not, and it walks the same `_set` the UI walks.
  Future<void> setze(WidgetTester tester, String feld, int wert) async {
    final slider = tester.widget<Slider>(
      find.byKey(ValueKey<String>('onboarding-$feld-slider')),
    );
    slider.onChanged!(wert.toDouble());
    await tester.pumpAndSettle();
  }

  String angezeigt(WidgetTester tester, String feld) => tester
      .widget<Text>(find.byKey(ValueKey<String>('onboarding-$feld-value')))
      .data!;

  testWidgets('Zielgewicht: Fussnote nennt die Zahl, die darueber steht',
      (tester) async {
    await starte(tester);

    // intro → sex → age → height → weight
    for (var i = 0; i < 4; i++) {
      await weiter(tester);
    }
    await setze(tester, 'weight', 80);
    await weiter(tester); // activity
    await weiter(tester); // goal

    await tester.tap(find.byKey(const ValueKey('onboarding-goal-lose')));
    await tester.pumpAndSettle();
    await weiter(tester);
    expect(find.byKey(const ValueKey('onboarding-step-target')), findsOneWidget);
    // The direction default: 80 − 5.
    expect(angezeigt(tester, 'target'), '75');
    expect(find.text('5 kg abnehmen'), findsOneWidget);

    // Back to the weight step and down to 60 — WITHOUT touching the target
    // row again. Its window is now 30 … 59.
    for (var i = 0; i < 3; i++) {
      await zurueck(tester);
    }
    expect(find.byKey(const ValueKey('onboarding-step-weight')), findsOneWidget);
    await setze(tester, 'weight', 60);

    for (var i = 0; i < 3; i++) {
      await weiter(tester);
    }
    expect(find.byKey(const ValueKey('onboarding-step-target')), findsOneWidget);

    // The number and the sentence have to mean the same kilograms.
    expect(angezeigt(tester, 'target'), '59');
    expect(find.text('1 kg abnehmen'), findsOneWidget);
    expect(find.text('15 kg abnehmen'), findsNothing);
  });

  testWidgets('Zielgewicht beim Zunehmen: spiegelbildlich derselbe Fall',
      (tester) async {
    await starte(tester);

    for (var i = 0; i < 4; i++) {
      await weiter(tester);
    }
    await setze(tester, 'weight', 60);
    await weiter(tester);
    await weiter(tester);

    await tester.tap(find.byKey(const ValueKey('onboarding-goal-gain')));
    await tester.pumpAndSettle();
    await weiter(tester);
    expect(angezeigt(tester, 'target'), '65'); // 60 + 5
    expect(find.text('5 kg zunehmen'), findsOneWidget);

    // Raise the weight past the old target: the window becomes 81 … 250.
    for (var i = 0; i < 3; i++) {
      await zurueck(tester);
    }
    await setze(tester, 'weight', 80);
    for (var i = 0; i < 3; i++) {
      await weiter(tester);
    }

    expect(angezeigt(tester, 'target'), '81');
    expect(find.text('1 kg zunehmen'), findsOneWidget);
    expect(find.text('15 kg zunehmen'), findsNothing);
  });

  testWidgets('der gespeicherte Plan nimmt genau die angezeigte Zahl',
      (tester) async {
    await starte(tester);

    for (var i = 0; i < 4; i++) {
      await weiter(tester);
    }
    await setze(tester, 'weight', 80);
    await weiter(tester);
    await weiter(tester);
    await tester.tap(find.byKey(const ValueKey('onboarding-goal-lose')));
    await tester.pumpAndSettle();
    await weiter(tester);

    for (var i = 0; i < 3; i++) {
      await zurueck(tester);
    }
    await setze(tester, 'weight', 60);
    for (var i = 0; i < 3; i++) {
      await weiter(tester);
    }
    expect(angezeigt(tester, 'target'), '59');

    // target → pace → diet → summary; the CTA is `onboarding-finish` there.
    for (var i = 0; i < 3; i++) {
      await weiter(tester);
    }
    await tester.tap(find.byKey(const ValueKey('onboarding-finish')));
    await tester.pumpAndSettle();

    final fertig = await leseProfil();
    expect(fertig, isNotNull);
    expect(fertig!.weightKg, 60);
    expect(fertig.targetWeightKg, 59);
  });
}
