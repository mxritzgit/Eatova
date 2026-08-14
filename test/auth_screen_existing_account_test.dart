import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthException;

import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/screens/auth_screen.dart';
import 'package:eatova/src/theme/app_theme.dart';

// Registrierung auf eine Adresse, zu der es schon ein Konto gibt
// (Audit 2026-08-14):
//
//  * Vorher: der Screen versprach „Bestätigungs-Code unterwegs", schob die
//    Code-Seite davor — und es kam nie eine Mail. Sackgasse.
//  * Jetzt: NEUTRALE Meldung (keine Aussage, OB das Konto existiert) und
//    Wechsel in den Login-Modus, damit es einen Weg nach vorn gibt.
//  * Ausserdem: zwei schnelle Taps auf den CTA sind eine Registrierung, nicht
//    zwei — die Sperre am Knopf greift erst mit dem naechsten Frame.

/// Fake, der beide Spielarten des Konflikts nachstellen kann:
///
///  * [SignUpOutcome.emailAlreadyRegistered] — der STILLE Produktionsfall bei
///    aktiver Mail-Bestaetigung: GoTrue antwortet erfolgreich, nur mit leerem
///    `identities`-Array, und schickt keine Mail;
///  * [wirft] — die laute Variante ohne Mail-Bestaetigung (`AuthException`).
///
/// `signUpCalls` zaehlt die Anfragen, `tor` haelt die erste offen, solange der
/// Test im Zustand „laeuft gerade" messen will.
class _ExistingAccountAuthRepository implements AuthRepository {
  _ExistingAccountAuthRepository({this.wirft = false, this.tor});

  final bool wirft;
  final Completer<void>? tor;

  int signUpCalls = 0;

  @override
  Future<SignUpOutcome> signUp({
    required String email,
    required String password,
    required String displayName,
  }) async {
    signUpCalls++;
    if (tor != null) await tor!.future;
    if (wirft) throw const AuthException('User already registered');
    return SignUpOutcome.emailAlreadyRegistered;
  }

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
  Future<void> startPasswordChange() => throw UnimplementedError();

  @override
  Future<void> confirmPasswordChange({
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
  await tester.pumpWidget(MaterialApp(
    theme: buildEatovaTheme(Brightness.dark),
    locale: const Locale('de'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: AuthScreen(authRepository: repo),
  ));
  await tester.pumpAndSettle();
}

/// Wechselt in den Registrier-Modus, fuellt alle drei Felder gueltig aus und
/// scrollt den CTA in den sichtbaren Bereich.
Future<void> _fillRegistration(WidgetTester tester) async {
  await tester
      .ensureVisible(find.byKey(const ValueKey('auth-toggle-register')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('auth-toggle-register')));
  await tester.pumpAndSettle();

  await tester.enterText(
      find.byKey(const ValueKey('auth-name-field')), 'Moritz');
  await tester.enterText(
      find.byKey(const ValueKey('auth-email-field')), 'schon@example.com');
  await tester.enterText(
      find.byKey(const ValueKey('auth-password-field')), 'eatova123');
  await tester.pumpAndSettle();

  await tester.ensureVisible(find.byKey(const ValueKey('auth-submit')));
  await tester.pumpAndSettle();
}

/// Prueft den Ausgang, den beide Spielarten teilen: neutrale Meldung im
/// Bestaetigungs-Slot, kein Fehler, keine Code-Seite, Login-Modus.
void _erwarteNeutralenAusweg() {
  expect(find.byKey(const ValueKey('auth-code-screen')), findsNothing,
      reason: 'ohne Mail waere die Code-Seite eine Sackgasse');
  expect(find.textContaining('Code unterwegs'), findsNothing,
      reason: 'es ist keine Mail unterwegs');

  expect(find.byKey(const ValueKey('auth-error')), findsNothing,
      reason: 'ein Fehler an dieser Stelle bestaetigt die Kontoexistenz');
  expect(find.byKey(const ValueKey('auth-message')), findsOneWidget);
  expect(find.text(deL10n.authSignupExistingAccountHint), findsOneWidget);
  expect(find.textContaining('schon registriert'), findsNothing,
      reason: 'keine Konto-Enumeration (auth_repository.dart:48-51)');

  // Der Ausweg: Login-Modus. Das Namensfeld ist weg, der CTA heisst wieder
  // „Einloggen", der Toggle bietet „Registrieren" an.
  expect(find.byKey(const ValueKey('auth-name-field')), findsNothing);
  expect(find.byKey(const ValueKey('auth-toggle-register')), findsOneWidget);
  expect(find.text('Einloggen'), findsOneWidget);
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

  testWidgets('zwei schnelle Taps auf Absenden sind eine Registrierung',
      (tester) async {
    final tor = Completer<void>();
    final repo = _ExistingAccountAuthRepository(tor: tor);
    await _pumpAuth(tester, repo);
    await _fillRegistration(tester);

    // Beide Taps im SELBEN Frame — genau die Luecke, die die Knopf-Sperre
    // (`enabled: !_busy`) offen laesst: sie wirkt erst nach dem Rebuild.
    await tester.tap(find.byKey(const ValueKey('auth-submit')));
    await tester.tap(find.byKey(const ValueKey('auth-submit')));
    await tester.pump();

    expect(repo.signUpCalls, 1);

    tor.complete();
    await tester.pumpAndSettle();
    expect(repo.signUpCalls, 1);
  });
}
