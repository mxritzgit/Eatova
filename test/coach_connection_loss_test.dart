import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/screens/coach/coach_chat_screen.dart';
import 'package:eatova/src/services/coach_chat_service.dart';

import 'support/harness.dart';

// A connection that dies while a Coach request is in flight says nothing
// about whether the server took it. functions_client wraps every transport
// error up to the response HEADERS as FunctionsFetchException, and coach-chat
// sends those only after its work (buffered /recipe, /plan, /log) or once the
// answer is under way (stream). A network switch, or iOS reclaiming the socket
// of an app the user left while /recipe ran, therefore leaves a claimed daily
// slot and a persisted answer behind. Reported as "not sent" with Retry, the
// retry buys a second of the five daily slots for the same request. These
// cases pin the transcript check that the deadline path already had.

const _sessionId = 's1';
const _assistantId = '0b6f2a4e-8c1d-4f7a-9e3b-5d2c1a0f9e8d';

const Map<String, Object?> _recipe = <String, Object?>{
  'title': 'Bowl',
  'description': 'Quick and high in protein.',
  'portion': '1 portion',
  'ingredients': '- 200 g chickpeas',
  'preparation': '1. Mix everything.',
  'calories_kcal': 480,
  'protein_g': 26,
  'carbs_g': 55,
  'fat_g': 14,
  'estimated_g': 400,
};

Map<String, Object?> _plan() => <String, Object?>{
  'schema_version': 1,
  'title': 'Strength basics',
  'description': '',
  'goal': '',
  'workouts': <Object?>[
    <String, Object?>{
      'title': 'A',
      'description': '',
      'exercises': <Object?>[
        <String, Object?>{
          'name': 'Squat',
          'sets': 3,
          'reps': 8,
          'duration_seconds': null,
          'rest_seconds': 90,
          'notes': '',
        },
      ],
    },
  ],
};

Map<String, Object?> _log() => <String, Object?>{
  'schema_version': 1,
  'title': 'Leg day',
  'performed_on': '2026-10-03',
  'duration_minutes': null,
  'other_days_omitted': false,
  'note': '',
  'exercises': <Object?>[
    <String, Object?>{
      'name': 'Squat',
      'kind': 'reps',
      'duration_seconds': null,
      'sets': <Object?>[
        <String, Object?>{'reps': 8, 'weight_kg': 100},
      ],
    },
  ],
};

/// The question and the answer as the server stored them, newest first (the
/// order loadHistory requests).
List<Map<String, Object?>> _exchange({
  required String question,
  required String answer,
  DateTime? at,
  Map<String, Object?>? recipe,
  Map<String, Object?>? plan,
  Map<String, Object?>? log,
}) {
  final t = (at ?? DateTime.now()).toUtc();
  return <Map<String, Object?>>[
    <String, Object?>{
      'id': _assistantId,
      'role': 'assistant',
      'content': answer,
      'refusal': false,
      'created_at': t.toIso8601String(),
      'recipe': recipe,
      'training_plan': plan,
      'workout_log': log,
    },
    <String, Object?>{
      'id': 'f0f0f0f0-0000-4000-8000-000000000001',
      'role': 'user',
      'content': question,
      'refusal': false,
      'created_at': t.subtract(const Duration(seconds: 1)).toIso8601String(),
      'recipe': null,
      'training_plan': null,
      'workout_log': null,
    },
  ];
}

/// Where the connection to coach-chat dies.
enum _Loss {
  /// After the upload, before the response headers (FunctionsFetchException).
  beforeHeaders,

  /// Inside the response body (a raw http.ClientException).
  inBody,
}

class _Backend {
  _Backend({required this.loss, this.persisted = const [], this.sse = false});

  final _Loss loss;

  /// What the server stores while the client waits; served once the
  /// connection is gone.
  final List<Map<String, Object?>> persisted;

  /// Whether the body is the chat's SSE stream instead of buffered JSON.
  final bool sse;

  /// No network at all: the history read fails too.
  bool offline = false;

  List<Map<String, Object?>> _history = const [];
  int functionCalls = 0;
  int historyReads = 0;

  http.Client client() => MockClient.streaming(_handle);

  Future<http.StreamedResponse> _handle(
    http.BaseRequest req,
    http.ByteStream body,
  ) async {
    await body.drain<void>();
    final path = req.url.path;
    if (path.contains('coach-chat')) {
      functionCalls++;
      // The request arrived: the server claims the slot and stores both rows.
      _history = persisted;
      if (loss == _Loss.beforeHeaders) {
        throw http.ClientException('Software caused connection abort', req.url);
      }
      return http.StreamedResponse(
        _brokenBody(req),
        200,
        request: req,
        headers: <String, String>{
          'content-type': sse
              ? 'text/event-stream; charset=utf-8'
              : 'application/json; charset=utf-8',
        },
      );
    }
    if (path.endsWith('/rest/v1/chat_messages')) {
      historyReads++;
      if (offline) throw http.ClientException('Failed host lookup', req.url);
      return _json(req, _history);
    }
    if (path.endsWith('/rpc/ensure_default_chat_session')) {
      return _json(req, _sessionId);
    }
    if (path.endsWith('/rpc/get_chat_quota_today')) {
      return _json(req, const <Map<String, Object?>>[
        <String, Object?>{'used': 1, 'remaining': 4, 'daily_limit': 5},
      ]);
    }
    return _json(req, const <Object?>[]);
  }

  /// The first bytes of the answer, then the socket dies.
  Stream<List<int>> _brokenBody(http.BaseRequest req) async* {
    yield utf8.encode(
      sse
          ? 'event: meta\ndata: {"session_id":"$_sessionId"}\n\n'
          : '{"reply":"Bowl — 480 kcal","recipe":{"title":"Bo',
    );
    throw http.ClientException('Connection reset by peer', req.url);
  }

  http.StreamedResponse _json(http.BaseRequest req, Object? data) {
    final bytes = utf8.encode(jsonEncode(data));
    return http.StreamedResponse(
      http.ByteStream.fromBytes(bytes),
      200,
      contentLength: bytes.length,
      request: req,
      headers: const <String, String>{'content-type': 'application/json'},
    );
  }
}

CoachChatService _service(_Backend backend, {bool dispose = true}) {
  final client = SupabaseClient(
    'https://example.supabase.co',
    'test-anon-key',
    httpClient: backend.client(),
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  if (dispose) addTearDown(client.dispose);
  return CoachChatService(client, 'user-123');
}

void main() {
  group('the connection dies after the request reached the server', () {
    for (final loss in _Loss.values) {
      test('/recipe ($loss): the stored card comes back, no second slot',
          () async {
        final backend = _Backend(
          loss: loss,
          persisted: _exchange(
            question: 'Chickpea bowl',
            answer: 'Bowl — 480 kcal',
            recipe: _recipe,
          ),
        );
        final svc = _service(backend);

        final res = await svc.requestRecipe(
          'Chickpea bowl',
          sessionId: _sessionId,
          locale: 'en',
        );

        expect(res.proposal?.title, 'Bowl');
        expect(res.proposal?.caloriesKcal, 480);
        expect(res.proposal?.imageBytes, isNull,
            reason: 'image bytes are never persisted; the card shows its '
                'placeholder');
        expect(res.assistantMessageId, _assistantId);
        expect(res.remaining, isNull,
            reason: 'unknown here; the screen keeps its counter');
        expect(backend.functionCalls, 1);
      });
    }

    for (final loss in _Loss.values) {
      test('chat ($loss): the stored answer comes back', () async {
        final backend = _Backend(
          loss: loss,
          sse: true,
          persisted: _exchange(
            question: 'How much protein?',
            answer: 'About 1.6 g per kilo.',
          ),
        );
        final svc = _service(backend);

        final res = await svc.send('How much protein?', sessionId: _sessionId);

        expect(res.reply, 'About 1.6 g per kilo.');
        expect(res.refusal, isFalse);
        expect(backend.functionCalls, 1);
      });
    }

    test('/plan: the stored draft comes back with its server id', () async {
      final backend = _Backend(
        loss: _Loss.beforeHeaders,
        persisted: _exchange(
          question: 'Strength for beginners',
          answer: 'Training proposal: Strength basics.',
          plan: _plan(),
        ),
      );
      final svc = _service(backend);

      final res = await svc.requestPlan(
        'Strength for beginners',
        sessionId: _sessionId,
        locale: 'en',
      );

      expect(res.proposal?.title, 'Strength basics');
      expect(res.assistantMessageId, _assistantId);
    });

    test('/log: the stored draft comes back with its server id', () async {
      final backend = _Backend(
        loss: _Loss.inBody,
        persisted: _exchange(
          question: 'today squats 1x8 100 kg',
          answer: 'Workout to log: Leg day.',
          log: _log(),
        ),
      );
      final svc = _service(backend);

      final res = await withClock(
        Clock.fixed(DateTime.now()),
        () => svc.requestWorkoutLog(
          'today squats 1x8 100 kg',
          sessionId: _sessionId,
          locale: 'en',
        ),
      );

      expect(res.proposal?.title, 'Leg day');
      expect(res.assistantMessageId, _assistantId);
    });
  });

  group('nothing proves an answer: the connection error stands', () {
    final requests = <String, Future<Object?> Function(CoachChatService)>{
      'chat': (svc) => svc.send('How much protein?', sessionId: _sessionId),
      'recipe': (svc) => svc.requestRecipe(
            'Chickpea bowl',
            sessionId: _sessionId,
            locale: 'de',
          ),
      'plan': (svc) => svc.requestPlan(
            'Strength for beginners',
            sessionId: _sessionId,
            locale: 'de',
          ),
      'log': (svc) => svc.requestWorkoutLog(
            'today squats 1x8 100 kg',
            sessionId: _sessionId,
            locale: 'de',
          ),
    };
    for (final MapEntry(key: name, value: request) in requests.entries) {
      for (final loss in _Loss.values) {
        test('$name ($loss): the server stored nothing', () async {
          final backend = _Backend(loss: loss, sse: name == 'chat');
          final svc = _service(backend);

          await expectLater(
            request(svc),
            throwsA(isA<CoachChatException>().having(
              (e) => e.message,
              'message',
              deL10n.coachErrorNoConnection,
            )),
          );
          expect(backend.historyReads, 1);
        });
      }

      test('$name offline: one history attempt, no backoff before the error',
          () async {
        final backend = _Backend(loss: _Loss.beforeHeaders, sse: name == 'chat')
          ..offline = true;
        final svc = _service(backend);
        final watch = Stopwatch()..start();

        await expectLater(
          request(svc),
          throwsA(isA<CoachChatException>().having(
            (e) => e.message,
            'message',
            deL10n.coachErrorNoConnection,
          )),
        );
        expect(backend.historyReads, 1,
            reason: 'PostgREST would retry a failing GET three times with '
                '1, 2 and 4 s pauses before the user sees the error');
        expect(watch.elapsed, lessThan(const Duration(milliseconds: 900)));
      });
    }

    test('the same question answered hours ago is not replayed', () async {
      final backend = _Backend(
        loss: _Loss.beforeHeaders,
        sse: true,
        persisted: _exchange(
          question: 'How much protein?',
          answer: 'About 1.6 g per kilo.',
          at: DateTime.now().subtract(const Duration(hours: 3)),
        ),
      );
      final svc = _service(backend);

      await expectLater(
        svc.send('How much protein?', sessionId: _sessionId),
        throwsA(isA<CoachChatException>().having(
          (e) => e.message,
          'message',
          deL10n.coachErrorNoConnection,
        )),
      );
    });
  });

  testWidgets('/recipe in the screen: the card stands, nothing to retry',
      (tester) async {
    final backend = _Backend(
      loss: _Loss.beforeHeaders,
      persisted: _exchange(
        question: 'Chickpea bowl',
        answer: 'Bowl — 480 kcal',
        recipe: _recipe,
      ),
    );
    final svc = _service(backend, dispose: false);
    await pumpLocalized(
      tester,
      CoachChatScreen(service: svc, userName: 'M'),
      surfaceSize: const Size(402, 781),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));

    await tester.enterText(
      find.byKey(const ValueKey('coach-input')),
      '/recipe Chickpea bowl',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('coach-send')));
    // functions_client encodes the body on a real isolate, which fake time
    // never reaches: let real time pass between frames.
    for (var i = 0; i < 10 && backend.historyReads < 2; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byKey(const ValueKey('coach-recipe-card')), findsOneWidget);
    expect(find.text(deL10n.coachErrorNoConnection), findsNothing);
    expect(find.byKey(const ValueKey('coach-unsent-retry')), findsNothing,
        reason: 'a retry would claim a second daily slot for a recipe the '
            'server already stored');
    expect(backend.functionCalls, 1);
  });
}
