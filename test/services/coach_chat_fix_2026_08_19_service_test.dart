import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/services/coach_chat_service.dart';
import 'package:eatova/src/services/crash_reporter.dart';

// Finding 4 (review 2026-08-19): `coach_chat_service.dart` did not import
// `crash_reporter.dart` at all, so every error path ended in `dev.log` — a
// total edge-function outage was invisible in production.
//
// The counter-check is part of the deal: EXPECTED cases (offline, daily limit,
// expired session) must stay out, or blindness is traded for noise that scales
// with the user count.
//
// And no user content may ever leave: the coach message is the most sensitive
// text this app handles.

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
  late List<Object> gemeldet;
  late List<String?> kontexte;

  setUp(() {
    gemeldet = <Object>[];
    kontexte = <String?>[];
    CrashReporter.debugSentrySink = (error, stack, context) {
      gemeldet.add(error);
      kontexte.add(context);
    };
  });

  tearDown(() => CrashReporter.debugSentrySink = null);

  // capture() runs unawaited; one microtask pass is enough.
  Future<void> pumpe() => Future<void>.delayed(Duration.zero);

  group('gemeldet wird, was niemand sonst sieht', () {
    test('500 der Edge Function -> Report mit Operation im context-Tag',
        () async {
      final svc = _service((req) async => _json({'error': 'internal'}, 500));

      await expectLater(
        svc.send('Hallo', sessionId: 's1'),
        throwsA(isA<CoachChatException>()),
      );
      await pumpe();

      expect(kontexte, <String>['coach.send.http']);
      expect(
        gemeldet.single.toString(),
        contains('status=500'),
        reason: 'der Status IST die Diagnose — mehr braucht es nicht',
      );
    });

    test('500 im Rezept-Modus -> eigener context, damit sich die beiden '
        'Pfade in Sentry trennen lassen', () async {
      final svc = _service((req) async => _json({'error': 'internal'}, 500));

      await expectLater(
        svc.requestRecipe('Bowl mit Kichererbsen',
            sessionId: 's1', locale: 'de'),
        throwsA(isA<CoachChatException>()),
      );
      await pumpe();

      expect(kontexte, <String>['coach.recipe.http']);
    });

    test('200 ohne Text ist ein gebrochener Vertrag und wird gemeldet',
        () async {
      final svc = _service((req) async => _json({'reply': '   '}, 200));

      await expectLater(
        svc.send('Hallo', sessionId: 's1'),
        throwsA(isA<CoachChatException>()),
      );
      await pumpe();

      expect(kontexte, <String>['coach.send.leereAntwort']);
    });

    test('loadHistory: der DB-Fehler geht mit raus', () async {
      final svc = _service((req) async => _json({'message': 'kaputt'}, 500));

      await expectLater(
        svc.loadHistory('s1'),
        throwsA(isA<CoachDataUnavailable>()),
      );
      await pumpe();

      expect(kontexte, <String>['coach.loadHistory']);
    });

    test('loadSessions: eine Antwort in unerwarteter Form ist kein Netzfehler',
        () async {
      // The RPC promises a table; an object means the server changed,
      // typically after a migration.
      final svc = _service((req) async => _json({'a': 1}, 200));

      await expectLater(
        svc.loadSessions(),
        throwsA(isA<CoachDataUnavailable>()),
      );
      await pumpe();

      // Only the operation tag is guaranteed, not the branch: an off-contract
      // response already makes the PostgREST client throw, so the report comes
      // from the catch rather than the shape check, which stays as a second
      // line for responses the client still passes through.
      expect(kontexte, hasLength(1));
      expect(kontexte.single, startsWith('coach.loadSessions'));
    });

    test('loadQuotaToday: Antwort ohne verwertbare Zahlen wird gemeldet',
        () async {
      final svc = _service((req) async => _json(<Object>[], 200));

      await expectLater(
        svc.loadQuotaToday(),
        throwsA(isA<CoachDataUnavailable>()),
      );
      await pumpe();

      // As above: the operation tag is the guarantee, the branch is not.
      expect(kontexte, hasLength(1));
      expect(kontexte.single, startsWith('coach.loadQuotaToday'));
    });

    test('deleteSession: „nicht geloescht" ist ein Vorfall', () async {
      final svc = _service((req) async => _json({'message': 'kaputt'}, 500));

      await expectLater(
        svc.deleteSession('s1'),
        throwsA(isA<CoachDataUnavailable>()),
      );
      await pumpe();

      expect(kontexte, <String>['coach.deleteSession']);
    });
  });

  group('nicht gemeldet wird, was vorgesehen ist', () {
    test('Tageslimit (429 quota_exceeded) erzeugt keinen Report', () async {
      final svc = _service((req) async => _json({
            'error': 'quota_exceeded',
            'reply': 'Tageslimit erreicht. Morgen geht es weiter.',
            'remaining': 0,
            'daily_limit': 5,
          }, 429));

      await expectLater(
        svc.send('Hi', sessionId: 's1'),
        throwsA(isA<CoachQuotaExceeded>()),
      );
      await pumpe();

      expect(
        gemeldet,
        isEmpty,
        reason: 'das Limit ist die Funktionsweise des Systems, nicht sein '
            'Ausfall — und der Report waere nutzerproportional',
      );
    });

    test('abgelaufene Sitzung (401) erzeugt keinen Report', () async {
      final svc =
          _service((req) async => _json({'error': 'Unauthorized'}, 401));

      await expectLater(
        svc.send('Hi', sessionId: 's1'),
        throwsA(isA<CoachChatException>()),
      );
      await pumpe();

      expect(gemeldet, isEmpty);
    });

    test('Bild zu gross (413) erzeugt keinen Report', () async {
      final svc = _service((req) async => _json({'error': 'too_large'}, 413));

      await expectLater(
        svc.send('Hi', sessionId: 's1'),
        throwsA(isA<CoachChatException>()),
      );
      await pumpe();

      expect(gemeldet, isEmpty);
    });

    test('Netzabbruch erzeugt keinen Report — sonst waere jede U-Bahnfahrt '
        'ein Vorfall', () async {
      final svc = _service((req) async {
        throw http.ClientException('connection reset');
      });

      await expectLater(
        svc.send('Hi', sessionId: 's1'),
        throwsA(isA<CoachChatException>()),
      );
      await pumpe();

      expect(gemeldet, isEmpty);
    });

    test('auch die Sitzungsliste meldet einen Netzabbruch nicht', () async {
      // Deliberately an RPC path (POST): postgrest only retries GET/HEAD, so a
      // network error on `select()` would burn three real backoff pauses.
      final svc = _service((req) async {
        throw http.ClientException('connection reset');
      });

      await expectLater(
        svc.loadSessions(),
        throwsA(isA<CoachDataUnavailable>()),
      );
      await pumpe();

      expect(gemeldet, isEmpty);
    });
  });

  group('Datenschutz: was gemeldet wird, traegt keinen Nutzerinhalt', () {
    test('weder die Coach-Frage noch die Antwort der Function stehen im '
        'Report', () async {
      const frage = 'Ich wiege 78,4 kg und nehme Metformin — was soll ich '
          'heute Abend essen?';
      final svc = _service(
        (req) async => _json({
          'error': 'internal',
          'reply': 'Interner Fehlertext mit Rohdaten aus der Anfrage',
        }, 500),
      );

      await expectLater(
        svc.send(frage, sessionId: 's1'),
        throwsA(isA<CoachChatException>()),
      );
      await pumpe();

      final bericht = gemeldet.single.toString();
      expect(bericht, isNot(contains('Metformin')));
      expect(bericht, isNot(contains('78,4')));
      expect(bericht, isNot(contains('Rohdaten')));
      expect(
        kontexte.single,
        'coach.send.http',
        reason: 'das context-Tag ist IMMER ein Literal aus dem Quelltext',
      );
    });
  });
}
