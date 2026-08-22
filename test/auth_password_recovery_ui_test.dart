import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/screens/auth_code_screen.dart';
import 'package:eatova/src/screens/auth_screen.dart';
import 'package:eatova/src/theme/app_theme.dart';

// 8-digit code flow (OTP instead of a mail link):
//
//  * Forgot password opens its own page: email -> request code (neutrally
//    confirmed, no account enumeration) -> verify -> new password.
//  * Signup confirms the email by code too (AuthCodeFlow.signup).
//  * Wrong or expired codes show a hint plus a resend path.

Future<void> _pumpAuth(WidgetTester tester, InMemoryAuthRepository repo) async {
  await tester.pumpWidget(MaterialApp(
    theme: buildEatovaTheme(Brightness.dark),
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
    theme: buildEatovaTheme(Brightness.dark),
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

    await tester.enterText(find.byKey(const ValueKey('code-field')), '48291357');
    await tester.tap(find.byKey(const ValueKey('code-primary')));
    await tester.pumpAndSettle();

    expect(repo.verifiedCodes, ['user@example.com:48291357']);
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
    // The send latch blocks a second mail for 60 s after a successful code,
    // so an immediate resend sends nothing. The test therefore controls the
    // clock, which the screen reads via `clock.now()`.
    var jetzt = DateTime(2026, 8, 14, 9, 30);
    await withClock(Clock(() => jetzt), () async {
      await _pumpCode(tester, repo, flow: AuthCodeFlow.recovery);
      await tester.tap(find.byKey(const ValueKey('code-primary')));
      await tester.pumpAndSettle();

      repo.verifyFails = true;
      await tester.enterText(
          find.byKey(const ValueKey('code-field')), '00000000');
      await tester.tap(find.byKey(const ValueKey('code-primary')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('code-error')), findsOneWidget);
      expect(find.textContaining('abgelaufen'), findsOneWidget);
      expect(find.byKey(const ValueKey('code-field')), findsOneWidget,
          reason: 'kein Weiterkommen mit falschem Code');

      await tester.tap(find.byKey(const ValueKey('code-resend')));
      await tester.pumpAndSettle();
      expect(repo.passwordResets, hasLength(1),
          reason: 'innerhalb des Cooldowns geht keine zweite Mail raus');

      jetzt = jetzt.add(const Duration(seconds: 61));
      await tester.tap(find.byKey(const ValueKey('code-resend')));
      await tester.pumpAndSettle();
      expect(repo.passwordResets, hasLength(2),
          reason: 'nach dem Cooldown stoesst Neuanfordern den Reset erneut an');

      // The countdown runs on a `Timer.periodic`; without tearing the widget
      // down flutter_test reports a pending timer.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  });

  testWidgets('Signup-Flow: startet direkt beim Code und prueft ihn',
      (tester) async {
    final repo = InMemoryAuthRepository();
    await _pumpCode(tester, repo, flow: AuthCodeFlow.signup);

    expect(find.byKey(const ValueKey('code-field')), findsOneWidget,
        reason: 'die Adresse steht fest — kein E-Mail-Schritt');

    await tester.enterText(find.byKey(const ValueKey('code-field')), '13579246');
    await tester.tap(find.byKey(const ValueKey('code-primary')));
    await tester.pumpAndSettle();

    expect(repo.verifiedCodes, ['user@example.com:13579246']);
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
