import 'dart:async';
import 'dart:convert';

import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/auth/google_id_token_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

String _session(String user, String sid) {
  String encode(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return jsonEncode({
    'access_token':
        '${encode({'alg': 'HS256'})}.'
        '${encode({'session_id': sid, 'exp': 4102444800})}.'
        'synthetic-signature',
    'refresh_token': 'synthetic-$sid',
    'token_type': 'bearer',
    'expires_in': 3600,
    'user': {
      'id': user,
      'email': '$user@example.invalid',
      'aud': 'authenticated',
      'created_at': '2026-09-16T00:00:00Z',
      'app_metadata': <String, dynamic>{},
      'user_metadata': <String, dynamic>{},
    },
  });
}

class _GoogleToken implements GoogleIdTokenProvider {
  _GoogleToken({this.token});

  final Future<String?>? token;

  @override
  Future<String?> getIdToken() async => token ?? 'synthetic-id-token';
}

class _PkceStore extends GotrueAsyncStorage {
  final values = <String, String>{'pending-oauth': 'synthetic-verifier'};
  int writes = 0;

  @override
  Future<String?> getItem({required String key}) async => values[key];

  @override
  Future<void> setItem({required String key, required String value}) async {
    writes++;
    values[key] = value;
  }

  @override
  Future<void> removeItem({required String key}) async {
    writes++;
    values.remove(key);
  }
}

SupabaseClient _client(http.Client transport) => SupabaseClient(
  'https://ci.invalid',
  'ci-dummy-key',
  httpClient: transport,
  authOptions: const AuthClientOptions(
    autoRefreshToken: false,
    authFlowType: AuthFlowType.implicit,
  ),
);

Future<void> _login(SupabaseAuthRepository repository, String method) async {
  switch (method) {
    case 'password':
      await repository.signIn(
        email: ' a@example.invalid ',
        password: 'synthetic-password',
      );
    case 'signup':
      await repository.signUp(
        email: ' a@example.invalid ',
        password: 'synthetic-password',
        displayName: ' Ada ',
      );
    case 'google':
      await repository.signInWithOAuth(EatovaOAuthProvider.google);
  }
}

void main() {
  for (final method in ['password', 'signup', 'google']) {
    for (final transition in ['another account', 'login then logout']) {
      test('$method late response cannot replace $transition', () async {
        final started = Completer<void>();
        final release = Completer<void>();
        final transport = MockClient((request) async {
          if (request.url.path.endsWith('/logout')) {
            return http.Response('{}', 200);
          }
          started.complete();
          await release.future;
          return http.Response(_session('a', 'late-a'), 200);
        });
        final client = _client(transport);
        addTearDown(client.dispose);
        final repository = SupabaseAuthRepository(
          client,
          mutationHttpClient: transport,
          googleIdTokenProvider: _GoogleToken(),
        );
        final result = _login(
          repository,
          method,
        ).then<Object?>((_) => null, onError: (Object error) => error);
        await started.future;
        await client.auth.setInitialSession(_session('b', 'new-b'));
        if (transition == 'login then logout') await client.auth.signOut();
        await Future<void>.delayed(Duration.zero);
        final identities = <String?>[];
        final subscription = client.auth.onAuthStateChange.listen(
          (event) => identities.add(event.session?.user.id),
        );
        addTearDown(subscription.cancel);
        release.complete();

        expect(await result, isA<AuthException>());
        await Future<void>.delayed(Duration.zero);
        expect(
          repository.currentUser?.id,
          transition == 'another account' ? 'b' : null,
        );
        expect(identities, isNot(contains('a')));
      });
    }

    test(
      '$method still establishes the requested session and wire data',
      () async {
        final transport = MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(request.url.host, 'ci.invalid');
          if (method == 'google') {
            expect(request.url.queryParameters['grant_type'], 'id_token');
            expect(body['provider'], 'google');
            expect(body['id_token'], 'synthetic-id-token');
          } else {
            expect(body['email'], 'a@example.invalid');
            expect(body['password'], 'synthetic-password');
            if (method == 'signup') {
              expect(request.url.path, '/auth/v1/signup');
              expect(body['data'], {'display_name': 'Ada'});
              expect(body['redirect_to'], isNull);
            } else {
              expect(request.url.queryParameters['grant_type'], 'password');
            }
          }
          return http.Response(_session('a', 'new-a'), 200);
        });
        final client = _client(transport);
        addTearDown(client.dispose);
        final repository = SupabaseAuthRepository(
          client,
          mutationHttpClient: transport,
          googleIdTokenProvider: _GoogleToken(),
        );
        final events = <AuthChangeEvent>[];
        final subscription = client.auth.onAuthStateChange.listen(
          (event) => events.add(event.event),
        );
        addTearDown(subscription.cancel);
        await _login(repository, method);
        await Future<void>.delayed(Duration.zero);
        expect(repository.currentUser?.id, 'a');
        expect(client.auth.currentSession?.refreshToken, 'synthetic-new-a');
        expect(
          events.where((event) => event == AuthChangeEvent.signedIn),
          hasLength(1),
        );
      },
    );
  }

  for (final method in ['password', 'google']) {
    test('$method rejects a successful response without a session', () async {
      final transport = MockClient((request) async => http.Response('{}', 200));
      final client = _client(transport);
      addTearDown(client.dispose);
      final repository = SupabaseAuthRepository(
        client,
        mutationHttpClient: transport,
        googleIdTokenProvider: _GoogleToken(),
      );
      await expectLater(
        _login(repository, method),
        throwsA(isA<AuthException>()),
      );
      expect(repository.currentUser, isNull);
    });
  }

  test(
    'pending signup preserves OAuth PKCE storage without establishing a session',
    () async {
      final pkce = _PkceStore();
      final transport = MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['code_challenge'], isNull);
        expect(body['redirect_to'], isNull);
        expect(request.headers['apikey'], 'ci-dummy-key');
        return http.Response(
          jsonEncode(jsonDecode(_session('a', 'signup'))['user']),
          200,
        );
      });
      final client = SupabaseClient(
        'https://ci.invalid',
        'ci-dummy-key',
        httpClient: transport,
        authOptions: AuthClientOptions(
          autoRefreshToken: false,
          pkceAsyncStorage: pkce,
        ),
      );
      addTearDown(client.dispose);
      final repository = SupabaseAuthRepository(
        client,
        mutationHttpClient: transport,
      );
      expect(
        await repository.signUp(
          email: 'a@example.invalid',
          password: 'synthetic-password',
          displayName: 'Ada',
        ),
        SignUpOutcome.created,
      );
      expect(repository.currentUser, isNull);
      expect(pkce.writes, 0);
      expect(pkce.values, {'pending-oauth': 'synthetic-verifier'});
    },
  );

  test(
    'Google account chooser cannot supersede an intervening login',
    () async {
      final selected = Completer<String?>();
      final transport = MockClient(
        (request) async => http.Response(_session('a', 'late-a'), 200),
      );
      final client = _client(transport);
      addTearDown(client.dispose);
      final repository = SupabaseAuthRepository(
        client,
        mutationHttpClient: transport,
        googleIdTokenProvider: _GoogleToken(token: selected.future),
      );
      final result = _login(
        repository,
        'google',
      ).then<Object?>((_) => null, onError: (Object error) => error);
      await client.auth.setInitialSession(_session('b', 'new-b'));
      selected.complete('synthetic-id-token');
      expect(await result, isA<AuthException>());
      expect(repository.currentUser?.id, 'b');
    },
  );
}
