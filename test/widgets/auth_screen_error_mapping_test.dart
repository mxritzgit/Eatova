import 'dart:io' show SocketException;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' show ClientException;
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthRetryableFetchException;

import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/screens/auth_screen.dart';

import '../support/harness.dart';

/// Throws the typed cancellation that runNativeGoogleSignIn produces when the
/// user aborts.
class _CancelingAuthRepository implements AuthRepository {
  @override
  EatovaUser? get currentUser => null;

  @override
  Stream<EatovaUser?> get authStateChanges => const Stream.empty();

  @override
  Future<void> sendPasswordReset(String email) => throw UnimplementedError();

  @override
  Future<void> verifyRecoveryCode(
          {required String email, required String code}) =>
      throw UnimplementedError();

  @override
  Future<void> verifySignupCode(
          {required String email, required String code}) =>
      throw UnimplementedError();

  @override
  Future<void> resendSignupCode(String email) => throw UnimplementedError();

  @override
  Future<void> updatePassword(String newPassword) => throw UnimplementedError();

  @override
  Future<void> startPasswordChange() async {}

  @override
  Future<void> confirmPasswordChange({
    required String code,
    required String newPassword,
  }) async {}

  @override
  Future<void> startEmailChange(String newEmail) async {}

  @override
  Future<void> confirmEmailChange({
    required String email,
    required String code,
  }) async {}

  @override
  Future<void> signIn({required String email, required String password}) =>
      throw UnimplementedError();

  @override
  Future<SignUpOutcome> signUp({
    required String email,
    required String password,
    required String displayName,
  }) =>
      throw UnimplementedError();

  @override
  Future<void> signInWithOAuth(EatovaOAuthProvider provider) async {
    throw const AuthCancelledException('Google');
  }

  @override
  Future<void> signOut() async {}
}

/// Throws [fehler] on the e-mail login — the path `_friendlyError` classifies.
class _WerfendesLoginRepository extends InMemoryAuthRepository {
  _WerfendesLoginRepository(this.fehler);

  final Object fehler;

  @override
  Future<void> signIn({required String email, required String password}) async {
    throw fehler;
  }
}

void main() {
  // P4-02b: the code screen was switched to TYPED classification in wave 2
  // (AuthUnavailableException -> isNetworkSyncError -> codes -> text), the
  // login screen was not. A SocketException fell through to authErrorGeneric
  // ("Das hat gerade nicht geklappt. Bitte nochmal versuchen.") — advice that
  // cannot work without a connection, and that makes the user suspect their
  // password.
  group('P4-02b — Netzfehler im Login-Screen heissen Netzfehler', () {
    for (final fall in <({String name, Object fehler})>[
      (
        name: 'SocketException (Funkloch)',
        fehler: const SocketException('Failed host lookup: ci.invalid'),
      ),
      (
        name: 'ClientException (Verbindung abgerissen)',
        fehler: ClientException('Connection closed before full header'),
      ),
      (
        name: 'AuthRetryableFetchException (GoTrue-Wrapper)',
        fehler: AuthRetryableFetchException(
            message: 'ClientException: Failed host lookup'),
      ),
    ]) {
      testWidgets('${fall.name} nennt die Verbindung statt der Generik',
          (tester) async {
        tester.view.physicalSize = const Size(1179, 2556);
        tester.view.devicePixelRatio = 3.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await pumpLocalized(
          tester,
          AuthScreen(authRepository: _WerfendesLoginRepository(fall.fehler)),
          reducedMotion: false,
          scaffold: false,
          safeArea: false,
        );

        await tester.enterText(
            find.byKey(const ValueKey('auth-email-field')), 'du@eatova.de');
        await tester.enterText(
            find.byKey(const ValueKey('auth-password-field')), 'geheim99');
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('auth-submit')));
        await tester.pumpAndSettle();

        expect(find.text(deL10n.authCodeOfflineError), findsOneWidget,
            reason: 'derselbe Satz, den der Code-Screen seit Welle 2 sagt');
        expect(find.text(deL10n.authErrorGeneric), findsNothing,
            reason: '"nochmal versuchen" kann offline nie klappen');
      });
    }
  });

  testWidgets(
      'Google-Abbruch zeigt die Abbruch-Meldung, nicht die Generik '
      '(Regression: Mapper matchte auf Text; jetzt auf den Typ)',
      (tester) async {
    // The screen reads `context.t` and `context.l10n`: without theme extension
    // and delegates it would die in the first build, before the error mapper
    // runs.
    await pumpLocalized(
      tester,
      AuthScreen(authRepository: _CancelingAuthRepository()),
      reducedMotion: false,
      scaffold: false,
      safeArea: false,
    );

    await tester.tap(find.text('Mit Google anmelden'));
    await tester.pumpAndSettle();

    expect(find.text('Login wurde abgebrochen.'), findsOneWidget);
    expect(
      find.textContaining('Das hat gerade nicht geklappt'),
      findsNothing,
    );
  });
}
