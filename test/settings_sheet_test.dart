import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/settings/goals_screen.dart';
import 'package:eatova/src/widgets/design/design.dart';
import 'package:eatova/src/widgets/shared/settings_sheet.dart';

import 'support/harness.dart';

// Profile & goals: the gentle BMI hint on the target weight (appears and
// disappears live while typing) and the GDPR minimum age of 16 — the same
// bounds as onboarding and the DB constraint.
//
// The age used to be silently clamped to 16 on save, writing an invented age
// into a 12-year-old's profile and calorie target. Since C1 typed values are
// rejected, never bent.
//
// The filename stays although the screen is no longer a sheet: renaming looks
// like a deletion in the history.
void main() {
  Future<Future<SettingsResult?>> openSettings(
    WidgetTester tester, {
    required UserProfile profile,
  }) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final prior = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception.toString().contains('overflowed')) return;
      prior?.call(details);
    };
    addTearDown(() => FlutterError.onError = prior);

    late Future<SettingsResult?> result;
    await pumpLocalized(
      tester,
      Builder(
        builder: (context) => Center(
          child: FilledButton(
            key: const ValueKey('open-settings'),
            onPressed: () {
              result = Navigator.of(context).push<SettingsResult>(
                MaterialPageRoute<SettingsResult>(
                  builder: (_) => GoalsScreen(profile: profile),
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
      reducedMotion: false,
      brightness: Brightness.light,
      safeArea: false,
    );
    await tester.tap(find.byKey(const ValueKey('open-settings')));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets(
      'BMI hint appears for a low target weight and disappears again',
      (tester) async {
    await openSettings(
      tester,
      profile: const UserProfile(heightCm: 178, targetWeightKg: 70),
    );

    // Target 70 kg / 1.78 m -> BMI 22.1: no hint.
    expect(find.byKey(const ValueKey('target-bmi-hint')), findsNothing);

    // Target 55 kg -> BMI 17.4 (< 18.5): the gentle hint appears.
    await tester.enterText(
      find.byKey(const ValueKey('settings-target-weight')),
      '55',
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('target-bmi-hint')), findsOneWidget);
    expect(find.textContaining('unterhalb'), findsOneWidget);

    // Target 120 kg -> BMI 37.9 (> 35): the mild upward hint.
    await tester.enterText(
      find.byKey(const ValueKey('settings-target-weight')),
      '120',
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('target-bmi-hint')), findsOneWidget);
    expect(find.textContaining('oberhalb'), findsOneWidget);

    // Back into the unremarkable range: the hint disappears.
    await tester.enterText(
      find.byKey(const ValueKey('settings-target-weight')),
      '70',
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('target-bmi-hint')), findsNothing);
  });

  testWidgets('Alter unter 16 blockiert das Speichern (DSGVO Art. 8)',
      (tester) async {
    final resultFuture = await openSettings(
      tester,
      profile: const UserProfile(),
    );

    await tester.enterText(
      find.byKey(const ValueKey('settings-age')),
      '12',
    );
    await tester.pump();

    // No silent clamp: the field states the allowed range and save stays off.
    expect(find.text('16–100 Jahre'), findsOneWidget);
    expect(
      tester
          .widget<PrimaryActionButton>(
            find.byKey(const ValueKey('settings-save')),
          )
          .onTap,
      isNull,
    );

    // After the correction it proceeds — with the user's own value.
    await tester.enterText(
      find.byKey(const ValueKey('settings-age')),
      '31',
    );
    await tester.pump();

    await tester.ensureVisible(find.byKey(const ValueKey('settings-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-save')));
    await tester.pumpAndSettle();

    final result = await resultFuture;
    expect(result, isNotNull);
    expect(result!.profile.ageYears, 31);
  });
}
