// Visual evidence for the login / registration polish (design polish run
// 2026-10-02).
//
// Mounts the real AuthScreen and AuthCodeScreen at the design's reference
// geometry and walks them through every state a user can meet:
//   login / signup               the two modes at rest
//   login-error-*                local validation, a server throttle, the
//                                unconfirmed-address note with its action
//   login-loading / google-loading  both pending states
//   signup-existing              the neutral info note
//   login-keyboard               focus + a 300 px keyboard
//   signup-de / login-de-error   German, the densest variants
//   login-x2 / signup-x2-keyboard  text scale 2.0
//   code-*                       the 8-digit code entry: empty, partial,
//                                rejected, resend cooldown, quota escape
//   recovery-*                   the three recovery steps
//   code-x2-keyboard / code-de   the code page at 2.0 with keyboard, German
//
// With --dart-define=DARK_REDESIGN_CAPTURE=true the shots land in
// build/dark-redesign/. Without it the suite still pins that every state
// renders overflow-free and keeps its keys and its texts.

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthApiException;

import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/screens/auth_code_screen.dart';
import 'package:eatova/src/screens/auth_screen.dart';
import 'package:eatova/src/services/local_cache.dart'
    show InMemoryKeyValueStore;

import '../support/design_capture.dart';
import '../support/harness.dart';

final DateTime _now = DateTime(2026, 10, 2, 9, 30);

/// Repository whose answers each scenario sets up front.
class _ScriptedRepository extends InMemoryAuthRepository {
  Object? signInError;
  Completer<void>? signInPending;
  Completer<void>? oauthPending;
  bool signUpExisting = false;
  Object? resendError;

  @override
  Future<void> signIn({required String email, required String password}) async {
    if (signInError != null) throw signInError!;
    await signInPending?.future;
  }

  @override
  Future<void> signInWithOAuth(EatovaOAuthProvider provider) async {
    await oauthPending?.future;
  }

  @override
  Future<SignUpOutcome> signUp({
    required String email,
    required String password,
    required String displayName,
  }) async {
    if (signUpExisting) return SignUpOutcome.emailAlreadyRegistered;
    return super.signUp(
      email: email,
      password: password,
      displayName: displayName,
    );
  }

  @override
  Future<void> resendSignupCode(String email) async {
    if (resendError != null) throw resendError!;
    return super.resendSignupCode(email);
  }
}

Future<_ScriptedRepository> _pumpAuth(
  WidgetTester tester, {
  Locale locale = const Locale('en'),
  double textScale = 1.0,
}) async {
  final repository = _ScriptedRepository();
  addTearDown(repository.dispose);
  pinDesignViewport(tester);
  await tester.pumpWidget(
    designCaptureBoundary(
      localizedApp(
        AuthScreen(authRepository: repository),
        locale: locale,
        textScale: textScale,
        scaffold: false,
        safeArea: false,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return repository;
}

Future<_ScriptedRepository> _pumpCode(
  WidgetTester tester, {
  AuthCodeFlow flow = AuthCodeFlow.signup,
  Locale locale = const Locale('en'),
  double textScale = 1.0,
  _ScriptedRepository? repository,
}) async {
  final repo = repository ?? _ScriptedRepository();
  addTearDown(repo.dispose);
  pinDesignViewport(tester);
  await tester.pumpWidget(
    designCaptureBoundary(
      localizedApp(
        AuthCodeScreen(
          authRepository: repo,
          flow: flow,
          initialEmail: 'mira.lehmann@example.com',
          throttleStore: InMemoryKeyValueStore(),
        ),
        locale: locale,
        textScale: textScale,
        scaffold: false,
        safeArea: false,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return repo;
}

Finder _key(String key) => find.byKey(ValueKey(key));

Future<void> _toggleRegister(WidgetTester tester) async {
  await tester.ensureVisible(_key('auth-toggle-register'));
  await tester.tap(_key('auth-toggle-register'));
  await tester.pumpAndSettle();
}

Future<void> _fill(
  WidgetTester tester, {
  String? name,
  String email = 'mira.lehmann@example.com',
  String password = 'correct-horse-9',
}) async {
  if (name != null) await tester.enterText(_key('auth-name-field'), name);
  await tester.enterText(_key('auth-email-field'), email);
  await tester.enterText(_key('auth-password-field'), password);
}

Future<void> _submit(WidgetTester tester, {bool settle = true}) async {
  await tester.ensureVisible(_key('auth-submit'));
  await tester.tap(_key('auth-submit'));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

/// Unfocuses and scrolls back to the top before a resting shot.
Future<void> _rest(WidgetTester tester) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
  final scrollable = find.byType(Scrollable).first;
  tester.state<ScrollableState>(scrollable).position.jumpTo(0);
  await tester.pumpAndSettle();
}

void _keyboard(WidgetTester tester, double logical) {
  tester.view.viewInsets = FakeViewPadding(
    bottom: logical * kDesignPixelRatio,
  );
}

/// Runs [body] under the frozen clock and fails on any overflow.
Future<void> _guarded(
  WidgetTester tester,
  Future<void> Function() body,
) async {
  await withClock(Clock.fixed(_now), () async {
    final overflows = await collectOverflows(body);
    expect(overflows, isEmpty, reason: describeOverflows(overflows));
    expect(tester.takeException(), isNull);
    // Cancels the code page's countdown ticker.
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

void main() {
  setUpAll(loadDesignFonts);

  group('auth screen', () {
    testWidgets('login and signup at rest', (tester) async {
      await _guarded(tester, () async {
        await _pumpAuth(tester);
        for (final key in [
          'auth-hero',
          'auth-toggle-login',
          'auth-toggle-register',
          'auth-google-oauth',
          'auth-email-field',
          'auth-password-field',
          'auth-forgot-password',
          'auth-submit',
          'auth-consent-notice',
        ]) {
          expect(_key(key), findsOneWidget, reason: key);
        }
        expect(find.text(enL10n.authHeadlineLogin), findsOneWidget);
        await captureDesignShot(tester, 'login');
        await _toggleRegister(tester);
        await _rest(tester);
        expect(_key('auth-name-field'), findsOneWidget);
        expect(find.text(enL10n.authHeadlineRegister), findsOneWidget);
        await captureDesignShot(tester, 'signup');
      });
    });

    testWidgets('login errors: validation, throttle, unconfirmed', (
      tester,
    ) async {
      await _guarded(tester, () async {
        final repo = await _pumpAuth(tester);
        await _fill(tester, email: 'mira.lehmann.example.com');
        await _submit(tester);
        expect(find.text(enL10n.authErrorInvalidEmail), findsOneWidget);
        await _rest(tester);
        await captureDesignShot(tester, 'login-error-validation');

        repo.signInError = const AuthApiException(
          'Too many requests',
          statusCode: '429',
          code: 'over_request_rate_limit',
        );
        await _fill(tester);
        await _submit(tester);
        expect(find.text(enL10n.settingsAccountRateLimited), findsOneWidget);
        await _rest(tester);
        await captureDesignShot(tester, 'login-error-server');

        repo.signInError = const AuthApiException(
          'Email not confirmed',
          statusCode: '400',
          code: 'email_not_confirmed',
        );
        await _submit(tester);
        expect(find.text(enL10n.authErrorEmailNotConfirmed), findsOneWidget);
        expect(_key('auth-enter-code'), findsOneWidget);
        await _rest(tester);
        await captureDesignShot(tester, 'login-error-unconfirmed');
      });
    });

    testWidgets('pending login and pending Google sign-in', (tester) async {
      await _guarded(tester, () async {
        final repo = await _pumpAuth(tester);
        final login = repo.signInPending = Completer<void>();
        await _fill(tester);
        FocusManager.instance.primaryFocus?.unfocus();
        await _submit(tester, settle: false);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        await captureDesignShot(tester, 'login-loading');
        login.complete();
        await tester.pumpAndSettle();

        final oauth = repo.oauthPending = Completer<void>();
        repo.signInPending = null;
        await tester.tap(_key('auth-google-oauth'));
        await tester.pump();
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        await captureDesignShot(tester, 'google-loading');
        oauth.complete();
        await tester.pumpAndSettle();
      });
    });

    testWidgets('signup with an existing address shows the neutral hint', (
      tester,
    ) async {
      await _guarded(tester, () async {
        final repo = await _pumpAuth(tester);
        repo.signUpExisting = true;
        await _toggleRegister(tester);
        await _fill(tester, name: 'Mira');
        await _submit(tester);
        expect(find.text(enL10n.authSignupExistingAccountHint), findsOneWidget);
        await _rest(tester);
        await captureDesignShot(tester, 'signup-existing');
      });
    });

    testWidgets('keyboard open with a focused field', (tester) async {
      await _guarded(tester, () async {
        await _pumpAuth(tester);
        await tester.tap(_key('auth-email-field'));
        await tester.enterText(_key('auth-email-field'), 'mira.leh');
        _keyboard(tester, 300);
        await tester.pumpAndSettle();
        await tester.ensureVisible(_key('auth-email-field'));
        await tester.pumpAndSettle();
        await captureDesignShot(tester, 'login-keyboard');
        _keyboard(tester, 0);
        await tester.pumpAndSettle();
      });
    });

    testWidgets('German: signup and a login error', (tester) async {
      await _guarded(tester, () async {
        final repo = await _pumpAuth(tester, locale: const Locale('de'));
        repo.signInError = const AuthApiException(
          'Invalid login credentials',
          statusCode: '400',
          code: 'invalid_credentials',
        );
        await _fill(tester);
        await _submit(tester);
        expect(find.text(deL10n.authErrorInvalidCredentials), findsOneWidget);
        await _rest(tester);
        await captureDesignShot(tester, 'login-de-error');
        await _toggleRegister(tester);
        await _rest(tester);
        await captureDesignShot(tester, 'signup-de');
      });
    });

    testWidgets('text scale 2.0, at rest and with the keyboard', (
      tester,
    ) async {
      await _guarded(tester, () async {
        await _pumpAuth(tester, textScale: 2);
        await captureDesignShot(tester, 'login-x2');
        await scrollDesignTabBy(tester, 640);
        await captureDesignShot(tester, 'login-x2-01');
        await _toggleRegister(tester);
        await tester.tap(_key('auth-name-field'));
        _keyboard(tester, 300);
        await tester.pumpAndSettle();
        await tester.ensureVisible(_key('auth-name-field'));
        await tester.pumpAndSettle();
        expect(_key('auth-name-field').hitTestable(), findsOneWidget);
        await captureDesignShot(tester, 'signup-x2-keyboard');
        await tester.ensureVisible(_key('auth-submit'));
        await tester.pumpAndSettle();
        expect(_key('auth-submit').hitTestable(), findsOneWidget);
        await captureDesignShot(tester, 'signup-x2-keyboard-01');
        _keyboard(tester, 0);
        await tester.pumpAndSettle();
      });
    });

    testWidgets('German at 2.0: the mode switch stacks', (tester) async {
      await _guarded(tester, () async {
        await _pumpAuth(tester, locale: const Locale('de'), textScale: 2);
        await _toggleRegister(tester);
        await _rest(tester);
        await tester.ensureVisible(_key('auth-toggle-login'));
        await tester.pumpAndSettle();
        expect(_key('auth-toggle-login').hitTestable(), findsOneWidget);
        await captureDesignShot(tester, 'signup-de-x2');
      });
    });
  });

  group('code screen', () {
    testWidgets('signup code: empty, partial, rejected', (tester) async {
      await _guarded(tester, () async {
        final repo = await _pumpCode(tester);
        expect(_key('code-field'), findsOneWidget);
        expect(_key('code-resend'), findsOneWidget);
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        await captureDesignShot(tester, 'code-empty');

        await tester.tap(_key('code-field'));
        await tester.enterText(_key('code-field'), '4829');
        await tester.pumpAndSettle();
        await captureDesignShot(tester, 'code-partial');

        repo.verifyFails = true;
        await tester.enterText(_key('code-field'), '48291357');
        await tester.tap(_key('code-primary'));
        await tester.pumpAndSettle();
        expect(find.text(enL10n.authCodeErrorRejected), findsOneWidget);
        await captureDesignShot(tester, 'code-error');
      });
    });

    testWidgets('resend cooldown and the quota escape', (tester) async {
      await _guarded(tester, () async {
        await _pumpCode(tester);
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.tap(_key('code-resend'));
        await tester.pumpAndSettle();
        expect(find.text(enL10n.authCodeResendCountdown(60)), findsOneWidget);
        await captureDesignShot(tester, 'code-cooldown');
      });
    });

    testWidgets('quota block offers the one escape', (tester) async {
      await _guarded(tester, () async {
        final repo = _ScriptedRepository()
          ..resendError = const AuthApiException(
            'Email rate limit exceeded',
            statusCode: '429',
            code: 'over_email_send_rate_limit',
          );
        await _pumpCode(tester, repository: repo);
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.tap(_key('code-resend'));
        await tester.pumpAndSettle();
        expect(find.text(enL10n.authCodeQuotaExhausted), findsOneWidget);
        expect(_key('code-send-anyway'), findsOneWidget);
        await captureDesignShot(tester, 'code-quota');
      });
    });

    testWidgets('recovery: address, code, new password', (tester) async {
      await _guarded(tester, () async {
        await _pumpCode(tester, flow: AuthCodeFlow.recovery);
        expect(_key('code-email-field'), findsOneWidget);
        await captureDesignShot(tester, 'recovery-email');
        await tester.tap(_key('code-primary'));
        await tester.pumpAndSettle();
        expect(_key('code-field'), findsOneWidget);
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        await captureDesignShot(tester, 'recovery-code');
        await tester.enterText(_key('code-field'), '48291357');
        await tester.tap(_key('code-primary'));
        await tester.pumpAndSettle();
        expect(_key('code-password-field'), findsOneWidget);
        await tester.tap(_key('code-password-field'));
        await tester.enterText(_key('code-password-field'), 'new-horse-12');
        await tester.pumpAndSettle();
        await captureDesignShot(tester, 'recovery-password');
      });
    });

    testWidgets('code page at 2.0 with the keyboard, and in German', (
      tester,
    ) async {
      await _guarded(tester, () async {
        await _pumpCode(tester, textScale: 2);
        await tester.enterText(_key('code-field'), '482913');
        _keyboard(tester, 300);
        await tester.pumpAndSettle();
        await tester.ensureVisible(_key('code-field'));
        await tester.pumpAndSettle();
        expect(_key('code-field').hitTestable(), findsOneWidget);
        await captureDesignShot(tester, 'code-x2-keyboard');
        await tester.ensureVisible(_key('code-primary'));
        await tester.pumpAndSettle();
        expect(_key('code-primary').hitTestable(), findsOneWidget);
        await captureDesignShot(tester, 'code-x2-keyboard-01');
        _keyboard(tester, 0);
        await tester.pumpAndSettle();

        await tester.pumpWidget(const SizedBox.shrink());
        await _pumpCode(tester, locale: const Locale('de'));
        await tester.enterText(_key('code-field'), '4829135');
        await tester.pumpAndSettle();
        await captureDesignShot(tester, 'code-de');
      });
    });
  });
}
