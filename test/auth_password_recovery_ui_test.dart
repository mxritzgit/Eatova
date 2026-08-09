import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/screens/auth_code_screen.dart';
import 'package:eatova/src/screens/auth_screen.dart';
import 'package:eatova/src/theme/app_theme.dart';

// 6-stelliger Code-Flow (OTP statt Mail-Link, 2026-08-09):
//
//  * „Passwort vergessen?" fuehrt auf eine EIGENE Seite: E-Mail -> Code
//    anfordern (neutral bestaetigt — keine Konto-Enumeration) -> Code
//    pruefen (verifyOTP recovery stellt die Session her) -> neues Passwort.
//  * Die Registrierung bestaetigt die E-Mail ebenfalls per Code
//    (AuthCodeFlow.signup) statt per Link.
//  * Falsche/abgelaufene Codes zeigen einen Hinweis samt Neuanfordern-Weg.

Future<void> _pumpAuth(WidgetTester tester, InMemoryAuthRepository repo) async {
  await tester.pumpWidget(MaterialApp(
    theme: buildEatovaTheme(),
    home: AuthScreen(authRepository: repo),
  ));
  await tester.pumpAndSettle();
}

Future<void> _pumpCode(
  WidgetTester tester,
  InMemoryAuthRepository repo, {
  required AuthCodeFlow flow,
  String email = 'user@example.com',
}) async {
  await tester.pumpWidget(MaterialApp(
    theme: buildEatovaTheme(),
    home: AuthCodeScreen(
      authRepository: repo,
      flow: flow,
      initialEmail: email,
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Passwort vergessen oeffnet die Code-Seite mit vorbefuellter '
      'E-Mail', (tester) async {
    final repo = InMemoryAuthRepository();
    await _pumpAuth(tester, repo);

    await tester.enterText(
        find.byKey(const ValueKey('auth-email-field')), 'user@example.com');
    await tester
        .ensureVisible(find.byKey(const ValueKey('auth-forgot-password')));
    await tester.tap(find.byKey(const ValueKey('auth-forgot-password')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('auth-code-screen')), findsOneWidget);
    expect(find.text('user@example.com'), findsOneWidget,
        reason: 'die getippte Adresse ist vorbefuellt');
  });

  testWidgets('Recovery: Code anfordern bestaetigt NEUTRAL und wechselt zur '
      'Code-Eingabe', (tester) async {
    final repo = InMemoryAuthRepository();
    await _pumpCode(tester, repo, flow: AuthCodeFlow.recovery);

    await tester.tap(find.byKey(const ValueKey('code-primary')));
    await tester.pumpAndSettle();

    expect(repo.passwordResets, ['user@example.com']);
    expect(find.byKey(const ValueKey('code-field')), findsOneWidget);
    expect(find.textContaining('Falls ein Konto'), findsOneWidget,
        reason: 'neutral — keine Aussage, OB das Konto existiert');
    expect(find.textContaining('10 Minuten'), findsOneWidget);
  });

  testWidgets('Recovery: Code pruefen -> Passwort-Schritt -> speichern',
      (tester) async {
    final repo = InMemoryAuthRepository();
    await _pumpCode(tester, repo, flow: AuthCodeFlow.recovery);
    await tester.tap(find.byKey(const ValueKey('code-primary')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const ValueKey('code-field')), '482913');
    await tester.tap(find.byKey(const ValueKey('code-primary')));
    await tester.pumpAndSettle();

    expect(repo.verifiedCodes, ['user@example.com:482913']);
    expect(
        find.byKey(const ValueKey('code-password-field')), findsOneWidget);

    await tester.enterText(
        find.byKey(const ValueKey('code-password-field')), 'neues-passwort9');
    await tester.tap(find.byKey(const ValueKey('code-primary')));
    await tester.pumpAndSettle();

    expect(repo.passwordUpdates, ['neues-passwort9']);
  });

  testWidgets('falscher Code: Hinweis + Neuanfordern statt Weiterkommen',
      (tester) async {
    final repo = InMemoryAuthRepository();
    await _pumpCode(tester, repo, flow: AuthCodeFlow.recovery);
    await tester.tap(find.byKey(const ValueKey('code-primary')));
    await tester.pumpAndSettle();

    repo.verifyFails = true;
    await tester.enterText(find.byKey(const ValueKey('code-field')), '000000');
    await tester.tap(find.byKey(const ValueKey('code-primary')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('code-error')), findsOneWidget);
    expect(find.textContaining('abgelaufen'), findsOneWidget);
    expect(find.byKey(const ValueKey('code-field')), findsOneWidget,
        reason: 'kein Weiterkommen mit falschem Code');

    await tester.tap(find.byKey(const ValueKey('code-resend')));
    await tester.pumpAndSettle();
    expect(repo.passwordResets, hasLength(2),
        reason: 'Neuanfordern stoesst den Reset erneut an');
  });

  testWidgets('Signup-Flow: startet direkt beim Code und prueft ihn',
      (tester) async {
    final repo = InMemoryAuthRepository();
    await _pumpCode(tester, repo, flow: AuthCodeFlow.signup);

    expect(find.byKey(const ValueKey('code-field')), findsOneWidget,
        reason: 'die Adresse steht fest — kein E-Mail-Schritt');

    await tester.enterText(find.byKey(const ValueKey('code-field')), '135791');
    await tester.tap(find.byKey(const ValueKey('code-primary')));
    await tester.pumpAndSettle();

    expect(repo.verifiedCodes, ['user@example.com:135791']);
  });

  testWidgets('Signup-Flow: Neuanfordern nutzt resendSignupCode',
      (tester) async {
    final repo = InMemoryAuthRepository();
    await _pumpCode(tester, repo, flow: AuthCodeFlow.signup);

    await tester.tap(find.byKey(const ValueKey('code-resend')));
    await tester.pumpAndSettle();

    expect(repo.signupResends, ['user@example.com']);
    expect(repo.passwordResets, isEmpty,
        reason: 'Signup-Resend darf keinen Passwort-Reset ausloesen');
  });
}
