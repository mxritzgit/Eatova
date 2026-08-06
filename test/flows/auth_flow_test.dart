// Auth-Flows (aus test/widget_test.dart aufgeteilt): Registrierung, Login,
// Logout und die OAuth-Buttons auf dem Auth-Screen.

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
    expect(find.text('Mit Google anmelden'), findsOneWidget);
    expect(find.text('Mit Apple anmelden'), findsNothing);
    expect(find.text('Einloggen'), findsOneWidget);

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

    expect(find.byKey(const ValueKey('screen-kcal-tracker')), findsOneWidget);

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

    expect(find.byKey(const ValueKey('screen-kcal-tracker')), findsOneWidget);
  });

  testWidgetsRobust('Auth screen supports OAuth buttons', (WidgetTester tester) async {
    final authRepository = InMemoryAuthRepository();
    addTearDown(authRepository.dispose);

    await tester.pumpWidget(EatovaApp(authRepository: authRepository));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('auth-google-oauth')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('screen-kcal-tracker')), findsOneWidget);
  });
}
