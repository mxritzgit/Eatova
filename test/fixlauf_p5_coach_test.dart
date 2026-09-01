import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/chat_message.dart';
import 'package:eatova/src/models/chat_session.dart';
import 'package:eatova/src/models/coach_recipe_proposal.dart';
import 'package:eatova/src/screens/coach/coach_chat_screen.dart';
import 'package:eatova/src/services/coach_chat_service.dart';

import 'support/harness.dart';

// Fix-Lauf Review 2026-08-29, Coach-Paket P5.
//
//   P5-01  Der Client las die `session_id` der Antwort nie. Der Server faellt
//          bei einer geloeschten Session still in die Default-Session zurueck
//          und meldet das im Feld `session_id`; der Client haengte die Antwort
//          trotzdem an die Unterhaltung, die es nicht mehr gibt.
//   P5-02  /rezept schickte `user_context` (Gewicht, Zielgewicht, Tagesbilanz,
//          Namen der heute geloggten Lebensmittel) mit, obwohl
//          `handleRecipeMode` den Parameter gar nicht entgegennimmt.
//   P5-03  Das Eingabefeld hatte keinen Deckel. Ab 1000 Zeichen lehnte der
//          Server mit 413 ab — nach dem Absenden, also mit geleertem Feld, und
//          die eigene Blase war als blankes `Text` nicht mal markierbar:
//          Abtippen war der einzige Weg zurueck.
//   P5-04  Weder `send` noch `requestRecipe` hatten eine Frist. Eine haengende
//          Antwort liess `_laufendeSendungen > 0` stehen: Senden, Mikrofon,
//          Anhang und Wiederholen waren tot, ohne Abbruchmoeglichkeit.
//   P5-06  Das Tageslimit stand zweimal: `claim_chat_quota` erzwingt
//          COACH_DAILY_LIMIT, `get_chat_quota_today` rechnet `remaining` gegen
//          den Wert, den der CLIENT uebergibt (harte 5).
//   P5-06b Der Fix zu P5-06 machte den Composer bei ANGENOMMENEM Limit wieder
//          tippbar, die Anzeige zog nicht nach: der Platzhalter sagte weiter
//          „Limit fuer heute erreicht" ueber einem Feld, das Text annimmt.

const Size _flaeche = Size(402, 781);

DateTime _t(int minute) => DateTime(2026, 8, 29, 10, minute);

// ---------------------------------------------------------------------------
// Test-Doubles auf dem echten Service (P5-01, P5-02)
// ---------------------------------------------------------------------------

/// Coach-Double: liefert Sessions/Verlauf lokal und protokolliert, mit welcher
/// Session der Verlauf geladen und welcher Kontext an /rezept gereicht wurde.
class _NotizCoach extends CoachChatService {
  _NotizCoach(super.client, super.userId);

  static _NotizCoach create() {
    final client = SupabaseClient(
      'https://example.supabase.co',
      'test-anon-key',
      httpClient: MockClient((req) async => http.Response('[]', 200)),
    );
    client.auth.stopAutoRefresh();
    return _NotizCoach(client, 'user-123');
  }

  /// Session, die der SERVER in seiner Antwort nennt.
  String antwortSessionId = 's-alt';

  final List<String> verlaufAufrufe = <String>[];

  /// Was der Screen an `requestRecipe` durchgereicht hat. `#nichts` heisst:
  /// die Methode wurde noch nicht gerufen.
  Object? rezeptKontext = #nichts;
  Object? chatKontext = #nichts;

  @override
  Future<List<ChatSession>> loadSessions() async => <ChatSession>[
        ChatSession(
          id: 's-alt',
          title: 'Alte Unterhaltung',
          createdAt: _t(0),
          lastMessageAt: _t(5),
          messageCount: 0,
        ),
        ChatSession(
          id: 's-default',
          title: 'Neue Unterhaltung',
          createdAt: _t(0),
          lastMessageAt: _t(1),
          messageCount: 2,
        ),
      ];

  @override
  Future<String?> ensureDefaultSession() async => 's-default';

  @override
  Future<List<ChatMessage>> loadHistory(
    String sessionId, {
    int limit = 100,
  }) async {
    verlaufAufrufe.add(sessionId);
    if (sessionId != 's-default') return const <ChatMessage>[];
    return <ChatMessage>[
      ChatMessage(
        id: 'm1',
        role: ChatRole.user,
        content: 'Wie viel Protein brauche ich?',
        createdAt: _t(1),
      ),
      ChatMessage(
        id: 'm2',
        role: ChatRole.assistant,
        content: 'Etwa 1,6 g pro Kilo.',
        createdAt: _t(2),
      ),
    ];
  }

  @override
  Future<ChatQuotaSnapshot> loadQuotaToday() async =>
      const ChatQuotaSnapshot(used: 0, remaining: 5, dailyLimit: 5);

  @override
  Future<CoachChatReply> send(
    String message, {
    required String sessionId,
    String? imageBase64,
    String? imageMimeType,
    String? userContext,
    void Function(String text)? onPartialReply,
  }) async {
    chatKontext = userContext;
    return CoachChatReply(
      reply: 'Antwort vom Coach.',
      refusal: false,
      remaining: 4,
      dailyLimit: 5,
      sessionId: antwortSessionId,
    );
  }

  @override
  Future<CoachRecipeReply> requestRecipe(
    String wish, {
    required String sessionId,
    required String locale,
    // Bleibt als optionaler Zusatzparameter stehen, damit die Notiz auch dann
    // funktioniert, wenn die Basisklasse ihn nicht mehr kennt.
    String? userContext,
  }) async {
    rezeptKontext = userContext;
    return CoachRecipeReply(
      reply: 'Rezeptvorschlag: Bowl.',
      refusal: false,
      proposal: const CoachRecipeProposal(
        title: 'Bowl',
        description: 'Schnell und proteinreich.',
        portion: '1 Portion',
        ingredients: '- 200 g Kichererbsen',
        preparation: '1. Alles mischen.',
        caloriesKcal: 480,
        proteinG: 26,
        carbsG: 55,
        fatG: 14,
        estimatedGrams: 400,
      ),
      remaining: 4,
      dailyLimit: 5,
      sessionId: antwortSessionId,
    );
  }
}

Future<void> _pumpCoach(
  WidgetTester tester, {
  required CoachChatService service,
  String? userContext,
}) async {
  await pumpLocalized(
    tester,
    CoachChatScreen(service: service, userName: 'M', userContext: userContext),
    surfaceSize: _flaeche,
    reducedMotion: false,
  );
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump(const Duration(milliseconds: 500));
}

Future<void> _sende(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const ValueKey('coach-input')), text);
  await tester.pump();
  await tester.tap(find.byKey(const ValueKey('coach-send')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump(const Duration(milliseconds: 500));
}

// ---------------------------------------------------------------------------
// Echter Service auf einem MockClient (P5-04, P5-06)
// ---------------------------------------------------------------------------

/// `request:` ist Pflicht: `PostgrestBuilder._parseResponse` dereferenziert
/// `response.request!`.
http.Response _json(http.Request req, Object? body, int status) => http.Response(
      jsonEncode(body),
      status,
      request: req,
      headers: const {'Content-Type': 'application/json'},
    );

/// Gefaelschtes Supabase-Backend fuer die Pfade, die der Coach wirklich ruft.
class _Backend {
  _Backend({this.quotaZeile = const {'used': 0, 'remaining': 5, 'daily_limit': 5}});

  Map<String, Object?> quotaZeile;

  /// Wird nie erfuellt: die Edge Function antwortet einfach nicht mehr.
  final Completer<http.Response> _haengt = Completer<http.Response>();

  /// true: `coach-chat` haengt. false: normale Antwort.
  bool funktionHaengt = false;

  /// Antwort der Edge Function, wenn sie antwortet.
  Map<String, Object?> funktionsAntwort = const {
    'reply': 'Klar, mach das.',
    'refusal': false,
    'remaining': 7,
    'daily_limit': 10,
    'session_id': 's1',
  };

  /// Jeder `p_daily_limit`, den der Client an `get_chat_quota_today` gereicht
  /// hat — in Aufrufreihenfolge.
  final List<Object?> quotaLimits = <Object?>[];

  http.Client client() => MockClient(_handle);

  Future<http.Response> _handle(http.Request req) async {
    final path = req.url.path;
    if (path.endsWith('/rpc/get_chat_quota_today')) {
      final body = jsonDecode(req.body);
      quotaLimits.add(body is Map ? body['p_daily_limit'] : null);
      return _json(req, [quotaZeile], 200);
    }
    if (path.endsWith('/rpc/ensure_default_chat_session')) {
      return _json(req, 's1', 200);
    }
    if (path.endsWith('/rpc/list_chat_sessions')) return _json(req, <dynamic>[], 200);
    if (path.contains('coach-chat')) {
      if (funktionHaengt) return _haengt.future;
      return _json(req, funktionsAntwort, 200);
    }
    return _json(req, <dynamic>[], 200);
  }
}

CoachChatService _echterService(_Backend backend) {
  final client = SupabaseClient(
    'https://example.supabase.co',
    'test-anon-key',
    httpClient: backend.client(),
  );
  client.auth.stopAutoRefresh();
  return CoachChatService(client, 'user-123');
}

bool _composerTippbar(WidgetTester tester) =>
    tester.widget<TextField>(find.byKey(const ValueKey('coach-input'))).enabled ??
    true;

/// Was WIRKLICH im Feld steht — nicht, was hineingetippt wurde.
String _feldText(WidgetTester tester) => tester
    .widget<TextField>(find.byKey(const ValueKey('coach-input')))
    .controller!
    .text;

bool _sendenAktiv(WidgetTester tester) =>
    tester
        .widget<GestureDetector>(find.byKey(const ValueKey('coach-send')))
        .onTap !=
    null;

/// Diktat, das laenger zurueckkommt als der Server annimmt.
///
/// Die Spracheingabe schreibt den Controller direkt — der einzige Weg, an den
/// inputFormattern des Feldes vorbei in den Entwurf zu kommen.
class _LangesDiktat extends CoachSpeechInput {
  const _LangesDiktat();

  static const int laenge = 1200;

  @override
  Future<String?> listen({
    String localeId = 'de_DE',
    required AppLocalizations l10n,
  }) async =>
      'a' * laenge;
}

void main() {
  group('P5-01 · der Client folgt der Session, die der Server benutzt hat', () {
    testWidgets(
        'meldet der Server eine andere session_id, wandert die Anzeige dorthin '
        'und sagt es', (tester) async {
      final coach = _NotizCoach.create()..antwortSessionId = 's-default';
      await _pumpCoach(tester, service: coach);

      expect(coach.verlaufAufrufe, <String>['s-alt'],
          reason: 'Bootstrap oeffnet die neueste Unterhaltung');

      await _sende(tester, 'Wie viel Protein brauche ich?');

      expect(
        find.text(
          'Diese Unterhaltung gibt es nicht mehr. Deine Frage und die Antwort '
          'stehen jetzt in einer anderen Unterhaltung — sie ist geöffnet.',
        ),
        findsOneWidget,
        reason: 'sonst glaubt der Nutzer, sein Beitrag stehe in s-alt',
      );
      expect(coach.verlaufAufrufe, contains('s-default'),
          reason: 'die tatsaechlich benutzte Unterhaltung wird nachgeladen');
      expect(find.text('Etwa 1,6 g pro Kilo.'), findsOneWidget,
          reason: 'angezeigt wird jetzt der Verlauf der Server-Session');
    });

    testWidgets('gleiche session_id: kein Hinweis, kein Nachladen',
        (tester) async {
      final coach = _NotizCoach.create()..antwortSessionId = 's-alt';
      await _pumpCoach(tester, service: coach);

      await _sende(tester, 'Hi Coach');

      expect(coach.verlaufAufrufe, <String>['s-alt']);
      expect(find.textContaining('gibt es nicht mehr'), findsNothing);
      expect(find.text('Antwort vom Coach.'), findsOneWidget);
    });
  });

  group('P5-02 · /rezept schickt keine Gesundheitsdaten mehr', () {
    testWidgets('der Screen reicht keinen user_context an requestRecipe',
        (tester) async {
      final coach = _NotizCoach.create()..antwortSessionId = 's-alt';
      await _pumpCoach(
        tester,
        service: coach,
        userContext: 'Gewicht 82 kg, Ziel 78 kg, heute 1420 kcal, Haferflocken',
      );

      await _sende(tester, '/recipe Bowl mit Kichererbsen');

      expect(coach.rezeptKontext, isNot(#nichts),
          reason: 'requestRecipe muss ueberhaupt gelaufen sein');
      expect(coach.rezeptKontext, isNull,
          reason: 'handleRecipeMode nimmt den Parameter gar nicht entgegen — '
              'gesendet wuerden Gewicht, Zielgewicht, Tagesbilanz und die '
              'Namen der heute geloggten Lebensmittel');
    });

    testWidgets('der normale Chat behaelt seinen Kontext (Gegenprobe)',
        (tester) async {
      final coach = _NotizCoach.create()..antwortSessionId = 's-alt';
      await _pumpCoach(tester, service: coach, userContext: 'Gewicht 82 kg');

      await _sende(tester, 'Wie viel Protein?');

      expect(coach.chatKontext, 'Gewicht 82 kg',
          reason: 'im Chat-Modus liest der Server den Kontext wirklich');
    });

    test('der Rezept-Rumpf traegt genau vier Felder', () async {
      Map<String, dynamic> rumpf = const <String, dynamic>{};
      final client = SupabaseClient(
        'https://example.supabase.co',
        'test-anon-key',
        httpClient: MockClient((req) async {
          if (req.url.path.contains('coach-chat')) {
            rumpf = (jsonDecode(req.body) as Map).cast<String, dynamic>();
          }
          return _json(req, {
            'reply': 'Rezept.',
            'refusal': false,
            'recipe': {
              'title': 'Bowl',
              'description': 'x',
              'portion': '1',
              'ingredients': '- a',
              'preparation': '1. b',
              'calories_kcal': 400,
              'protein_g': 20,
              'carbs_g': 40,
              'fat_g': 10,
              'estimated_grams': 350,
            },
          }, 200);
        }),
      );
      client.auth.stopAutoRefresh();
      addTearDown(client.dispose);

      await CoachChatService(client, 'user-123')
          .requestRecipe('Bowl', sessionId: 's1', locale: 'de');

      expect(rumpf.keys.toSet(),
          <String>{'message', 'mode', 'locale', 'session_id'});
      expect(rumpf.containsKey('user_context'), isFalse);
    });
  });

  group('P5-03 · der Client haelt die Eingabegrenze des Servers ein', () {
    testWidgets('das Feld nimmt genau 1000 Zeichen — und keins mehr',
        (tester) async {
      await _pumpCoach(tester, service: _NotizCoach.create());
      final feld = find.byKey(const ValueKey('coach-input'));

      await tester.enterText(feld, 'a' * kCoachMaxInputChars);
      await tester.pump();
      expect(_feldText(tester).length, kCoachMaxInputChars,
          reason: 'die Grenze selbst muss noch hineingehen');

      await tester.enterText(feld, 'a' * (kCoachMaxInputChars + 1));
      await tester.pump();
      expect(_feldText(tester).length, kCoachMaxInputChars,
          reason: 'ohne Deckel ging das Zeichen durch und der Server '
              'antwortete mit 413 — auf ein Feld, das schon geleert war');
    });

    testWidgets('der sichtbare Grund steht ueber dem Feld', (tester) async {
      await _pumpCoach(tester, service: _NotizCoach.create());
      final feld = find.byKey(const ValueKey('coach-input'));

      expect(find.byKey(const ValueKey('coach-length-hint')), findsNothing,
          reason: 'ein Dauerzaehler waere Gemecker an jeder kurzen Frage');

      await tester.enterText(feld, 'a' * 950);
      await tester.pump();
      expect(find.text('950/1000 Zeichen'), findsOneWidget);

      await tester.enterText(feld, 'a' * kCoachMaxInputChars);
      await tester.pump();
      expect(find.text('Maximale Länge erreicht (1000 Zeichen)'), findsOneWidget,
          reason: 'ab hier schluckt das Feld Tasten — ohne genannten Grund '
              'sieht das nach einem kaputten Feld aus');
    });

    testWidgets(
        'ein zu langes Diktat kommt am Feld vorbei — der Senden-Knopf bleibt '
        'trotzdem aus', (tester) async {
      // Das Mikrofon rendert nur auf iOS. Reset im `finally`: das Binding
      // prueft die foundation-Variablen vor den tearDowns.
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        await pumpLocalized(
          tester,
          CoachChatScreen(
            service: _NotizCoach.create(),
            userName: 'M',
            speechInput: const _LangesDiktat(),
          ),
          surfaceSize: _flaeche,
          reducedMotion: false,
        );
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump(const Duration(milliseconds: 500));

        await tester.tap(find.byKey(const ValueKey('coach-mic')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));

        expect(_feldText(tester).length, _LangesDiktat.laenge,
            reason: 'die Spracheingabe schreibt den Controller direkt');
        expect(
            find.text('Maximale Länge erreicht (1000 Zeichen)'), findsOneWidget);
        expect(_sendenAktiv(tester), isFalse,
            reason: 'der garantierte 413 wuerde beide Rate-Limit-Fenster '
                'kosten und das Feld dabei leeren');

        // Kuerzen muss weiter gehen, sonst waere das Feld eine Sackgasse.
        await tester.enterText(
            find.byKey(const ValueKey('coach-input')), 'kurze Frage');
        await tester.pump();
        expect(_feldText(tester), 'kurze Frage');
        expect(_sendenAktiv(tester), isTrue);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('die eigene Blase ist auswaehlbar wie die des Coachs',
        (tester) async {
      final coach = _NotizCoach.create()..antwortSessionId = 's-alt';
      await _pumpCoach(tester, service: coach);
      await _sende(tester, 'Wie sieht mein Tag aus?');

      Finder inAuswahl(String text) => find.ancestor(
            of: find.text(text),
            matching: find.byType(SelectionArea),
          );
      expect(inAuswahl('Antwort vom Coach.'), findsOneWidget,
          reason: 'Gegenprobe: die Coach-Blase konnte das schon');
      expect(inAuswahl('Wie sieht mein Tag aus?'), findsOneWidget,
          reason: 'nach dem Absenden ist die eigene Blase die einzige Kopie '
              'des Textes — als blankes Text blieb nur Abtippen');
    });
  });

  group('P5-04 · Coach-Anfragen haben eine Frist', () {
    testWidgets(
        'eine nie aufloesende Antwort endet in einer lesbaren Meldung und '
        'einem wieder bedienbaren Composer', (tester) async {
      final backend = _Backend()..funktionHaengt = true;
      final svc = _echterService(backend);
      await pumpLocalized(
        tester,
        CoachChatScreen(service: svc, userName: 'M'),
        surfaceSize: _flaeche,
        reducedMotion: false,
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));

      await tester.enterText(
          find.byKey(const ValueKey('coach-input')), 'Hallo Coach');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('coach-send')));
      await tester.pump();

      // Unterwegs: nichts geht, und genau das war der Befund.
      expect(find.byKey(const ValueKey('coach-unsent-retry')), findsNothing);

      // Ueber jede Frist hinaus (Chat: 75 s + Puffer).
      await tester.pump(const Duration(seconds: 120));
      await tester.pump(const Duration(milliseconds: 500));

      expect(
        find.text('Der Coach hat zu lange gebraucht. Bitte versuch es nochmal.'),
        findsOneWidget,
        reason: 'ohne Frist laeuft der Future, bis das OS die Verbindung raeumt',
      );
      expect(find.byKey(const ValueKey('coach-unsent-retry')), findsOneWidget,
          reason: 'der Wiederholen-Knopf haengt an _canInteract — er beweist, '
              'dass _laufendeSendungen wieder 0 ist');
      expect(_composerTippbar(tester), isTrue);
    });
  });

  group('P5-06 · das Tageslimit kommt vom Server', () {
    testWidgets(
        'ein nur ANGENOMMENES Limit sperrt den Composer nicht', (tester) async {
      // Der Server laeuft mit COACH_DAILY_LIMIT=10, die RPC rechnet aber gegen
      // die 5, die der Client uebergibt -> remaining 0, obwohl noch fuenf
      // Slots frei sind.
      final backend = _Backend(
        quotaZeile: const {'used': 5, 'remaining': 0, 'daily_limit': 5},
      );
      final svc = _echterService(backend);
      await pumpLocalized(
        tester,
        CoachChatScreen(service: svc, userName: 'M'),
        surfaceSize: _flaeche,
        reducedMotion: false,
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));

      expect(_composerTippbar(tester), isTrue,
          reason: 'der Client kennt COACH_DAILY_LIMIT nicht — im Zweifel darf '
              'er nicht sperren, der Server lehnt notfalls mit 429 ab');
    });

    testWidgets(
        'P5-06b · … und der Platzhalter behauptet dann auch nicht mehr, das '
        'Limit sei erreicht', (tester) async {
      final backend = _Backend(
        quotaZeile: const {'used': 5, 'remaining': 0, 'daily_limit': 5},
      );
      await pumpLocalized(
        tester,
        CoachChatScreen(service: _echterService(backend), userName: 'M'),
        surfaceSize: _flaeche,
        reducedMotion: false,
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));

      expect(_composerTippbar(tester), isTrue);
      expect(find.text('Limit für heute erreicht'), findsNothing,
          reason: 'das Feld nimmt Text an — der Platzhalter darf nicht das '
              'Gegenteil behaupten. Die 0 stammt aus einer Annahme, nicht '
              'vom Server');
      expect(find.text('Frag den KI-Coach…'), findsOneWidget);
      expect(find.byKey(const ValueKey('coach-quota-hint')), findsNothing);
    });

    testWidgets(
        'Gegenprobe: nennt der Server sein Limit, sagt der Platzhalter es auch',
        (tester) async {
      final backend = _Backend(
        quotaZeile: const {'used': 5, 'remaining': 0, 'daily_limit': 5},
      );
      // Ein Limit, das die Edge Function selbst genannt hat — ab hier ist die
      // 0 eine Aussage und keine Rechnung gegen die eigene Annahme.
      final svc = _echterService(backend)..serverDailyLimit = 5;
      await pumpLocalized(
        tester,
        CoachChatScreen(service: svc, userName: 'M'),
        surfaceSize: _flaeche,
        reducedMotion: false,
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));

      expect(_composerTippbar(tester), isFalse);
      expect(find.text('Limit für heute erreicht'), findsOneWidget,
          reason: 'hier gehoert die Meldung hin — sonst waere der Fix eine '
              'Loeschung statt eines Nachzugs');
    });

    test('nach der ersten Server-Antwort fragt die RPC mit dem Server-Limit',
        () async {
      final backend = _Backend();
      final svc = _echterService(backend);

      await svc.loadQuotaToday();
      expect(backend.quotaLimits, <Object?>[5],
          reason: 'vor der ersten Antwort bleibt nur die Annahme');

      // Der Server nennt sein Limit in der Antwort der Edge Function.
      await svc.send('Hi', sessionId: 's1');
      await svc.loadQuotaToday();

      expect(backend.quotaLimits.last, 10,
          reason: 'die harte 5 aus ChatQuotaSnapshot.standardTageslimit war '
              'die zweite Wahrheit neben COACH_DAILY_LIMIT');
    });
  });
}
