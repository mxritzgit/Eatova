import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthApiException, AuthException;

import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/screens/auth_screen.dart';

import 'support/harness.dart';

// Signing up with an address that already has an account (Audit 2026-08-14):
// a NEUTRAL message (no statement about whether the account exists) plus a
// switch to login mode, instead of a code screen that never gets a mail. Also:
// two fast taps on the CTA are one signup — the button lock only takes effect
// on the next frame.

/// Fake covering both variants of the conflict:
///
///  * [SignUpOutcome.emailAlreadyRegistered] — the SILENT production case with
///    mail confirmation on: GoTrue succeeds with an empty `identities` array
///    and sends no mail;
///  * [wirft] — the loud variant without mail confirmation (`AuthException`);
///  * [fehler] — any other rejection, e.g. the alias hook's 422.
///
/// `signUpCalls` counts requests, `tor` holds the first one open.
class _ExistingAccountAuthRepository implements AuthRepository {
  _ExistingAccountAuthRepository({this.wirft = false, this.tor, this.fehler});

  final bool wirft;
  final Completer<void>? tor;
  final Object? fehler;

  int signUpCalls = 0;

  @override
  Future<SignUpOutcome> signUp({
    required String email,
    required String password,
    required String displayName,
  }) async {
    signUpCalls++;
    if (tor != null) await tor!.future;
    if (fehler != null) throw fehler!;
    if (wirft) throw const AuthException('User already registered');
    return SignUpOutcome.emailAlreadyRegistered;
  }

  @override
  EatovaUser? get currentUser => null;

  @override
  Stream<EatovaUser?> get authStateChanges => const Stream.empty();

  @override
  Future<void> sendAccountDeletionCode({required String userId, required String email}) async {}

  @override
  Future<void> sendPasswordReset(String email) => throw UnimplementedError();

  @override
  Future<PasswordRecovery> verifyRecoveryCode(
          {required String email, required String code}) =>
      throw UnimplementedError();

  @override
  Future<void> verifySignupCode(
          {required String email, required String code}) =>
      throw UnimplementedError();

  @override
  Future<void> resendSignupCode(String email) => throw UnimplementedError();

  @override
  Future<void> startPasswordChange() => throw UnimplementedError();

  @override
  Future<void> confirmPasswordChange({
    required String currentPassword,
    required String code,
    required String newPassword,
  }) =>
      throw UnimplementedError();

  @override
  Future<void> startEmailChange(String newEmail) => throw UnimplementedError();

  @override
  Future<void> confirmEmailChange({
    required String email,
    required String code,
  }) =>
      throw UnimplementedError();

  @override
  Future<void> signIn({required String email, required String password}) =>
      throw UnimplementedError();

  @override
  Future<void> signInWithOAuth(EatovaOAuthProvider provider) =>
      throw UnimplementedError();

  @override
  Future<void> signOut() async {}
}

Future<void> _pumpAuth(WidgetTester tester, AuthRepository repo) async {
  await pumpLocalized(
    tester,
    AuthScreen(authRepository: repo),
    // Motion on: the mode toggle sits in an AnimatedSize, and a zero duration
    // makes it re-dirty itself during layout.
    reducedMotion: false,
    scaffold: false,
    safeArea: false,
  );
  await tester.pumpAndSettle();
}

/// Switches to signup mode, fills all three fields validly and scrolls the CTA
/// into view.
Future<void> _fillRegistration(WidgetTester tester,
    {String email = 'schon@example.com'}) async {
  await tester
      .ensureVisible(find.byKey(const ValueKey('auth-toggle-register')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('auth-toggle-register')));
  await tester.pumpAndSettle();

  await tester.enterText(
      find.byKey(const ValueKey('auth-name-field')), 'Moritz');
  await tester.enterText(find.byKey(const ValueKey('auth-email-field')), email);
  await tester.enterText(
      find.byKey(const ValueKey('auth-password-field')), 'eatova123');
  await tester.pumpAndSettle();

  await tester.ensureVisible(find.byKey(const ValueKey('auth-submit')));
  await tester.pumpAndSettle();
}

/// Checks the outcome all variants share: neutral message ([hinweis], the plain
/// hint by default), no error, no code screen, login mode.
void _erwarteNeutralenAusweg([String? hinweis]) {
  expect(find.byKey(const ValueKey('auth-code-screen')), findsNothing,
      reason: 'ohne Mail waere die Code-Seite eine Sackgasse');
  expect(find.textContaining('Code unterwegs'), findsNothing,
      reason: 'es ist keine Mail unterwegs');

  expect(find.byKey(const ValueKey('auth-error')), findsNothing,
      reason: 'ein Fehler an dieser Stelle bestaetigt die Kontoexistenz');
  expect(find.byKey(const ValueKey('auth-message')), findsOneWidget);
  expect(find.text(hinweis ?? deL10n.authSignupExistingAccountHint),
      findsOneWidget);
  expect(find.textContaining('schon registriert'), findsNothing,
      reason: 'keine Konto-Enumeration (AuthRepository, Hauslinie)');

  // The way out is login mode: no name field, the CTA reads "Einloggen" again
  // and the toggle offers signup.
  expect(find.byKey(const ValueKey('auth-name-field')), findsNothing);
  expect(find.byKey(const ValueKey('auth-toggle-register')), findsOneWidget);
  expect(
    find.descendant(
      of: find.byKey(const ValueKey('auth-submit')),
      matching: find.text(deL10n.authSubmitLogin),
    ),
    findsOneWidget,
  );
}

void main() {
  testWidgets('stille GoTrue-Antwort (leeres identities-Array): neutrale '
      'Meldung + Login-Modus statt Code-Seite', (tester) async {
    final repo = _ExistingAccountAuthRepository();
    await _pumpAuth(tester, repo);
    await _fillRegistration(tester);

    await tester.tap(find.byKey(const ValueKey('auth-submit')));
    await tester.pumpAndSettle();

    expect(repo.signUpCalls, 1);
    _erwarteNeutralenAusweg();
  });

  testWidgets('laute Variante (AuthException) endet genauso neutral',
      (tester) async {
    final repo = _ExistingAccountAuthRepository(wirft: true);
    await _pumpAuth(tester, repo);
    await _fillRegistration(tester);

    await tester.tap(find.byKey(const ValueKey('auth-submit')));
    await tester.pumpAndSettle();

    expect(repo.signUpCalls, 1);
    _erwarteNeutralenAusweg();
  });

  // The Before User Created hook rejects an alias of an existing account as
  // GoTrue's own sentence with status 422 and code `unknown` (gotrue-dart
  // 2.27.2, API version 2024-01-01). A code-first match would miss it.
  const hookAblehnung = AuthApiException(
    'User already registered',
    statusCode: '422',
    code: 'unknown',
  );

  testWidgets('Alias-Hook (422, code unknown) endet genauso neutral',
      (tester) async {
    final repo = _ExistingAccountAuthRepository(fehler: hookAblehnung);
    await _pumpAuth(tester, repo);
    await _fillRegistration(tester);

    await tester.tap(find.byKey(const ValueKey('auth-submit')));
    await tester.pumpAndSettle();

    expect(repo.signUpCalls, 1);
    _erwarteNeutralenAusweg();
  });

  // The sentence on spellings follows the shape of the input, the two
  // shapes the server folds: Gmail (dots, googlemail) and a +tag anywhere.
  for (final (email, hinweis) in <(String, String)>[
    ('Moritz.Gietl@GMAIL.com', deL10n.authSignupExistingAccountAliasHint),
    ('moritzgietl@googlemail.com', deL10n.authSignupExistingAccountAliasHint),
    ('jane+eatova@outlook.com', deL10n.authSignupExistingAccountAliasHint),
    ('jane.doe@outlook.com', deL10n.authSignupExistingAccountHint),
  ]) {
    testWidgets('$email: neutraler Hinweis, Satz zu Schreibweisen je nach Form',
        (tester) async {
      final repo = _ExistingAccountAuthRepository(fehler: hookAblehnung);
      await _pumpAuth(tester, repo);
      await _fillRegistration(tester, email: email);

      await tester.tap(find.byKey(const ValueKey('auth-submit')));
      await tester.pumpAndSettle();

      expect(repo.signUpCalls, 1);
      _erwarteNeutralenAusweg(hinweis);
    });
  }

  testWidgets('zwei schnelle Taps auf Absenden sind eine Registrierung',
      (tester) async {
    final tor = Completer<void>();
    final repo = _ExistingAccountAuthRepository(tor: tor);
    await _pumpAuth(tester, repo);
    await _fillRegistration(tester);

    // Both taps in the SAME frame — the gap the button lock
    // (`enabled: !_busy`) leaves open, since it only applies after a rebuild.
    await tester.tap(find.byKey(const ValueKey('auth-submit')));
    await tester.tap(find.byKey(const ValueKey('auth-submit')));
    await tester.pump();

    expect(repo.signUpCalls, 1);

    tor.complete();
    await tester.pumpAndSettle();
    expect(repo.signUpCalls, 1);
  });
}
