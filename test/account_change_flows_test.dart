import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthException;

import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/screens/settings/account_change_messages.dart';
import 'package:eatova/src/services/secure_screen.dart';
import 'package:eatova/src/screens/settings/settings_screen.dart';
import 'package:eatova/src/theme/app_theme.dart';

// The two account-change flows in settings.
//
// Checks the UI against the already tested auth contract
// (`test/auth_account_change_test.dart`), with [InMemoryAuthRepository] as the
// recording counterpart. Three guarantees: no server call the app can rule out
// beforehand; both email codes go to the RIGHT address and one alone does not
// finish the change; a rejected code keeps the input and hides raw details.

/// Counterpart that rejects exactly the SECOND `confirmEmailChange` call —
/// `InMemoryAuthRepository.verifyFails` always hits the next one, the first.
class _ZweiterCodeScheitert extends InMemoryAuthRepository {
  _ZweiterCodeScheitert({super.initialUser});

  int _aufrufe = 0;

  @override
  Future<void> confirmEmailChange({
    required String email,
    required String code,
  }) async {
    _aufrufe++;
    if (_aufrufe == 2) {
      throw const AuthException('Token has expired or is invalid');
    }
    return super.confirmEmailChange(email: email, code: code);
  }
}

/// Counterpart whose first call hangs until released, making the loading
/// state observable.
class _LangsamerStart extends InMemoryAuthRepository {
  _LangsamerStart({super.initialUser});

  final Completer<void> _tor = Completer<void>();

  void freigeben() => _tor.complete();

  @override
  Future<void> startPasswordChange() async {
    await _tor.future;
    return super.startPasswordChange();
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  InMemoryAuthRepository baueRepo() {
    final repo = InMemoryAuthRepository(
      initialUser: const EatovaUser(id: 'u1', email: 'alt@eatova.de'),
    );
    addTearDown(repo.dispose);
    return repo;
  }

  Future<void> pump(
    WidgetTester tester, {
    AuthRepository? repo,
    String? email = 'alt@eatova.de',
    Brightness brightness = Brightness.light,
  }) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildEatovaTheme(brightness),
        // context.l10n throughout; without delegates it throws.
        locale: const Locale('de'),
        supportedLocales: const [Locale('de'), Locale('en')],
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: SettingsScreen(email: email, authRepository: repo),
      ),
    );
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

  /// Lets a standing toast expire, else the test clock reports a live timer.
  Future<void> raeumeToastAb(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  }

  /// Up to the code step of the password change.
  Future<void> oeffnePasswortSchritt2(
    WidgetTester tester,
    InMemoryAuthRepository repo,
  ) async {
    await pump(tester, repo: repo);
    await tippe(tester, find.byKey(const ValueKey('settings-change-password')));
    await tippe(tester, find.text('Code anfordern'));
  }

  /// Up to the double-code step of the email change.
  Future<void> oeffneMailSchritt2(
    WidgetTester tester,
    InMemoryAuthRepository repo, {
    String ziel = 'neu@eatova.de',
  }) async {
    await pump(tester, repo: repo);
    await tippe(tester, find.byKey(const ValueKey('settings-change-email')));
    await schreibe(tester, 'email-change-new-address', ziel);
    await tippe(tester, find.text('Codes anfordern'));
  }

  // --- The two rows ---------------------------------------------------------

  group('Die Zeilen in der Gruppe KONTO', () {
    testWidgets('stehen da, sobald ein AuthRepository durchgereicht ist',
        (tester) async {
      await pump(tester, repo: baueRepo());

      expect(
        find.byKey(const ValueKey('settings-change-password')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('settings-change-email')),
        findsOneWidget,
      );
      expect(find.text('Passwort ändern'), findsOneWidget);
      expect(find.text('E-Mail-Adresse ändern'), findsOneWidget);
    });

    testWidgets('fehlen ersatzlos ohne AuthRepository', (tester) async {
      // No greyed-out row: a disabled row would claim the path exists.
      await pump(tester);

      expect(
        find.byKey(const ValueKey('settings-change-password')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('settings-change-email')), findsNothing);
      expect(find.text('Passwort ändern'), findsNothing);
      expect(find.text('E-Mail-Adresse ändern'), findsNothing);
      expect(find.byKey(const ValueKey('settings-email')), findsOneWidget);
    });

    // Codes and addresses must not reach the app-switcher preview; the guard
    // is ref-counted, so nesting is free.
    for (final schluessel in const <String>[
      'settings-change-password',
      'settings-change-email',
    ]) {
      testWidgets('$schluessel oeffnet ein Sheet unter einem SecureScreenGuard',
          (tester) async {
        await pump(tester, repo: baueRepo());
        expect(find.byType(SecureScreenGuard), findsOneWidget);

        await tippe(tester, find.byKey(ValueKey<String>(schluessel)));

        expect(find.byType(SecureScreenGuard), findsNWidgets(2));
      });
    }
  });

  // --- Flow 1: password -----------------------------------------------------

  group('Passwort ändern', () {
    testWidgets('„Code anfordern" ruft startPasswordChange', (tester) async {
      final repo = baueRepo();
      await oeffnePasswortSchritt2(tester, repo);

      expect(repo.reauthRequests, <String>['alt@eatova.de']);
      // Fields appear only afterwards: an empty code field is a dead end.
      expect(
        find.byKey(const ValueKey('password-change-code')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('password-change-new')), findsOneWidget);
    });

    testWidgets('reicht Code UND neues Passwort durch', (tester) async {
      final repo = baueRepo();
      await oeffnePasswortSchritt2(tester, repo);

      await schreibe(tester, 'password-change-code', '12345678');
      await schreibe(tester, 'password-change-new', 'geheim99');
      await schreibe(tester, 'password-change-repeat', 'geheim99');
      await tippe(tester, find.text('Passwort jetzt ändern'));

      expect(repo.usedNonces, <String>['12345678']);
      expect(repo.passwordUpdates, <String>['geheim99']);
      expect(
        find.byKey(const ValueKey('password-change-sheet')),
        findsNothing,
      );
      expect(find.text('Passwort geändert.'), findsOneWidget);
      await raeumeToastAb(tester);
    });

    testWidgets('eine abweichende Wiederholung blockt VOR dem Aufruf',
        (tester) async {
      final repo = baueRepo();
      await oeffnePasswortSchritt2(tester, repo);

      await schreibe(tester, 'password-change-code', '12345678');
      await schreibe(tester, 'password-change-new', 'geheim99');
      await schreibe(tester, 'password-change-repeat', 'geheim98');
      await tippe(tester, find.text('Passwort jetzt ändern'));

      expect(repo.usedNonces, isEmpty);
      expect(repo.passwordUpdates, isEmpty);
      expect(find.text(kAccountPasswordMismatch()), findsOneWidget);
      expect(
        find.byKey(const ValueKey('password-change-sheet')),
        findsOneWidget,
      );
    });

    testWidgets('ein zu kurzes Passwort blockt VOR dem Aufruf', (tester) async {
      // Same minimum as auth_screen.dart / auth_code_screen.dart: 8 chars.
      final repo = baueRepo();
      await oeffnePasswortSchritt2(tester, repo);

      await schreibe(tester, 'password-change-code', '12345678');
      await schreibe(tester, 'password-change-new', 'kurz');
      await schreibe(tester, 'password-change-repeat', 'kurz');
      await tippe(tester, find.text('Passwort jetzt ändern'));

      expect(repo.passwordUpdates, isEmpty);
      expect(
        find.text('Das Passwort braucht mindestens 8 Zeichen.'),
        findsOneWidget,
      );
    });

    testWidgets('ein Code mit weniger als 8 Ziffern blockt VOR dem Aufruf',
        (tester) async {
      final repo = baueRepo();
      await oeffnePasswortSchritt2(tester, repo);

      await schreibe(tester, 'password-change-code', '12345');
      await schreibe(tester, 'password-change-new', 'geheim99');
      await schreibe(tester, 'password-change-repeat', 'geheim99');
      await tippe(tester, find.text('Passwort jetzt ändern'));

      expect(repo.usedNonces, isEmpty);
      expect(find.text('Der Code hat 8 Ziffern.'), findsOneWidget);
    });

    testWidgets('der Knopf sperrt waehrend des Aufrufs und sagt es',
        (tester) async {
      final repo = _LangsamerStart(
        initialUser: const EatovaUser(id: 'u1', email: 'alt@eatova.de'),
      );
      addTearDown(repo.dispose);

      await pump(tester, repo: repo);
      await tippe(
        tester,
        find.byKey(const ValueKey('settings-change-password')),
      );

      // Two taps with NO frame between: only the latch in the handler blocks
      // the second call.
      await tester.tap(find.text('Code anfordern'));
      await tester.tap(find.text('Code anfordern'));
      await tester.pump();

      expect(find.text('Code wird angefordert…'), findsOneWidget);
      expect(find.text('Code anfordern'), findsNothing);

      repo.freigeben();
      await tester.pumpAndSettle();

      expect(repo.reauthRequests, hasLength(1));
      expect(
        find.byKey(const ValueKey('password-change-code')),
        findsOneWidget,
      );
    });

    testWidgets('ein falscher Code meldet verstaendlich und laesst alles stehen',
        (tester) async {
      final repo = baueRepo();
      await oeffnePasswortSchritt2(tester, repo);

      await schreibe(tester, 'password-change-code', '00000000');
      await schreibe(tester, 'password-change-new', 'geheim99');
      await schreibe(tester, 'password-change-repeat', 'geheim99');
      repo.verifyFails = true;
      await tippe(tester, find.text('Passwort jetzt ändern'));

      expect(repo.passwordUpdates, isEmpty);
      expect(
        find.byKey(const ValueKey('password-change-error')),
        findsOneWidget,
      );
      expect(find.text(kAccountCodeRejected()), findsOneWidget);
      // No raw detail on screen.
      expect(find.textContaining('AuthException'), findsNothing);
      expect(find.textContaining('Token has expired'), findsNothing);
      // And the input survives: nobody retypes a password over a wrong code.
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('password-change-code')))
            .controller
            ?.text,
        '00000000',
      );
      expect(
        find.byKey(const ValueKey('password-change-sheet')),
        findsOneWidget,
      );
    });
  });

  // --- Flow 2: email --------------------------------------------------------

  group('E-Mail-Adresse ändern', () {
    testWidgets('reicht die getrimmte Adresse an startEmailChange',
        (tester) async {
      final repo = baueRepo();
      await oeffneMailSchritt2(tester, repo, ziel: '  neu@eatova.de  ');

      expect(repo.emailChangeRequests, <String>['neu@eatova.de']);
      expect(
        find.byKey(const ValueKey('email-change-code-old')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('email-change-code-new')),
        findsOneWidget,
      );
    });

    testWidgets('zeigt beide Adressen im Klartext an ihren Feldern',
        (tester) async {
      final repo = baueRepo();
      await oeffneMailSchritt2(tester, repo);

      // Which code goes where must not be guesswork.
      expect(find.text('alt@eatova.de'), findsWidgets);
      expect(find.text('neu@eatova.de'), findsWidgets);
      expect(
        find.byKey(const ValueKey('email-change-both-hint')),
        findsOneWidget,
      );
    });

    testWidgets('verifiziert JEDEN Code mit SEINER Adresse', (tester) async {
      final repo = baueRepo();
      await oeffneMailSchritt2(tester, repo);

      await schreibe(tester, 'email-change-code-old', '11111111');
      await schreibe(tester, 'email-change-code-new', '22222222');
      await tippe(tester, find.text('Adresse jetzt ändern'));

      expect(repo.verifiedCodes, <String>[
        'alt@eatova.de:11111111',
        'neu@eatova.de:22222222',
      ]);
      expect(repo.currentUser?.email, 'neu@eatova.de');
      expect(find.byKey(const ValueKey('email-change-sheet')), findsNothing);
      expect(find.text('E-Mail-Adresse geändert.'), findsOneWidget);
      await raeumeToastAb(tester);
    });

    testWidgets('ein einzelner Code schliesst den Vorgang NICHT ab',
        (tester) async {
      final repo = baueRepo();
      await oeffneMailSchritt2(tester, repo);

      await schreibe(tester, 'email-change-code-old', '11111111');
      await tippe(tester, find.text('Adresse jetzt ändern'));

      // Not even the one code is sent: it would burn for nothing.
      expect(repo.verifiedCodes, isEmpty);
      expect(repo.currentUser?.email, 'alt@eatova.de');
      expect(find.byKey(const ValueKey('email-change-sheet')), findsOneWidget);
      expect(find.text('Der Code hat 8 Ziffern.'), findsOneWidget);
    });

    testWidgets('eine ungueltige Adresse blockt VOR dem Aufruf',
        (tester) async {
      final repo = baueRepo();
      await pump(tester, repo: repo);
      await tippe(tester, find.byKey(const ValueKey('settings-change-email')));

      await schreibe(tester, 'email-change-new-address', 'keine-adresse');
      await tippe(tester, find.text('Codes anfordern'));

      expect(repo.emailChangeRequests, isEmpty);
      expect(find.text('Bitte gib eine gültige E-Mail ein.'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('email-change-code-old')),
        findsNothing,
      );
    });

    testWidgets('die eigene Adresse ist keine Aenderung', (tester) async {
      final repo = baueRepo();
      await pump(tester, repo: repo);
      await tippe(tester, find.byKey(const ValueKey('settings-change-email')));

      await schreibe(tester, 'email-change-new-address', 'ALT@eatova.de');
      await tippe(tester, find.text('Codes anfordern'));

      expect(repo.emailChangeRequests, isEmpty);
      expect(find.text(kAccountEmailUnchanged()), findsOneWidget);
    });

    testWidgets('ein falscher Code laesst beide Eingaben stehen',
        (tester) async {
      final repo = baueRepo();
      await oeffneMailSchritt2(tester, repo);

      await schreibe(tester, 'email-change-code-old', '00000000');
      await schreibe(tester, 'email-change-code-new', '22222222');
      repo.verifyFails = true;
      await tippe(tester, find.text('Adresse jetzt ändern'));

      expect(repo.currentUser?.email, 'alt@eatova.de');
      expect(find.text(kAccountCodeRejected()), findsWidgets);
      expect(
        tester
            .widget<TextField>(
                find.byKey(const ValueKey('email-change-code-new')))
            .controller
            ?.text,
        '22222222',
      );
      expect(find.byKey(const ValueKey('email-change-sheet')), findsOneWidget);
    });

    testWidgets('ein zweiter Anlauf wiederholt den bereits geglueckten Code '
        'nicht', (tester) async {
      // GoTrue burns a confirmed code, so a retry must not resubmit the first.
      final repo = _ZweiterCodeScheitert(
        initialUser: const EatovaUser(id: 'u1', email: 'alt@eatova.de'),
      );
      addTearDown(repo.dispose);

      await pump(tester, repo: repo);
      await tippe(tester, find.byKey(const ValueKey('settings-change-email')));
      await schreibe(tester, 'email-change-new-address', 'neu@eatova.de');
      await tippe(tester, find.text('Codes anfordern'));

      await schreibe(tester, 'email-change-code-old', '11111111');
      await schreibe(tester, 'email-change-code-new', '99999999');
      await tippe(tester, find.text('Adresse jetzt ändern'));

      expect(repo.verifiedCodes, <String>['alt@eatova.de:11111111']);
      expect(repo.currentUser?.email, 'alt@eatova.de');

      await schreibe(tester, 'email-change-code-new', '22222222');
      await tippe(tester, find.text('Adresse jetzt ändern'));

      expect(repo.verifiedCodes, <String>[
        'alt@eatova.de:11111111',
        'neu@eatova.de:22222222',
      ], reason: 'der erste Code darf NICHT erneut eingereicht werden');
      expect(find.text('E-Mail-Adresse geändert.'), findsOneWidget);
      await raeumeToastAb(tester);
    });

    testWidgets('die Einstellungen zeigen danach die neue Adresse',
        (tester) async {
      final repo = baueRepo();
      await oeffneMailSchritt2(tester, repo);

      await schreibe(tester, 'email-change-code-old', '11111111');
      await schreibe(tester, 'email-change-code-new', '22222222');
      await tippe(tester, find.text('Adresse jetzt ändern'));
      await raeumeToastAb(tester);

      // The page listens to `authStateChanges`, not a route rebuild.
      expect(find.text('neu@eatova.de'), findsOneWidget);
    });
  });

  // --- The error translator (pure, no widget) -------------------------------

  group('accountChangeErrorMessage', () {
    test('uebersetzt den abgelaufenen/falschen Code', () {
      expect(
        accountChangeErrorMessage(
            const AuthException('Token has expired or is invalid')),
        kAccountCodeRejected(),
      );
    });

    test('uebersetzt eine bereits vergebene Adresse — ohne sie zu bestaetigen',
        () {
      expect(
        accountChangeErrorMessage(const AuthException(
            'A user with this email address has already been registered')),
        deL10n.settingsAccountEmailNotAvailable,
        reason: 'die alte Meldung („wird bereits verwendet") bestaetigte '
            'fremde Kontoexistenz (Audit 2026-08-14)',
      );
    });

    test('uebersetzt ein zu schwaches Passwort', () {
      expect(
        accountChangeErrorMessage(
            const AuthException('Password should be at least 6 characters')),
        'Dieses Passwort ist zu schwach. Nimm ein längeres oder '
            'ungewöhnlicheres.',
      );
    });

    test('uebersetzt fehlendes Netz', () {
      expect(
        accountChangeErrorMessage(const SocketException('no route to host')),
        startsWith('Offline'),
      );
    });

    test('uebersetzt eine Sperre wegen zu vieler Versuche', () {
      expect(
        accountChangeErrorMessage(const AuthException(
            'For security purposes, you can only request this after 51 seconds')),
        startsWith('Zu viele Versuche'),
      );
    });

    test('gibt NIE den Roh-Text weiter', () {
      // An AuthException text can carry internals, so unknown stays generic.
      const roh = 'unexpected_failure at https://xyz.supabase.co/auth/v1/user';
      final meldung = accountChangeErrorMessage(const AuthException(roh));

      expect(meldung, 'Das hat gerade nicht geklappt. Bitte versuch es später '
          'erneut.');
      expect(meldung.contains('supabase'), isFalse);
    });
  });
}
