import 'dart:async';

import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/screens/auth_screen.dart';
import 'package:eatova/src/widgets/auth/auth_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthException;

import 'support/harness.dart';

class _RecordingRepository extends InMemoryAuthRepository {
  final signIns = <(String, String)>[];
  final signUps = <(String, String, String)>[];
  final oauthCalls = <EatovaOAuthProvider>[];
  Completer<void>? pending;
  String? conflictCode;
  Object? signInError;

  @override
  Future<void> signInWithOAuth(EatovaOAuthProvider provider) async {
    oauthCalls.add(provider);
  }

  @override
  Future<void> signIn({required String email, required String password}) async {
    signIns.add((email, password));
    if (signInError != null) throw signInError!;
    await pending?.future;
  }

  @override
  Future<SignUpOutcome> signUp({
    required String email,
    required String password,
    required String displayName,
  }) async {
    signUps.add((email, password, displayName));
    if (conflictCode != null) {
      throw AuthException('Localized provider response', code: conflictCode);
    }
    return SignUpOutcome.created;
  }
}

Future<_RecordingRepository> _pump(
  WidgetTester tester, {
  bool reducedMotion = true,
}) async {
  final repository = _RecordingRepository();
  addTearDown(repository.dispose);
  await pumpLocalized(
    tester,
    AuthScreen(authRepository: repository),
    scaffold: false,
    safeArea: false,
    reducedMotion: reducedMotion,
    settle: true,
  );
  return repository;
}

Future<void> _fill(WidgetTester tester, String password) async {
  await tester.enterText(
    find.byKey(const ValueKey('auth-email-field')),
    ' member@example.com ',
  );
  await tester.enterText(
    find.byKey(const ValueKey('auth-password-field')),
    password,
  );
}

Future<void> _submit(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(const ValueKey('auth-submit')));
  await tester.tap(find.byKey(const ValueKey('auth-submit')));
  await tester.pumpAndSettle();
}

void main() {
  for (final reducedMotion in [false, true]) {
    testWidgets(
      'mode changes preserve credentials and settle with reduced motion '
      '$reducedMotion',
      (tester) async {
        final repository = await _pump(tester, reducedMotion: reducedMotion);
        await _fill(tester, 'long-password');
        final password = tester.widget<TextField>(
          find.byKey(const ValueKey('auth-password-field')),
        );
        password.controller!.selection = const TextSelection.collapsed(
          offset: 4,
        );
        password.focusNode!.unfocus();
        await tester.pumpAndSettle();

        // Reverse the transition before it finishes, then open signup again.
        for (final mode in ['register', 'login', 'register']) {
          tester
              .widget<InkWell>(find.byKey(ValueKey('auth-toggle-$mode')))
              .onTap!();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 40));
          expect(
            find.byKey(const ValueKey('auth-email-field')),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('auth-password-field')),
            findsOneWidget,
          );
        }
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('auth-name-field')), findsOneWidget);
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('auth-email-field')))
              .controller!
              .text,
          ' member@example.com ',
        );
        final retainedPassword = tester.widget<TextField>(
          find.byKey(const ValueKey('auth-password-field')),
        );
        expect(retainedPassword.controller!.text, 'long-password');
        expect(retainedPassword.controller!.selection.baseOffset, 4);
        expect(repository.signIns, isEmpty);
        expect(repository.signUps, isEmpty);
        expect(tester.binding.transientCallbackCount, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('reduced motion reaches the mode layout without a transition', (
    tester,
  ) async {
    await _pump(tester);
    tester
        .widget<InkWell>(find.byKey(const ValueKey('auth-toggle-register')))
        .onTap!();
    await tester.pump();
    final field = find.byKey(const ValueKey('auth-name-field'));
    expect(field, findsOneWidget);
    final immediateRect = tester.getRect(field);
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.getRect(field), immediateRect);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('mode changes keep platform autofill and keyboard focus order', (
    tester,
  ) async {
    await _pump(tester);
    final emailFinder = find.byKey(const ValueKey('auth-email-field'));
    final passwordFinder = find.byKey(const ValueKey('auth-password-field'));
    expect(find.byType(AutofillGroup), findsOneWidget);
    expect(
      tester.widget<TextField>(passwordFinder).autofillHints,
      contains(AutofillHints.password),
    );
    await tester.enterText(emailFinder, 'member@example.com');
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pump();
    expect(
      tester.widget<TextField>(passwordFinder).focusNode!.hasFocus,
      isTrue,
    );

    tester
        .widget<InkWell>(find.byKey(const ValueKey('auth-toggle-register')))
        .onTap!();
    await tester.pumpAndSettle();
    final nameFinder = find.byKey(const ValueKey('auth-name-field'));
    expect(find.byType(AutofillGroup), findsOneWidget);
    expect(
      tester.widget<TextField>(nameFinder).autofillHints,
      contains(AutofillHints.name),
    );
    expect(
      tester.widget<TextField>(emailFinder).autofillHints,
      contains(AutofillHints.email),
    );
    expect(
      tester.widget<TextField>(passwordFinder).autofillHints,
      contains(AutofillHints.newPassword),
    );
    await tester.enterText(nameFinder, 'Mira');
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pump();
    expect(tester.widget<TextField>(emailFinder).focusNode!.hasFocus, isTrue);
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pump();
    expect(
      tester.widget<TextField>(passwordFinder).focusNode!.hasFocus,
      isTrue,
    );

    tester
        .widget<InkWell>(find.byKey(const ValueKey('auth-toggle-login')))
        .onTap!();
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(passwordFinder).autofillHints,
      contains(AutofillHints.password),
    );
    expect(
      tester.widget<TextField>(emailFinder).controller!.text,
      'member@example.com',
    );
  });

  testWidgets('pending login locks fields and actions until failure returns', (
    tester,
  ) async {
    final repository = await _pump(tester);
    final pending = Completer<void>();
    repository.pending = pending;
    await _fill(tester, 'long-password');
    final submit = tester
        .widget<AuthPrimaryButton>(find.byType(AuthPrimaryButton))
        .onTap;
    submit();
    submit();
    await tester.pump();
    expect(repository.signIns, hasLength(1));
    for (final field in ['email', 'password']) {
      expect(
        tester
            .widget<TextField>(find.byKey(ValueKey('auth-$field-field')))
            .enabled,
        isFalse,
      );
    }
    for (final action in [
      'google-oauth',
      'toggle-register',
      'forgot-password',
      'toggle-password',
    ]) {
      expect(
        tester.widget<InkWell>(find.byKey(ValueKey('auth-$action'))).onTap,
        isNull,
      );
    }
    expect(
      tester.widget<AuthPrimaryButton>(find.byType(AuthPrimaryButton)).enabled,
      isFalse,
    );
    pending.completeError(
      const AuthException('Invalid credentials', code: 'invalid_credentials'),
    );
    await tester.pumpAndSettle();
    expect(find.text(deL10n.authErrorInvalidCredentials), findsOneWidget);
    for (final field in ['email', 'password']) {
      expect(
        tester
            .widget<TextField>(find.byKey(ValueKey('auth-$field-field')))
            .enabled,
        isTrue,
      );
    }
    expect(
      tester.widget<AuthPrimaryButton>(find.byType(AuthPrimaryButton)).enabled,
      isTrue,
    );
    repository.pending = null;
    await _submit(tester);
    expect(repository.signIns, [
      ('member@example.com', 'long-password'),
      ('member@example.com', 'long-password'),
    ]);
  });

  testWidgets(
    'opening recovery latches covered actions and returning unlocks them',
    (tester) async {
      final repository = await _pump(tester);
      await _fill(tester, 'long-password');
      final recover = tester
          .widget<InkWell>(find.byKey(const ValueKey('auth-forgot-password')))
          .onTap!;
      final mode = tester
          .widget<InkWell>(find.byKey(const ValueKey('auth-toggle-register')))
          .onTap!;
      final google = tester
          .widget<InkWell>(find.byKey(const ValueKey('auth-google-oauth')))
          .onTap!;
      final submit = tester
          .widget<AuthPrimaryButton>(find.byType(AuthPrimaryButton))
          .onTap;
      recover();
      mode();
      google();
      submit();
      await tester.pumpAndSettle();
      expect(repository.signIns, isEmpty);
      expect(repository.oauthCalls, isEmpty);
      expect(
        find.byKey(const ValueKey('auth-name-field'), skipOffstage: false),
        findsNothing,
      );
      Navigator.of(
        tester.element(find.byKey(const ValueKey('auth-code-screen'))),
      ).pop();
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<AuthPrimaryButton>(find.byType(AuthPrimaryButton))
            .enabled,
        isTrue,
      );
      await _submit(tester);
      expect(repository.signIns, [('member@example.com', 'long-password')]);
    },
  );
  testWidgets('unconfirmed code action cannot race a pending login retry', (
    tester,
  ) async {
    final repository = await _pump(tester);
    repository.signInError = const AuthException(
      'Unconfirmed',
      code: 'email_not_confirmed',
    );
    await _fill(tester, 'long-password');
    await _submit(tester);
    final enterCode = tester
        .widget<InkWell>(find.byKey(const ValueKey('auth-enter-code')))
        .onTap!;
    repository.signInError = null;
    final pending = Completer<void>();
    repository.pending = pending;
    tester.widget<AuthPrimaryButton>(find.byType(AuthPrimaryButton)).onTap();
    enterCode();
    await tester.pump();
    expect(find.byKey(const ValueKey('auth-code-screen')), findsNothing);
    expect(repository.signIns, hasLength(2));
    pending.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('two same-frame recovery taps open one code route', (
    tester,
  ) async {
    await _pump(tester);
    final recover = tester
        .widget<InkWell>(find.byKey(const ValueKey('auth-forgot-password')))
        .onTap!;
    recover();
    recover();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('auth-code-screen'), skipOffstage: false),
      findsOneWidget,
    );
  });

  testWidgets('existing passwords are not rejected by new-account policy', (
    tester,
  ) async {
    final repository = await _pump(tester);
    await _fill(tester, 'old123');
    await _submit(tester);
    expect(repository.signIns, [('member@example.com', 'old123')]);
    expect(find.byKey(const ValueKey('auth-error')), findsNothing);
  });

  testWidgets('empty login password and short signup password stay local', (
    tester,
  ) async {
    final repository = await _pump(tester);
    await _fill(tester, '');
    await _submit(tester);
    expect(repository.signIns, isEmpty);
    expect(find.text(deL10n.authErrorPasswordMissing), findsOneWidget);
    await tester.ensureVisible(
      find.byKey(const ValueKey('auth-toggle-register')),
    );
    await tester.tap(find.byKey(const ValueKey('auth-toggle-register')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('auth-name-field')),
      'Mira',
    );
    await _fill(tester, 'old123');
    await _submit(tester);
    expect(repository.signUps, isEmpty);
    expect(find.text(deL10n.authErrorPasswordTooShort(8)), findsOneWidget);
  });

  for (final code in ['email_exists', 'user_already_exists']) {
    testWidgets('typed conflict $code offers the neutral login path', (
      tester,
    ) async {
      final repository = await _pump(tester);
      repository.conflictCode = code;
      await tester.ensureVisible(
        find.byKey(const ValueKey('auth-toggle-register')),
      );
      await tester.tap(find.byKey(const ValueKey('auth-toggle-register')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('auth-name-field')),
        'Mira',
      );
      await _fill(tester, 'long-password');
      await _submit(tester);
      expect(repository.signUps, [
        ('member@example.com', 'long-password', 'Mira'),
      ]);
      expect(find.text(deL10n.authSignupExistingAccountHint), findsOneWidget);
      expect(find.byKey(const ValueKey('auth-code-screen')), findsNothing);
      expect(find.byKey(const ValueKey('auth-error')), findsNothing);
      expect(find.byKey(const ValueKey('auth-name-field')), findsNothing);
    });
  }

  testWidgets('same-frame mode and recovery actions cannot race a login', (
    tester,
  ) async {
    final repository = await _pump(tester);
    final pending = Completer<void>();
    repository.pending = pending;
    await _fill(tester, 'long-password');
    final mode = tester
        .widget<InkWell>(find.byKey(const ValueKey('auth-toggle-register')))
        .onTap!;
    final recovery = tester
        .widget<InkWell>(find.byKey(const ValueKey('auth-forgot-password')))
        .onTap!;
    final submit = tester
        .widget<AuthPrimaryButton>(find.byType(AuthPrimaryButton))
        .onTap;
    submit();
    mode();
    recovery();
    await tester.pump();
    expect(repository.signIns, hasLength(1));
    expect(find.byKey(const ValueKey('auth-code-screen')), findsNothing);
    expect(find.byKey(const ValueKey('auth-name-field')), findsNothing);
    pending.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('password reveal never enables keyboard suggestions', (
    tester,
  ) async {
    await _pump(tester);
    await tester.ensureVisible(
      find.byKey(const ValueKey('auth-toggle-password')),
    );
    await tester.tap(find.byKey(const ValueKey('auth-toggle-password')));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('auth-password-field')),
    );
    expect(field.obscureText, isFalse);
    expect(field.autocorrect, isFalse);
    expect(field.enableSuggestions, isFalse);
  });
}
