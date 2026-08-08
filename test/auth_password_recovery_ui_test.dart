import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/auth_gate.dart';
import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/screens/auth_screen.dart';
import 'package:eatova/src/theme/app_theme.dart';

// „Passwort vergessen" — UI-Haelfte (2026-08-08).
//
//  * Sign-in: der Link unter dem Passwortfeld stoesst den Reset fuer die
//    getippte E-Mail an. Die Bestaetigung ist IMMER neutral („falls ein
//    Konto existiert…") — ob die Mail existiert oder ein reines
//    Google-Konto ist, verraet die App nicht (Konto-Enumeration).
//  * Recovery: klickt der Nutzer den Mail-Link, tauscht supabase_flutter
//    den Code gegen eine Session und feuert passwordRecovery. Der AuthGate
//    zeigt dann den Neues-Passwort-Dialog — ohne ihn waere der Nutzer
//    einfach eingeloggt und der Reset liefe ins Leere.

Future<void> _pumpAuth(WidgetTester tester, InMemoryAuthRepository repo) async {
  await tester.pumpWidget(MaterialApp(
    theme: buildEatovaTheme(),
    home: AuthScreen(authRepository: repo),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Passwort vergessen: schickt Reset fuer die getippte E-Mail '
      'und bestaetigt neutral', (tester) async {
    final repo = InMemoryAuthRepository();
    await _pumpAuth(tester, repo);

    await tester.enterText(
        find.byKey(const ValueKey('auth-email-field')), 'user@example.com');
    await tester
        .ensureVisible(find.byKey(const ValueKey('auth-forgot-password')));
    await tester.tap(find.byKey(const ValueKey('auth-forgot-password')));
    await tester.pumpAndSettle();

    expect(repo.passwordResets, ['user@example.com']);
    expect(find.byKey(const ValueKey('auth-message')), findsOneWidget);
    expect(find.textContaining('Falls ein Konto'), findsOneWidget,
        reason: 'neutral — keine Aussage, OB das Konto existiert');
  });

  testWidgets('Passwort vergessen ohne E-Mail: Hinweis statt Request',
      (tester) async {
    final repo = InMemoryAuthRepository();
    await _pumpAuth(tester, repo);

    await tester
        .ensureVisible(find.byKey(const ValueKey('auth-forgot-password')));
    await tester.tap(find.byKey(const ValueKey('auth-forgot-password')));
    await tester.pumpAndSettle();

    expect(repo.passwordResets, isEmpty);
    expect(find.byKey(const ValueKey('auth-error')), findsOneWidget);
  });

  testWidgets('Registrieren-Modus zeigt den Link nicht', (tester) async {
    final repo = InMemoryAuthRepository();
    await _pumpAuth(tester, repo);

    await tester
        .ensureVisible(find.byKey(const ValueKey('auth-toggle-register')));
    await tester.tap(find.byKey(const ValueKey('auth-toggle-register')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('auth-forgot-password')), findsNothing,
        reason: 'beim Registrieren gibt es noch kein Passwort zu vergessen');
  });

  testWidgets('passwordRecovery-Event: Neues-Passwort-Dialog erscheint und '
      'speichert', (tester) async {
    final repo = InMemoryAuthRepository(
        initialUser: const EatovaUser(id: 'u1', email: 'user@example.com'));
    await tester.pumpWidget(MaterialApp(
      theme: buildEatovaTheme(),
      home: AuthGate(
        authRepository: repo,
        builder: (context, user, fresh) => const Scaffold(body: Text('Home')),
      ),
    ));
    await tester.pumpAndSettle();

    repo.emitPasswordRecovery();
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('password-reset-dialog')), findsOneWidget);

    await tester.enterText(
        find.byKey(const ValueKey('password-reset-field')), 'neues-passwort9');
    await tester.tap(find.byKey(const ValueKey('password-reset-submit')));
    await tester.pumpAndSettle();

    expect(repo.passwordUpdates, ['neues-passwort9']);
    expect(find.byKey(const ValueKey('password-reset-dialog')), findsNothing,
        reason: 'nach dem Speichern schliesst der Dialog');
  });

  testWidgets('passwordRecovery: zu kurzes Passwort wird abgelehnt',
      (tester) async {
    final repo = InMemoryAuthRepository(
        initialUser: const EatovaUser(id: 'u1', email: 'user@example.com'));
    await tester.pumpWidget(MaterialApp(
      theme: buildEatovaTheme(),
      home: AuthGate(
        authRepository: repo,
        builder: (context, user, fresh) => const Scaffold(body: Text('Home')),
      ),
    ));
    await tester.pumpAndSettle();
    repo.emitPasswordRecovery();
    await tester.pumpAndSettle();

    await tester.enterText(
        find.byKey(const ValueKey('password-reset-field')), 'kurz');
    await tester.tap(find.byKey(const ValueKey('password-reset-submit')));
    await tester.pumpAndSettle();

    expect(repo.passwordUpdates, isEmpty);
    expect(find.byKey(const ValueKey('password-reset-dialog')), findsOneWidget,
        reason: 'Dialog bleibt offen, bis ein gueltiges Passwort da ist');
  });
}
