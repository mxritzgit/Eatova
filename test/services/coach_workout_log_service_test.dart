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
import 'package:eatova/src/services/crash_reporter.dart';

// Spec C1/C2: the client half of Coach `/log`. The request is buffered JSON
// with an explicit mode and the device's calendar day; the answer is strictly
// validated, a refusal never carries a draft, an old server is "not
// available yet", a deadline asks the transcript, and an account change
// drops the answer. Nothing here writes training data.

final _now = DateTime(2026, 10, 3, 23, 50);
const _assistantId = '0b6f2a4e-8c1d-4f7a-9e3b-5d2c1a0f9e8d';
const _fallbackSessionId = '11111111-1111-4111-8111-111111111111';

Map<String, Object?> _log() => {
  'schema_version': 1,
  'title': 'Beintag',
  'performed_on': '2026-10-03',
  'duration_minutes': null,
  'other_days_omitted': false,
  'note': '',
  'exercises': [
    {
      'name': 'Kniebeuge',
      'kind': 'reps',
      'duration_seconds': null,
      'sets': [
        {'reps': 8, 'weight_kg': 100},
        {'reps': 8, 'weight_kg': 100},
      ],
    },
    {
      'name': 'Plank',
      'kind': 'timed',
      'duration_seconds': 60,
      'sets': [
        {'reps': null, 'weight_kg': null},
      ],
    },
  ],
};

Map<String, Object?> _reply() => {
  'reply': 'Beintag erkannt. Prüfe und füge ihn hinzu.',
  'workout_log': _log(),
  'remaining': 3,
  'daily_limit': 5,
  'session_id': 's1',
  'assistant_message_id': _assistantId,
};

Map<String, Object?> _row({
  String role = 'assistant',
  String content = 'Beintag erkannt. Prüfe und füge ihn hinzu.',
  Object? workoutLog,
  Object? plan,
  Object? recipe,
  bool refusal = false,
  DateTime? createdAt,
}) => {
  'id': role == 'user' ? 'f0f0f0f0-0000-4000-8000-000000000001' : _assistantId,
  'role': role,
  'content': content,
  'created_at': (createdAt ?? _now).toUtc().toIso8601String(),
  'refusal': refusal,
  'recipe': recipe,
  'training_plan': plan,
  'workout_log': workoutLog,
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

Future<CoachWorkoutLogReply> _request(
  CoachChatService service, {
  String locale = 'de',
}) => withClock(
  Clock.fixed(_now),
  () => service.requestWorkoutLog(
    'heute Kniebeugen 2x8 mit 100 kg',
    sessionId: 's1',
    locale: locale,
  ),
);

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
        'app_metadata': <dynamic, dynamic>{},
        'user_metadata': <dynamic, dynamic>{},
      },
    }),
  );
}

Matcher _coachError(String message) => throwsA(
  isA<CoachChatException>().having((e) => e.message, 'message', message),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Workout log protocol', () {
    test('sends exactly mode, wish, local day, locale and session', () async {
      final requests = <http.Request>[];
      final client = _client(
        MockClient((request) async {
          requests.add(request);
          return _json(_reply());
        }),
      );
      await _signIn(client, 'A');
      final service = CoachChatService(client, 'A');
      final response = await _request(service, locale: 'en-US');

      expect(requests, hasLength(1));
      expect(requests.single.url.path, '/functions/v1/coach-chat');
      expect(jsonDecode(requests.single.body), {
        'message': 'heute Kniebeugen 2x8 mit 100 kg',
        'mode': 'log',
        // The device's local day, ten minutes before its midnight.
        'local_date': '2026-10-03',
        'locale': 'en',
        'session_id': 's1',
      });
      expect(requests.single.headers['Accept-Language'], 'en');
      expect(requests.single.headers['authorization'], 'Bearer fixture-A');
      // Buffered JSON, like /plan: the server never streams a log.
      expect(requests.single.headers['Accept'], isNot('text/event-stream'));

      expect(response.proposal!.toJson(), _log());
      expect(response.refusal, isFalse);
      expect(response.reply, _reply()['reply']);
      expect(response.assistantMessageId, _assistantId);
      expect(response.sessionId, 's1');
      expect(response.remaining, 3);
      expect(response.dailyLimit, 5);
      expect(service.serverDailyLimit, 5);
    });

    test('the SSE done payload is parsed like the buffered body', () async {
      final body =
          _frame('meta', {'session_id': 's1'}) +
          _frame('done', _reply()..['session_id'] = _fallbackSessionId);
      final service = CoachChatService(
        _client(
          MockClient.streaming((request, requestBody) async {
            await requestBody.drain<void>();
            final bytes = utf8.encode(body);
            return http.StreamedResponse(
              Stream.fromIterable([bytes.sublist(0, 23), bytes.sublist(23)]),
              200,
              headers: {'content-type': 'text/event-stream; charset=utf-8'},
              request: request,
            );
          }),
        ),
        'A',
      );
      final response = await _request(service);
      expect(response.proposal!.toJson(), _log());
      expect(response.sessionId, _fallbackSessionId);
    });

    test('a stream without done is never a draft', () async {
      final service = CoachChatService(
        _client(
          MockClient.streaming((request, requestBody) async {
            await requestBody.drain<void>();
            return http.StreamedResponse(
              Stream.value(utf8.encode(_frame('delta', {'t': 'Beintag'}))),
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

    group('malformed payloads', () {
      final reports = <String?>[];
      final reported = <String>[];
      setUp(() {
        reports.clear();
        reported.clear();
        CrashReporter.debugSentrySink = (error, stack, context) {
          reports.add(context);
          reported.add(error.toString());
        };
      });
      tearDown(() => CrashReporter.debugSentrySink = null);

      for (final mutation in <String, void Function(Map<String, Object?>)>{
        'missing log': (payload) => payload.remove('workout_log'),
        'malformed log': (payload) =>
            payload['workout_log'] = {'title': 'Beintag'},
        'log with a plan': (payload) =>
            payload['training_plan'] = {'title': 'Plan'},
        'log with a recipe': (payload) =>
            payload['recipe'] = {'title': 'Suppe'},
        'blank reply': (payload) => payload['reply'] = ' ',
        'unsafe session': (payload) =>
            payload['session_id'] = '../another-session',
        'malformed refusal': (payload) => payload['refusal'] = 'true',
      }.entries) {
        test('${mutation.key} is an invalid response, reported without '
            'content', () async {
          final payload = _reply();
          mutation.value(payload);
          final service = _service((_) async => _json(payload));
          await expectLater(
            _request(service),
            _coachError(deL10n.coachErrorEmptyReply),
          );
          await Future<void>.delayed(Duration.zero);
          expect(reports, ['coach.workoutLog.invalidResponse']);
          for (final text in reported) {
            expect(text, isNot(contains('Kniebeuge')));
            expect(text, isNot(contains('Beintag')));
          }
          expect(service.serverDailyLimit, isNull);
        });
      }
    });

    test('a refusal suppresses even a valid draft', () async {
      final service = _service(
        (_) async => _json(
          _reply()
            ..['refusal'] = true
            ..['refusal_reason'] = 'log_not_completed'
            ..['reply'] =
                'Das klingt nach einem Plan, nicht nach einem '
                'erledigten Training.',
        ),
      );
      final response = await _request(service);
      expect(response.refusal, isTrue);
      expect(response.proposal, isNull);
      expect(response.refusalReason, 'log_not_completed');
      expect(response.remaining, 3);
    });

    test(
      'a prefilter refusal without quota fields keeps quota unknown',
      () async {
        final service = _service(
          (_) async => _json({
            'reply': 'Dabei kann ich nicht helfen.',
            'refusal': true,
            'refusal_reason': 'prompt_injection',
            'session_id': 's1',
          }),
        );
        final response = await _request(service);
        expect(response.refusal, isTrue);
        expect(response.proposal, isNull);
        expect(response.remaining, isNull);
        expect(response.dailyLimit, isNull);
        expect(service.serverDailyLimit, isNull);
      },
    );

    for (final code in [
      'invalid_mode',
      'invalid_local_date',
      'log_mode_required',
      'log_fields_not_supported',
      // A rolled-back function knows no `local_date` field at all.
      'invalid_body',
    ]) {
      for (final english in [false, true]) {
        test('400 $code is "not available in this version yet" '
            '(${english ? 'en' : 'de'}), once, without quota', () async {
          var calls = 0;
          final service = _service((_) async {
            calls++;
            return _json({'error': code}, 400);
          });
          final l10n = english ? enL10n : deL10n;
          service.l10n = l10n;
          await expectLater(
            _request(service, locale: english ? 'en' : 'de'),
            throwsA(
              isA<CoachRequestUnsupported>().having(
                (e) => e.message,
                'message',
                l10n.coachWorkoutLogUnavailable,
              ),
            ),
          );
          expect(calls, 1, reason: 'no retry loop');
          expect(service.serverDailyLimit, isNull);
        });
      }
    }

    test('an unrelated 400 keeps the generic mapping', () async {
      final service = _service((_) async => _json({'error': 'empty_log'}, 400));
      await expectLater(
        _request(service),
        throwsA(
          allOf(
            isNot(isA<CoachRequestUnsupported>()),
            isA<CoachChatException>().having(
              (e) => e.message,
              'message',
              deL10n.coachErrorRequestFailed,
            ),
          ),
        ),
      );
    });

    test('daily quota 429 locks', () async {
      final service = _service(
        (_) async => _json({'error': 'quota_exceeded', 'daily_limit': 8}, 429),
      );
      await expectLater(_request(service), throwsA(isA<CoachQuotaExceeded>()));
      expect(service.serverDailyLimit, 8);
    });
  });

  group('Workout log deadline and ownership', () {
    for (final recover in [true, false]) {
      test(
        'a deadline asks the transcript; persisted row found=$recover',
        () async {
          var calls = 0;
          final client = _client(
            MockClient.streaming((request, body) async {
              await body.drain<void>();
              if (request.url.path.contains('coach-chat')) {
                calls++;
                await (request as http.Abortable).abortTrigger!;
                throw http.RequestAbortedException(request.url);
              }
              expect(
                request.url.queryParameters['select'],
                contains('workout_log'),
              );
              expect(request.headers['authorization'], 'Bearer fixture-A');
              final history = recover
                  ? [
                      _row(workoutLog: _log()),
                      _row(
                        role: 'user',
                        content: 'heute Kniebeugen 2x8 mit 100 kg',
                      ),
                    ]
                  : [
                      // A plan answer is no answer to a log.
                      _row(plan: {'title': 'Plan'}),
                      _row(
                        role: 'user',
                        content: 'heute Kniebeugen 2x8 mit 100 kg',
                      ),
                    ];
              return http.StreamedResponse(
                Stream.value(utf8.encode(jsonEncode(history))),
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
            logFrist: const Duration(milliseconds: 30),
            fristPuffer: const Duration(milliseconds: 30),
          );
          if (recover) {
            final response = await _request(service);
            expect(response.proposal!.toJson(), _log());
            expect(response.assistantMessageId, _assistantId);
            expect(response.remaining, isNull);
            expect(response.dailyLimit, isNull);
          } else {
            await expectLater(
              _request(service),
              _coachError(deL10n.coachErrorTimeout),
            );
          }
          expect(calls, 1, reason: 'the transcript never buys a second slot');
        },
      );
    }

    test('an account switch mid-request drops the answer', () async {
      final entered = Completer<void>();
      final response = Completer<http.Response>();
      final client = _client(
        MockClient((request) async {
          entered.complete();
          return response.future;
        }),
      );
      await _signIn(client, 'A');
      final service = CoachChatService(client, 'A');
      final rejected = expectLater(
        _request(service),
        _coachError(deL10n.coachErrorSessionExpired),
      );
      await entered.future;
      await _signIn(client, 'B');
      response.complete(_json(_reply()));
      await rejected;
      expect(service.serverDailyLimit, isNull);
    });

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
        _coachError(deL10n.coachErrorSessionExpired),
      );
      expect(calls, 0);
    });
  });

  group('Workout log history', () {
    test(
      'the history select reads workout_log and rebuilds the card',
      () async {
        final service = _service((request) async {
          expect(
            request.url.queryParameters['select'],
            contains('workout_log'),
          );
          return _json([_row(workoutLog: _log())], 200, request);
        });
        final message = (await service.loadHistory('s1')).single;
        expect(message.workoutLogProposal!.toJson(), _log());
        expect(message.trainingPlanProposal, isNull);
        expect(message.recipeProposal, isNull);
      },
    );

    test('exactly one proposal column, else text only', () {
      for (final row in [
        _row(workoutLog: _log(), plan: {'title': 'Plan'}),
        _row(workoutLog: _log(), recipe: {'title': 'Suppe'}),
        _row(workoutLog: _log(), refusal: true),
        _row(role: 'user', workoutLog: _log()),
        _row(workoutLog: {'title': 'Beintag'}),
      ]) {
        final message = ChatMessage.fromRow(row);
        expect(message.workoutLogProposal, isNull);
        expect(message.trainingPlanProposal, isNull);
        expect(message.recipeProposal, isNull);
      }
    });
  });
}
