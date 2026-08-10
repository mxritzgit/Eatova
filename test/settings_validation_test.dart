import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/settings/goals_screen.dart';
import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/widgets/design/design.dart';
import 'package:eatova/src/widgets/shared/settings_sheet.dart';

// C1 — die Freitextfelder der Einstellungen gingen ungeprueft in den Upsert.
// `digitsOnly` ist ein Typ-Guard, kein Wertebereichs-Guard: „75,5" verliert das
// Komma und wird zu 755, gegen `weight_kg between 30 and 300`. Der resultierende
// PostgreSQL-Fehler 23514 traegt die komplette fehlgeschlagene Zeile inklusive
// E-Mail — das war der reale Ausloeser des Sentry-Leaks.
//
// Richtig ist ABLEHNEN, nicht klemmen: 755 auf 300 zu klemmen schriebe eine
// Zahl ins Profil, die der Nutzer nie gemeint hat.
//
// Seit dem Design-Refactor 2026-08-09 ist „Profil & Ziele" eine ROUTE statt
// eines Sheets; geprueft wird woertlich dasselbe, nur ueber Navigator.push.
// Der Speichern-Knopf ist ein [PrimaryActionButton] (onTap) statt eines
// FilledButton (onPressed) — „gesperrt" heisst weiterhin: kein Callback.
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
      'manuelles kcal-Ziel misst an der DB-Grenze, nicht an der 1200er-Klemme',
      (tester) async {
    // Standardprofil: 2200 gespeichert vs. 2000 gerechnet → Manuell-Modus,
    // die kcal-/Makro-Felder sind sichtbar.
    final resultFuture = await openSettings(tester);

    await tippe(tester, 'settings-kcal', '500');
    expect(find.text('800–7000 kcal'), findsOneWidget);
    expect(saveHandler(tester), isNull);

    // 1000 liegt unter der Rechner-Untergrenze (1200), ist aber eine bewusste
    // manuelle Entscheidung und von der DB gedeckt (800..7000).
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

    // Unsinn ins kcal-Feld, dann zurueck in den Live-Modus: das Feld ist weg,
    // die Werte kommen aus der Rechnung — nichts darf mehr gesperrt sein.
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

    expect((await resultFuture)!.profile.dailyKcalGoal, 2000);
  });
}
