import 'dart:async';
import 'dart:convert';

import 'package:eatova/src/auth/auth_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _json = {'content-type': 'application/json'};

Map<String, dynamic> _user(String id) => {
  'id': id,
  'aud': 'authenticated',
  'email': '$id@example.com',
  'created_at': '2026-09-08T10:00:00Z',
  'app_metadata': <String, dynamic>{},
  'user_metadata': <String, dynamic>{},
};

Map<String, dynamic> _session(String id) => {
  'access_token': 'fixture-token-$id',
  'refresh_token': 'fixture-refresh-$id',
  'token_type': 'bearer',
  'expires_in': 3600,
  'user': _user(id),
};

String _jwt(String id, String sessionId, int version) {
  String encode(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${encode({'alg': 'HS256', 'typ': 'JWT'})}.'
      '${encode({'sub': id, 'session_id': sessionId, 'exp': 4102444800, 'version': version})}.'
      'fixture-signature';
}

Map<String, dynamic> _realisticSession(
  String id,
  String sessionId, {
  int version = 1,
}) => {
  ..._session(id),
  'access_token': _jwt(id, sessionId, version),
  'refresh_token': 'fixture-refresh-$sessionId-$version',
};

SupabaseClient _client(http.Client transport) => SupabaseClient(
  'https://ci.invalid',
  'ci-dummy-key',
  httpClient: transport,
  authOptions: const AuthClientOptions(
    autoRefreshToken: false,
    authFlowType: AuthFlowType.implicit,
  ),
);

class _AfterBodyClient extends http.BaseClient {
  _AfterBodyClient(this.onBody);
  final void Function() onBody;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(jsonEncode(_user('account-a')))).map((
        bytes,
      ) {
        // Runs after send returned and while Response.fromStream consumes it.
        scheduleMicrotask(onBody);
        return bytes;
      }),
      200,
      headers: _json,
    );
  }
}

void main() {
  for (final operation in <String>[
    'recovery password',
    'password change',
    'email change',
    'email confirmation',
  ]) {
    test(
      '$operation cannot replace the next account with a late response',
      () async {
        final sent = Completer<void>();
        final release = Completer<void>();
        final transport = MockClient((request) async {
          if (request.url.path.endsWith('/token')) {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            final id = (body['email'] as String).split('@').first;
            return http.Response(jsonEncode(_session(id)), 200, headers: _json);
          }
          if (request.url.path.endsWith('/logout')) {
            return http.Response('{}', 200, headers: _json);
          }
          sent.complete();
          await release.future;
          return http.Response(
            jsonEncode(
              operation == 'email confirmation'
                  ? _session('account-a')
                  : _user('account-a'),
            ),
            200,
            headers: _json,
          );
        });
        final client = SupabaseClient(
          'https://ci.invalid',
          'ci-dummy-key',
          httpClient: transport,
          authOptions: const AuthClientOptions(
            autoRefreshToken: false,
            authFlowType: AuthFlowType.implicit,
          ),
        );
        addTearDown(client.dispose);
        final repository = SupabaseAuthRepository(
          client,
          mutationHttpClient: transport,
        );
        await repository.signIn(
          email: 'account-a@example.com',
          password: 'fixture-password',
        );

        final pending = switch (operation) {
          'recovery password' => repository.updatePassword(
            'new-fixture-password',
          ),
          'password change' => repository.confirmPasswordChange(
            code: '12345678',
            newPassword: 'new-fixture-password',
          ),
          'email change' => repository.startEmailChange('new@example.com'),
          _ => repository.confirmEmailChange(
            email: 'account-a@example.com',
            code: '12345678',
          ),
        };
        // Observe rejection immediately so the future cannot become unhandled.
        final result = pending.then<Object?>(
          (_) => null,
          onError: (Object e) => e,
        );
        await sent.future;
        await repository.signOut();
        await repository.signIn(
          email: 'account-b@example.com',
          password: 'fixture-password',
        );
        expect(repository.currentUser?.id, 'account-b');

        final identities = <String?>[];
        final subscription = client.auth.onAuthStateChange.listen(
          (event) => identities.add(event.session?.user.id),
        );
        addTearDown(subscription.cancel);
        release.complete();
        await result;
        await Future<void>.delayed(Duration.zero);

        expect(
          repository.currentUser?.id,
          'account-b',
          reason: 'A late mutation must not overwrite B in the SDK session',
        );
        expect(
          client.auth.currentSession?.accessToken,
          'fixture-token-account-b',
        );
        expect(
          identities,
          isNot(contains('account-a')),
          reason: 'The old identity must never reach AuthGate or its caches',
        );
      },
    );
  }

  for (final transition in ['same user login', 'logout', 'no change']) {
    test('password response respects $transition', () async {
      final sent = Completer<void>();
      final release = Completer<void>();
      var login = 0;
      final transport = MockClient((request) async {
        if (request.url.path.endsWith('/token')) {
          login++;
          return http.Response(
            jsonEncode(_realisticSession('account-a', 'login-$login')),
            200,
            headers: _json,
          );
        }
        if (request.url.path.endsWith('/logout')) {
          return http.Response('{}', 200, headers: _json);
        }
        sent.complete();
        await release.future;
        return http.Response(
          jsonEncode(_user('account-a')),
          200,
          headers: _json,
        );
      });
      final client = _client(transport);
      addTearDown(client.dispose);
      final repo = SupabaseAuthRepository(
        client,
        mutationHttpClient: transport,
      );
      await repo.signIn(
        email: 'account-a@example.com',
        password: 'fixture-pass',
      );
      final pending = repo
          .updatePassword('fixture-new-password')
          .then<Object?>((_) => null, onError: (Object e) => e);
      await sent.future;
      if (transition != 'no change') await repo.signOut();
      if (transition == 'same user login') {
        await repo.signIn(
          email: 'account-a@example.com',
          password: 'fixture-pass',
        );
      }
      final token = client.auth.currentSession?.accessToken;
      release.complete();
      final result = await pending;
      expect(result, transition == 'no change' ? isNull : isA<AuthException>());
      expect(client.auth.currentSession?.accessToken, token);
      expect(
        repo.currentUser?.id,
        transition == 'logout' ? isNull : 'account-a',
      );
    });
  }

  test(
    'an account switch during response body processing never installs A',
    () async {
      late final SupabaseClient client;
      late final Future<void> switched;
      final transport = _AfterBodyClient(() {
        switched = client.auth.setInitialSession(
          jsonEncode(_realisticSession('account-b', 'login-b')),
        );
      });
      client = _client(transport);
      addTearDown(client.dispose);
      await client.auth.setInitialSession(
        jsonEncode(_realisticSession('account-a', 'login-a')),
      );
      final repo = SupabaseAuthRepository(
        client,
        mutationHttpClient: transport,
      );
      await expectLater(
        repo.updatePassword('fixture-new-password'),
        throwsA(isA<AuthException>()),
      );
      await switched;
      expect(repo.currentUser?.id, 'account-b');
      expect(
        client.auth.currentSession?.accessToken,
        _jwt('account-b', 'login-b', 1),
      );
    },
  );

  for (final refreshFirst in [true, false]) {
    test(
      'refresh ${refreshFirst ? 'before' : 'after'} update response stays coherent',
      () async {
        final updateSent = Completer<void>();
        final refreshSent = Completer<void>();
        final releaseUpdate = Completer<void>();
        final releaseRefresh = Completer<void>();
        final transport = MockClient((request) async {
          if (request.url.path.endsWith('/token')) {
            refreshSent.complete();
            await releaseRefresh.future;
            return http.Response(
              jsonEncode(
                _realisticSession('account-a', 'same-session', version: 2),
              ),
              200,
              headers: _json,
            );
          }
          updateSent.complete();
          await releaseUpdate.future;
          return http.Response(
            jsonEncode({
              ..._user('account-a'),
              'user_metadata': {'display_name': 'Updated name'},
            }),
            200,
            headers: _json,
          );
        });
        final client = _client(transport);
        addTearDown(client.dispose);
        await client.auth.setInitialSession(
          jsonEncode(_realisticSession('account-a', 'same-session')),
        );
        final repo = SupabaseAuthRepository(
          client,
          mutationHttpClient: transport,
        );
        final mutation = repo.updatePassword('fixture-new-password');
        await updateSent.future;
        final refresh = client.auth.refreshSession();
        await refreshSent.future;
        if (refreshFirst) {
          releaseRefresh.complete();
          await refresh;
        }
        releaseUpdate.complete();
        await mutation;
        if (!refreshFirst) {
          releaseRefresh.complete();
          await refresh;
        }
        expect(
          repo.currentUser?.displayName,
          'Updated name',
          reason: 'A stale refresh must not overwrite the adopted user',
        );
        expect(
          client.auth.currentSession?.accessToken,
          _jwt('account-a', 'same-session', refreshFirst ? 2 : 1),
        );
      },
    );
  }

  test(
    'an empty intermediate email response keeps the existing session',
    () async {
      final transport = MockClient(
        (_) async => http.Response('{}', 200, headers: _json),
      );
      final client = _client(transport);
      addTearDown(client.dispose);
      await client.auth.setInitialSession(jsonEncode(_session('account-a')));
      final original = client.auth.currentSession;
      final repo = SupabaseAuthRepository(
        client,
        mutationHttpClient: transport,
      );
      await repo.confirmEmailChange(
        email: 'account-a@example.com',
        code: '12345678',
      );
      expect(client.auth.currentSession, same(original));
    },
  );

  for (final foreignUser in [false, true]) {
    test(
      '${foreignUser ? 'foreign user' : 'server error'} response cannot alter the session',
      () async {
        final transport = MockClient(
          (_) async => http.Response(
            jsonEncode(
              foreignUser
                  ? _user('account-b')
                  : {
                      'code': 'same_password',
                      'message': 'Password must be different',
                    },
            ),
            foreignUser ? 200 : 422,
            headers: _json,
          ),
        );
        final client = _client(transport);
        addTearDown(client.dispose);
        await client.auth.setInitialSession(jsonEncode(_session('account-a')));
        final original = client.auth.currentSession;
        final repo = SupabaseAuthRepository(
          client,
          mutationHttpClient: transport,
        );
        await expectLater(
          repo.updatePassword('fixture-new-password'),
          throwsA(isA<AuthException>()),
        );
        expect(client.auth.currentSession, same(original));
      },
    );
  }

  test(
    'logout before the isolated request starts prevents sending it',
    () async {
      var updates = 0;
      final transport = MockClient((request) async {
        if (request.url.path.endsWith('/user')) updates++;
        return http.Response('{}', 200, headers: _json);
      });
      final client = _client(transport);
      addTearDown(client.dispose);
      await client.auth.setInitialSession(jsonEncode(_session('account-a')));
      final repo = SupabaseAuthRepository(
        client,
        mutationHttpClient: transport,
      );
      final mutation = repo.updatePassword('fixture-new-password');
      final result = expectLater(mutation, throwsA(isA<AuthException>()));
      await repo.signOut();
      await result;
      expect(updates, 0);
      expect(client.auth.currentSession, isNull);
    },
  );
}
