import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/screens/settings/settings_screen.dart';
import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/theme/theme_mode_controller.dart';

// Die Einstellungen (Design-Refactor 2026-08-10) — Konto, Präferenzen, Daten,
// Gefahrenzone. „Profil & Ziele" ist seit dieser Trennung eine eigene Seite;
// hier steht nur noch die Zeile, die dorthin fuehrt.
//
// Der Pruefgegenstand dieser Datei ist VERHALTEN, nicht Geometrie:
//
//   1. Jede Zeile ruft ihren Callback — sonst ist sie Dekoration.
//   2. Ein FEHLENDER Callback blendet seine Zeile AUS. Bewusst nicht
//      „deaktiviert": ein grauer Eintrag behauptet, es gaebe den Weg, und die
//      App koenne ihn gerade nur nicht. Ohne Sync gibt es ihn schlicht nicht.
//   3. Der Erscheinungsbild-Umschalter setzt den Modus wirklich (er ist die
//      einzige Einstellung, die dieser Screen selbst schreibt).
/// Zaehlt Route-Pops. Dient dem Ordnungsbeweis „erst schliessen, dann den
/// Callback rufen" — der Widget-Baum taugt dafuer nicht, weil die gepoppte
/// Route waehrend ihrer Ausblend-Animation noch darin steht.
class _PopSpion extends NavigatorObserver {
  int pops = 0;

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pops++;
    super.didPop(route, previousRoute);
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  /// Pumpt die Seite als ROUTE ueber einer Starterseite — nur so laesst sich
  /// pruefen, dass Ausloggen und Loeschen die Seite vorher schliessen.
  Future<void> pump(
    WidgetTester tester, {
    String? email = 'jonas@example.com',
    /// Die Auth-Schicht. Seit dem Sicherheits-Audit 2026-08-14 traegt sie
    /// nicht nur Passwort- und Adresswechsel, sondern auch die
    /// Re-Authentifizierung vor der Kontoloeschung — ohne sie entfaellt der
    /// Loesch-Block ersatzlos.
    AuthRepository? authRepository,
    VoidCallback? onOpenGoals,
    Future<void> Function()? onSignOut,
    Future<void> Function()? onDeleteAccount,
    Future<String> Function()? onExportData,
    ThemeModeController? controller,
    Brightness brightness = Brightness.light,
    NavigatorObserver? observer,
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

    final app = MaterialApp(
      theme: buildEatovaTheme(brightness),
      locale: const Locale('de'),
      supportedLocales: const [Locale('de'), Locale('en')],
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      navigatorObservers: <NavigatorObserver>[
        if (observer != null) observer,
      ],
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: FilledButton(
              key: const ValueKey('open-settings'),
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => SettingsScreen(
                    email: email,
                    authRepository: authRepository,
                    onOpenGoals: onOpenGoals,
                    onSignOut: onSignOut,
                    onDeleteAccount: onDeleteAccount,
                    onExportData: onExportData,
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.pumpWidget(
      controller == null
          ? app
          : ThemeModeScope(controller: controller, child: app),
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

  /// Gegenstelle fuer die Zeilen, die an der Auth-Schicht haengen — dieselbe
  /// wie in `test/account_change_flows_test.dart` und
  /// `test/delete_account_reauth_test.dart`.
  InMemoryAuthRepository baueRepo() {
    final repo = InMemoryAuthRepository(
      initialUser: const EatovaUser(id: 'u1', email: 'jonas@example.com'),
    );
    addTearDown(repo.dispose);
    return repo;
  }

  // --- Grundgeruest ---------------------------------------------------------

  testWidgets('die Seite traegt ihren Schluessel und ihren Titel',
      (tester) async {
    await pump(tester);

    expect(find.byKey(const ValueKey('screen-settings')), findsOneWidget);
    expect(find.text('Einstellungen'), findsOneWidget);
    // Der Schluessel `screen-goals` gehoert seit der Trennung der ANDEREN
    // Seite — hier darf er nicht auftauchen.
    expect(find.byKey(const ValueKey('screen-goals')), findsNothing);

    // Kein Verwerfen-Schutz: dieser Screen haelt keinen ungespeicherten
    // Entwurf. Jede Zeile wirkt sofort, der Zurueck-Knopf geht also sofort.
    await tippe(tester, find.byKey(const ValueKey('settings-back')));
    expect(find.byKey(const ValueKey('discard-changes-dialog')), findsNothing);
    expect(find.byKey(const ValueKey('screen-settings')), findsNothing);
  });

  testWidgets('die Attrappen der Vorlage sind nicht gebaut', (tester) async {
    // „Units", „Language", „Weekly summary email" haben in dieser App keine
    // Funktion (deutsch, metrisch, kein Wochen-Report). Diese Zusicherung ist
    // die Bremse gegen ein spaeteres „bauen wir schonmal ein".
    await pump(tester, onOpenGoals: () {});

    for (final text in const <String>[
      'Einheiten',
      'Sprache',
      'Wochenrückblick',
      'Passwort ändern',
      'Apple Health',
    ]) {
      expect(find.text(text), findsNothing, reason: text);
    }
  });

  // --- KONTO ----------------------------------------------------------------

  testWidgets('die Mailadresse steht als Untertitel', (tester) async {
    await pump(tester, email: 'jonas@example.com');

    expect(find.byKey(const ValueKey('settings-email')), findsOneWidget);
    expect(find.text('jonas@example.com'), findsOneWidget);
  });

  testWidgets('ohne Mailadresse entfaellt die KONTO-Gruppe ganz',
      (tester) async {
    await pump(tester, email: null);

    expect(find.byKey(const ValueKey('settings-email')), findsNothing);
    expect(find.text('KONTO'), findsNothing);
  });

  // --- PRAEFERENZEN ---------------------------------------------------------

  testWidgets('„Profil & Ziele" ruft onOpenGoals', (tester) async {
    var aufgerufen = 0;
    await pump(tester, onOpenGoals: () => aufgerufen++);

    expect(find.text('Profil & Ziele'), findsOneWidget);
    await tippe(tester, find.byKey(const ValueKey('settings-open-goals')));

    expect(aufgerufen, 1);
  });

  testWidgets('ohne onOpenGoals fehlt die Zeile', (tester) async {
    await pump(tester);

    expect(find.byKey(const ValueKey('settings-open-goals')), findsNothing);
  });

  testWidgets('die drei Optionen schalten den Modus wirklich um',
      (tester) async {
    final controller = ThemeModeController();
    addTearDown(controller.dispose);

    await pump(tester, controller: controller);
    expect(controller.mode, ThemeMode.system);

    await tippe(tester, find.byKey(const ValueKey('settings-theme-mode-dark')));
    expect(controller.mode, ThemeMode.dark);

    await tippe(tester, find.byKey(const ValueKey('settings-theme-mode-light')));
    expect(controller.mode, ThemeMode.light);

    await tippe(
      tester,
      find.byKey(const ValueKey('settings-theme-mode-system')),
    );
    expect(controller.mode, ThemeMode.system);
  });

  testWidgets('ohne ThemeModeScope fehlt die Erscheinungsbild-Zeile ersatzlos',
      (tester) async {
    // Previews und Tests, die nur diesen Screen pumpen. Ein Schalter ohne
    // Controller waere ein toter Schalter — also gar keiner.
    await pump(tester);

    expect(find.text('Erscheinungsbild'), findsNothing);
    expect(find.byKey(const ValueKey('settings-theme-mode')), findsNothing);
  });

  // --- DATEN & PRIVATSPHAERE ------------------------------------------------

  testWidgets('„Daten exportieren" oeffnet die Auskunft mit dem JSON',
      (tester) async {
    var aufgerufen = 0;
    await pump(
      tester,
      onExportData: () async {
        aufgerufen++;
        return '{ "meals": [] }';
      },
    );

    await tippe(tester, find.byKey(const ValueKey('settings-export')));

    expect(aufgerufen, 1);
    expect(find.text('Datenauskunft'), findsOneWidget);
    expect(find.text('{ "meals": [] }'), findsOneWidget);
    // Derselbe Kopieren-Knopf wie im Profil — ein zweites Export-Sheet gibt
    // es bewusst nicht.
    expect(find.byKey(const ValueKey('profile-export-copy')), findsOneWidget);
  });

  testWidgets('ohne onExportData fehlt die Export-Zeile', (tester) async {
    await pump(tester);

    expect(find.byKey(const ValueKey('settings-export')), findsNothing);
  });

  testWidgets('die drei Rechtsseiten stehen als Zeilen mit ihren Schluesseln',
      (tester) async {
    // DSGVO Art. 13 / § 5 DDG: nach dem Login erreichbar, nicht nur auf dem
    // Auth-Screen. Die Schluessel sind unveraendert die aus
    // [SettingsLegalLinks] (DESIGN_REFACTOR §6: „Key bleibt Key").
    await pump(tester);

    expect(find.byKey(const ValueKey('settings-privacy-link')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-terms-link')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-imprint-link')), findsOneWidget);
    expect(find.text('Datenschutz'), findsOneWidget);
    expect(find.text('Impressum'), findsOneWidget);
  });

  // --- GEFAHRENZONE ---------------------------------------------------------

  testWidgets('„Ausloggen" schliesst erst die Seite und ruft dann den Callback',
      (tester) async {
    // Die Reihenfolge ist Absicht: `AuthGate` zeigt „Deine Sitzung ist
    // abgelaufen", wenn beim Auth-Wechsel noch Routen offen sind. Nach einem
    // gewollten Logout waere das schlicht falsch.
    // Gemessen wird die Navigator-Historie, nicht der Widget-Baum: die Route
    // ist beim Callback bereits gepoppt, ihre Ausblend-Animation laeuft aber
    // noch — der Baum wuerde also luegen.
    final spion = _PopSpion();
    var abgemeldet = 0;
    var popsBeimCallback = -1;
    await pump(
      tester,
      observer: spion,
      onSignOut: () async {
        abgemeldet++;
        popsBeimCallback = spion.pops;
      },
    );

    await tippe(tester, find.byKey(const ValueKey('settings-sign-out')));

    expect(abgemeldet, 1);
    expect(popsBeimCallback, 1, reason: 'erst schliessen, dann abmelden');
    expect(find.byKey(const ValueKey('screen-settings')), findsNothing);
  });

  testWidgets('ohne onSignOut fehlt die Zeile', (tester) async {
    await pump(tester);

    expect(find.byKey(const ValueKey('settings-sign-out')), findsNothing);
  });

  testWidgets('ohne beide Gefahren-Callbacks fehlt die ganze Gruppe',
      (tester) async {
    // MIT Auth-Schicht, damit der Fall wirklich die fehlenden Callbacks misst
    // und nicht bloss das fehlende Repository.
    await pump(tester, authRepository: baueRepo());

    expect(find.text('GEFAHRENZONE'), findsNothing);
    expect(find.byKey(const ValueKey('settings-delete-account')), findsNothing);
  });

  testWidgets('„Konto löschen" verlangt das getippte Wort und danach den Code',
      (tester) async {
    // Seit dem Sicherheits-Audit 2026-08-14 sind es ZWEI Huerden, und dieser
    // Fall haelt fest, dass KEINE von beiden allein loescht. Bis dahin genuegte
    // das getippte Wort — das direkt daneben als Hinweistext stand.
    //
    // Die Wort-Huerde ist dabei NICHT entfallen: sie faengt weiter das
    // Versehen ab, bevor ueberhaupt eine Mail rausgeht. Der Code faengt den
    // fremden Finger am entsperrten Geraet.
    //
    // Die Feinheiten des zweiten Schritts (zu kurzer Code, abgelehnter Code,
    // Doppel-Tap) liegen in `test/delete_account_reauth_test.dart`.
    final repo = baueRepo();
    var geloescht = 0;
    await pump(
      tester,
      authRepository: repo,
      onDeleteAccount: () async => geloescht++,
    );

    await tippe(tester, find.byKey(const ValueKey('settings-delete-account')));
    // Schritt 1 traegt den Loesch-Knopf gar nicht: hier wird nichts geloescht,
    // hier wird der Code angefordert.
    expect(find.text('Code anfordern'), findsOneWidget);
    expect(find.text('Konto endgültig löschen'), findsNothing);

    // Ohne das Wort ist der Knopf nicht scharf — es geht nicht einmal eine
    // Mail raus.
    await tester.tap(find.text('Code anfordern'));
    await tester.pumpAndSettle();
    expect(repo.passwordResets, isEmpty);
    expect(geloescht, 0);

    // Ein FALSCHES Wort schaltet ebenfalls nicht scharf.
    await tester.enterText(
      find.byKey(const ValueKey('settings-delete-confirm-field')),
      'löschen bitte',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Code anfordern'));
    await tester.pumpAndSettle();
    expect(repo.passwordResets, isEmpty);
    expect(geloescht, 0);

    // Mit dem Wort geht der Code raus (Kleinschreibung genuegt: die Huerde
    // schuetzt vor dem Versehen, nicht vor der Shift-Taste) — geloescht ist
    // damit aber NICHTS.
    await tester.enterText(
      find.byKey(const ValueKey('settings-delete-confirm-field')),
      'löschen',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Code anfordern'));
    await tester.pumpAndSettle();

    expect(repo.passwordResets, <String>['jonas@example.com']);
    expect(geloescht, 0, reason: 'das getippte Wort allein loescht nichts');
    expect(find.byKey(const ValueKey('screen-settings')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('settings-delete-code-field')),
      findsOneWidget,
    );

    // Auch der Loesch-Knopf selbst loescht nicht, solange kein Code steht.
    await tester.tap(find.text('Konto endgültig löschen'));
    await tester.pumpAndSettle();
    expect(repo.verifiedCodes, isEmpty);
    expect(geloescht, 0);
    expect(find.byKey(const ValueKey('screen-settings')), findsOneWidget);

    // Erst der vom SERVER bestaetigte Code laeuft durch — Seite zu, dann der
    // Callback.
    await tester.enterText(
      find.byKey(const ValueKey('settings-delete-code-field')),
      '12345678',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Konto endgültig löschen'));
    await tester.pumpAndSettle();

    expect(repo.verifiedCodes, <String>['jonas@example.com:12345678']);
    expect(geloescht, 1);
    expect(find.byKey(const ValueKey('screen-settings')), findsNothing);
  });

  testWidgets('ohne onDeleteAccount fehlt der Loesch-Block', (tester) async {
    // Auch hier mit Repository: die Zeile fehlt wegen des fehlenden Callbacks,
    // nicht wegen der fehlenden Auth-Schicht.
    await pump(
      tester,
      authRepository: baueRepo(),
      onSignOut: () async {},
    );

    expect(find.text('GEFAHRENZONE'), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-sign-out')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-delete-account')), findsNothing);
    expect(find.text('Konto löschen'), findsNothing);
  });
}
