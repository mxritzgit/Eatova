import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/services/coach_chat_service.dart';

// The Coach's per-request identity fence listened on the async auth stream.
// That stream replays its latest event to every new subscriber, an ERROR
// included (a failed background refresh, or a crafted login-callback link
// whose exchange throws). The replayed error marked the identity as changed,
// so every /plan and /log failed as "session expired" without being sent,
// until the next auth data event, up to an hour later. Identity changes
// always arrive as data events; an error says nothing about who is signed in.

const _userId = '6f1d7a52-0c3e-4f5b-9a8e-2b4c6d8e0f13';

String _validJwt() {
  String part(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  final exp = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
  return '${part({'alg': 'HS256', 'typ': 'JWT'})}.'
      '${part({'sub': _userId, 'exp': exp, 'session_id': 'sess-1'})}.signature';
}

String _session() => jsonEncode({
  'access_token': _validJwt(),
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

void main() {
  final requests = <String, Future<Object?> Function(CoachChatService)>{
    'plan': (svc) => svc.requestPlan('Kraft', sessionId: 's1', locale: 'de'),
    'log': (svc) => svc.requestWorkoutLog(
      'heute Kniebeugen 3x5',
      sessionId: 's1',
      locale: 'de',
    ),
  };

  for (final MapEntry(key: name, value: request) in requests.entries) {
    test('$name: an earlier auth-stream error does not block the request',
        () async {
      final coachCalls = <String>[];
      final transport = MockClient((req) async {
        if (req.url.path.endsWith('/functions/v1/coach-chat')) {
          coachCalls.add(req.url.path);
        }
        return http.Response('{"error":"internal_error"}', 500);
      });
      final client = SupabaseClient(
        'https://example.invalid',
        'anon-fixture',
        httpClient: transport,
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      addTearDown(client.dispose);
      await client.auth.setInitialSession(_session());
      // A failed background refresh or a bad callback link, before the user
      // asks the Coach.
      // ignore: invalid_use_of_internal_member
      client.auth.notifyException(const AuthException('bad callback code'));

      final svc = CoachChatService(client, _userId);
      try {
        await request(svc);
      } on CoachChatException {
        // The 500 above; only whether the request left matters here.
      }

      expect(coachCalls, hasLength(1),
          reason: 'the same user is still signed in; the request must leave');
    });
  }
}
