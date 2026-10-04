import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/services/coach_chat_service.dart';

// /plan and /log capture the bearer before they send, refreshing an expired
// access token first. Offline that refresh fails with GoTrue's
// AuthRetryableFetchException, which the request mapped like every other
// AuthException: "Your session has expired. Please sign in again." Nothing
// had ended but the connection (a chat question in the same moment says "No
// connection"); /log right after a workout in a basement gym is the typical
// case, and signing out offline is the wrong advice.

const _userId = '6f1d7a52-0c3e-4f5b-9a8e-2b4c6d8e0f13';

/// GoTrue reads the expiry from the access token's `exp` claim.
String _expiredJwt() {
  String part(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  final exp = DateTime.now().millisecondsSinceEpoch ~/ 1000 - 600;
  return '${part({'alg': 'HS256', 'typ': 'JWT'})}.'
      '${part({'sub': _userId, 'exp': exp})}.signature';
}

String _expiredSession() => jsonEncode({
  'access_token': _expiredJwt(),
  'refresh_token': 'refresh-token',
  'token_type': 'bearer',
  'expires_in': 3600,
  'user': {
    'id': _userId,
    'aud': 'authenticated',
    'created_at': '2026-01-01T00:00:00Z',
    'app_metadata': <String, Object?>{},
    'user_metadata': <String, Object?>{},
  },
});

/// The real GoTrue retries a retryable refresh for several seconds before it
/// gives up; this one fails the same way at once.
class _FailingRefreshAuth extends GoTrueClient {
  _FailingRefreshAuth(this.failure)
    : super(url: 'https://example.invalid/auth/v1', autoRefreshToken: false);

  final AuthException failure;

  @override
  Future<AuthResponse> refreshSession([String? refreshToken]) async =>
      throw failure;
}

class _Client extends SupabaseClient {
  _Client(this._auth, http.Client transport)
    : super(
        'https://example.invalid',
        'anon-fixture',
        httpClient: transport,
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );

  final GoTrueClient? _auth;

  @override
  GoTrueClient get auth => _auth ?? super.auth;
}

/// [refreshFailure] null: the real GoTrue refreshes against [tokenStatus]
/// (null = no network at all).
Future<(CoachChatService, List<String>)> _service({
  int? tokenStatus,
  AuthException? refreshFailure,
}) async {
  final paths = <String>[];
  final transport = MockClient((req) async {
    paths.add(req.url.path);
    if (req.url.path.endsWith('/auth/v1/token') && tokenStatus != null) {
      return http.Response('{"message":"refused"}', tokenStatus);
    }
    throw http.ClientException('Failed host lookup', req.url);
  });
  final auth = refreshFailure == null
      ? null
      : _FailingRefreshAuth(refreshFailure);
  final client = _Client(auth, transport);
  addTearDown(client.dispose);
  await client.auth.setInitialSession(_expiredSession());
  expect(client.auth.currentSession!.isExpired, isTrue);
  return (CoachChatService(client, _userId), paths);
}

Matcher _fails(String message) => throwsA(
  isA<CoachChatException>().having((e) => e.message, 'message', message),
);

void main() {
  final requests = <String, Future<Object?> Function(CoachChatService)>{
    'plan': (svc) => svc.requestPlan('Kraft', sessionId: 's1', locale: 'de'),
    'log': (svc) => svc.requestWorkoutLog(
      'heute Kniebeugen 3x5',
      sessionId: 's1',
      locale: 'de',
    ),
  };

  test('no network at all: the real refresh failure says "No connection"',
      () async {
    final (svc, paths) = await _service();

    await expectLater(
      svc.requestPlan('Kraft', sessionId: 's1', locale: 'de'),
      _fails(deL10n.coachErrorNoConnection),
    );
    expect(paths, everyElement(endsWith('/auth/v1/token')),
        reason: 'nothing was sent to coach-chat, so nothing was charged');
  });

  for (final MapEntry(key: name, value: request) in requests.entries) {
    test('$name offline with an expired token: "No connection"', () async {
      final (svc, paths) = await _service(
        refreshFailure: AuthRetryableFetchException(),
      );

      await expectLater(request(svc), _fails(deL10n.coachErrorNoConnection));
      expect(paths, isEmpty);
    });

    test('$name with GoTrue down: the Coach is unreachable', () async {
      final (svc, _) = await _service(
        refreshFailure: AuthRetryableFetchException(statusCode: '503'),
      );

      await expectLater(request(svc), _fails(deL10n.coachErrorUnreachable));
    });

    test('$name with a rejected refresh token: the session did end', () async {
      final (svc, _) = await _service(tokenStatus: 400);

      await expectLater(request(svc), _fails(deL10n.coachErrorSessionExpired));
    });
  }
}
