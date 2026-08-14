import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/screens/settings/account_change_messages.dart';
import 'package:eatova/src/screens/settings/settings_screen.dart';
import 'package:eatova/src/theme/app_theme.dart';

// Die Re-Authentifizierung vor der Kontoloeschung (Sicherheits-Audit
// 2026-08-14).
//
// Bis dahin genuegte das getippte Wort „LÖSCHEN" — das direkt daneben als
// Hinweistext stand. Die einzige unwiderrufliche Aktion der App war damit
// schwaecher gesichert als der Passwortwechsel eine Gruppe darueber, der einen
// Mail-Code verlangt; serverseitig prueft `delete_account()` nur `auth.uid()`,
// die Hemmschwelle liegt also vollstaendig in der Oberflaeche.
//
// Drei Zusicherungen tragen die Datei:
//
//   1. Das getippte Wort ALLEIN loescht nichts mehr — es fordert nur den Code
//      an. Der Loesch-Callback bleibt nachweislich aus.
//   2. Erst der bestaetigte Code aus dem Postfach loest die Loeschung aus.
//   3. Ein abgelehnter Code loescht nicht, meldet verstaendlich und laesst die
//      Eingabe stehen.
//
// Gegenstelle ist das [InMemoryAuthRepository] (`passwordResets`,
// `verifiedCodes`, `verifyFails`) — dasselbe Muster wie in
// `test/account_change_flows_test.dart`.

/// Gegenstelle, deren Code-Anforderung haengen bleibt, bis der Test sie
/// freigibt — nur so laesst sich der Doppel-Tap ueberhaupt beobachten.
class _LangsamerVersand extends InMemoryAuthRepository {
  _LangsamerVersand({super.initialUser});

  final Completer<void> _tor = Completer<void>();

  void freigeben() => _tor.complete();

  @override
  Future<void> sendPasswordReset(String email) async {
    await _tor.future;
    return super.sendPasswordReset(email);
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  InMemoryAuthRepository baueRepo() {
    final repo = InMemoryAuthRepository(
      initialUser: const EatovaUser(id: 'u1', email: 'jonas@eatova.de'),
    );
    addTearDown(repo.dispose);
    return repo;
  }

  /// Pumpt die Seite als ROUTE ueber einer Starterseite — nur so laesst sich
  /// pruefen, dass die Loeschung die Seite vorher schliesst.
  Future<void> pump(
    WidgetTester tester, {
    AuthRepository? repo,
    Future<void> Function()? onDeleteAccount,
    String? email = 'jonas@eatova.de',
    double textScale = 1.0,
  }) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3.0;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

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
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                key: const ValueKey('open-settings'),
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) => SettingsScreen(
                      email: email,
                      authRepository: repo,
                      onDeleteAccount: onDeleteAccount,
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open-settings')));
    await tester.pumpAndSettle();
  }

  Future<void> tippe(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
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

  /// Bis zum Code-Schritt: Sheet auf, Wort getippt, Code angefordert.
  Future<void> oeffneCodeSchritt(
    WidgetTester tester,
    InMemoryAuthRepository repo,
    Future<void> Function() onDeleteAccount,
  ) async {
    await pump(tester, repo: repo, onDeleteAccount: onDeleteAccount);
    await tippe(tester, find.byKey(const ValueKey('settings-delete-account')));
    await schreibe(tester, 'settings-delete-confirm-field', 'LÖSCHEN');
    await tippe(tester, find.text('Code anfordern'));
  }

  // --- (a) Das getippte Wort allein loescht NICHT mehr -----------------------

  testWidgets('das getippte Wort fordert nur den Code an und loescht nichts',
      (tester) async {
    final repo = baueRepo();
    var geloescht = 0;
    await pump(tester, repo: repo, onDeleteAccount: () async => geloescht++);

    await tippe(tester, find.byKey(const ValueKey('settings-delete-account')));
    // Der alte Zustand: mit dem getippten Wort stand hier sofort der
    // Loesch-Knopf, und ein Tap darauf war das Konto. Im ersten Schritt gibt
    // es ihn gar nicht mehr.
    expect(find.text('Konto endgültig löschen'), findsNothing);

    await schreibe(tester, 'settings-delete-confirm-field', 'LÖSCHEN');
    expect(find.text('Konto endgültig löschen'), findsNothing);

    await tippe(tester, find.text('Code anfordern'));

    expect(geloescht, 0, reason: 'das Wort allein loescht nichts');
    expect(repo.passwordResets, <String>['jonas@eatova.de']);
    // Stattdessen steht die Seite noch, und das Sheet fragt jetzt den Code.
    expect(find.byKey(const ValueKey('screen-settings')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('settings-delete-code-field')),
      findsOneWidget,
    );
    expect(find.text('Konto endgültig löschen'), findsOneWidget);
  });

  testWidgets('ohne das richtige Wort geht nicht einmal die Anforderung raus',
      (tester) async {
    // Die Wort-Huerde selbst ist mit dem zweiten Schritt NICHT weggefallen —
    // sie faengt weiter das Versehen ab, bevor ueberhaupt eine Mail rausgeht.
    // Diese Zusicherung lag bis zum Audit in `settings_screen_test`
    // („Konto löschen" verlangt das getippte Wort) und gehoert jetzt hierher,
    // weil der Rest jenes Falls (Wort tippen = geloescht) genau das ist, was
    // dieser Fix abgeschafft hat.
    final repo = baueRepo();
    var geloescht = 0;
    await pump(tester, repo: repo, onDeleteAccount: () async => geloescht++);

    await tippe(tester, find.byKey(const ValueKey('settings-delete-account')));
    await tester.tap(find.text('Code anfordern'));
    await tester.pumpAndSettle();

    expect(repo.passwordResets, isEmpty);
    expect(geloescht, 0);
    expect(
      find.byKey(const ValueKey('settings-delete-code-field')),
      findsNothing,
    );

    // Ein FALSCHES Wort schaltet ebenfalls nicht scharf.
    await schreibe(tester, 'settings-delete-confirm-field', 'löschen bitte');
    await tester.tap(find.text('Code anfordern'));
    await tester.pumpAndSettle();

    expect(repo.passwordResets, isEmpty);
    expect(geloescht, 0);
    expect(
      find.byKey(const ValueKey('settings-delete-code-field')),
      findsNothing,
    );

    // Kleinschreibung dagegen genuegt: die Huerde schuetzt vor dem Versehen,
    // nicht vor der Shift-Taste.
    await schreibe(tester, 'settings-delete-confirm-field', 'löschen');
    await tippe(tester, find.text('Code anfordern'));

    expect(repo.passwordResets, <String>['jonas@eatova.de']);
    expect(geloescht, 0);
  });

  // --- (b) Erst der bestaetigte Code loescht --------------------------------

  testWidgets('erst der bestaetigte Code loescht das Konto', (tester) async {
    final repo = baueRepo();
    var geloescht = 0;
    await oeffneCodeSchritt(tester, repo, () async => geloescht++);

    await schreibe(tester, 'settings-delete-code-field', '123456');
    await tippe(tester, find.text('Konto endgültig löschen'));

    expect(repo.verifiedCodes, <String>['jonas@eatova.de:123456']);
    expect(geloescht, 1);
    // Erst schliessen, dann loeschen — sonst raeumt der AuthGate die Seite
    // unter dem Nutzer weg und erklaert ihm eine „abgelaufene Sitzung".
    expect(find.byKey(const ValueKey('screen-settings')), findsNothing);
  });

  testWidgets('ein zu kurzer Code blockt VOR dem Aufruf', (tester) async {
    // Ein absehbar aussichtsloser Aufruf verbrennt nur den Code — GoTrue
    // akzeptiert ihn nur einmal.
    final repo = baueRepo();
    var geloescht = 0;
    await oeffneCodeSchritt(tester, repo, () async => geloescht++);

    await schreibe(tester, 'settings-delete-code-field', '12345');
    await tippe(tester, find.text('Konto endgültig löschen'));

    expect(repo.verifiedCodes, isEmpty);
    expect(geloescht, 0);
    expect(find.text(kAccountCodeInvalid()), findsOneWidget);
  });

  // --- (c) Ein falscher Code loescht nicht ----------------------------------

  testWidgets('ein falscher Code loescht nicht und meldet verstaendlich',
      (tester) async {
    final repo = baueRepo();
    var geloescht = 0;
    await oeffneCodeSchritt(tester, repo, () async => geloescht++);

    await schreibe(tester, 'settings-delete-code-field', '000000');
    repo.verifyFails = true;
    await tippe(tester, find.text('Konto endgültig löschen'));

    expect(geloescht, 0);
    expect(find.byKey(const ValueKey('settings-delete-error')), findsOneWidget);
    expect(find.text(kAccountCodeRejected()), findsOneWidget);
    // Kein Roh-Detail auf dem Screen.
    expect(find.textContaining('AuthException'), findsNothing);
    expect(find.textContaining('Token has expired'), findsNothing);
    // Sheet bleibt offen, die Eingabe steht noch — wer sich vertippt, soll
    // korrigieren koennen statt von vorn anzufangen.
    expect(find.byKey(const ValueKey('delete-account-sheet')), findsOneWidget);
    expect(find.text('000000'), findsOneWidget);
    expect(find.byKey(const ValueKey('screen-settings')), findsOneWidget);
  });

  // --- Riegel und Sichtbarkeit ---------------------------------------------

  testWidgets('zwei Taps auf „Code anfordern" fordern nur EINEN Code an',
      (tester) async {
    final repo = _LangsamerVersand(
      initialUser: const EatovaUser(id: 'u1', email: 'jonas@eatova.de'),
    );
    addTearDown(repo.dispose);

    await pump(tester, repo: repo, onDeleteAccount: () async {});
    await tippe(tester, find.byKey(const ValueKey('settings-delete-account')));
    await schreibe(tester, 'settings-delete-confirm-field', 'LÖSCHEN');

    // Zwei Taps OHNE Frame dazwischen: der Baum traegt den Knopf noch als
    // scharf, allein der Riegel im Handler verhindert den zweiten Versand.
    await tester.tap(find.text('Code anfordern'));
    await tester.tap(find.text('Code anfordern'));
    await tester.pump();

    expect(find.text('Code wird angefordert…'), findsOneWidget);

    repo.freigeben();
    await tester.pumpAndSettle();

    expect(repo.passwordResets, hasLength(1));
    expect(
      find.byKey(const ValueKey('settings-delete-code-field')),
      findsOneWidget,
    );
  });

  testWidgets('beide Schritte rendern bei textScale 2.0 ohne Overflow',
      (tester) async {
    // Uebernommen aus `settings_screen_render_test` — dort konnte der Fall nur
    // den ersten Schritt sehen, weil es keinen zweiten gab. Der Code-Schritt
    // ist der engere von beiden: Untertitel mit voller Mailadresse,
    // beschriftetes Ziffernfeld und der 52-px-Knopf.
    final repo = baueRepo();
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
      await pump(
        tester,
        repo: repo,
        onDeleteAccount: () async {},
        textScale: 2.0,
      );

      // Bei doppelter Schrift liegt der Loesch-Block weit unterhalb des
      // Viewports, und die Seite ist eine (lazy) ListView — ohne Scrollen
      // existiert er gar nicht erst im Baum.
      final oeffner = find.byKey(const ValueKey('settings-delete-account'));
      await tester.scrollUntilVisible(
        oeffner,
        400,
        scrollable: find.descendant(
          of: find.byKey(const ValueKey('screen-settings')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(oeffner);
      await tester.pumpAndSettle();

      await schreibe(tester, 'settings-delete-confirm-field', 'LÖSCHEN');
      await tippe(tester, find.text('Code anfordern'));

      expect(
        find.byKey(const ValueKey('settings-delete-code-field')),
        findsOneWidget,
      );
      await schreibe(tester, 'settings-delete-code-field', '123456');
    } finally {
      FlutterError.onError = prior;
    }

    expect(overflows, isEmpty, reason: overflows.join('\n'));
  });

  testWidgets('ohne AuthRepository fehlt der Loesch-Block ganz',
      (tester) async {
    // Ohne Auth-Schicht gibt es nichts, wogegen sich der Nutzer erneut
    // ausweisen koennte — dann wird die unwiderrufliche Aktion gar nicht erst
    // angeboten (dieselbe Regel wie fuer Passwort- und Adresswechsel).
    //
    // Im Betrieb tritt der Fall nicht auf: `EatovaApp` reicht Repository und
    // Adresse gemeinsam durch (`eatova_app.dart:162`), waehrend der
    // Loesch-Callback am Sync haengt. Nur Previews und Tests, die den Screen
    // nackt pumpen, sehen ihn — und dort ist die fehlende Zeile die richtige
    // Antwort.
    await pump(tester, onDeleteAccount: () async {});

    expect(find.byKey(const ValueKey('settings-delete-account')), findsNothing);
  });

  testWidgets('ohne bekannte Adresse fehlt der Loesch-Block ebenfalls',
      (tester) async {
    // Der Code wird gegen GENAU diese Adresse verifiziert — ohne sie liesse
    // sich der zweite Schritt nicht abschliessen, und ein Sheet, das in einer
    // Sackgasse endet, ist schlimmer als eine fehlende Zeile.
    //
    // Die Sitzung schlaegt den Aufruf-Parameter (`_adresse`), also muss auch
    // der Nutzer des Repositorys ohne Adresse dastehen — sonst prueft der Fall
    // nichts.
    final repo = InMemoryAuthRepository(
      initialUser: const EatovaUser(id: 'u1'),
    );
    addTearDown(repo.dispose);

    await pump(tester, repo: repo, onDeleteAccount: () async {}, email: null);

    expect(find.byKey(const ValueKey('settings-delete-account')), findsNothing);
  });
}
