import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/settings/goals_screen.dart';
import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/widgets/design/design.dart';
import 'package:eatova/src/widgets/shared/settings_sheet.dart';

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
    await tester.pumpWidget(
      MaterialApp(
        theme: buildEatovaTheme(Brightness.light),
        locale: const Locale('de'),
        supportedLocales: const [Locale('de'), Locale('en')],
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
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

  VoidCallback? saveHandler(WidgetTester tester) => tester
      .widget<PrimaryActionButton>(find.byKey(const ValueKey('settings-save')))
      .onTap;

  Future<void> tippe(WidgetTester tester, String key, String text) async {
    await tester.enterText(find.byKey(ValueKey(key)), text);
    await tester.pump();
  }

  testWidgets('755 kg (verschlucktes Komma) sperrt das Speichern',
      (tester) async {
    await openSettings(tester);
    expect(saveHandler(tester), isNotNull);

    await tippe(tester, 'settings-weight', '755');

    expect(find.text('30–300 kg (ganze Zahl)'), findsOneWidget);
    expect(saveHandler(tester), isNull,
        reason: 'ein 23514 darf gar nicht erst abgeschickt werden');
    expect(find.byKey(const ValueKey('settings-validation-note')),
        findsOneWidget);
  });

  testWidgets('25 kg (Tippfehler) sperrt das Speichern ebenfalls',
      (tester) async {
    await openSettings(tester);
    await tippe(tester, 'settings-weight', '25');

    expect(find.text('30–300 kg (ganze Zahl)'), findsOneWidget);
    expect(saveHandler(tester), isNull);
  });

  testWidgets('korrigiertes Gewicht gibt das Speichern wieder frei',
      (tester) async {
    final resultFuture = await openSettings(tester);
    await tippe(tester, 'settings-weight', '755');
    expect(saveHandler(tester), isNull);

    await tippe(tester, 'settings-weight', '76');
    expect(find.text('30–300 kg (ganze Zahl)'), findsNothing);
    expect(saveHandler(tester), isNotNull);

    await tester.ensureVisible(find.byKey(const ValueKey('settings-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-save')));
    await tester.pumpAndSettle();

    final result = await resultFuture;
    expect(result!.profile.weightKg, 76);
  });

  testWidgets('Groesse ausserhalb 100–250 cm wird abgelehnt', (tester) async {
    await openSettings(tester);
    await tippe(tester, 'settings-height', '17');

    expect(find.text('100–250 cm'), findsOneWidget);
    expect(saveHandler(tester), isNull);
  });

  testWidgets('Alter unter 16 wird abgelehnt statt still geklemmt',
      (tester) async {
    await openSettings(tester);
    await tippe(tester, 'settings-age', '12');

    expect(find.text('16–100 Jahre'), findsOneWidget);
    expect(saveHandler(tester), isNull,
        reason: 'auf 16 zu klemmen schriebe ein erfundenes Alter ins Profil');
  });

  testWidgets('Wunschgewicht ausserhalb 30–300 kg wird abgelehnt',
      (tester) async {
    await openSettings(tester);
    await tippe(tester, 'settings-target-weight', '755');

    expect(find.text('30–300 kg (ganze Zahl)'), findsOneWidget);
    expect(saveHandler(tester), isNull);
  });

  testWidgets('Schritt- und Wasserziel tragen ihre DB-Grenzen',
      (tester) async {
    await openSettings(tester);

    await tippe(tester, 'settings-steps-goal', '999');
    expect(find.text('1000–100000'), findsOneWidget);
    expect(saveHandler(tester), isNull);
    await tippe(tester, 'settings-steps-goal', '8000');
    expect(saveHandler(tester), isNotNull);

    await tippe(tester, 'settings-water', '99');
    expect(find.text('500–12000 ml'), findsOneWidget);
    expect(saveHandler(tester), isNull);
  });

  testWidgets('leeres Pflichtfeld sperrt das Speichern', (tester) async {
    await openSettings(tester);
    await tippe(tester, 'settings-weight', '');

    expect(find.text('Bitte ausfüllen'), findsOneWidget);
    expect(saveHandler(tester), isNull);
  });

  testWidgets(
      'manuelles kcal-Ziel misst an der DB-Grenze, nicht an der Rechner-Klemme',
      (tester) async {
    // 2200 stored vs. 2150 computed → manual mode, so the kcal/macro fields
    // are visible.
    final resultFuture = await openSettings(tester);

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
    await openSettings(tester);

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
    final resultFuture = await openSettings(tester);

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
    expect((await resultFuture)!.profile.dailyKcalGoal, 2150);
  });
}
