import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/screens/settings/settings_screen.dart';
import 'package:eatova/src/theme/app_theme.dart';

// DESIGN_REFACTOR §7.2 / §5: beide Konto-Aenderungs-Flows rendern in BEIDEN
// Helligkeiten und bei Systemschrift 200 % ohne RenderFlex-Overflow.
//
// Die Bruchstellen sind hier andere als auf der Seite selbst: zwei bzw. drei
// Eingabefelder plus Erklaertext plus Fehlerkasten in einem Bottom-Sheet, das
// nur die Bildschirmhoehe hat. Overflows werden deshalb NICHT geschluckt —
// sie sind der Pruefgegenstand.

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  /// Faengt Overflow-Meldungen ein, statt sie den Test hart abbrechen zu
  /// lassen — so steht am Ende die vollstaendige Liste im Fehlerbericht.
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
        home: SettingsScreen(
          email: 'jonas.schmidt.mit.langer.adresse@beispiel-mail.de',
          authRepository: repo,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return repo;
  }

  /// Scrollt die Zeile in den Blick und tippt sie. Bei doppelter Schrift liegt
  /// sie sonst unterhalb des Viewports — und die Seite ist eine lazy ListView.
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

  /// Tippt eine Aktion IM Sheet. Bei doppelter Schrift liegt der Knopf unter
  /// dem sichtbaren Rand — [SheetScaffold] scrollt dafuer, aber der Test muss
  /// den Knopf erst in den Blick holen, sonst geht der Tap ins Leere.
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

          // Der dichteste Zustand: drei Felder mit Feldfehlern.
          await schreibe(tester, 'password-change-code', '12345');
          await schreibe(tester, 'password-change-new', 'kurz');
          await schreibe(tester, 'password-change-repeat', 'anders');
          await tippeAktion(tester, 'Passwort jetzt ändern');

          expect(find.text('Der Code hat 6 Ziffern.'), findsOneWidget);
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

          // Zwei Code-Felder mit je einer langen Adresse darueber, dazu der
          // Doppel-Code-Hinweis und ein abgelehnter Code.
          await schreibe(tester, 'email-change-code-old', '111111');
          await schreibe(tester, 'email-change-code-new', '222222');
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
