import 'dart:async';
import 'dart:convert';

import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/auth/google_id_token_provider.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/screens/auth_screen.dart';
import 'package:eatova/src/screens/settings/account_change_messages.dart';
import 'package:eatova/src/widgets/design/controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'support/harness.dart';

// GoTrue sets no request timeout of its own. Without a deadline a stalled
// connection (network handover, captive portal) kept the sign-in spinner
// running with every control on the entry screen disabled until the app was
// killed. Each GoTrue exchange of the isolated mutation client is bounded by
// the same deadline as the other auth flows; a native account chooser is not.

String _session(String user, String sid) {
  String encode(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return jsonEncode({
    'access_token':
        '${encode({'alg': 'HS256'})}.'
        '${encode({'sub': user, 'session_id': sid, 'exp': 4102444800})}.'
        'synthetic-signature',
    'refresh_token': 'synthetic-$sid',
    'token_type': 'bearer',
    'expires_in': 3600,
    'user': {
      'id': user,
      'email': '$user@example.invalid',
      'aud': 'authenticated',
      'created_at': '2026-10-04T00:00:00Z',
      'app_metadata': <String, dynamic>{},
      'user_metadata': <String, dynamic>{},
    },
  });
}

/// Accepts every request and never answers.
MockClient _stalled(List<http.Request> requests) => MockClient((request) {
  requests.add(request);
  return Completer<http.Response>().future;
});

SupabaseClient _client(http.Client transport, {Duration? deadline}) =>
    SupabaseClient(
      'https://ci.invalid',
      'ci-dummy-key',
      httpClient: transport,
      authOptions: const AuthClientOptions(
        autoRefreshToken: false,
        authFlowType: AuthFlowType.implicit,
      ),
      postgrestOptions: PostgrestClientOptions(requestTimeout: deadline),
    );

class _SlowChooser implements GoogleIdTokenProvider {
  _SlowChooser(this.token);

  final Future<String?> token;

  @override
  Future<String?> getIdToken() => token;
}

void main() {
  const deadline = Duration(milliseconds: 50);

  // The outer guard only turns a hang into a readable failure.
  Future<Object?> outcome(Future<void> Function() call) async {
    try {
      await call().timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw StateError('auth request never finished'),
      );
      return null;
    } catch (error) {
      return error;
    }
  }

  for (final flow in <String>['password', 'signup', 'google id token']) {
    test(
      '$flow login against a stalled server ends as an offline error',
      () async {
        final requests = <http.Request>[];
        final transport = _stalled(requests);
        final client = _client(transport, deadline: deadline);
        addTearDown(client.dispose);
        final repository = SupabaseAuthRepository(
          client,
          mutationHttpClient: transport,
          googleIdTokenProvider: _SlowChooser(Future.value('synthetic-id')),
        );

        final error = await outcome(() async {
          switch (flow) {
            case 'password':
              await repository.signIn(
                email: 'a@example.invalid',
                password: 'synthetic-password',
              );
            case 'signup':
              await repository.signUp(
                email: 'a@example.invalid',
                password: 'synthetic-password',
                displayName: 'Ada',
              );
            default:
              await repository.signInWithOAuth(EatovaOAuthProvider.google);
          }
        });

        expect(error, isNotNull);
        expect(error, isNot(isA<StateError>()), reason: 'request hung');
        expect(classifyAuthError(error!).kind, AuthErrorKind.offline);
        expect(requests, hasLength(1));
        expect(client.auth.currentSession, isNull);
      },
    );
  }

  test(
    'the native account chooser itself is not bounded by the deadline',
    () async {
      final chooser = Completer<String?>();
      final transport = MockClient(
        (_) async => http.Response(_session('a', 'sid-a'), 200),
      );
      final client = _client(transport, deadline: deadline);
      addTearDown(client.dispose);
      final repository = SupabaseAuthRepository(
        client,
        mutationHttpClient: transport,
        googleIdTokenProvider: _SlowChooser(chooser.future),
      );

      final login = repository.signInWithOAuth(EatovaOAuthProvider.google);
      // The user takes far longer than one request deadline to pick an account.
      await Future<void>.delayed(deadline * 6);
      chooser.complete('synthetic-id');
      await login;

      expect(client.auth.currentUser?.id, 'a');
    },
  );

  for (final change in <String>[
    'password change',
    'email change request',
    'email change code',
  ]) {
    test('$change against a stalled server ends as an offline error and '
        'keeps the login', () async {
      final requests = <http.Request>[];
      final transport = _stalled(requests);
      final client = _client(transport, deadline: deadline);
      addTearDown(client.dispose);
      await client.auth.setInitialSession(_session('a', 'sid-a'));
      final repository = SupabaseAuthRepository(
        client,
        mutationHttpClient: transport,
      );

      final error = await outcome(() async {
        switch (change) {
          case 'password change':
            await repository.confirmPasswordChange(
              currentPassword: 'synthetic-old',
              code: '12345678',
              newPassword: 'synthetic-new',
            );
          case 'email change request':
            await repository.startEmailChange('b@example.invalid');
          default:
            await repository.confirmEmailChange(
              email: 'a@example.invalid',
              code: '12345678',
            );
        }
      });

      expect(error, isNotNull);
      expect(error, isNot(isA<StateError>()), reason: 'request hung');
      expect(classifyAuthError(error!).kind, AuthErrorKind.offline);
      expect(requests, hasLength(1));
      expect(client.auth.currentUser?.id, 'a');
      expect(client.auth.currentUser?.email, 'a@example.invalid');
    });
  }

  testWidgets('a stalled sign-in releases the entry screen with the offline '
      'note', (tester) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final requests = <http.Request>[];
    final transport = _stalled(requests);
    // Production default: no PostgREST override, so the shared 20 s deadline.
    // Not disposed: its realtime teardown never completes under fake time.
    final client = _client(transport);

    await pumpLocalized(
      tester,
      AuthScreen(
        authRepository: SupabaseAuthRepository(
          client,
          mutationHttpClient: transport,
        ),
      ),
      scaffold: false,
      safeArea: false,
    );
    await tester.enterText(
      find.byKey(const ValueKey('auth-email-field')),
      'du@eatova.de',
    );
    await tester.enterText(
      find.byKey(const ValueKey('auth-password-field')),
      'geheim99',
    );
    await tester.ensureVisible(find.byKey(const ValueKey('auth-submit')));
    await tester.tap(find.byKey(const ValueKey('auth-submit')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    expect(requests, hasLength(1));

    await tester.pump(const Duration(seconds: 21));
    // The SDK settles its auth-stream cancellation outside fake time.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();

    expect(find.text(deL10n.authCodeOfflineError), findsOneWidget);
    final submit = tester.widget<PrimaryActionButton>(
      find.byKey(const ValueKey('auth-submit')),
    );
    expect(submit.onTap, isNotNull, reason: 'the form is usable again');
  });
}
