import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthException;

import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/screens/auth_screen.dart';

import 'support/harness.dart';

// Fix run 2026-08-27, package B:
//  * F2-03 — "please confirm your e-mail first" is no dead end any more: the
//    note carries an inline action that opens the signup code page for the
//    typed address (the resend path exists there).
//  * F2-05 — the error mapper works on TYPES and GoTrue codes, never on a
//    localized sentence (the old check matched the German word "abgebrochen").

/// GoTrue with mail confirmation on: signup succeeds, login with the same
/// address fails with `email_not_confirmed` until the code is verified.
class _UnconfirmedAuthRepository extends InMemoryAuthRepository {
  final Set<String> unconfirmed = <String>{};

  @override
  Future<SignUpOutcome> signUp({
    required String email,
    required String password,
    required String displayName,
  }) async {
    unconfirmed.add(email.trim());
    return SignUpOutcome.created;
  }

  @override
  Future<void> signIn({required String email, required String password}) async {
    if (unconfirmed.contains(email.trim())) {
      throw const AuthException('Email not confirmed',
          statusCode: '400', code: 'email_not_confirmed');
    }
    return super.signIn(email: email, password: password);
  }
}

/// Fails every sign-in with [error].
class _FailingAuthRepository extends InMemoryAuthRepository {
  _FailingAuthRepository(this.error);

  final Object error;

  @override
  Future<void> signIn({required String email, required String password}) =>
      Future<void>.error(error);

  @override
  Future<void> signInWithOAuth(EatovaOAuthProvider provider) =>
      Future<void>.error(error);
}

Future<void> _pumpAuth(WidgetTester tester, AuthRepository repo) async {
  pinPhoneViewport(tester);
  await pumpLocalized(
    tester,
    AuthScreen(authRepository: repo),
    // Motion stays on: with duration 0 the screen's AnimatedSize re-dirties
    // itself inside its own performLayout.
    reducedMotion: false,
    scaffold: false,
    safeArea: false,
    settle: true,
  );
}

Future<void> _login(WidgetTester tester, String email) async {
  await tester.enterText(find.byKey(const ValueKey('auth-email-field')), email);
  await tester.enterText(
      find.byKey(const ValueKey('auth-password-field')), 'eatova123');
  await tester.ensureVisible(find.byKey(const ValueKey('auth-submit')));
  await tester.tap(find.byKey(const ValueKey('auth-submit')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('F2-03: Signup -> Zurueck -> Login mit derselben Adresse fuehrt '
      'per Inline-Aktion zur Code-Eingabe', (tester) async {
    final repo = _UnconfirmedAuthRepository();
    addTearDown(repo.dispose);
    await _pumpAuth(tester, repo);

    // Register.
    await tester.ensureVisible(find.byKey(const ValueKey('auth-toggle-register')));
    await tester.tap(find.byKey(const ValueKey('auth-toggle-register')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('auth-name-field')), 'Moritz');
    await _login(tester, 'moritz@example.com');
    expect(find.byKey(const ValueKey('auth-code-screen')), findsOneWidget);

    // Back without entering the code (mail not there yet).
    await tester.tap(find.byKey(const ValueKey('auth-code-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-auth')), findsOneWidget);

    // Login mode, same address.
    await tester.ensureVisible(find.byKey(const ValueKey('auth-toggle-login')));
    await tester.tap(find.byKey(const ValueKey('auth-toggle-login')));
    await tester.pumpAndSettle();
    await _login(tester, 'moritz@example.com');

    expect(find.byKey(const ValueKey('auth-error')), findsOneWidget);
    expect(find.text(deL10n.authErrorEmailNotConfirmed), findsOneWidget);
    final action = find.byKey(const ValueKey('auth-enter-code'));
    expect(action, findsOneWidget, reason: 'die Meldung braucht einen Ausweg');
    expect(tester.getSemantics(action),
        isSemantics(isButton: true, label: deL10n.authEnterCodeCta));

    await tester.ensureVisible(action);
    await tester.tap(action);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('auth-code-screen')), findsOneWidget);
    expect(find.byKey(const ValueKey('code-field')), findsOneWidget,
        reason: 'Signup-Flow startet direkt beim Code');
    expect(find.textContaining('moritz@example.com'), findsOneWidget,
        reason: 'die getippte Adresse ist vorbelegt');

    // The resend path is the signup one, not a password reset.
    await tester.tap(find.byKey(const ValueKey('code-resend')));
    await tester.pumpAndSettle();
    expect(repo.signupResends, ['moritz@example.com']);
    expect(repo.passwordResets, isEmpty);
  });

  testWidgets('ohne Bestaetigungs-Fehler gibt es keine Code-Aktion',
      (tester) async {
    final repo = _FailingAuthRepository(
        const AuthException('Invalid login credentials'));
    addTearDown(repo.dispose);
    await _pumpAuth(tester, repo);
    await _login(tester, 'moritz@example.com');
    expect(find.text(deL10n.authErrorInvalidCredentials), findsOneWidget);
    expect(find.byKey(const ValueKey('auth-enter-code')), findsNothing);
  });

  group('F2-05: Fehler-Erkennung ueber Typ und Code', () {
    testWidgets('AuthCancelledException -> Abbruch-Meldung', (tester) async {
      final repo =
          _FailingAuthRepository(const AuthCancelledException('Google'));
      addTearDown(repo.dispose);
      await _pumpAuth(tester, repo);
      await tester.tap(find.byKey(const ValueKey('auth-google-oauth')));
      await tester.pumpAndSettle();
      expect(find.text(deL10n.authErrorCancelled), findsOneWidget);
      expect(find.text(deL10n.authErrorGeneric), findsNothing);
    });

    testWidgets('AuthUnavailableException -> Neustart-Hinweis',
        (tester) async {
      final repo = _FailingAuthRepository(const AuthUnavailableException());
      addTearDown(repo.dispose);
      await _pumpAuth(tester, repo);
      await _login(tester, 'moritz@example.com');
      expect(find.text(deL10n.authErrorUnavailable), findsOneWidget);
    });

    testWidgets('GoTrue-Code invalid_credentials zaehlt auch ohne den '
        'bekannten Satz', (tester) async {
      final repo = _FailingAuthRepository(const AuthException(
          'something else entirely',
          statusCode: '400',
          code: 'invalid_credentials'));
      addTearDown(repo.dispose);
      await _pumpAuth(tester, repo);
      await _login(tester, 'moritz@example.com');
      expect(find.text(deL10n.authErrorInvalidCredentials), findsOneWidget);
    });

    testWidgets('unbekannter Fehler -> generische Meldung', (tester) async {
      final repo = _FailingAuthRepository(StateError('kaputt'));
      addTearDown(repo.dispose);
      await _pumpAuth(tester, repo);
      await _login(tester, 'moritz@example.com');
      expect(find.text(deL10n.authErrorGeneric), findsOneWidget);
    });
  });
}
