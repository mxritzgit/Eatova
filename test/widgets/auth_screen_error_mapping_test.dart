import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/screens/auth_screen.dart';
import 'package:eatova/src/theme/app_theme.dart';

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

void main() {
  testWidgets(
      'Google-Abbruch zeigt die Abbruch-Meldung, nicht die Generik '
      '(Regression: Mapper matchte auf Text; jetzt auf den Typ)',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        // The screen reads `context.t` and `context.l10n`: without theme
        // extension and delegates it would die in the first build, before the
        // error mapper runs.
        theme: buildEatovaTheme(Brightness.dark),
        locale: const Locale('de'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: AuthScreen(authRepository: _CancelingAuthRepository()),
      ),
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
