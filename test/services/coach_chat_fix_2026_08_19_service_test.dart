import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/services/coach_chat_service.dart';
import 'package:eatova/src/services/crash_reporter.dart';

// Komplettreview 2026-08-19, Fund 4: `coach_chat_service.dart` importierte
// `crash_reporter.dart` gar nicht. Saemtliche Fehlerpfade — loadSessions,
// ensureDefaultSession, createSession, renameSession, deleteSession,
// loadHistory, loadQuotaToday und die vier catch-Arme von send/requestRecipe —
// endeten in `dev.log`, und das schreibt ausschliesslich in die lokale
// Geraete-/IDE-Konsole. Ein Totalausfall der Edge Function war in der
// Produktion unsichtbar; der Coach war der einzige Bereich der App ohne einen
// einzigen Crash-Reporter-Ausloeser.
//
// Die Gegenprobe gehoert zwingend dazu: der Filter muss die ERWARTBAREN Faelle
// draussen halten (offline, Tageslimit, abgelaufene Sitzung), sonst tauscht
// man Blindheit gegen Rauschen — und Rauschen ist hier nutzerproportional.
//
// Und: es darf NIE Nutzerinhalt hinausgehen. Die App verarbeitet
// Gesundheitsdaten; die Coach-Nachricht selbst ist der sensibelste Text, den
// sie kennt.

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

  // capture() laeuft unawaited los; ein Mikrotask-Durchlauf reicht.
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
      // Der RPC sagt eine Tabelle zu; kommt ein Objekt zurueck, hat sich
      // serverseitig etwas geaendert — typischerweise nach einer Migration.
      final svc = _service((req) async => _json({'a': 1}, 200));

      await expectLater(
        svc.loadSessions(),
        throwsA(isA<CoachDataUnavailable>()),
      );
      await pumpe();

      // Nur das Operations-Tag ist zugesichert, nicht der Zweig: eine
      // vertragswidrige Antwort laesst schon den PostgREST-Client werfen, der
      // Report kommt also aus dem catch (`coach.loadSessions`) statt aus der
      // eigenen Formpruefung (`…​.form`). Die bleibt als zweite Linie stehen —
      // sie greift fuer Antworten, die der Client noch durchreicht.
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

      // Wie oben: das Operations-Tag ist die Zusicherung, der Zweig nicht.
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
      // Bewusst ein RPC-Pfad (POST): postgrest wiederholt nur GET/HEAD, ein
      // Netzfehler auf `select()` liefe hier sonst durch drei echte
      // Backoff-Pausen.
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
