import 'dart:async';
import 'dart:convert';

import 'package:eatova/src/auth/auth_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

String _session(String user, String sid, {int version = 1}) {
  String encode(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return jsonEncode({
    'access_token':
        '${encode({'alg': 'HS256'})}.'
        '${encode({'session_id': sid, 'exp': 4102444800, 'version': version})}.'
        'synthetic-signature',
    'refresh_token': 'synthetic-$user-$sid-$version',
    'token_type': 'bearer',
    'expires_in': 3600,
    'user': {
      'id': user,
      'email': '$user@example.invalid',
      'aud': 'authenticated',
      'created_at': '2026-09-15T00:00:00Z',
      'app_metadata': <String, dynamic>{},
      'user_metadata': <String, dynamic>{},
    },
  });
}

SupabaseClient _client(http.Client transport) => SupabaseClient(
  'https://ci.invalid',
  'ci-dummy-key',
  httpClient: transport,
  authOptions: const AuthClientOptions(autoRefreshToken: false),
);

Future<void> _verify(SupabaseAuthRepository repository, String type) =>
    type == 'recovery'
    ? repository.verifyRecoveryCode(
        email: 'a@example.invalid',
        code: '12345678',
      )
    : repository.verifySignupCode(email: 'a@example.invalid', code: '12345678');

void main() {
  for (final type in ['recovery', 'signup']) {
    test('$type verification allows a genuine signed-out login', () async {
      final transport = MockClient((request) async {
        expect(request.url.path, '/auth/v1/verify');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['type'], type);
        expect(body['email'], 'a@example.invalid');
        expect(body['token'], '12345678');
        expect(body['redirect_to'], isNull);
        return http.Response(_session('a', 'verified-a'), 200);
      });
      final client = _client(transport);
      addTearDown(client.dispose);
      final repository = SupabaseAuthRepository(
        client,
        mutationHttpClient: transport,
      );
      await _verify(repository, type);
      expect(client.auth.currentUser?.id, 'a');
    });

    test('$type verification succeeds after a completed logout', () async {
      final transport = MockClient(
        (request) async => http.Response(
          request.url.path.endsWith('/logout')
              ? '{}'
              : _session('a', 'verified-a'),
          200,
        ),
      );
      final client = _client(transport);
      addTearDown(client.dispose);
      final repository = SupabaseAuthRepository(
        client,
        mutationHttpClient: transport,
      );
      await client.auth.setInitialSession(_session('b', 'old-b'));
      await repository.signOut();
      await Future<void>.delayed(Duration.zero);
      expect(client.auth.currentSession, isNull);

      await _verify(repository, type);
      expect(client.auth.currentUser?.id, 'a');
    });

    test('$type rejects A to B to the identical A session', () async {
      final started = Completer<void>();
      final release = Completer<void>();
      final transport = MockClient((request) async {
        started.complete();
        await release.future;
        return http.Response(_session('a', 'verified-a'), 200);
      });
      final client = _client(transport);
      addTearDown(client.dispose);
      final original = _session('a', 'old-a');
      await client.auth.setInitialSession(original);
      final repository = SupabaseAuthRepository(
        client,
        mutationHttpClient: transport,
      );
      final result = _verify(
        repository,
        type,
      ).then<Object?>((_) => null, onError: (Object error) => error);
      await started.future;
      unawaited(client.auth.setInitialSession(_session('b', 'new-b')));
      unawaited(client.auth.setInitialSession(original));
      release.complete();

      expect(await result, isA<AuthException>());
      expect(client.auth.currentSession?.refreshToken, 'synthetic-a-old-a-1');
    });

    for (final change in [
      'B',
      'B then logout',
      'logout A',
      'new A login',
      'A refresh',
    ]) {
      test('$type response respects intervening $change', () async {
        final started = Completer<void>();
        final release = Completer<void>();
        final transport = MockClient((request) async {
          if (request.url.path.endsWith('/logout')) {
            return http.Response('{}', 200);
          }
          started.complete();
          await release.future;
          return http.Response(_session('a', 'verified-a'), 200);
        });
        final client = _client(transport);
        addTearDown(client.dispose);
        if (change.startsWith('A ') ||
            change == 'new A login' ||
            change == 'logout A') {
          await client.auth.setInitialSession(_session('a', 'old-a'));
        }
        final repository = SupabaseAuthRepository(
          client,
          mutationHttpClient: transport,
        );
        final result = _verify(
          repository,
          type,
        ).then<Object?>((_) => null, onError: (Object error) => error);
        await started.future;
        final events = <String?>[];
        final sub = client.auth.onAuthStateChange.listen(
          (event) => events.add(event.session?.user.id),
        );
        addTearDown(sub.cancel);
        if (change.startsWith('B')) {
          await client.auth.setInitialSession(_session('b', 'new-b'));
          if (change == 'B then logout') await client.auth.signOut();
        } else if (change == 'logout A') {
          await client.auth.signOut();
        } else {
          await client.auth.setInitialSession(
            change == 'A refresh'
                ? _session('a', 'old-a', version: 2)
                : _session('a', 'new-a'),
          );
        }
        await Future<void>.delayed(Duration.zero);
        events.clear();
        release.complete();
        final error = await result;
        await Future<void>.delayed(Duration.zero);
        if (change == 'A refresh') {
          expect(error, isNull);
          expect(
            client.auth.currentSession?.refreshToken,
            'synthetic-a-verified-a-1',
          );
        } else {
          expect(error, isA<AuthException>());
          expect(client.auth.currentUser?.id, switch (change) {
            'B' => 'b',
            'B then logout' || 'logout A' => null,
            _ => 'a',
          });
          if (change.startsWith('B') || change == 'logout A') {
            expect(events, isNot(contains('a')));
          }
          if (change == 'new A login') {
            expect(
              client.auth.currentSession?.refreshToken,
              'synthetic-a-new-a-1',
            );
          }
        }
      });
    }

    for (final payload in ['{}', 'foreign user']) {
      test(
        '$type rejects $payload without changing the existing account',
        () async {
          final transport = MockClient(
            (request) async => http.Response(
              payload == '{}' ? '{}' : _session('b', 'foreign-b'),
              200,
            ),
          );
          final client = _client(transport);
          addTearDown(client.dispose);
          await client.auth.setInitialSession(_session('a', 'old-a'));
          final repository = SupabaseAuthRepository(
            client,
            mutationHttpClient: transport,
          );
          await expectLater(
            _verify(repository, type),
            throwsA(isA<AuthException>()),
          );
          expect(client.auth.currentUser?.id, 'a');
          expect(
            client.auth.currentSession?.refreshToken,
            'synthetic-a-old-a-1',
          );
        },
      );
    }
  }
}
