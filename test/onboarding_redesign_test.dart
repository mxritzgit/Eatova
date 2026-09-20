import 'dart:io';
import 'dart:ui' as ui;

import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/onboarding_screen.dart';
import 'package:eatova/src/services/kcal_calculator.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';
import 'support/onboarding_harness.dart';

final _boundary = GlobalKey();
Finder _key(String value) => find.byKey(ValueKey(value));

Future<void> _capture(WidgetTester tester, String name) async {
  const directory = String.fromEnvironment('ONBOARDING_CAPTURE');
  if (directory.isEmpty) return;
  await tester.pumpAndSettle();
  final boundary =
      _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('build/onboarding-preview/$directory/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

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
    RepaintBoundary(
      key: _boundary,
      child: localizedApp(
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
      'Archivo': [
        'Archivo-Regular.ttf',
        'Archivo-Medium.ttf',
        'Archivo-SemiBold.ttf',
        'Archivo-Bold.ttf',
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
        testWidgets('six groups ${brightness.name} $locale at $scale', (
          tester,
        ) async {
          await _mount(
            tester,
            brightness: brightness,
            locale: locale,
            scale: scale,
          );
          for (final step in onboardingGroups) {
            expect(_key('onboarding-step-$step'), findsOneWidget);
            await _capture(tester, '${brightness.name}-$locale-$scale-$step');
            expect(tester.takeException(), isNull);
            if (step == 'goal') {
              await tester.ensureVisible(_key('onboarding-pace-lose05kg'));
              await tester.pumpAndSettle();
              await _capture(tester, '${brightness.name}-$locale-$scale-pace');
            }
            if (step == 'summary') {
              await tester.ensureVisible(_key('onboarding-edit-diet'));
              await tester.pumpAndSettle();
              await _capture(
                tester,
                '${brightness.name}-$locale-$scale-review',
              );
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

      // Editing the first group keeps system Back inside this review session.
      await _tap(tester, 'onboarding-edit-basics');
      expect(
        tester.widget<PopScope<Object?>>(find.byType(PopScope<Object?>).last).canPop,
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
      await goToOnboarding(tester, 'goal');
      await _tap(tester, 'onboarding-goal-lose');
      tester.widget<Slider>(_key('onboarding-target-slider')).onChanged!(70);
      await tester.pumpAndSettle();
      await _tap(tester, 'onboarding-pace-lose025kg');
      await _tap(tester, 'onboarding-goal-lose');
      expect(tester.widget<Text>(_key('onboarding-target-value')).data, '70');
      await _tap(tester, 'onboarding-goal-gain');
      tester.widget<Slider>(_key('onboarding-target-slider')).onChanged!(90);
      await tester.pumpAndSettle();
      await _tap(tester, 'onboarding-goal-maintain');
      expect(_key('onboarding-target-section'), findsNothing);
      expect(_key('onboarding-pace-gain025kg'), findsNothing);
      await _tap(tester, 'onboarding-goal-lose');
      expect(tester.widget<Text>(_key('onboarding-target-value')).data, '70');
      expect(
        tester.getSemantics(_key('onboarding-pace-lose025kg')),
        isSemantics(isSelected: true),
      );
      await _tap(tester, 'onboarding-goal-gain');
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
