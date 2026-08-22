import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/services/coach_chat_service.dart';

// D2 — error mapping of CoachChatService.send().
//
// `functions_client` throws on every non-2xx: `x-relay-error: true` gives
// FunctionsRelayException, otherwise FunctionsHttpException. A 429 therefore
// never reaches the caller as `res.status`.
//
// These tests drive the real SupabaseClient through a MockClient and check the
// shape the server actually sends. Two promises matter:
//   1. A quota 429 must become CoachQuotaExceeded, or the composer stays open
//      and the user hits the same wall.
//   2. A rate-limit 429 must NOT, since it carries no daily_limit and would
//      lock the composer for the rest of the day.
// Across all cases: never raw server data in UI text.

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

http.Response _json(Object body, int status, {Map<String, String>? headers}) =>
    http.Response(
      jsonEncode(body),
      status,
      headers: {'Content-Type': 'application/json', ...?headers},
    );

/// Captures the exception from send() so individual fields can be checked;
/// throwsA matchers are not enough for the text assertions.
Future<Object> _failureOf(CoachChatService svc) async {
  try {
    await svc.send('Hi Coach', sessionId: 's1');
  } catch (e) {
    return e;
  }
  fail('send() sollte werfen, lief aber durch.');
}

String _messageOf(Object e) {
  if (e is CoachQuotaExceeded) return e.message;
  if (e is CoachChatException) return e.message;
  fail('Unerwarteter Fehlertyp: ${e.runtimeType}');
}

void main() {
  group('D2 · 429 wird korrekt aufgeteilt', () {
    test('429 + quota_exceeded (echte Server-Form) -> CoachQuotaExceeded', () async {
      final svc = _service((req) async {
        expect(req.url.path, contains('coach-chat'));
        return _json({
          'error': 'quota_exceeded',
          'reply': 'Tageslimit erreicht (5 Coach-Fragen pro Tag). '
              'Morgen geht es weiter.',
          'remaining': 0,
          'daily_limit': 5,
        }, 429);
      });

      final failure = await _failureOf(svc);
      expect(failure, isA<CoachQuotaExceeded>());
      expect((failure as CoachQuotaExceeded).dailyLimit, 5);
      expect(failure.message, contains('Tageslimit erreicht'));
    });

    test('429 + rate_limited -> CoachChatException, NICHT CoachQuotaExceeded',
        () async {
      // rate_limited carries no daily_limit; mapped as quota it would lock the
      // composer all day although sending is allowed again in 30 seconds.
      final svc = _service((req) async {
        return _json({
          'error': 'rate_limited',
          'reply': 'Zu viele Coach-Anfragen. Bitte gleich nochmal versuchen.',
        }, 429);
      });

      final failure = await _failureOf(svc);
      expect(failure, isNot(isA<CoachQuotaExceeded>()));
      expect(failure, isA<CoachChatException>());
      expect(_messageOf(failure), contains('Zu viele'));
    });

    test('429 + quota_exceeded ohne daily_limit -> Fallback 5, eigener Text',
        () async {
      final svc = _service((req) async {
        return _json({'error': 'quota_exceeded'}, 429);
      });

      final failure = await _failureOf(svc);
      expect(failure, isA<CoachQuotaExceeded>());
      expect((failure as CoachQuotaExceeded).dailyLimit, 5);
      expect(failure.message, contains('Tageslimit'));
    });
  });

  group('D2 · weitere Status bekommen eine lesbare deutsche Meldung', () {
    test('401 -> Hinweis auf neue Anmeldung statt "unbekannter Fehler"',
        () async {
      final svc = _service((req) async {
        return _json({'error': 'Unauthorized'}, 401);
      });

      final failure = await _failureOf(svc);
      expect(failure, isA<CoachChatException>());
      final msg = _messageOf(failure);
      expect(msg, contains('Sitzung'));
      expect(msg, contains('melde dich neu an'));
      expect(msg, isNot(contains('Unauthorized')));
    });

    test('413 image_too_large -> Server-reply zum Bild', () async {
      final svc = _service((req) async {
        return _json({
          'error': 'image_too_large',
          'reply': 'Das Bild ist zu gross. Bitte schick ein kleineres oder '
              'komprimiertes Bild.',
          'refusal': true,
        }, 413);
      });

      final failure = await _failureOf(svc);
      expect(failure, isA<CoachChatException>());
      expect(_messageOf(failure), contains('Bild'));
    });

    test('500 -> generische Meldung, kein Roh-Dump und kein Fehlercode',
        () async {
      final svc = _service((req) async {
        return _json({'error': 'rpc_unavailable'}, 500);
      });

      final failure = await _failureOf(svc);
      expect(failure, isA<CoachChatException>());
      final msg = _messageOf(failure);
      expect(msg, isNot(contains('FunctionsHttpException')));
      expect(msg, isNot(contains('rpc_unavailable')));
      expect(msg, contains('Coach'));
    });
  });

  group('D2 · details ist dynamic — Map, String, HTML', () {
    test('details als Klartext-String -> generische Meldung, kein Durchreichen',
        () async {
      final svc = _service((req) async {
        return http.Response('boom: upstream connect error', 503,
            headers: const {'Content-Type': 'text/plain'});
      });

      final failure = await _failureOf(svc);
      final msg = _messageOf(failure);
      expect(msg, isNot(contains('upstream connect error')));
      expect(msg, isNot(contains('FunctionsHttpException')));
    });

    test('details als HTML-Gateway-Seite -> kein Markup im UI-Text', () async {
      final svc = _service((req) async {
        return http.Response(
          '<html><head><title>502 Bad Gateway</title></head>'
          '<body><h1>502 Bad Gateway</h1></body></html>',
          502,
          headers: const {'Content-Type': 'text/html'},
        );
      });

      final failure = await _failureOf(svc);
      final msg = _messageOf(failure);
      expect(msg, isNot(contains('<')));
      expect(msg, isNot(contains('Bad Gateway')));
    });

    test('reply-Feld ist kein String (Zahl) -> generische Meldung', () async {
      final svc = _service((req) async {
        return _json({'error': 'weird', 'reply': 42}, 500);
      });

      final failure = await _failureOf(svc);
      expect(_messageOf(failure), isNot(contains('42')));
    });

    test('FunctionsRelayException (x-relay-error) -> eigener, sauberer Zweig',
        () async {
      // The relay error is a different type from FunctionsHttpException and
      // must still produce a message.
      final svc = _service((req) async {
        return _json({'msg': 'relay down'}, 500,
            headers: const {'x-relay-error': 'true'});
      });

      final failure = await _failureOf(svc);
      expect(failure, isA<CoachChatException>());
      final msg = _messageOf(failure);
      expect(msg, isNot(contains('FunctionsRelayException')));
      expect(msg, isNot(contains('relay down')));
    });

    test('Transportfehler -> Hinweis auf die Verbindung', () async {
      final svc = _service((req) async {
        throw http.ClientException('connection reset');
      });

      final failure = await _failureOf(svc);
      expect(failure, isA<CoachChatException>());
      final msg = _messageOf(failure);
      expect(msg.toLowerCase(), contains('verbindung'));
      expect(msg, isNot(contains('connection reset')));
    });
  });

  group('D2 · kein Fehlerfall traegt jemals den Exception-Dump in die UI', () {
    for (final status in <int>[401, 413, 429, 500, 502]) {
      test('Status $status -> Meldung ohne "FunctionsHttpException"', () async {
        final svc = _service((req) async {
          return _json({'error': 'irgendwas', 'details': 'intern'}, status);
        });

        final failure = await _failureOf(svc);
        final msg = _messageOf(failure);
        expect(msg, isNot(contains('FunctionsHttpException')));
        expect(msg, isNot(contains('status:')));
        expect(msg.trim(), isNotEmpty);
      });
    }
  });
}
