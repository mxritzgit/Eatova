import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/services/coach_chat_service.dart';

// TEST-3: Fehlerpfade von CoachChatService.send() ueber die PUBLIC API.
// coach_chat_service.dart wird NICHT editiert. Wir treiben den echten
// SupabaseClient mit einem MockClient (package:http/testing.dart), der die
// Edge-Function-Antwort fuer `coach-chat` faked. Verifiziert das beobachtbare
// Verhalten: Quota-Exhaustion, Server-/HTTP-Fehler und leere Antwort.
//
// Wichtig fuer die Erwartungen: functions.invoke wirft bei non-2xx-Status
// selbst eine FunctionException (functions_client). send() faengt das im
// generischen catch und verpackt es als CoachChatException. Die
// quota_exceeded-Semantik kommt daher als 200 mit error-Feld zurueck (so wie
// die Edge Function antwortet), nicht als roher 429.

/// Baut einen echten SupabaseClient, dessen HTTP-Schicht durch [handler]
/// ersetzt ist, und gibt einen CoachChatService darauf zurueck. Nur der
/// functions.invoke-Pfad wird in diesen Tests genutzt. Der Client wird per
/// addTearDown disposed (Isolate/Auth-Timer aufraeumen).
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
    test('quota_exceeded (200 + error-Feld) -> CoachQuotaExceeded mit Limit', () async {
      final svc = _service((req) async {
        expect(req.url.path, contains('coach-chat'));
        return _json({
          'error': 'quota_exceeded',
          'reply': 'Tageslimit erreicht. Morgen geht es weiter.',
          'daily_limit': 5,
        }, 200);
      });

      await expectLater(
        svc.send('Hi Coach', sessionId: 's1'),
        throwsA(
          isA<CoachQuotaExceeded>()
              .having((e) => e.dailyLimit, 'dailyLimit', 5)
              .having((e) => e.message, 'message', contains('Tageslimit')),
        ),
      );
    });

    test('roher 429-Status -> CoachChatException (invoke wirft FunctionException)',
        () async {
      final svc = _service((req) async {
        return _json({'error': 'quota_exceeded', 'daily_limit': 5}, 429);
      });

      // Non-2xx wird vom functions_client als FunctionException geworfen und
      // landet im generischen catch -> CoachChatException (kein Crash).
      await expectLater(
        svc.send('Hi', sessionId: 's1'),
        throwsA(isA<CoachChatException>()),
      );
    });

    test('Server-Fehler 500 -> CoachChatException', () async {
      final svc = _service((req) async {
        return _json({'error': 'internal'}, 500);
      });

      await expectLater(
        svc.send('Hallo', sessionId: 's1'),
        throwsA(isA<CoachChatException>()),
      );
    });

    test('leere Antwort (200, reply: "") -> CoachChatException', () async {
      final svc = _service((req) async {
        return _json({'reply': '   '}, 200);
      });

      await expectLater(
        svc.send('Hallo', sessionId: 's1'),
        throwsA(
          isA<CoachChatException>()
              .having((e) => e.message, 'message', contains('Leere Antwort')),
        ),
      );
    });

    test('fehlendes reply-Feld (200, kein reply) -> CoachChatException', () async {
      final svc = _service((req) async {
        return _json({'refusal': false}, 200);
      });

      await expectLater(
        svc.send('Hallo', sessionId: 's1'),
        throwsA(isA<CoachChatException>()),
      );
    });

    test('Netzwerk-/Transport-Fehler -> CoachChatException', () async {
      final svc = _service((req) async {
        throw http.ClientException('connection reset');
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
}
