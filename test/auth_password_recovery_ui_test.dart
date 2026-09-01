import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/screens/auth_code_screen.dart';
import 'package:eatova/src/screens/auth_screen.dart';
import 'package:eatova/src/screens/settings/account_change_messages.dart'
    show kAccountCodeLength;

import 'support/harness.dart';

// 8-digit code flow (OTP instead of a mail link):
//
//  * Forgot password opens its own page: email -> request code (neutrally
//    confirmed, no account enumeration) -> verify -> new password.
//  * Signup confirms the email by code too (AuthCodeFlow.signup).
//  * Wrong or expired codes show a hint plus a resend path.
//
// The auth screens read `context.l10n`, so both harnesses pin `de` with the
// generated delegates; the German expectations below stay byte-identical.

Future<void> _pumpAuth(WidgetTester tester, InMemoryAuthRepository repo) async {
  await pumpLocalized(
    tester,
    AuthScreen(authRepository: repo),
    // Motion stays on: with duration 0 the screen's AnimatedSize re-dirties
    // itself inside its own performLayout.
    reducedMotion: false,
    scaffold: false,
    safeArea: false,
    settle: true,
  );
}

Future<void> _pumpCode(
  WidgetTester tester,
  InMemoryAuthRepository repo, {
  required AuthCodeFlow flow,
  String email = 'user@example.com',
}) async {
  await pumpLocalized(
    tester,
    AuthCodeScreen(
      authRepository: repo,
      flow: flow,
      initialEmail: email,
    ),
    // Motion as before the migration.
    reducedMotion: false,
    scaffold: false,
    safeArea: false,
    settle: true,
  );
}

/// Value of one `| \`schluessel\` | \`zahl\` |` row in the config table of
/// supabase/AUTH_EMAIL_OTP.md.
int _serverEinstellung(String schluessel) {
  final doku = File('supabase/AUTH_EMAIL_OTP.md').readAsStringSync();
  final treffer =
      RegExp('`$schluessel`\\s*\\|\\s*`(\\d+)`').firstMatch(doku);
  expect(treffer, isNotNull,
      reason: 'ohne die Zeile `$schluessel` in supabase/AUTH_EMAIL_OTP.md '
          'prueft dieser Abgleich nichts mehr');
  return int.parse(treffer!.group(1)!);
}

void main() {
  // The 2026-08-18 incident: the code length was raised, and app and server
  // config were changed in the wrong order — an older build cut the input off
  // at six digits and stopped accepting ANY code. Nothing tied the two halves
  // together; every flow below just types eight digits by hand, so both sides
  // could drift again without a single test going red.
  //
  // The doc IS the server contract here (there is no API to read the live
  // config from a unit test), so the length the field, the validation and both
  // mails hang on is compared against exactly that row.
  test('Code-Laenge und Gueltigkeit stehen so in der Server-Konfiguration',
      () {
    expect(kAccountCodeLength, _serverEinstellung('mailer_otp_length'),
        reason: 'laufen App und Server auseinander, nimmt der ausgelieferte '
            'Build keinen Code mehr an — und die Reihenfolge (erst App '
            'verteilen, dann Config patchen) steht in derselben Datei');
    expect(_serverEinstellung('mailer_otp_exp'), 600,
        reason: 'die App verspricht in beiden Sprachen 10 Minuten — auf der '
            'Code-Seite, in der Passwort- und in der Loesch-Bestaetigung');
  });

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

  testWidgets('ein zu kurzer Code erreicht den Server gar nicht',
      (tester) async {
    // The mirror of the delete sheet's guard (delete_account_reauth_test.dart):
    // a hopeless call is REJECTED by the server and burns one of the five
    // attempts against a lockout that only a NEW code can lift — the same cost
    // P4-02c removed for misclassified errors. Only the shape of the input is
    // checked here, so it belongs before the request, not after it.
    final repo = InMemoryAuthRepository();
    await _pumpCode(tester, repo, flow: AuthCodeFlow.signup);

    await tester.enterText(find.byKey(const ValueKey('code-field')), '1234');
    await tester.tap(find.byKey(const ValueKey('code-primary')));
    await tester.pumpAndSettle();

    expect(repo.verifiedCodes, isEmpty,
        reason: 'ein unvollstaendiger Code darf keinen Versuch kosten');
    expect(find.text(deL10n.authCodeErrorLength(kAccountCodeLength)),
        findsOneWidget,
        reason: 'und der Nutzer erfaehrt, dass Ziffern fehlen — nicht, dass '
            'der Code falsch war');
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
