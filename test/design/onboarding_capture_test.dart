// Visual evidence for the onboarding redesign (2026-10-04).
//
// Walks the real OnboardingScreen through a weight-loss journey, every step
// in German and English, at the design's 390 px reference and on a 320 px
// phone (568 tall) with 2x text. Shots, per locale and size suffix:
//   onboarding-<step>[-NN]-<locale><suffix>   every step, long ones scrolled
//   onboarding-plan-maintain-<locale><suffix> the plan of a maintain journey
//   onboarding-plan-warning-<locale><suffix>  a plan a safety limit changed
//
// With --dart-define=DARK_REDESIGN_CAPTURE=true the PNGs land in
// build/dark-redesign/. Without it the suite still pins that every step
// renders without an exception or overflow at both sizes and in both
// languages.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/onboarding_screen.dart';

import '../support/design_capture.dart';
import '../support/harness.dart';

/// The 320 px phone: iPhone SE (1st gen), 320 x 568 with a 20 px status bar.
void _narrowViewport(WidgetTester tester) {
  pinDesignViewport(tester);
  const size = Size(320, 568);
  tester.view.physicalSize = size * kDesignPixelRatio;
  const padding = FakeViewPadding(top: 20 * kDesignPixelRatio);
  tester.view.padding = padding;
  tester.view.viewPadding = padding;
}

/// Collects overflow reports instead of failing on the first; the test
/// asserts the list is empty at the end, so every step is checked.
List<String> _collectOverflows() {
  final overflows = <String>[];
  final prior = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exception.toString().contains('overflowed')) {
      overflows.add(details.summary.toString());
      return;
    }
    prior?.call(details);
  };
  addTearDown(() => FlutterError.onError = prior);
  return overflows;
}

Finder _key(String value) => find.byKey(ValueKey(value));

Future<void> _tap(WidgetTester tester, String key) async {
  await tester.ensureVisible(_key(key));
  await tester.pumpAndSettle();
  await tester.tap(_key(key));
  await tester.pumpAndSettle();
}

/// Shoots the current step top to bottom: `-00`, `-01`, … when it scrolls,
/// the bare name when it fits.
Future<void> _shootStep(
  WidgetTester tester,
  String step,
  String name,
) async {
  final scrollable = find
      .descendant(
        of: _key('onboarding-step-$step'),
        matching: find.byType(Scrollable),
      )
      .first;
  final position = tester.state<ScrollableState>(scrollable).position;
  if (position.maxScrollExtent < 24) {
    await captureDesignShot(tester, name);
    return;
  }
  final page = position.viewportDimension * 0.8;
  var i = 0;
  for (double y = 0; ; y += page) {
    position.jumpTo(y.clamp(0, position.maxScrollExtent));
    await tester.pumpAndSettle();
    final parts = name.split('-');
    // onboarding-<step>-<locale><suffix> -> onboarding-<step>-NN-<locale>…
    parts.insert(2, i.toString().padLeft(2, '0'));
    await captureDesignShot(tester, parts.join('-'));
    i++;
    if (y >= position.maxScrollExtent) break;
  }
  position.jumpTo(0);
  await tester.pumpAndSettle();
}

Future<void> _mount(
  WidgetTester tester, {
  required Locale locale,
  required bool narrow,
  UserProfile profile = const UserProfile(),
}) async {
  if (narrow) {
    _narrowViewport(tester);
  } else {
    pinDesignViewport(tester);
  }
  await tester.pumpWidget(
    designCaptureBoundary(
      localizedApp(
        OnboardingScreen(
          firstName: 'Alex',
          initialProfile: profile,
          onComplete: (_) {},
        ),
        locale: locale,
        textScale: narrow ? 2 : 1,
        safeArea: false,
        scaffold: false,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void _setSlider(WidgetTester tester, String field, int value) {
  tester.widget<Slider>(_key('onboarding-$field-slider')).onChanged!(
    value.toDouble(),
  );
}

void main() {
  setUpAll(loadDesignFonts);

  const sizes = <(String, bool)>[('', false), ('-320-x2', true)];
  const locales = <Locale>[Locale('de'), Locale('en')];

  for (final (suffix, narrow) in sizes) {
    for (final locale in locales) {
      final tag = '${locale.languageCode}$suffix';

      testWidgets('weight-loss journey $tag', (tester) async {
        final overflows = _collectOverflows();
        await _mount(tester, locale: locale, narrow: narrow);

        // 1 goal: lose
        await _tap(tester, 'onboarding-goal-lose');
        await _shootStep(tester, 'goal', 'onboarding-goal-$tag');
        await _tap(tester, 'onboarding-next');

        // 2 about you: female, 34
        expect(_key('onboarding-step-basics'), findsOneWidget);
        await _tap(tester, 'onboarding-sex-female');
        _setSlider(tester, 'age', 34);
        await tester.pumpAndSettle();
        await _shootStep(tester, 'basics', 'onboarding-basics-$tag');
        await _tap(tester, 'onboarding-next');

        // 3 body: 168 cm, 74 kg
        expect(_key('onboarding-step-body'), findsOneWidget);
        _setSlider(tester, 'height', 168);
        _setSlider(tester, 'weight', 74);
        await tester.pumpAndSettle();
        await _shootStep(tester, 'body', 'onboarding-body-$tag');
        await _tap(tester, 'onboarding-next');

        // 4 activity: lightly active
        expect(_key('onboarding-step-activity'), findsOneWidget);
        await _tap(tester, 'onboarding-activity-light');
        await _shootStep(tester, 'activity', 'onboarding-activity-$tag');
        await _tap(tester, 'onboarding-next');

        // 5 target: 66 kg
        expect(_key('onboarding-step-target'), findsOneWidget);
        _setSlider(tester, 'target', 66);
        await tester.pumpAndSettle();
        await _shootStep(tester, 'target', 'onboarding-target-$tag');
        await _tap(tester, 'onboarding-next');

        // 6 pace: moderate (the default)
        expect(_key('onboarding-step-pace'), findsOneWidget);
        await _shootStep(tester, 'pace', 'onboarding-pace-$tag');
        await _tap(tester, 'onboarding-next');

        // 7 diet: vegetarian
        expect(_key('onboarding-step-diet'), findsOneWidget);
        await _shootStep(tester, 'diet', 'onboarding-diet-$tag');
        await _tap(tester, 'onboarding-diet-vegetarian');
        await _tap(tester, 'onboarding-next');

        // 8 plan
        expect(_key('onboarding-step-summary'), findsOneWidget);
        await _shootStep(tester, 'summary', 'onboarding-plan-$tag');
        expect(_key('onboarding-finish'), findsOneWidget);

        expect(tester.takeException(), isNull);
        expect(overflows, isEmpty, reason: overflows.join('\n'));
      });

      testWidgets('maintain plan $tag', (tester) async {
        final overflows = _collectOverflows();
        await _mount(tester, locale: locale, narrow: narrow);
        // Six steps: target and pace are not asked for maintain.
        for (var i = 0; i < 5; i++) {
          await _tap(tester, 'onboarding-next');
        }
        expect(_key('onboarding-step-summary'), findsOneWidget);
        await captureDesignShot(tester, 'onboarding-plan-maintain-$tag');
        expect(tester.takeException(), isNull);
        expect(overflows, isEmpty, reason: overflows.join('\n'));
      });

      testWidgets('plan with a safety note $tag', (tester) async {
        final overflows = _collectOverflows();
        // −1 kg/week at 78 kg: the 1 % cap allows −0.75, the plan says why.
        await _mount(
          tester,
          locale: locale,
          narrow: narrow,
          profile: const UserProfile(
            weightGoal: WeightGoal.lose1kg,
            targetWeightKg: 68,
          ),
        );
        while (_key('onboarding-step-summary').evaluate().isEmpty) {
          await _tap(tester, 'onboarding-next');
        }
        expect(_key('onboarding-summary-pace-warning'), findsOneWidget);
        final scrollable = find
            .descendant(
              of: _key('onboarding-step-summary'),
              matching: find.byType(Scrollable),
            )
            .first;
        await tester.scrollUntilVisible(
          _key('onboarding-summary-pace-warning'),
          200,
          scrollable: scrollable,
        );
        await tester.pumpAndSettle();
        await captureDesignShot(tester, 'onboarding-plan-warning-$tag');
        expect(tester.takeException(), isNull);
        expect(overflows, isEmpty, reason: overflows.join('\n'));
      });
    }
  }
}
