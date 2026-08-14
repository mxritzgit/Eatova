import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/eatova_app.dart';
import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/screens/settings/settings_screen.dart';
import 'package:eatova/src/theme/app_theme.dart';

// Nutzer-Befund 2026-08-10: „ich finde die Einstellung nicht".
//
// Beim Aufteilen von Einstellungen und „Profil & Ziele" hingen im Profil
// beide an EINEM Callback. Das Zahnrad dort trug die Beschriftung
// „Einstellungen", oeffnete aber die Ziele — und die Einstellungen selbst
// waren nur ueber ein Schieberegler-Symbol im Food-Kopf erreichbar.
//
// Analyzer und Testsuite waren dabei gruen: beide Ziele existierten, beide
// Routen funktionierten, nur zeigte der falsche Knopf auf die falsche Seite.
// Diese Tests pruefen deshalb nicht, DASS es die Screens gibt, sondern dass
// man von der Oberflaeche aus TATSAECHLICH bei ihnen ankommt.
//
// Seit dem 2026-08-10 traegt die Datei eine zweite Aufgabe. An diesem Tag ist
// der Profil-Block „Daten & Konto" entfallen (er doppelte die Einstellungen).
// Fuenf seiner sechs Zeilen leben nur noch in den Einstellungen weiter — sie
// haben keinen zweiten Ort mehr, an dem ihr Fehlen auffiele. Die beiden
// letzten Tests unten sind genau dieser Waechter.

void main() {
  Future<void> boot(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    // EatovaApp() loest ihre Sprache seit Paket 6 (i18n) ueber die
    // Geraeteliste auf (resolveEatovaLocale) — der Test-Harness liefert dort
    // KEIN Deutsch (typischerweise en-US), waehrend diese Datei mit
    // deutschen `find.text(...)`-Erwartungen arbeitet. Ohne diese Zeile
    // rendert „Über Eatova" als „About Eatova" und der Text-Fund schlaegt
    // fehl, obwohl nichts kaputt ist.
    tester.platformDispatcher.localesTestValue = const [Locale('de')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    await tester.pumpWidget(const EatovaApp());
    await tester.pumpAndSettle();
  }

  Future<void> tippe(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> oeffneProfil(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('today-profile')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-profile')), findsOneWidget);
  }

  Future<void> oeffneEinstellungen(WidgetTester tester) async {
    await oeffneProfil(tester);
    await tester.tap(find.byKey(const ValueKey('profile-open-settings')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-settings')), findsOneWidget);
  }

  testWidgets('das Zahnrad im Profil fuehrt in die EINSTELLUNGEN',
      (tester) async {
    await boot(tester);
    await oeffneProfil(tester);

    await tester.tap(find.byKey(const ValueKey('profile-open-settings')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('screen-settings')), findsOneWidget,
        reason: 'ein Zahnrad mit der Beschriftung „Einstellungen" muss in '
            'die Einstellungen fuehren');
    expect(find.byKey(const ValueKey('screen-goals')), findsNothing);

    // Final-Review i18n-Grundgeruest: die Zeile haengt am LocaleScope der
    // App-Schale — faellt der Scope, verschwindet sie STILL. Ankunft allein
    // genuegt deshalb nicht: beide Praeferenz-Zeilen muessen DA sein.
    expect(find.byKey(const ValueKey('settings-language')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-theme-mode')), findsOneWidget);

    // Dasselbe Muster fuer die Auth-Schicht: seit dem Sicherheits-Audit
    // 2026-08-14 haengen an ihr drei Zeilen — Passwortwechsel, Adresswechsel
    // UND die Kontoloeschung. Reicht die Schale das Repository nicht durch,
    // verschwinden alle drei STILL (kein Analyzer-Fehler, kein Absturz). Diese
    // Zeile ist der Waechter dafuer, dass die Schale es tut.
    expect(
      find.byKey(const ValueKey('settings-change-password')),
      findsOneWidget,
      reason: 'ohne durchgereichtes AuthRepository entfaellt auch der '
          'Loesch-Block ersatzlos',
    );
  });

  testWidgets('die Bearbeiten-Knoepfe im Profil fuehren auf „Profil & Ziele"',
      (tester) async {
    // Bis 2026-08-10 lief dieser Weg ueber die Zeile `profile-action-edit` im
    // Block „Daten & Konto". Der Block ist weg; der Weg haengt seither an den
    // Bearbeiten-Knoepfen von Plan- und Zielkarte. Genau deshalb wird hier
    // BEIDES geprueft und nicht nur einer davon.
    await boot(tester);

    for (final key in const <String>[
      'profile-goalplan-edit',
      'profile-edit-goals',
    ]) {
      await oeffneProfil(tester);
      await tippe(tester, find.byKey(ValueKey(key)));

      expect(find.byKey(const ValueKey('screen-goals')), findsOneWidget,
          reason: key);
      expect(find.byKey(const ValueKey('screen-settings')), findsNothing);

      // Zurueck aufs Heute, damit der naechste Durchlauf sauber startet.
      await tippe(tester, find.byKey(const ValueKey('settings-close')));
      await tippe(tester, find.byKey(const ValueKey('profile-close')));
    }
  });

  testWidgets('auch der Kopf des Food-Tabs fuehrt in die Einstellungen',
      (tester) async {
    await boot(tester);
    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('topbar-settings')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('screen-settings')), findsOneWidget);
  });

  testWidgets('von den Einstellungen kommt man weiter zu den Zielen',
      (tester) async {
    await boot(tester);
    await oeffneEinstellungen(tester);

    await tippe(tester, find.byKey(const ValueKey('settings-open-goals')));

    expect(find.byKey(const ValueKey('screen-goals')), findsOneWidget);
  });

  testWidgets('„Über Eatova" ist aus der laufenden App heraus erreichbar',
      (tester) async {
    // Die einzige der sechs Profil-Zeilen ohne Gegenstueck in den
    // Einstellungen — deshalb ist sie mitsamt Sheet UMGEZOGEN statt geloescht.
    // Und das nicht aus Nostalgie: das Sheet traegt die nach ODbL
    // vorgeschriebene Quellennennung fuer die OpenFoodFacts-Daten und die
    // Datenschutz-Zeile nach DSGVO Art. 13 (auch nach dem Login erreichbar,
    // nicht nur auf dem Auth-Screen).
    await boot(tester);
    await oeffneEinstellungen(tester);

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('settings-about')),
      300,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('screen-settings')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Über Eatova'), findsOneWidget);

    await tippe(tester, find.byKey(const ValueKey('settings-about')));

    expect(find.text('Quellen'), findsOneWidget);
    expect(find.textContaining('OpenFoodFacts'), findsOneWidget,
        reason: 'die Quellennennung ist lizenzrechtlich vorgeschrieben (ODbL)');
    expect(find.byKey(const ValueKey('profile-privacy-link')), findsOneWidget,
        reason: 'Key bleibt Key — er ist mit dem Sheet mitgewandert');
  });

  testWidgets('alle Wege des entfallenen Profil-Blocks stehen im Screen',
      (tester) async {
    // DER Waechter. Die Schale oben kann nicht alle Zeilen zeigen: Export und
    // Kontoloeschung haengen am Sync, den es im Test/Preview nicht gibt (ein
    // grauer Eintrag waere schlimmer als keiner, s. settings_screen.dart).
    // Der VOLL verdrahtete Screen zeigt sie — und genau er ist der Ort, an dem
    // auffallen muss, wenn beim naechsten Umbau eine davon verschwindet.
    //
    // „Tagesdaten zurücksetzen" fehlt hier bewusst: die Aktion ist ersatzlos
    // gestrichen, nicht umgezogen (Nutzer-Entscheid). Die Negativ-Zusicherung
    // dazu haelt `goals_screen_render_test`.
    //
    // Seit dem Sicherheits-Audit 2026-08-14 gehoert das [AuthRepository] zur
    // vollen Verdrahtung: die Kontoloeschung verlangt eine echte
    // Re-Authentifizierung per Mail-Code und entfaellt ohne Auth-Schicht
    // ersatzlos. Die App reicht es immer durch (`eatova_app.dart` baut es
    // notfalls selbst und gibt es an `EatovaHomePage` weiter, die es an diesen
    // Screen haengt) — dass sie das TUT, prueft der erste Fall dieser Datei am
    // gebooteten `EatovaApp`. Hier steht deshalb dieselbe Verdrahtung wie im
    // Betrieb, nur mit der In-Memory-Gegenstelle.
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final repo = InMemoryAuthRepository(
      initialUser: const EatovaUser(id: 'u1', email: 'jonas@example.com'),
    );
    addTearDown(repo.dispose);

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
        home: SettingsScreen(
          email: 'jonas@example.com',
          authRepository: repo,
          onOpenGoals: () {},
          onSignOut: () async {},
          onDeleteAccount: () async {},
          onExportData: () async => '{}',
        ),
      ),
    );
    await tester.pumpAndSettle();

    final scroller = find.descendant(
      of: find.byKey(const ValueKey('screen-settings')),
      matching: find.byType(Scrollable),
    );

    for (final zeile in const <({String key, String text})>[
      // „Profil & Ziele"     — vormals profile-action-edit
      (key: 'settings-open-goals', text: 'Profil & Ziele'),
      // „Daten exportieren"  — vormals profile-action-export
      (key: 'settings-export', text: 'Daten exportieren'),
      // „Über Eatova"        — vormals profile-action-about
      (key: 'settings-about', text: 'Über Eatova'),
      // „Ausloggen"          — vormals profile-action-logout
      (key: 'settings-sign-out', text: 'Ausloggen'),
      // „Konto löschen"      — vormals profile-action-delete
      (key: 'settings-delete-account', text: 'Konto löschen'),
    ]) {
      await tester.scrollUntilVisible(
        find.byKey(ValueKey(zeile.key)),
        300,
        scrollable: scroller,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey(zeile.key)), findsOneWidget,
          reason: zeile.key);
      expect(find.text(zeile.text), findsOneWidget, reason: zeile.text);
    }
  });
}
