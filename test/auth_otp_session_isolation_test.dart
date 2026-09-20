import 'dart:async';
import 'dart:convert';

import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/auth/password_recovery.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Map<String, dynamic> _user(String user) => {
  'id': user,
  'email': '$user@example.invalid',
  'aud': 'authenticated',
  'created_at': '2026-09-15T00:00:00Z',
  'app_metadata': <String, dynamic>{},
  'user_metadata': <String, dynamic>{},
};

String _session(String user, String sid) {
  String encode(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return jsonEncode({
    'access_token':
        '${encode({'alg': 'HS256'})}.'
        '${encode({'sub': user, 'session_id': sid, 'exp': 4102444800})}.'
        'synthetic-signature',
    'refresh_token': 'synthetic-$user-$sid',
    'token_type': 'bearer',
    'expires_in': 3600,
    'user': _user(user),
  });
}

String _bearer(String user, String sid) =>
    'Bearer ${(jsonDecode(_session(user, sid)) as Map)['access_token']}';

SupabaseClient _client(http.Client transport, {Duration? timeout}) =>
    SupabaseClient(
      'https://ci.invalid',
      'ci-dummy-key',
      httpClient: transport,
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      postgrestOptions: PostgrestClientOptions(requestTimeout: timeout),
    );

Future<PasswordRecovery?> _verify(
  SupabaseClient client,
  http.Client transport,
  String type,
) async {
  final repo = SupabaseAuthRepository(client, mutationHttpClient: transport);
  if (type == 'signup') {
    await repo.verifySignupCode(email: 'a@example.invalid', code: '12345678');
    return null;
  }
  return repo.verifyRecoveryCode(email: 'a@example.invalid', code: '12345678');
}

class _CancellableClient extends http.BaseClient {
  final pending = Completer<http.StreamedResponse>();
  int closes = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      pending.future;
  @override
  void close() {
    closes++;
    if (!pending.isCompleted) {
      pending.completeError(http.ClientException('Request cancelled'));
    }
  }
}

void main() {
  test(
    'owned HTTP is cancelled on timeout without changing the app client',
    () async {
      var sharedRequests = 0;
      final shared = MockClient((_) async {
        sharedRequests++;
        return http.Response('{}', 500);
      });
      final client = _client(shared, timeout: const Duration(milliseconds: 50));
      addTearDown(client.dispose);
      final owned = _CancellableClient();
      await expectLater(
        http.runWithClient(
          () => beginPasswordRecovery(
            client,
            email: 'a@example.invalid',
            code: '12345678',
          ),
          () => owned,
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(owned.closes, 1);
      expect(sharedRequests, 0);
      expect(client.auth.currentSession, isNull);
    },
  );

  test(
    'a late verification response after timeout is revoked when received',
    () async {
      final release = Completer<void>();
      final revoked = Completer<void>();
      final transport = MockClient((request) async {
        if (request.url.path.endsWith('/logout')) {
          expect(request.headers['Authorization'], _bearer('a', 'verified-a'));
          revoked.complete();
          return http.Response('', 204);
        }
        await release.future;
        return http.Response(_session('a', 'verified-a'), 200);
      });
      final client = _client(
        transport,
        timeout: const Duration(milliseconds: 50),
      );
      addTearDown(client.dispose);
      await expectLater(
        _verify(client, transport, 'recovery'),
        throwsA(isA<TimeoutException>()),
      );
      release.complete();
      await revoked.future;
      expect(client.auth.currentSession, isNull);
    },
  );

  for (final type in ['recovery', 'signup']) {
    test('$type proof never becomes shared auth or persisted login', () async {
      final requests = <http.Request>[];
      final transport = MockClient((request) async {
        requests.add(request);
        if (request.url.path.endsWith('/logout')) {
          expect(request.url.queryParameters['scope'], 'local');
          expect(request.headers['Authorization'], _bearer('a', 'verified-a'));
          return http.Response('', 204);
        }
        expect(request.url.path, '/auth/v1/verify');
        expect(jsonDecode(request.body), containsPair('type', type));
        return http.Response(_session('a', 'verified-a'), 200);
      });
      final client = _client(transport);
      addTearDown(client.dispose);
      final events = <AuthState>[];
      final sub = client.auth.onAuthStateChange.listen(events.add);
      addTearDown(sub.cancel);
      final handle = await _verify(client, transport, type);
      expect(client.auth.currentSession, isNull);
      await handle?.close();
      await Future<void>.delayed(Duration.zero);
      expect(events.where((event) => event.session != null), isEmpty);
      expect(requests.map((r) => r.url.path), [
        '/auth/v1/verify',
        '/auth/v1/logout',
      ]);
    });

    test('$type rejects an already active application account', () async {
      var requests = 0;
      final transport = MockClient((_) async {
        requests++;
        return http.Response('{}', 500);
      });
      final client = _client(transport);
      addTearDown(client.dispose);
      await client.auth.setInitialSession(_session('b', 'login-b'));
      await expectLater(
        _verify(client, transport, type),
        throwsA(isA<AuthException>()),
      );
      expect(requests, 0);
      expect(client.auth.currentSession?.refreshToken, 'synthetic-b-login-b');
    });

    for (final aba in [false, true]) {
      test('$type late proof cannot cross a login (ABA=$aba)', () async {
        final started = Completer<void>();
        final release = Completer<void>();
        final revoked = <String?>[];
        final transport = MockClient((request) async {
          if (request.url.path.endsWith('/logout')) {
            revoked.add(request.headers['Authorization']);
            return http.Response('', 204);
          }
          started.complete();
          await release.future;
          return http.Response(_session('a', 'verified-a'), 200);
        });
        final client = _client(transport);
        addTearDown(client.dispose);
        final pending = _verify(
          client,
          transport,
          type,
        ).then<Object?>((_) => null, onError: (Object error) => error);
        await started.future;
        await client.auth.setInitialSession(_session('b', 'login-b'));
        if (aba) await client.auth.signOut();
        release.complete();
        expect(await pending, isA<AuthException>());
        expect(client.auth.currentUser?.id, aba ? null : 'b');
        expect(revoked, contains(_bearer('a', 'verified-a')));
        if (!aba) expect(revoked, isNot(contains(_bearer('b', 'login-b'))));
      });
    }

    for (final payload in ['missing', 'wrong email', 'wrong subject']) {
      test('$type rejects $payload proof without shared changes', () async {
        final transport = MockClient((request) async {
          if (request.url.path.endsWith('/logout')) {
            return http.Response('', 204);
          }
          final session = jsonDecode(_session('a', 'verified-a')) as Map;
          if (payload == 'wrong email') session['user'] = _user('b');
          if (payload == 'wrong subject') {
            session['access_token'] =
                (jsonDecode(_session('b', 'verified-b'))
                    as Map)['access_token'];
          }
          return http.Response(
            payload == 'missing' ? '{}' : jsonEncode(session),
            200,
          );
        });
        final client = _client(transport);
        addTearDown(client.dispose);
        await expectLater(
          _verify(client, transport, type),
          throwsA(isA<AuthException>()),
        );
        expect(client.auth.currentSession, isNull);
      });
    }
  }

  test(
    'recovery updates once with fixed proof, revokes and stays signed out',
    () async {
      final requests = <http.Request>[];
      final transport = MockClient((request) async {
        requests.add(request);
        return http.Response(switch (request.url.path) {
          '/auth/v1/verify' => _session('a', 'verified-a'),
          '/auth/v1/user' => jsonEncode(_user('a')),
          _ => '',
        }, request.url.path.endsWith('/logout') ? 204 : 200);
      });
      final client = _client(transport);
      addTearDown(client.dispose);
      final recovery = (await _verify(client, transport, 'recovery'))!;
      await recovery.updatePassword('synthetic-new-password');
      expect(recovery.isActive, isFalse);
      expect(client.auth.currentSession, isNull);
      final update = requests.singleWhere((r) => r.method == 'PUT');
      expect(update.headers['Authorization'], _bearer('a', 'verified-a'));
      expect(jsonDecode(update.body), {'password': 'synthetic-new-password'});
      await expectLater(
        recovery.updatePassword('another-password'),
        throwsA(isA<AuthException>()),
      );
      await recovery.close();
      expect(requests.map((r) => r.url.path), [
        '/auth/v1/verify',
        '/auth/v1/user',
        '/auth/v1/logout',
      ]);
    },
  );

  for (final errorCode in ['same_password', 'weak_password']) {
    test('$errorCode can be corrected using the same unshared proof', () async {
      var writes = 0;
      final transport = MockClient((request) async {
        if (request.url.path.endsWith('/verify')) {
          return http.Response(_session('a', 'verified-a'), 200);
        }
        if (request.url.path.endsWith('/logout')) return http.Response('', 204);
        if (writes++ == 0) {
          return http.Response(
            jsonEncode({'error_code': errorCode, 'msg': errorCode}),
            422,
          );
        }
        return http.Response(jsonEncode(_user('a')), 200);
      });
      final client = _client(transport);
      addTearDown(client.dispose);
      final recovery = (await _verify(client, transport, 'recovery'))!;
      await expectLater(
        recovery.updatePassword('rejected-password'),
        throwsA(isA<AuthException>()),
      );
      expect(recovery.isActive, isTrue);
      await recovery.updatePassword('corrected-password');
      expect(writes, 2);
      expect(client.auth.currentSession, isNull);
    });
  }

  for (final reason in ['cancel', 'new login', 'expiry']) {
    test('$reason closes the proof before a password write', () async {
      final requests = <http.Request>[];
      final transport = MockClient((request) async {
        requests.add(request);
        return http.Response(
          request.url.path.endsWith('/verify')
              ? _session('a', 'verified-a')
              : '{}',
          200,
        );
      });
      final client = _client(transport);
      addTearDown(client.dispose);
      final recovery = await beginPasswordRecovery(
        client,
        email: 'a@example.invalid',
        code: '12345678',
        httpClient: transport,
        authorizationLifetime: reason == 'expiry'
            ? const Duration(milliseconds: 1)
            : const Duration(minutes: 10),
      );
      if (reason == 'cancel') await recovery.close();
      if (reason == 'new login') {
        await client.auth.setInitialSession(_session('b', 'login-b'));
      }
      if (reason == 'expiry') {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await expectLater(
        recovery.updatePassword('synthetic-password'),
        throwsA(isA<AuthException>()),
      );
      await recovery.close();
      expect(requests.where((r) => r.method == 'PUT'), isEmpty);
      expect(
        requests.last.headers['Authorization'],
        _bearer('a', 'verified-a'),
      );
      expect(client.auth.currentUser?.id, reason == 'new login' ? 'b' : null);
    });
  }

  test(
    'lost update response closes proof; late response cannot re-enable it',
    () async {
      final release = Completer<void>();
      final writes = <http.Request>[];
      final transport = MockClient((request) async {
        if (request.url.path.endsWith('/verify')) {
          return http.Response(_session('a', 'verified-a'), 200);
        }
        if (request.url.path.endsWith('/logout')) return http.Response('', 204);
        writes.add(request);
        await release.future;
        return http.Response(jsonEncode(_user('a')), 200);
      });
      final client = _client(
        transport,
        timeout: const Duration(milliseconds: 50),
      );
      addTearDown(client.dispose);
      final recovery = (await _verify(client, transport, 'recovery'))!;
      await expectLater(
        recovery.updatePassword('synthetic-password'),
        throwsA(isA<TimeoutException>()),
      );
      expect(recovery.isActive, isFalse);
      release.complete();
      await Future<void>.delayed(Duration.zero);
      await expectLater(
        recovery.updatePassword('another-password'),
        throwsA(isA<AuthException>()),
      );
      expect(writes, hasLength(1));
      expect(client.auth.currentSession, isNull);
    },
  );

  test(
    'lost logout response cannot turn successful reset into a retry',
    () async {
      final release = Completer<void>();
      var writes = 0;
      final transport = MockClient((request) async {
        if (request.url.path.endsWith('/verify')) {
          return http.Response(_session('a', 'verified-a'), 200);
        }
        if (request.url.path.endsWith('/logout')) {
          await release.future;
          return http.Response('', 204);
        }
        writes++;
        return http.Response(jsonEncode(_user('a')), 200);
      });
      final client = _client(
        transport,
        timeout: const Duration(milliseconds: 50),
      );
      addTearDown(client.dispose);
      final recovery = (await _verify(client, transport, 'recovery'))!;
      await recovery.updatePassword('synthetic-password');
      expect(recovery.isActive, isFalse);
      expect(writes, 1);
      expect(client.auth.currentSession, isNull);
      release.complete();
    },
  );
}
