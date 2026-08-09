import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/settings/goals_screen.dart';
import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/widgets/design/design.dart';
import 'package:eatova/src/widgets/shared/settings_sheet.dart';

// „Profil & Ziele": sanfter BMI-Hinweis am Wunschgewicht (erscheint/verschwindet
// live beim Tippen) und das DSGVO-Mindestalter 16 — dieselben Grenzen wie
// Onboarding und DB-Constraint.
//
// Das Alter wurde frueher beim Speichern still auf 16 geklemmt. Das schrieb
// einem 12-Jaehrigen ein erfundenes Alter ins Profil (und in den
// Kalorienbedarf), ohne dass er es je erfahren haette. Seit C1 gilt fuer
// getippte Werte durchgaengig: ablehnen, nicht verbiegen.
//
// Der Dateiname bleibt, obwohl der Screen seit dem Design-Refactor 2026-08-09
// kein Sheet mehr ist: ein Umbenennen sieht in der Historie wie Loeschen aus.
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
    await tester.pumpWidget(
      MaterialApp(
        theme: buildEatovaTheme(Brightness.light),
        home: Scaffold(
          body: Builder(
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
        ),
      ),
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

    // Ziel 70 kg / 1,78 m → BMI 22,1: kein Hinweis.
    expect(find.byKey(const ValueKey('target-bmi-hint')), findsNothing);

    // Ziel 55 kg → BMI 17,4 (< 18,5): sanfter Hinweis erscheint.
    await tester.enterText(
      find.byKey(const ValueKey('settings-target-weight')),
      '55',
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('target-bmi-hint')), findsOneWidget);
    expect(find.textContaining('unterhalb'), findsOneWidget);

    // Ziel 120 kg → BMI 37,9 (> 35): milder Hinweis nach oben.
    await tester.enterText(
      find.byKey(const ValueKey('settings-target-weight')),
      '120',
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('target-bmi-hint')), findsOneWidget);
    expect(find.textContaining('oberhalb'), findsOneWidget);

    // Zurück in den unauffälligen Bereich: Hinweis verschwindet.
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

    // Kein stiller Clamp mehr: das Feld sagt, was erlaubt ist, und „Speichern"
    // ist so lange aus.
    expect(find.text('16–100 Jahre'), findsOneWidget);
    expect(
      tester
          .widget<PrimaryActionButton>(
            find.byKey(const ValueKey('settings-save')),
          )
          .onTap,
      isNull,
    );

    // Nach der Korrektur geht es weiter — und zwar mit dem Wert des Nutzers.
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
