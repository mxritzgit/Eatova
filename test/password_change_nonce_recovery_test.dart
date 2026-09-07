import 'package:flutter/material.dart';
import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthException;

import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/screens/settings/settings_screen.dart';
import 'package:eatova/src/widgets/design/sheets.dart';

import 'support/harness.dart';

/// Models the one-use nonce of a session that requires reauthentication.
class _OldSessionAuth extends InMemoryAuthRepository {
  _OldSessionAuth({this.throttleResend = false})
    : super(
        initialUser: const EatovaUser(
          id: 'review',
          email: 'review@example.invalid',
        ),
      );
  final bool throttleResend;
  int sends = 0;
  int attempts = 0;
  String? nonce;
  String? saved;

  @override
  Future<void> startPasswordChange() async {
    sends++;
    if (throttleResend && sends == 2) {
      throw const AuthException(
        'For security purposes, you can only request this after 120 seconds.',
        code: 'over_email_send_rate_limit',
        statusCode: '429',
      );
    }
    nonce = sends == 1 ? '12345678' : '87654321';
  }

  @override
  Future<void> confirmPasswordChange({
    required String code,
    required String newPassword,
  }) async {
    attempts++;
    if (nonce == null || code != nonce) {
      throw const AuthException(
        'Reauthentication nonce is invalid',
        statusCode: '422',
        code: 'reauthentication_not_valid',
      );
    }
    nonce = null;
    if (newPassword == 'SamePassword99') {
      throw const AuthException(
        'New password should be different from the old password.',
        statusCode: '422',
        code: 'same_password',
      );
    }
    saved = newPassword;
  }
}

void main() {
  for (final throttle in [false, true]) {
    testWidgets(
      'spent nonce can be renewed and password saved (throttle=$throttle)',
      (tester) async {
        var now = DateTime.utc(2026, 9, 7, 12);
        await withClock(Clock(() => now), () async {
          Future<void> advance(Duration duration) async {
            now = now.add(duration);
            await tester.pump(duration);
          }

          SharedPreferences.setMockInitialValues({});
          final repo = _OldSessionAuth(throttleResend: throttle);
          addTearDown(repo.dispose);
          tester.view.physicalSize = const Size(1179, 2556);
          tester.view.devicePixelRatio = 3;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await pumpLocalized(
            tester,
            SettingsScreen(
              email: 'review@example.invalid',
              authRepository: repo,
            ),
            scaffold: false,
            safeArea: false,
          );
          Future<void> tap(Finder f) async {
            await tester.ensureVisible(f);
            await tester.tap(f);
            await tester.pumpAndSettle();
          }

          Future<void> enter(String key, String value) async {
            final f = find.byKey(ValueKey(key));
            await tester.ensureVisible(f);
            await tester.enterText(f, value);
          }

          await tap(find.byKey(const ValueKey('settings-change-password')));
          await tap(find.text('Code anfordern'));
          await enter('password-change-code', '12345678');
          await enter('password-change-new', 'SamePassword99');
          await enter('password-change-repeat', 'SamePassword99');
          final submit = tester
              .element(find.byKey(const ValueKey('password-change-code')))
              .l10n
              .settingsPasswordChangeSubmitCta;
          await tap(find.text(submit));
          expect(repo.attempts, 1);
          expect(
            repo.sends,
            1,
            reason: 'No automatic extra email on password rejection',
          );
          final code = find.byKey(const ValueKey('password-change-code'));
          expect(tester.widget<TextField>(code).controller!.text, isEmpty);
          expect(
            tester
                .widget<SheetField>(
                  find.byKey(const ValueKey('password-change-new')),
                )
                .controller!
                .text,
            'SamePassword99',
          );
          final resend = find.byKey(const ValueKey('password-change-resend'));
          expect(tester.widget<TextButton>(resend).onPressed, isNull);
          await advance(const Duration(seconds: 61));
          await tap(resend);
          if (throttle) {
            expect(repo.sends, 2);
            expect(tester.widget<TextButton>(resend).onPressed, isNull);
            await advance(const Duration(seconds: 119));
            expect(tester.widget<TextButton>(resend).onPressed, isNull);
            await advance(const Duration(seconds: 2));
            await tap(resend);
          }
          await enter('password-change-code', '87654321');
          await enter('password-change-new', 'DifferentPassword99');
          await enter('password-change-repeat', 'DifferentPassword99');
          await tap(find.text(submit));
          expect(repo.saved, 'DifferentPassword99');
          expect(repo.attempts, 2);
          expect(
            code,
            findsNothing,
            reason: 'Successful flow closes the sheet',
          );
        });
      },
    );
  }
}
