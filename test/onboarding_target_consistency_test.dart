import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/onboarding_screen.dart';

import 'support/harness.dart';
import 'support/onboarding_harness.dart';

// P9-07 — the target step showed one number and said another.
//
// The picker clamps the value it DRAWS but cannot write it back, so the
// footnote read the raw state. Lower the weight under a chosen target and the
// step showed "59 kg" over "15 kg abnehmen": 59 = clamp(75, 30, 59),
// 15 = |60 − 75|. The saved plan was always right (it clamped too) — only the
// sentence lied.
//
// Since 2026-10-04 the goal is the first question and an UNCHOSEN target
// follows the weight (onboarding_flow_test.dart). These cases therefore pick
// the target by hand first: only a chosen target can end up outside the
// window the weight leaves open.
//
// Counterpart to goals_target_consistency_test.dart, which pins the same
// promise for the settings side.
void main() {
  /// Mounts the onboarding and returns the profile the flow finally hands out.
  Future<UserProfile?> Function() leseProfil = () async => null;

  Future<void> starte(WidgetTester tester) async {
    pinPhoneViewport(tester);

    // The big digits overflow the pinned viewport at some steps; that is a
    // layout case of its own (onboarding_screen_render_test) and not the
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

  /// Direction, weight and a hand-picked target, then the target step.
  Future<void> waehleZiel(
    WidgetTester tester, {
    required bool zunehmen,
    required int gewicht,
    required int ziel,
  }) async {
    await starte(tester);
    await tapOnboarding(
      tester,
      zunehmen ? 'onboarding-goal-gain' : 'onboarding-goal-lose',
    );
    await goToOnboarding(tester, 'body');
    await setze(tester, 'weight', gewicht);
    await goToOnboarding(tester, 'target');
    await setze(tester, 'target', ziel);
  }

  /// Back to the body step, a new weight, forward to the target again.
  Future<void> neuesGewicht(WidgetTester tester, int gewicht) async {
    await goToOnboarding(tester, 'body');
    await setze(tester, 'weight', gewicht);
    await goToOnboarding(tester, 'target');
    expect(
      find.byKey(const ValueKey('onboarding-target-section')),
      findsOneWidget,
    );
  }

  testWidgets('Zielgewicht: Fussnote nennt die Zahl, die darueber steht', (
    tester,
  ) async {
    await waehleZiel(tester, zunehmen: false, gewicht: 80, ziel: 75);
    expect(angezeigt(tester, 'target'), '75');
    expect(find.text('5 kg abnehmen'), findsOneWidget);

    // Down to 60 — WITHOUT touching the target again. Its window is now
    // 30 … 59.
    await neuesGewicht(tester, 60);

    // The number and the sentence have to mean the same kilograms.
    expect(angezeigt(tester, 'target'), '59');
    expect(find.text('1 kg abnehmen'), findsOneWidget);
    expect(find.text('15 kg abnehmen'), findsNothing);
  });

  testWidgets('Zielgewicht beim Zunehmen: spiegelbildlich derselbe Fall', (
    tester,
  ) async {
    await waehleZiel(tester, zunehmen: true, gewicht: 60, ziel: 65);
    expect(angezeigt(tester, 'target'), '65');
    expect(find.text('5 kg zunehmen'), findsOneWidget);

    // Raise the weight past the chosen target: the window becomes 81 … 300.
    await neuesGewicht(tester, 80);

    expect(angezeigt(tester, 'target'), '81');
    expect(find.text('1 kg zunehmen'), findsOneWidget);
    expect(find.text('15 kg zunehmen'), findsNothing);
  });

  testWidgets('ein selbst gesetztes Ziel ueberlebt den Gewichtswechsel', (
    tester,
  ) async {
    // P9-07b — a write-back `_target = _targetSafe` in the weight callback
    // cost the input: 80 kg, target 70 by hand, weight 60 (shows 59) and back
    // to 80 — and the target read 59 instead of the 70 the user chose.
    // Narrowing alone carries the consistency.
    await waehleZiel(tester, zunehmen: false, gewicht: 80, ziel: 70);
    expect(angezeigt(tester, 'target'), '70');

    // Weight under the target: the window is 30 … 59, 59 is shown.
    await neuesGewicht(tester, 60);
    expect(angezeigt(tester, 'target'), '59');
    expect(find.text('1 kg abnehmen'), findsOneWidget);

    // Back to 80 kg: the window lets the 70 through again.
    await neuesGewicht(tester, 80);
    expect(
      angezeigt(tester, 'target'),
      '70',
      reason: 'die 70 war eine Eingabe, kein Zwischenstand',
    );
    expect(find.text('10 kg abnehmen'), findsOneWidget);
  });

  testWidgets('der gespeicherte Plan nimmt genau die angezeigte Zahl', (
    tester,
  ) async {
    await waehleZiel(tester, zunehmen: false, gewicht: 80, ziel: 75);
    await neuesGewicht(tester, 60);
    expect(angezeigt(tester, 'target'), '59');

    await goToOnboarding(tester, 'summary');
    await tapOnboarding(tester, 'onboarding-finish');

    final fertig = await leseProfil();
    expect(fertig, isNotNull);
    expect(fertig!.weightKg, 60);
    expect(fertig.targetWeightKg, 59);
  });
}
