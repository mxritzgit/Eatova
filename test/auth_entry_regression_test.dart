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

Future<_RecordingRepository> _pump(WidgetTester tester) async {
  final repository = _RecordingRepository();
  addTearDown(repository.dispose);
  await pumpLocalized(
    tester,
    AuthScreen(authRepository: repository),
    scaffold: false,
    safeArea: false,
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
