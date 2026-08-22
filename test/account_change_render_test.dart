import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/screens/settings/settings_screen.dart';
import 'package:eatova/src/theme/app_theme.dart';

// DESIGN_REFACTOR §7.2 / §5: both account-change flows render in both
// brightnesses and at 200 % text scale without RenderFlex overflow.
// Overflows are deliberately NOT swallowed — they are what is under test.

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  /// Collects overflow errors instead of failing fast, so the report lists
  /// all of them.
  Future<void> ohneOverflow(
    WidgetTester tester,
    String fall,
    Future<void> Function(WidgetTester tester) ablauf,
  ) async {
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
      await ablauf(tester);
    } finally {
      FlutterError.onError = prior;
    }
    expect(tester.takeException(), isNull);
    expect(overflows, isEmpty, reason: '$fall overflowt:\n${overflows.join('\n')}');
  }

  Future<InMemoryAuthRepository> pump(
    WidgetTester tester, {
    required Brightness brightness,
    double textScale = 1.0,
  }) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3.0;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    final repo = InMemoryAuthRepository(
      initialUser: const EatovaUser(
        id: 'u1',
        email: 'jonas.schmidt.mit.langer.adresse@beispiel-mail.de',
      ),
    );
    addTearDown(repo.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildEatovaTheme(brightness),
        locale: const Locale('de'),
        supportedLocales: const [Locale('de'), Locale('en')],
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: SettingsScreen(
          email: 'jonas.schmidt.mit.langer.adresse@beispiel-mail.de',
          authRepository: repo,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return repo;
  }

  /// Scrolls the row into view and taps it; at double text scale it sits
  /// below the viewport of the lazy ListView.
  Future<void> oeffne(WidgetTester tester, String schluessel) async {
    final ziel = find.byKey(ValueKey<String>(schluessel));
    await tester.scrollUntilVisible(
      ziel,
      200,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('screen-settings')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(ziel);
    await tester.pumpAndSettle();
  }

  Future<void> schreibe(
    WidgetTester tester,
    String schluessel,
    String text,
  ) async {
    await tester.enterText(find.byKey(ValueKey<String>(schluessel)), text);
    await tester.pumpAndSettle();
  }

  /// Taps an action inside the sheet. At double text scale the button sits
  /// below the fold, so the test must scroll it into view first.
  Future<void> tippeAktion(WidgetTester tester, String beschriftung) async {
    final ziel = find.text(beschriftung);
    await tester.ensureVisible(ziel);
    await tester.pumpAndSettle();
    await tester.tap(ziel);
    await tester.pumpAndSettle();
  }

  for (final (name, helligkeit) in const <(String, Brightness)>[
    ('hell', Brightness.light),
    ('dunkel', Brightness.dark),
  ]) {
    for (final skala in const <double>[1.0, 2.0]) {
      testWidgets('Passwort-Flow rendert $name @$skala', (tester) async {
        await ohneOverflow(tester, 'Passwort $name @$skala', (tester) async {
          await pump(tester, brightness: helligkeit, textScale: skala);
          await oeffne(tester, 'settings-change-password');
          expect(
            find.byKey(const ValueKey('password-change-sheet')),
            findsOneWidget,
          );

          await tippeAktion(tester, 'Code anfordern');

          // The densest state: three fields, each with a field error.
          await schreibe(tester, 'password-change-code', '12345');
          await schreibe(tester, 'password-change-new', 'kurz');
          await schreibe(tester, 'password-change-repeat', 'anders');
          await tippeAktion(tester, 'Passwort jetzt ändern');

          expect(find.text('Der Code hat 8 Ziffern.'), findsOneWidget);
        });
      });

      testWidgets('E-Mail-Flow rendert $name @$skala', (tester) async {
        await ohneOverflow(tester, 'E-Mail $name @$skala', (tester) async {
          final repo = await pump(
            tester,
            brightness: helligkeit,
            textScale: skala,
          );
          await oeffne(tester, 'settings-change-email');
          expect(
            find.byKey(const ValueKey('email-change-sheet')),
            findsOneWidget,
          );

          await schreibe(
            tester,
            'email-change-new-address',
            'jonas.neue.sehr.lange.adresse@beispiel-mail.de',
          );
          await tippeAktion(tester, 'Codes anfordern');

          // Two code fields with a long address each, plus the hint and a
          // rejected code.
          await schreibe(tester, 'email-change-code-old', '11111111');
          await schreibe(tester, 'email-change-code-new', '22222222');
          repo.verifyFails = true;
          await tippeAktion(tester, 'Adresse jetzt ändern');

          expect(
            find.byKey(const ValueKey('email-change-both-hint')),
            findsOneWidget,
          );
        });
      });
    }
  }
}
