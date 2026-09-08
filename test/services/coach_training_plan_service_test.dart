import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/chat_message.dart';
import 'package:eatova/src/services/coach_chat_service.dart';

final _now = DateTime.utc(2026, 9, 8, 12);
const _fallbackSessionId = '11111111-1111-4111-8111-111111111111';

Map<String, Object?> _plan() => {
  'schema_version': 1,
  'title': 'Kraft im Alltag',
  'description': 'Zwei einfache Übungen.',
  'goal': 'Regelmäßig bewegen',
  'workouts': [
    {
      'title': 'Ganzkörper',
      'description': '',
      'exercises': [
        {
          'name': 'Kniebeugen',
          'sets': 3,
          'reps': 10,
          'duration_seconds': null,
          'rest_seconds': 60,
          'notes': '',
        },
        {
          'name': 'Plank',
          'sets': 2,
          'reps': null,
          'duration_seconds': 30,
          'rest_seconds': 45,
          'notes': '',
        },
      ],
    },
  ],
};

Map<String, Object?> _reply() => {
  'reply': 'Dein Trainingsplan ist bereit.',
  'refusal': false,
  'training_plan': _plan(),
  'session_id': 's1',
  'assistant_message_id': 'assistant-1',
  'remaining': 4,
  'daily_limit': 5,
};

Map<String, Object?> _row({
  String role = 'assistant',
  String content = 'Dein Trainingsplan ist bereit.',
  Object? plan,
  bool refusal = false,
  DateTime? createdAt,
}) => {
  'id': role == 'user' ? 'user-message-1' : 'assistant-1',
  'role': role,
  'content': content,
  'created_at': (createdAt ?? _now).toIso8601String(),
  'refusal': refusal,
  'training_plan': plan,
};

http.Response _json(
  Object? data, [
  int status = 200,
  http.BaseRequest? request,
]) => http.Response(
  jsonEncode(data),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
  request: request,
);

SupabaseClient _client(http.Client transport) {
  final client = SupabaseClient(
    'https://example.invalid',
    'anon-fixture',
    httpClient: transport,
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  addTearDown(client.dispose);
  return client;
}

CoachChatService _service(
  Future<http.Response> Function(http.Request) handler,
) => CoachChatService(_client(MockClient(handler)), 'A');

Future<CoachPlanReply> _request(CoachChatService service) =>
    withClock(Clock.fixed(_now), () {
      return service.requestPlan(
        'Zuhause trainieren',
        sessionId: 's1',
        locale: 'de',
      );
    });

String _frame(String name, Object data) =>
    'event: $name\ndata: ${jsonEncode(data)}\n\n';

Future<void> _signIn(SupabaseClient client, String id) async {
  await client.auth.recoverSession(
    jsonEncode({
      'access_token': 'fixture-$id',
      'refresh_token': 'refresh-$id',
      'token_type': 'bearer',
      'expires_in': 3600,
      'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
      'user': {
        'id': id,
        'aud': 'authenticated',
        'created_at': '2026-01-01T00:00:00Z',
        'app_metadata': {},
        'user_metadata': {},
      },
    }),
  );
}

class _DelayedTokenClient extends SupabaseClient {
  _DelayedTokenClient(
    this.sessionClient,
    Future<String?> Function() token,
    http.Client transport,
  ) : super(
        'https://example.invalid',
        'anon-fixture',
        accessToken: token,
        httpClient: transport,
      );

  final SupabaseClient sessionClient;

  @override
  GoTrueClient get auth => sessionClient.auth;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Training plan protocol', () {
    test(
      'sends minimal plan intent and returns the validated typed draft',
      () async {
        final requests = <http.Request>[];
        final service = _service((request) async {
          requests.add(request);
          return _json(_reply());
        });
        final response = await service.requestPlan(
          'Drei Tage Zuhause',
          sessionId: 's1',
          locale: 'en-US',
        );

        expect(requests, hasLength(1));
        expect(requests.single.url.path, '/functions/v1/coach-chat');
        expect(jsonDecode(requests.single.body), {
          'message': 'Drei Tage Zuhause',
          'mode': 'plan',
          'session_id': 's1',
          'locale': 'en',
        });
        expect(response.proposal!.toJson(), _plan());
        expect(
          response.proposal!.workouts.single.exercises.last.durationSeconds,
          30,
        );
        expect(response.assistantMessageId, 'assistant-1');
        expect(response.sessionId, 's1');
        expect(response.remaining, 4);
        expect(response.dailyLimit, 5);
        expect(service.serverDailyLimit, 5);
      },
    );

    test(
      'unknown locale falls back to German and unknown quota stays unknown',
      () async {
        final service = _service((request) async {
          expect(jsonDecode(request.body)['locale'], 'de');
          return _json(
            _reply()
              ..remove('remaining')
              ..remove('daily_limit')
              ..remove('session_id')
              ..remove('assistant_message_id'),
          );
        });
        final response = await service.requestPlan(
          'Plan',
          sessionId: 's1',
          locale: 'fr-FR',
        );
        expect(response.remaining, isNull);
        expect(response.dailyLimit, isNull);
        expect(response.assistantMessageId, isNull);
        expect(response.sessionId, 's1');
        expect(service.serverDailyLimit, isNull);
      },
    );

    for (final refusal in [false, true]) {
      test(
        'server fallback session preserves the paid result (refusal=$refusal)',
        () async {
          var calls = 0;
          final client = _client(
            MockClient((request) async {
              calls++;
              expect(request.url.path, '/functions/v1/coach-chat');
              expect(request.headers['authorization'], 'Bearer fixture-A');
              expect(jsonDecode(request.body)['session_id'], 's1');
              // ensureSession chooses A's default when another device deleted s1.
              return _json(
                _reply()
                  ..['session_id'] = _fallbackSessionId
                  ..['refusal'] = refusal,
              );
            }),
          );
          await _signIn(client, 'A');
          final service = CoachChatService(client, 'A');
          final response = await _request(service);
          expect(response.sessionId, _fallbackSessionId);
          expect(response.refusal, refusal);
          expect(response.proposal?.toJson(), refusal ? null : _plan());
          expect(response.assistantMessageId, 'assistant-1');
          expect(response.remaining, 4);
          expect(service.serverDailyLimit, 5);
          expect(
            calls,
            1,
            reason: 'A completed paid generation must not retry.',
          );
        },
      );
    }

    test('refusal suppresses even a valid plan payload', () async {
      final service = _service(
        (_) async => _json(
          _reply()
            ..['refusal'] = true
            ..['refusal_reason'] = 'unsafe_request'
            ..['reply'] = 'Dabei kann ich nicht helfen.',
        ),
      );
      final response = await _request(service);
      expect(response.refusal, isTrue);
      expect(response.proposal, isNull);
      expect(response.refusalReason, 'unsafe_request');
    });

    for (final mutation in <String, void Function(Map<String, Object?>)>{
      'missing plan': (payload) => payload.remove('training_plan'),
      'malformed plan': (payload) =>
          payload['training_plan'] = {'title': 'Bad'},
      'plan and recipe conflict': (payload) =>
          payload['recipe'] = {'title': 'Bad'},
      'blank reply': (payload) => payload['reply'] = ' ',
      'empty session': (payload) => payload['session_id'] = '',
      'unsafe session': (payload) =>
          payload['session_id'] = '../another-session',
      'oversized session': (payload) => payload['session_id'] = 'a' * 101,
      'malformed session': (payload) => payload['session_id'] = 42,
      'malformed refusal': (payload) => payload['refusal'] = 'true',
    }.entries) {
      test(
        'rejects ${mutation.key} instead of producing an adoptable draft',
        () async {
          final payload = _reply();
          mutation.value(payload);
          final service = _service((_) async => _json(payload));
          await expectLater(
            _request(service),
            throwsA(isA<CoachChatException>()),
          );
          expect(service.serverDailyLimit, isNull);
        },
      );
    }

    test(
      'invalid quota fields and unsafe message IDs are not propagated',
      () async {
        final service = _service(
          (_) async => _json(
            _reply()
              ..['remaining'] = -1
              ..['daily_limit'] = 2.5
              ..['assistant_message_id'] = '../other-user',
          ),
        );
        final response = await _request(service);
        expect(response.remaining, isNull);
        expect(response.dailyLimit, isNull);
        expect(response.assistantMessageId, isNull);
      },
    );

    test('daily quota 429 locks while burst 429 remains retryable', () async {
      var daily = true;
      final service = _service(
        (_) async => _json(
          daily
              ? {'error': 'quota_exceeded', 'daily_limit': 8}
              : {'error': 'rate_limited'},
          429,
        ),
      );
      await expectLater(
        _request(service),
        throwsA(
          isA<CoachQuotaExceeded>().having(
            (error) => error.dailyLimit,
            'limit',
            8,
          ),
        ),
      );
      expect(service.serverDailyLimit, 8);
      daily = false;
      await expectLater(_request(service), throwsA(isA<CoachChatException>()));
    });

    for (final status in [401, 403, 500, 502]) {
      test('maps HTTP $status without exposing raw provider details', () async {
        final service = _service(
          (_) async => _json({
            'reply': 'private provider-token trace',
            'error': '<internal>',
          }, status),
        );
        await expectLater(
          _request(service),
          throwsA(
            isA<CoachChatException>().having(
              (error) => error.message,
              'sanitized message',
              status < 500
                  ? deL10n.coachErrorSessionExpired
                  : allOf(
                      isNot(contains('private')),
                      isNot(contains('internal')),
                    ),
            ),
          ),
        );
      });
    }

    test(
      'transport error has the existing localized offline message',
      () async {
        final service = _service((_) async {
          throw http.ClientException('private network details');
        });
        await expectLater(
          _request(service),
          throwsA(
            isA<CoachChatException>().having(
              (error) => error.message,
              'message',
              deL10n.coachErrorNoConnection,
            ),
          ),
        );
      },
    );

    test(
      'SSE final payload is authoritative; intermediate plan is ignored',
      () async {
        final body =
            _frame('delta', {'t': 'Unfinished draft'}) +
            _frame('plan', {'training_plan': _plan()}) +
            _frame('done', _reply()..['session_id'] = _fallbackSessionId);
        final service = CoachChatService(
          _client(
            MockClient.streaming((request, requestBody) async {
              await requestBody.drain<void>();
              final bytes = utf8.encode(body);
              return http.StreamedResponse(
                Stream.fromIterable([bytes.sublist(0, 17), bytes.sublist(17)]),
                200,
                headers: {'content-type': 'text/event-stream; charset=utf-8'},
                request: request,
              );
            }),
          ),
          'A',
        );
        final response = await _request(service);
        expect(response.reply, _reply()['reply']);
        expect(response.proposal!.toJson(), _plan());
        expect(response.sessionId, _fallbackSessionId);
      },
    );

    test('an incomplete SSE draft never becomes an adoptable plan', () async {
      final service = CoachChatService(
        _client(
          MockClient.streaming((request, requestBody) async {
            await requestBody.drain<void>();
            return http.StreamedResponse(
              Stream.value(
                utf8.encode(
                  _frame('delta', {'t': 'Draft'}) +
                      _frame('plan', {'training_plan': _plan()}),
                ),
              ),
              200,
              headers: {'content-type': 'text/event-stream'},
              request: request,
            );
          }),
        ),
        'A',
      );
      await expectLater(_request(service), throwsA(isA<CoachChatException>()));
    });
  });

  group('Training proposal history', () {
    test(
      'scopes history by account and session; proposals survive copyWith',
      () async {
        final service = _service((request) async {
          expect(request.method, 'GET');
          expect(request.url.queryParameters['user_id'], 'eq.A');
          expect(request.url.queryParameters['session_id'], 'eq.s1');
          expect(
            request.url.queryParameters['select'],
            contains('training_plan'),
          );
          return _json([_row(plan: _plan())], 200, request);
        });
        final message = (await service.loadHistory('s1')).single;
        expect(message.trainingPlanProposal!.toJson(), _plan());
        expect(
          message.copyWith(content: 'Updated').trainingPlanProposal,
          same(message.trainingPlanProposal),
        );
      },
    );

    for (final role in ['user', 'system', 'unknown']) {
      test('$role history never produces a training proposal', () {
        final message = ChatMessage.fromRow(_row(role: role, plan: _plan()));
        expect(message.trainingPlanProposal, isNull);
      });
    }

    test('invalid, refused and conflicting history preserves text only', () {
      for (final row in [
        _row(plan: {'title': 'Invalid'}),
        _row(plan: _plan(), refusal: true),
        _row(plan: _plan())..remove('role'),
        _row(plan: _plan())..['refusal'] = 'true',
        _row(plan: _plan())
          ..['recipe'] = {'title': 'Soup', 'calories_kcal': 300},
      ]) {
        final message = ChatMessage.fromRow(row);
        expect(message.trainingPlanProposal, isNull);
        expect(message.recipeProposal, isNull);
        expect(message.content, 'Dein Trainingsplan ist bereit.');
      }
    });
  });

  group('Training generation deadlines and ownership', () {
    test(
      'plan deadline allows the full generation budget without retry',
      () async {
        var historyCalls = 0;
        final service = CoachChatService(
          _client(
            MockClient((request) async {
              if (!request.url.path.contains('coach-chat')) {
                historyCalls++;
                return _json([], 200, request);
              }
              // Two milliseconds per production second. The real deadline drives
              // the test so shrinking it below the server budget is observable.
              await Future<void>.delayed(const Duration(milliseconds: 190));
              return _json(_reply());
            }),
          ),
          'A',
          planFrist: Duration(
            milliseconds: CoachChatService.planDeadline.inSeconds * 2,
          ),
          fristPuffer: Duration.zero,
        );
        final result = await _request(service);
        expect(result.proposal!.title, 'Kraft im Alltag');
        expect(historyCalls, 0);
      },
    );

    for (final recover in [true, false]) {
      test(
        'deadline aborts actual transport; valid history recovery=$recover',
        () async {
          var aborted = false;
          var calls = 0;
          final service = CoachChatService(
            _client(
              MockClient.streaming((request, body) async {
                await body.drain<void>();
                if (request.url.path.contains('coach-chat')) {
                  calls++;
                  expect(request, isA<http.Abortable>());
                  await (request as http.Abortable).abortTrigger!;
                  aborted = true;
                  throw http.RequestAbortedException(request.url);
                }
                final history = recover
                    ? [
                        _row(plan: _plan()),
                        _row(role: 'user', content: 'Zuhause trainieren'),
                      ]
                    : [
                        _row(plan: {'title': 'Broken'}),
                        _row(role: 'user', content: 'Zuhause trainieren'),
                      ];
                return http.StreamedResponse(
                  Stream.value(utf8.encode(jsonEncode(history))),
                  200,
                  headers: {'content-type': 'application/json'},
                  request: request,
                );
              }),
            ),
            'A',
            planFrist: const Duration(milliseconds: 30),
            fristPuffer: const Duration(milliseconds: 30),
          );
          if (recover) {
            final response = await _request(service);
            expect(response.proposal!.toJson(), _plan());
            expect(response.assistantMessageId, 'assistant-1');
            expect(response.remaining, isNull);
            expect(response.dailyLimit, isNull);
          } else {
            await expectLater(
              _request(service),
              throwsA(
                isA<CoachChatException>().having(
                  (error) => error.message,
                  'message',
                  deL10n.coachErrorTimeout,
                ),
              ),
            );
          }
          expect(aborted, isTrue);
          expect(calls, 1, reason: 'Recovery must never generate again.');
        },
      );
    }

    test(
      'old or different history does not get attributed to this request',
      () async {
        for (final history in [
          [
            _row(
              plan: _plan(),
              createdAt: _now.subtract(const Duration(days: 1)),
            ),
            _row(role: 'user', content: 'Zuhause trainieren'),
          ],
          [
            _row(plan: _plan()),
            _row(role: 'user', content: 'Eine andere Frage'),
          ],
        ]) {
          // FunctionsClient wraps thrown transport timeouts; an ignored abort
          // exercises the outer deadline and the same persisted-history check.
          final service = CoachChatService(
            _client(
              MockClient((request) async {
                if (request.url.path.contains('coach-chat')) {
                  await Future<void>.delayed(const Duration(milliseconds: 50));
                  return _json(_reply());
                }
                return _json(history, 200, request);
              }),
            ),
            'A',
            planFrist: const Duration(milliseconds: 5),
            fristPuffer: const Duration(milliseconds: 5),
          );
          await expectLater(
            _request(service),
            throwsA(
              isA<CoachChatException>().having(
                (error) => error.message,
                'message',
                deL10n.coachErrorTimeout,
              ),
            ),
          );
        }
      },
    );

    test('a stale service cannot send under a different account', () async {
      var calls = 0;
      final client = _client(
        MockClient((_) async {
          calls++;
          return _json(_reply());
        }),
      );
      await _signIn(client, 'B');
      await expectLater(
        _request(CoachChatService(client, 'A')),
        throwsA(
          isA<CoachChatException>().having(
            (error) => error.message,
            'message',
            deL10n.coachErrorSessionExpired,
          ),
        ),
      );
      expect(calls, 0);
    });

    test(
      'bearer remains account A while delayed SDK lookup switches to B',
      () async {
        final sessionClient = _client(MockClient((_) async => _json({})));
        await _signIn(sessionClient, 'A');
        final entered = Completer<void>();
        final release = Completer<void>();
        String? authorization;
        final client = _DelayedTokenClient(
          sessionClient,
          () async {
            entered.complete();
            await release.future;
            return sessionClient.auth.currentSession!.accessToken;
          },
          MockClient((request) async {
            authorization = request.headers['authorization'];
            return _json(_reply());
          }),
        );
        addTearDown(client.dispose);
        final pending = _request(CoachChatService(client, 'A'));
        final rejected = expectLater(
          pending,
          throwsA(isA<CoachChatException>()),
        );
        await entered.future;
        await _signIn(sessionClient, 'B');
        release.complete();
        await rejected;
        expect(authorization, 'Bearer fixture-A');
      },
    );
    for (final transition in ['B', 'logout', 'B then A']) {
      for (final status in [200, 429]) {
        test(
          'late HTTP $status after $transition cannot return or change quota',
          () async {
            final entered = Completer<void>();
            final response = Completer<http.Response>();
            final client = _client(
              MockClient((request) async {
                if (request.url.path.endsWith('/logout')) return _json({});
                entered.complete();
                return response.future;
              }),
            );
            await _signIn(client, 'A');
            final service = CoachChatService(client, 'A');
            final rejected = expectLater(
              _request(service),
              throwsA(
                isA<CoachChatException>().having(
                  (error) => error.message,
                  'message',
                  deL10n.coachErrorSessionExpired,
                ),
              ),
            );
            await entered.future;
            if (transition == 'logout') {
              await client.auth.signOut(scope: SignOutScope.local);
            } else {
              await _signIn(client, 'B');
              if (transition == 'B then A') await _signIn(client, 'A');
            }
            response.complete(
              _json(
                status == 200
                    ? (_reply()..['session_id'] = _fallbackSessionId)
                    : {'error': 'quota_exceeded', 'daily_limit': 8},
                status,
              ),
            );
            await rejected;
            expect(service.serverDailyLimit, isNull);
          },
        );
      }
    }

    test(
      'history fallback stays pinned and rejects a late A to B to A result',
      () async {
        final enteredHistory = Completer<void>();
        final releaseHistory = Completer<void>();
        final client = _client(
          MockClient.streaming((request, body) async {
            await body.drain<void>();
            if (request.url.path.contains('coach-chat')) {
              await (request as http.Abortable).abortTrigger!;
              throw http.RequestAbortedException(request.url);
            }
            expect(request.url.queryParameters['user_id'], 'eq.A');
            expect(request.headers['authorization'], 'Bearer fixture-A');
            enteredHistory.complete();
            await releaseHistory.future;
            return http.StreamedResponse(
              Stream.value(
                utf8.encode(
                  jsonEncode([
                    _row(plan: _plan()),
                    _row(role: 'user', content: 'Zuhause trainieren'),
                  ]),
                ),
              ),
              200,
              headers: {'content-type': 'application/json'},
              request: request,
            );
          }),
        );
        await _signIn(client, 'A');
        final service = CoachChatService(
          client,
          'A',
          planFrist: const Duration(milliseconds: 30),
          fristPuffer: const Duration(milliseconds: 30),
        );
        final rejected = expectLater(
          _request(service),
          throwsA(isA<CoachChatException>()),
        );
        await enteredHistory.future;
        await _signIn(client, 'B');
        await _signIn(client, 'A');
        releaseHistory.complete();
        await rejected;
        expect(service.serverDailyLimit, isNull);
      },
    );

    test('SSE completion after logout cannot return a plan or quota', () async {
      final entered = Completer<void>();
      final stream = StreamController<List<int>>();
      final client = _client(
        MockClient.streaming((request, body) async {
          await body.drain<void>();
          if (request.url.path.endsWith('/logout')) {
            return http.StreamedResponse(
              Stream.value(utf8.encode('{}')),
              200,
              headers: {'content-type': 'application/json'},
              request: request,
            );
          }
          entered.complete();
          return http.StreamedResponse(
            stream.stream,
            200,
            headers: {'content-type': 'text/event-stream'},
            request: request,
          );
        }),
      );
      await _signIn(client, 'A');
      final service = CoachChatService(client, 'A');
      final rejected = expectLater(
        _request(service),
        throwsA(isA<CoachChatException>()),
      );
      await entered.future;
      await client.auth.signOut(scope: SignOutScope.local);
      stream.add(utf8.encode(_frame('done', _reply())));
      await stream.close();
      await rejected;
      expect(service.serverDailyLimit, isNull);
    });
  });
}
