import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/settings/goals_screen.dart';
import 'package:eatova/src/widgets/design/design.dart';
import 'package:eatova/src/widgets/shared/settings_sheet.dart';

import 'support/harness.dart';

// C1 — the settings free-text fields went into the upsert unchecked.
// `digitsOnly` is a type guard, not a range guard: "75,5" becomes 755 and
// violates `weight_kg between 30 and 300`, and the resulting PostgreSQL 23514
// carries the whole failed row including the email (the Sentry leak).
//
// REJECT, not clamp: clamping 755 to 300 writes a number nobody meant.
// "locked" means: no callback on the [PrimaryActionButton].
void main() {
  Future<Future<SettingsResult?>> openSettings(
    WidgetTester tester, {
    UserProfile profile = const UserProfile(),
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
      brightness: Brightness.light,
    );
    await tester.tap(find.byKey(const ValueKey('open-settings')));
    await tester.pumpAndSettle();
    return result;
  }

  VoidCallback? saveHandler(WidgetTester tester) => tester
      .widget<PrimaryActionButton>(find.byKey(const ValueKey('settings-save')))
      .onTap;

  Future<void> tippe(WidgetTester tester, String key, String text) async {
    await tester.enterText(find.byKey(ValueKey(key)), text);
    await tester.pump();
  }

  testWidgets(
      'jedes Feld sperrt ausserhalb seiner DB-Grenze und speichert korrigiert '
      'genau den eingetippten Wert', (tester) async {
    final resultFuture = await openSettings(tester);
    expect(saveHandler(tester), isNotNull);

    // (field, rejected input, the field's message, corrected value). The
    // target weight has its own case in goals_target_consistency_test.dart.
    for (final (feld, falsch, meldung, richtig) in const [
      // "75,5" with the comma swallowed: the 23514 of the review.
      ('settings-weight', '755', '30–300 kg (ganze Zahl)', '76'),
      ('settings-weight', '25', '30–300 kg (ganze Zahl)', '76'),
      ('settings-weight', '', 'Bitte ausfüllen', '76'),
      ('settings-height', '17', '100–250 cm', '182'),
      // GDPR art. 8, the same bounds as onboarding and the DB constraint.
      // The age used to be clamped to 16 on save, writing an invented age
      // into a 12-year-old's profile and calorie target.
      ('settings-age', '12', '16–100 Jahre', '31'),
      ('settings-steps-goal', '999', '1000–100000', '8000'),
    ]) {
      final fall = '$feld "$falsch"';
      await tippe(tester, feld, falsch);
      expect(find.text(meldung), findsOneWidget, reason: fall);
      expect(saveHandler(tester), isNull,
          reason: '$fall: ein 23514 darf gar nicht erst abgeschickt werden');
      expect(find.byKey(const ValueKey('settings-validation-note')),
          findsOneWidget, reason: fall);

      await tippe(tester, feld, richtig);
      expect(find.text(meldung), findsNothing, reason: fall);
      expect(saveHandler(tester), isNotNull, reason: fall);
    }

    await tester.ensureVisible(find.byKey(const ValueKey('settings-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-save')));
    await tester.pumpAndSettle();

    // Rejected, never bent: what is saved is what the user typed last.
    final result = (await resultFuture)!.profile;
    expect(result.weightKg, 76);
    expect(result.heightCm, 182);
    expect(result.ageYears, 31);
    expect(result.dailyStepsGoal, 8000);
  });

  testWidgets(
      'manuelles kcal-Ziel misst an der DB-Grenze, nicht an der Rechner-Klemme',
      (tester) async {
    // Manual mode comes from the persisted flag (F7-01), not from a stored
    // vs. computed comparison, so the kcal/macro fields are visible.
    final resultFuture = await openSettings(
      tester,
      profile: const UserProfile(manualEnergy: true),
    );

    await tippe(tester, 'settings-kcal', '500');
    expect(find.text('800–7000 kcal'), findsOneWidget);
    expect(saveHandler(tester), isNull);

    // 1000 is below the calculator floor (1350), but it is a deliberate manual
    // choice and within the DB range (800..7000).
    await tippe(tester, 'settings-kcal', '1000');
    expect(saveHandler(tester), isNotNull);

    await tester.ensureVisible(find.byKey(const ValueKey('settings-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-save')));
    await tester.pumpAndSettle();

    expect((await resultFuture)!.profile.dailyKcalGoal, 1000);
  });

  testWidgets('manuelle Makros tragen ihre eigenen DB-Grenzen',
      (tester) async {
    await openSettings(tester, profile: const UserProfile(manualEnergy: true));

    await tippe(tester, 'settings-protein', '401');
    expect(find.text('0–400 g'), findsOneWidget);
    expect(saveHandler(tester), isNull);
    await tippe(tester, 'settings-protein', '130');

    await tippe(tester, 'settings-carbs', '801');
    expect(find.text('0–800 g'), findsOneWidget);
    expect(saveHandler(tester), isNull);
    await tippe(tester, 'settings-carbs', '240');

    await tippe(tester, 'settings-fat', '301');
    expect(find.text('0–300 g'), findsOneWidget);
    expect(saveHandler(tester), isNull);
    await tippe(tester, 'settings-fat', '70');

    expect(saveHandler(tester), isNotNull);
  });

  testWidgets('versteckte Makro-Felder blockieren das Speichern nicht',
      (tester) async {
    final resultFuture = await openSettings(
      tester,
      profile: const UserProfile(manualEnergy: true),
    );

    // Garbage into the kcal field, then back to live mode: the field is gone
    // and the values come from the calculation, so nothing may stay locked.
    await tippe(tester, 'settings-kcal', '500');
    expect(saveHandler(tester), isNull);

    await tester
        .ensureVisible(find.byKey(const ValueKey('settings-manual-energy')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-manual-energy')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('settings-kcal')), findsNothing);
    expect(saveHandler(tester), isNotNull);

    await tester.ensureVisible(find.byKey(const ValueKey('settings-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-save')));
    await tester.pumpAndSettle();

    // Live value: BMR 1665 × PAL 1.3 = 2164 → 2150 rounded to 50.
    final result = (await resultFuture)!.profile;
    expect(result.dailyKcalGoal, 2150);
    expect(result.manualEnergy, isFalse,
        reason: 'live -> false wird explizit geschrieben (F7-01)');
  });
}
