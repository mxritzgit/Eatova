import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthException;

import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/screens/auth_screen.dart';
import 'package:eatova/src/theme/app_theme.dart';

/// Wirft beim OAuth-Start die deutsche Abbruch-Meldung, wie sie
/// runNativeGoogleSignIn beim User-Abbruch produziert.
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
  Future<void> signUp({
    required String email,
    required String password,
    required String displayName,
  }) =>
      throw UnimplementedError();

  @override
  Future<void> signInWithOAuth(EatovaOAuthProvider provider) async {
    throw const AuthException('Google Login wurde abgebrochen.');
  }

  @override
  Future<void> signOut() async {}
}

void main() {
  testWidgets(
      'Google-Abbruch zeigt die Abbruch-Meldung, nicht die Generik '
      '(Regression: Mapper kannte nur engl. "cancel", nicht "abgebrochen")',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        // Design-Refactor 2026-08: die Wortmarke im Kopf des AuthScreens
        // (auth_screen.dart:285 -> EatovaWordmark) liest ihre Standardfarben
        // seit der Token-Migration ueber `context.t`. `AppTokens.of` wirft
        // absichtlich ohne ThemeExtension — eine nackte MaterialApp stirbt
        // damit schon im ersten Build, bevor der Fehler-Mapper drankommt.
        theme: buildEatovaTheme(Brightness.dark),
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
