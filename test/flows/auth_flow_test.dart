// Auth flows: register, login, logout and the OAuth buttons on the auth
// screen. The landing point after boot is the "today" tab (index 0), so the
// anchor here is `screen-today`.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/main.dart';
import 'package:eatova/src/auth/auth_repository.dart';

import 'flow_test_helpers.dart';

/// Records WHAT the auth screen hands to the repository.
///
/// [InMemoryAuthRepository] accepts any address and any password and signs the
/// user in either way, so "the home page appeared" says nothing about the
/// typed fields: a screen that sent constants would pass every screen-level
/// assertion. The three lists below are the only place where the values
/// leaving the form are visible — the same role `verifiedCodes` already plays
/// for the OTP code.
class _RecordingAuthRepository extends InMemoryAuthRepository {
  final List<String> signIns = <String>[];
  final List<String> signUps = <String>[];
  final List<EatovaOAuthProvider> oauthCalls = <EatovaOAuthProvider>[];

  @override
  Future<void> signIn({required String email, required String password}) {
    signIns.add('$email:$password');
    return super.signIn(email: email, password: password);
  }

  @override
  Future<SignUpOutcome> signUp({
    required String email,
    required String password,
    required String displayName,
  }) {
    signUps.add('$email:$password:$displayName');
    return super
        .signUp(email: email, password: password, displayName: displayName);
  }

  @override
  Future<void> signInWithOAuth(EatovaOAuthProvider provider) {
    oauthCalls.add(provider);
    return super.signInWithOAuth(provider);
  }
}

void main() {
  testWidgetsRobust('Auth screen supports register and login flow', (
    WidgetTester tester,
  ) async {
    final authRepository = _RecordingAuthRepository();
    addTearDown(authRepository.dispose);

    await tester.pumpWidget(EatovaApp(authRepository: authRepository));
    await tester.pump();

    expect(find.byKey(const ValueKey('screen-auth')), findsOneWidget);
    expect(find.byKey(const ValueKey('auth-hero')), findsOneWidget);
    expect(find.byKey(const ValueKey('auth-google-oauth')), findsOneWidget);
    expect(find.byKey(const ValueKey('auth-apple-oauth')), findsNothing);
    // Flow tests resolve to English (test PlatformDispatcher locale).
    expect(find.text('Sign in with Google'), findsOneWidget);
    expect(find.text('Sign in with Apple'), findsNothing);
    expect(find.text('Log in'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('auth-toggle-register')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('auth-name-field')), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('auth-name-field')),
      'Moritz',
    );
    await tester.enterText(
      find.byKey(const ValueKey('auth-email-field')),
      'moritz@example.com',
    );
    await tester.enterText(
      find.byKey(const ValueKey('auth-password-field')),
      'eatova123',
    );
    await tester.tap(find.byKey(const ValueKey('auth-submit')));
    await tester.pumpAndSettle();

    // The TYPED name, address and password left the form — exactly once. The
    // in-memory repository signs anyone in, so without this line a form that
    // sent constants would reach the code screen just the same.
    expect(authRepository.signUps, <String>['moritz@example.com:eatova123:Moritz'],
        reason: 'die Registrierung schickt genau die eingetippten Werte');

    // With the OTP flow, registration leads to the code screen: the email is
    // confirmed with an 8-digit code before the home page opens.
    expect(find.byKey(const ValueKey('auth-code-screen')), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('code-field')), '12345678');
    await tester.tap(find.byKey(const ValueKey('code-primary')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('screen-today')), findsOneWidget);

    await authRepository.signOut();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-auth')), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('auth-email-field')),
      'moritz@example.com',
    );
    await tester.enterText(
      find.byKey(const ValueKey('auth-password-field')),
      'eatova123',
    );
    await tester.tap(find.byKey(const ValueKey('auth-submit')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('screen-today')), findsOneWidget);
    // Same for the login leg: address and password are the typed ones, and the
    // login did NOT run a second sign-up.
    expect(authRepository.signIns, <String>['moritz@example.com:eatova123'],
        reason: 'der Login schickt genau die eingetippten Zugangsdaten');
    expect(authRepository.signUps, hasLength(1),
        reason: 'der Login darf kein zweites Konto anlegen');
  });

  testWidgetsRobust('Auth screen supports OAuth buttons', (WidgetTester tester) async {
    final authRepository = _RecordingAuthRepository();
    addTearDown(authRepository.dispose);

    await tester.pumpWidget(EatovaApp(authRepository: authRepository));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('auth-google-oauth')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('screen-today')), findsOneWidget);
    // The button asks for GOOGLE. Landing on the home page proves nothing
    // here: the fake signs the user in for either provider, so a
    // mis-wired button would open an Apple sheet on the device and still be
    // green.
    expect(authRepository.oauthCalls, <EatovaOAuthProvider>[
      EatovaOAuthProvider.google,
    ], reason: 'der Google-Knopf startet genau einen Google-OAuth');
  });
}
