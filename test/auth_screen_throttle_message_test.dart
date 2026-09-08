import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/screens/auth_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthApiException;

import 'support/harness.dart';

class _ThrottledRepository extends InMemoryAuthRepository {
  _ThrottledRepository(this.error);
  final Object error;

  @override
  Future<void> signIn({required String email, required String password}) async {
    throw error;
  }

  @override
  Future<SignUpOutcome> signUp({
    required String email,
    required String password,
    required String displayName,
  }) async {
    throw error;
  }
}

void main() {
  for (final scenario in [
    (
      name: 'login request limit',
      register: false,
      error: const AuthApiException(
        'Too many requests',
        statusCode: '429',
        code: 'over_request_rate_limit',
      ),
      expected: deL10n.settingsAccountRateLimited,
    ),
    (
      name: 'signup project mail quota',
      register: true,
      error: const AuthApiException(
        'Email rate limit exceeded',
        statusCode: '429',
        code: 'over_email_send_rate_limit',
      ),
      expected: deL10n.authCodeQuotaExhausted,
    ),
    (
      name: 'signup mail send cooldown',
      register: true,
      error: const AuthApiException(
        'For security purposes, you can only request this after 51 seconds.',
        statusCode: '429',
        code: 'over_email_send_rate_limit',
      ),
      expected: deL10n.authCodeRateLimitedSeconds(51),
    ),
  ]) {
    testWidgets(
      '${scenario.name} explains waiting instead of immediate retry',
      (tester) async {
        pinIphone14Pro(tester);
        final repository = _ThrottledRepository(scenario.error);
        addTearDown(repository.dispose);
        await pumpLocalized(
          tester,
          AuthScreen(authRepository: repository),
          reducedMotion: false,
          scaffold: false,
          safeArea: false,
          settle: true,
        );
        if (scenario.register) {
          final toggle = find.byKey(const ValueKey('auth-toggle-register'));
          await tester.ensureVisible(toggle);
          await tester.tap(toggle);
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byKey(const ValueKey('auth-name-field')),
            'Example',
          );
        }
        await tester.enterText(
          find.byKey(const ValueKey('auth-email-field')),
          'user@example.com',
        );
        await tester.enterText(
          find.byKey(const ValueKey('auth-password-field')),
          'fixture-password',
        );
        final submit = find.byKey(const ValueKey('auth-submit'));
        await tester.ensureVisible(submit);
        await tester.tap(submit);
        await tester.pumpAndSettle();

        expect(find.text(scenario.expected), findsOneWidget);
        expect(find.text(deL10n.authErrorGeneric), findsNothing);
        expect(
          find.byKey(const ValueKey('auth-code-screen')),
          findsNothing,
          reason: 'A rejected signup did not send a confirmation code',
        );
      },
    );
  }
}
