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
// KORREKTUR (Review D2/G1, 2026-08-08) — dieser Kopf stand hier vorher:
//
//   "Wichtig fuer die Erwartungen: functions.invoke wirft bei non-2xx-Status
//    selbst eine FunctionException (functions_client). send() faengt das im
//    generischen catch und verpackt es als CoachChatException. Die
//    quota_exceeded-Semantik kommt daher als 200 mit error-Feld zurueck (so
//    wie die Edge Function antwortet), nicht als roher 429."
//
// Der erste Satz stimmt, die Schlussfolgerung war falsch. Die Edge Function
// antwortet auf ein erschoepftes Tageskontingent mit *429* und JSON-Body
// (handler.ts:814-821: {error, reply, remaining, daily_limit}). Ein 200 mit
// error-Feld sendet der Server nie — der alte Test hat eine erfundene Form
// geprueft und damit den Produktionsbug abgesichert, statt ihn zu finden:
// dass jeder Fehler im generischen catch als CoachChatException(e.toString())
// endete, war kein Naturgesetz des Pakets, sondern die fehlende
// Fehlerbehandlung in send(). Die Erwartungen unten pruefen jetzt die Form,
// die der Server wirklich schickt.

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
    // Frueher: "quota_exceeded (200 + error-Feld) -> CoachQuotaExceeded mit
    // Limit". Die 200er-Form war erfunden; handler.ts:814-821 antwortet mit
    // 429, und genau dabei ist der Quota-Pfad frueher durchgefallen.
    test('quota_exceeded (429 + error-Feld, echte Server-Form) -> '
        'CoachQuotaExceeded mit Limit', () async {
      final svc = _service((req) async {
        expect(req.url.path, contains('coach-chat'));
        return _json({
          'error': 'quota_exceeded',
          'reply': 'Tageslimit erreicht. Morgen geht es weiter.',
          'remaining': 0,
          'daily_limit': 5,
        }, 429);
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

    // Frueher behauptete dieser Test woertlich: "roher 429-Status ->
    // CoachChatException (invoke wirft FunctionException)" — mit dem Body
    // {'error': 'quota_exceeded', 'daily_limit': 5}. Das war die
    // Bug-Beschreibung als Zusage: der Nutzer bekam beim Tageslimit einen
    // Exception-Dump im Banner statt der Quota-Sperre. Was bleibt, ist die
    // Unterscheidung, die es wirklich braucht: nicht jeder 429 ist die Quota.
    test('429 ohne quota_exceeded (rate_limited) -> CoachChatException, '
        'kein Quota-Lock', () async {
      final svc = _service((req) async {
        return _json({
          'error': 'rate_limited',
          'reply': 'Zu viele Coach-Anfragen. Bitte gleich nochmal versuchen.',
        }, 429);
      });

      // rate_limited traegt kein daily_limit (handler.ts:669-672, 686-689).
      // Als CoachQuotaExceeded gemappt wuerde der Composer bis Mitternacht
      // sperren, obwohl der Nutzer gleich wieder senden darf.
      await expectLater(
        svc.send('Hi', sessionId: 's1'),
        throwsA(
          allOf(
            isA<CoachChatException>(),
            isNot(isA<CoachQuotaExceeded>()),
            isA<CoachChatException>()
                .having((e) => e.message, 'message', contains('Zu viele')),
          ),
        ),
      );
    });

    test('Server-Fehler 500 -> CoachChatException ohne Roh-Dump', () async {
      final svc = _service((req) async {
        return _json({'error': 'internal'}, 500);
      });

      await expectLater(
        svc.send('Hallo', sessionId: 's1'),
        throwsA(
          isA<CoachChatException>().having(
            (e) => e.message,
            'message',
            allOf(
              isNot(contains('FunctionsHttpException')),
              isNot(contains('internal')),
            ),
          ),
        ),
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

  group('Sentinel-Rest: CoachDataUnavailable statt erfundener Zustaende', () {
    test('loadHistory: DB-Fehler wirft statt „Konversation war leer"', () async {
      // Frueher: catch -> leere Liste. Der Screen setzte sie als _messages
      // und zeigte den Hero-Leerzustand — der Nutzer sah seinen Verlauf als
      // geloescht, ohne Fehlerhinweis und ohne Retry. Exakt das Muster, das
      // loadSessions und loadQuotaToday bereits abgelegt haben.
      final svc = _service((req) async => _json({'message': 'kaputt'}, 500));

      await expectLater(
          svc.loadHistory('s1'), throwsA(isA<CoachDataUnavailable>()));
    });

    test('deleteSession: RPC-Fehler wirft statt still „geloescht" zu melden',
        () async {
      final svc = _service((req) async => _json({'message': 'kaputt'}, 500));

      await expectLater(
          svc.deleteSession('s1'), throwsA(isA<CoachDataUnavailable>()),
          reason: 'ein Future<void>, das normal zurueckkehrt, IST die '
              'positive Behauptung „ist geloescht"');
    });

    test('renameSession: RPC-Fehler wirft ebenfalls', () async {
      final svc = _service((req) async => _json({'message': 'kaputt'}, 500));

      await expectLater(svc.renameSession('s1', 'Neuer Titel'),
          throwsA(isA<CoachDataUnavailable>()));
    });

    test('send uebernimmt das daily_limit des Servers in die Antwort',
        () async {
      // Ohne das Feld rechnete der Screen jeden remaining-Wert gegen sein
      // angenommenes Standard-Limit — mit gesetztem COACH_DAILY_LIMIT != 5
      // war der angezeigte Zaehler erfunden.
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
