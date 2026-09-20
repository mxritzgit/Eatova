import 'dart:async';
import 'dart:convert';

import 'package:eatova/src/auth/auth_session_mutation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _headers = {'content-type': 'application/json'};

Map<String, dynamic> _session(
  String account,
  String id, {
  String? email,
  int version = 1,
}) {
  String encode(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return {
    'access_token':
        '${encode({'alg': 'HS256'})}.'
        '${encode({'sub': account, 'session_id': id, 'exp': 4102444800, 'version': version})}.'
        'fixture-signature',
    'refresh_token': 'fixture-refresh-$id-$version',
    'token_type': 'bearer',
    'expires_in': 3600,
    'user': {
      'id': account,
      'aud': 'authenticated',
      'email': email ?? '$account@example.test',
      'created_at': '2026-09-20T00:00:00Z',
      'app_metadata': <String, dynamic>{},
      'user_metadata': <String, dynamic>{},
    },
  };
}

SupabaseClient _client(http.Client transport) => SupabaseClient(
  'https://ci.invalid',
  'ci-dummy-key',
  httpClient: transport,
  authOptions: const AuthClientOptions(autoRefreshToken: false),
);

Future<void> _confirm(SupabaseClient client, http.Client transport) =>
    verifySessionEmailChange(
      client,
      email: 'new@example.test',
      code: '12345678',
      httpClient: transport,
    );

void main() {
  test(
    'email confirmation updates profile, preserves login, revokes only OTP',
    () async {
      final original = _session('a', 'normal');
      final otp = _session('a', 'temporary', email: 'new@example.test');
      final requests = <http.Request>[];
      final transport = MockClient((request) async {
        requests.add(request);
        return http.Response(
          request.url.path.endsWith('/verify') ? jsonEncode(otp) : '{}',
          200,
          headers: _headers,
        );
      });
      final client = _client(transport);
      addTearDown(client.dispose);
      await client.auth.setInitialSession(jsonEncode(original));
      final observedTokens = <String?>[];
      final subscription = client.auth.onAuthStateChange.listen(
        (event) => observedTokens.add(event.session?.accessToken),
      );
      addTearDown(subscription.cancel);
      await _confirm(client, transport);
      await Future<void>.delayed(Duration.zero);
      expect(client.auth.currentUser!.email, 'new@example.test');
      expect(client.auth.currentSession!.accessToken, original['access_token']);
      expect(
        client.auth.currentSession!.refreshToken,
        original['refresh_token'],
      );
      expect(observedTokens, isNot(contains(otp['access_token'])));
      final logout = requests.singleWhere(
        (r) => r.url.path.endsWith('/logout'),
      );
      expect(logout.url.queryParameters['scope'], 'local');
      expect(logout.headers['Authorization'], 'Bearer ${otp['access_token']}');
    },
  );

  test(
    'first secure-email proof has no session and does not log out',
    () async {
      final transport = MockClient((request) async {
        expect(request.url.path, '/auth/v1/verify');
        return http.Response('{}', 200, headers: _headers);
      });
      final client = _client(transport);
      addTearDown(client.dispose);
      final original = _session('a', 'normal');
      await client.auth.setInitialSession(jsonEncode(original));
      await _confirm(client, transport);
      expect(client.auth.currentUser!.email, 'a@example.test');
      expect(client.auth.currentSession!.accessToken, original['access_token']);
    },
  );

  test('cleanup failure does not undo confirmed email or adopt OTP', () async {
    final transport = MockClient((request) async {
      if (request.url.path.endsWith('/logout')) {
        throw http.ClientException('synthetic offline');
      }
      return http.Response(
        jsonEncode(_session('a', 'temporary', email: 'new@example.test')),
        200,
        headers: _headers,
      );
    });
    final client = _client(transport);
    addTearDown(client.dispose);
    final original = _session('a', 'normal');
    await client.auth.setInitialSession(jsonEncode(original));
    await _confirm(client, transport);
    expect(client.auth.currentUser!.email, 'new@example.test');
    expect(client.auth.currentSession!.accessToken, original['access_token']);
  });

  for (final mode in ['switch', 'aba', 'refresh']) {
    test(
      'email confirmation respects concurrent $mode during OTP cleanup',
      () async {
        final cleaning = Completer<void>();
        final release = Completer<void>();
        final transport = MockClient((request) async {
          if (request.url.path.endsWith('/logout')) {
            cleaning.complete();
            await release.future;
            return http.Response('{}', 200, headers: _headers);
          }
          return http.Response(
            jsonEncode(_session('a', 'temporary', email: 'new@example.test')),
            200,
            headers: _headers,
          );
        });
        final client = _client(transport);
        addTearDown(client.dispose);
        final original = _session('a', 'normal');
        await client.auth.setInitialSession(jsonEncode(original));
        final operation = _confirm(client, transport);
        await cleaning.future;
        late Map<String, dynamic> expected;
        if (mode == 'refresh') {
          expected = _session('a', 'normal', version: 2);
        } else {
          expected = _session('b', 'other');
          await client.auth.setInitialSession(jsonEncode(expected));
          if (mode == 'aba') expected = original;
        }
        await client.auth.setInitialSession(jsonEncode(expected));
        final outcome = mode == 'refresh'
            ? expectLater(operation, completes)
            : expectLater(operation, throwsA(isA<AuthException>()));
        release.complete();
        await outcome;
        expect(
          client.auth.currentSession!.accessToken,
          expected['access_token'],
        );
        expect(
          client.auth.currentUser!.email,
          mode == 'refresh'
              ? 'new@example.test'
              : '${mode == 'aba' ? 'a' : 'b'}@example.test',
        );
      },
    );
  }

  test('foreign verification response cannot mutate either account', () async {
    final transport = MockClient((request) async {
      expect(request.url.path, '/auth/v1/verify');
      return http.Response(
        jsonEncode(_session('b', 'foreign')),
        200,
        headers: _headers,
      );
    });
    final client = _client(transport);
    addTearDown(client.dispose);
    final original = _session('a', 'normal');
    await client.auth.setInitialSession(jsonEncode(original));
    await expectLater(
      _confirm(client, transport),
      throwsA(isA<AuthException>()),
    );
    expect(client.auth.currentSession!.accessToken, original['access_token']);
  });
}
