// Auth flows: register, login, logout and the OAuth buttons on the auth
// screen. The landing point after boot is the "today" tab (index 0), so the
// anchor here is `screen-today`.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/main.dart';
import 'package:eatova/src/auth/auth_repository.dart';

import 'flow_test_helpers.dart';

void main() {
  testWidgetsRobust('Auth screen supports register and login flow', (
    WidgetTester tester,
  ) async {
    final authRepository = InMemoryAuthRepository();
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
  });

  testWidgetsRobust('Auth screen supports OAuth buttons', (WidgetTester tester) async {
    final authRepository = InMemoryAuthRepository();
    addTearDown(authRepository.dispose);

    await tester.pumpWidget(EatovaApp(authRepository: authRepository));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('auth-google-oauth')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('screen-today')), findsOneWidget);
  });
}
