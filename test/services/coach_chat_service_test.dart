import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/services/coach_chat_service.dart';

// TEST-3: error paths of CoachChatService.send() through the PUBLIC API,
// driving the real SupabaseClient with a MockClient that fakes the
// `coach-chat` edge function response.
//
// Expectations follow the shape the server really sends: an exhausted daily
// quota is a *429* with a JSON body ({error, reply, remaining, daily_limit}),
// never a 200 with an error field.

/// Builds a real SupabaseClient whose HTTP layer is replaced by [handler] and
/// returns a CoachChatService on it. Disposed via addTearDown to clean up the
/// auth timer.
CoachChatService _service(
  Future<http.Response> Function(http.Request request) handler,
) {
  final client = SupabaseClient(
    'https://example.supabase.co',
    'test-anon-key',
    httpClient: MockClient((req) => handler(req)),
  );
  addTearDown(client.dispose);
  return CoachChatService(client, 'user-123');
}

http.Response _json(Object body, int status) => http.Response(
      jsonEncode(body),
      status,
      headers: const {'Content-Type': 'application/json'},
    );

void main() {
  group('CoachChatService.send Fehlerpfade', () {
    // handler.ts:814-821 answers with 429; the 200 form was made up.

    // The distinction that matters: not every 429 is the quota.

    test('fehlendes reply-Feld (200, kein reply) -> CoachChatException', () async {
      final svc = _service((req) async {
        return _json({'refusal': false}, 200);
      });

      await expectLater(
        svc.send('Hallo', sessionId: 's1'),
        throwsA(isA<CoachChatException>()),
      );
    });
  });

  group('CoachChatService.send Erfolgspfad (Kontrast)', () {
    test('gueltige Antwort -> CoachChatReply mit reply + remaining', () async {
      final svc = _service((req) async {
        return _json({
          'reply': 'Trink Wasser und schlaf genug.',
          'refusal': false,
          'remaining': 4,
          'session_id': 's1',
        }, 200);
      });

      final reply = await svc.send('Tipp?', sessionId: 's1');
      expect(reply.reply, 'Trink Wasser und schlaf genug.');
      expect(reply.refusal, isFalse);
      expect(reply.remaining, 4);
      expect(reply.sessionId, 's1');
    });
  });

  group('Sentinel-Rest: CoachDataUnavailable statt erfundener Zustaende', () {
    test('send uebernimmt das daily_limit des Servers in die Antwort',
        () async {
      // Without the field the screen compared remaining against its assumed
      // default limit, so a COACH_DAILY_LIMIT != 5 made the counter fiction.
      final svc = _service((req) async => _json({
            'reply': 'Ok.',
            'refusal': false,
            'remaining': 19,
            'daily_limit': 20,
            'session_id': 's1',
          }, 200));

      final reply = await svc.send('Hi', sessionId: 's1');

      expect(reply.dailyLimit, 20);
      expect(reply.remaining, 19);
    });
  });
}
