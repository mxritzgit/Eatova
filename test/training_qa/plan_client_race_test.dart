import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:eatova/src/services/coach_chat_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'fixtures.dart';

final _now = DateTime.utc(2026, 9, 8, 12);

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

Future<void> _signIn(SupabaseClient client, String id) => client.auth
    .recoverSession(
      jsonEncode({
        'access_token': 'ci-token-$id',
        'refresh_token': 'ci-refresh-$id',
        'token_type': 'bearer',
        'expires_in': 3600,
        'expires_at':
            _now.add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000,
        'user': {
          'id': id,
          'aud': 'authenticated',
          'created_at': '2026-01-01T00:00:00Z',
          'app_metadata': {},
          'user_metadata': {},
        },
      }),
    )
    .then((_) {});

SupabaseClient _client(Future<http.Response> Function(http.Request) handler) {
  final client = SupabaseClient(
    'https://ci.invalid',
    'ci-dummy-key',
    httpClient: MockClient(handler),
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  addTearDown(client.dispose);
  return client;
}

Future<CoachPlanReply> _request(CoachChatService service) => service
    .requestPlan('A comfortable plan', sessionId: 'session-A', locale: 'en');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'generation transport has no saved training writes',
    () => withClock(Clock.fixed(_now), () async {
      final calls = <http.Request>[];
      final client = _client((request) async {
        calls.add(request);
        if (request.url.path != '/functions/v1/coach-chat') {
          throw StateError(
            'Unexpected request ${request.method} ${request.url.path}',
          );
        }
        return _json(trainingReply());
      });
      await _signIn(client, 'account-A');
      final result = await _request(CoachChatService(client, 'account-A'));
      expect(result.proposal?.title, 'Two sessions');
      expect(calls, hasLength(1));
      expect(
        calls.single.headers['Authorization'],
        'Bearer ci-token-account-A',
      );
      expect(jsonDecode(calls.single.body)['mode'], 'plan');
    }),
  );

  for (final nextAccount in ['account-B', null]) {
    test(
      'late plan response rejected after ${nextAccount ?? 'logout'}',
      () => withClock(Clock.fixed(_now), () async {
        final started = Completer<void>();
        final response = Completer<http.Response>();
        final client = _client((request) async {
          if (request.url.path == '/auth/v1/logout') return _json({});
          expect(request.url.path, '/functions/v1/coach-chat');
          expect(request.headers['Authorization'], 'Bearer ci-token-account-A');
          started.complete();
          return response.future;
        });
        await _signIn(client, 'account-A');
        final pending = _request(CoachChatService(client, 'account-A'));
        final assertion = expectLater(
          pending,
          throwsA(isA<CoachChatException>()),
        );
        await started.future;
        if (nextAccount == null) {
          await client.auth.signOut(scope: SignOutScope.local);
          expect(client.auth.currentUser, isNull);
        } else {
          await _signIn(client, nextAccount);
        }
        response.complete(_json(trainingReply()));
        await assertion;
      }),
    );
  }

  test(
    'verified fallback session preserves the paid plan without another request',
    () => withClock(Clock.fixed(_now), () async {
      const fallbackSession = '11111111-1111-4111-8111-111111111111';
      var calls = 0;
      final client = _client((request) async {
        calls++;
        expect(request.url.path, '/functions/v1/coach-chat');
        expect(jsonDecode(request.body)['session_id'], 'session-A');
        return _json(trainingReply()..['session_id'] = fallbackSession);
      });
      await _signIn(client, 'account-A');
      final service = CoachChatService(client, 'account-A');
      final result = await _request(service);
      expect(result.sessionId, fallbackSession);
      expect(result.proposal?.title, 'Two sessions');
      expect(result.remaining, 4);
      expect(service.serverDailyLimit, 5);
      expect(calls, 1);
    }),
  );

  test(
    'tampered successful payload cannot produce a proposal',
    () => withClock(Clock.fixed(_now), () async {
      final raw = trainingReply();
      firstExercise(raw['training_plan'])['sets'] = 1000;
      final client = _client((_) async => _json(raw));
      await _signIn(client, 'account-A');
      await expectLater(
        _request(CoachChatService(client, 'account-A')),
        throwsA(isA<CoachChatException>()),
      );
    }),
  );
}
