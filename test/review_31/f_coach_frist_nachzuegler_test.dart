import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/screens/coach/coach_chat_screen.dart';
import 'package:eatova/src/services/coach_chat_service.dart';

import '../support/harness.dart';

// Review 2026-08-31, Paket F — coach_chat_service.dart:74.
//
// Die 75-s-Frist brach Sendevorgaenge ab, die der Server noch zu Ende brachte.
// `coach-chat` beansprucht den nicht erstattungsfaehigen Tagesslot VOR dem
// ersten Anbieter-Aufruf und hat kein Gesamtbudget: gedeckelt sind nur die zwei
// Provider-Runden (PROVIDER_TIMEOUTS_MS: 15 s + 45 s). Upload, zehn ungedeckelte
// PostgREST-Hops und die Antwort kamen obendrauf — 14 s Upload plus voll
// ausgeschoepfte Deckel ergaben ~76 s. Ergebnis: Slot verbrannt, Frage und
// Antwort in der Historie, im Client aber „Nicht gesendet" mit Wiederholen —
// und der Wiederholungsversuch beanspruchte den ZWEITEN von fuenf Tagesslots
// und schrieb den Austausch ein zweites Mal in den Verlauf.
//
// Festgenagelt wird beides:
//   1. Ein Server, der 85 s braucht, wird nicht mehr abgeschnitten. Die Zahlen
//      dieses Falls sind aus `CoachChatService.chatDeadline` ABGELEITET — wer
//      die Konstante auf 75 s zurueckdreht, macht den Test rot.
//   2. Wo der Server durchlief, liefert `send` die gespeicherte Antwort statt
//      der Fehlermeldung: es gibt keinen Wiederholen-Knopf, also keinen
//      zweiten Slot.
//   3. Der echte Zeitueberschreitungsfall (Server antwortet nie, nichts
//      gespeichert) meldet weiter „zu lange gebraucht" — mit Wiederholen.

const String _timeoutText =
    'Der Coach hat zu lange gebraucht. Bitte versuch es nochmal.';

const Size _flaeche = Size(402, 781);

/// Massstab fuer die Zeitfaelle: 1 s Produktionszeit = 25 ms hier.
///
/// Die echten Fristen sind Minuten lang, kein Test kann sie aussitzen. Die
/// Faelle rechnen deshalb dieselbe Aufstellung im Kleinen — aber mit Zahlen,
/// die aus den echten Konstanten stammen, damit eine geaenderte Konstante den
/// Fall veraendert statt ihn zu verfehlen.
Duration _skala(Duration echt) => Duration(milliseconds: echt.inSeconds * 25);

// ---------------------------------------------------------------------------
// Gefaelschtes Supabase-Backend
// ---------------------------------------------------------------------------

/// Bedient die Endpunkte, die der Fristpfad wirklich anfasst: die Edge Function
/// `coach-chat` und den Verlauf in `chat_messages`.
///
/// Bewusst `MockClient.streaming`: nur diese Form reicht dem Handler die
/// ORIGINAL-Anfrage durch, und nur die traegt den `abortTrigger`. Der einfache
/// `MockClient` bricht nie von selbst ab (seine eigene Doku ueberlaesst das dem
/// Handler) — der Test wuerde sonst den aeusseren `timeout` messen statt des
/// Abbruchsignals, das auf dem Geraet zuerst greift.
class _Backend {
  _Backend({
    this.antwortNach,
    this.verlauf = const <Map<String, Object?>>[],
    this.verlaufStatus = 200,
  });

  /// Wie lange die Edge Function bis zur Antwort braucht. null = sie antwortet
  /// nie.
  Duration? antwortNach;

  /// Zeilen aus `chat_messages`, NEUESTE ZUERST — die Reihenfolge, die
  /// loadHistory anfragt.
  List<Map<String, Object?>> verlauf;

  int verlaufStatus;

  Map<String, Object?> funktionsAntwort = const <String, Object?>{
    'reply': 'Etwa 1,6 g pro Kilo.',
    'refusal': false,
    'remaining': 4,
    'daily_limit': 5,
    'session_id': 's1',
  };

  int funktionsAufrufe = 0;
  int verlaufAufrufe = 0;

  http.Client client() => MockClient.streaming(_handle);

  Future<http.StreamedResponse> _handle(
    http.BaseRequest req,
    http.ByteStream koerper,
  ) async {
    await koerper.drain<void>();
    final pfad = req.url.path;
    if (pfad.contains('coach-chat')) {
      funktionsAufrufe++;
      await _wartenOderAbbrechen(req);
      return _antwort(req, funktionsAntwort, 200);
    }
    if (pfad.endsWith('/rest/v1/chat_messages')) {
      verlaufAufrufe++;
      return _antwort(req, verlauf, verlaufStatus);
    }
    if (pfad.endsWith('/rpc/ensure_default_chat_session')) {
      return _antwort(req, 's1', 200);
    }
    if (pfad.endsWith('/rpc/get_chat_quota_today')) {
      return _antwort(req, const <Map<String, Object?>>[
        <String, Object?>{'used': 0, 'remaining': 5, 'daily_limit': 5},
      ], 200);
    }
    return _antwort(req, const <dynamic>[], 200);
  }

  /// Verhaelt sich wie `IOClient` auf dem Geraet: antwortet nach [antwortNach]
  /// oder wirft, sobald der `abortTrigger` des Clients feuert.
  Future<void> _wartenOderAbbrechen(http.BaseRequest req) {
    final wartezeit = antwortNach;
    final antwort = wartezeit == null
        ? Completer<void>().future
        : Future<void>.delayed(wartezeit);
    Future<void>? abbruch;
    if (req is http.Abortable) abbruch = req.abortTrigger;
    if (abbruch == null) return antwort;
    return Future.any(<Future<void>>[
      antwort,
      abbruch.then<void>((_) => throw http.RequestAbortedException(req.url)),
    ]);
  }

  /// `request:` ist Pflicht: `PostgrestBuilder._parseResponse` dereferenziert
  /// `response.request!`.
  http.StreamedResponse _antwort(
    http.BaseRequest req,
    Object? koerper,
    int status,
  ) {
    final bytes = utf8.encode(jsonEncode(koerper));
    return http.StreamedResponse(
      http.ByteStream.fromBytes(bytes),
      status,
      contentLength: bytes.length,
      request: req,
      headers: const <String, String>{'content-type': 'application/json'},
    );
  }
}

/// [entsorgen] `false` fuer Widget-Tests: `dispose()` wartet auf den
/// JSON-Isolate von `SupabaseClient`, und der wird unter der FakeAsync-Uhr
/// eines Widget-Tests nie fertig gestartet.
CoachChatService _service(
  _Backend backend, {
  Duration? chatFrist,
  Duration? rezeptFrist,
  bool entsorgen = true,
}) {
  final client = SupabaseClient(
    'https://example.supabase.co',
    'test-anon-key',
    httpClient: backend.client(),
  );
  client.auth.stopAutoRefresh();
  if (entsorgen) addTearDown(client.dispose);
  return CoachChatService(
    client,
    'user-123',
    chatFrist: chatFrist,
    rezeptFrist: rezeptFrist,
  );
}

/// Frage plus Antwort, wie der Server sie geschrieben haette — neueste Zeile
/// zuerst, weil loadHistory absteigend sortiert und danach umdreht.
List<Map<String, Object?>> _austausch({
  required String frage,
  required String antwort,
  DateTime? wann,
  bool refusal = false,
  Map<String, Object?>? rezept,
}) {
  final t = wann ?? DateTime.now().toUtc();
  return <Map<String, Object?>>[
    <String, Object?>{
      'id': 'm-antwort',
      'role': 'assistant',
      'content': antwort,
      'refusal': refusal,
      'created_at': t.toIso8601String(),
      'recipe': rezept,
    },
    <String, Object?>{
      'id': 'm-frage',
      'role': 'user',
      'content': frage,
      'refusal': false,
      'created_at': t.subtract(const Duration(seconds: 1)).toIso8601String(),
      'recipe': null,
    },
  ];
}

const Map<String, Object?> _rezeptZeile = <String, Object?>{
  'title': 'Bowl',
  'description': 'Schnell und proteinreich.',
  'portion': '1 Portion',
  'ingredients': '- 200 g Kichererbsen',
  'preparation': '1. Alles mischen.',
  'calories_kcal': 480,
  'protein_g': 26,
  'carbs_g': 55,
  'fat_g': 14,
  'estimated_g': 400,
};

void main() {
  group('F · die Frist deckt jetzt den echten Server-Worst-Case', () {
    test(
        'Server antwortet nach 85 s — knapp ueber der alten 75-s-Frist: die '
        'Antwort kommt an, statt als „nicht gesendet" zu gelten', () async {
      // Der Verlauf bleibt LEER: nur die Frist selbst darf diesen Fall retten,
      // nicht der Nachzuegler-Abgleich. Wer chatDeadline auf 75 s
      // zurueckdreht, laesst den Abbruch vor der Antwort feuern — und weil es
      // nichts abzugleichen gibt, wird daraus die Zeitueberschreitung.
      final backend = _Backend(antwortNach: Duration.zero);
      final svc = _service(
        backend,
        chatFrist: _skala(CoachChatService.chatDeadline),
      );

      // Erst den JSON-Isolate von SupabaseClient warmlaufen lassen: sein
      // erster Start kostet unter Last dreistellige Millisekunden, und die
      // gingen sonst vom gemessenen Abstand zwischen Antwort (85 s) und Frist
      // (95 s) ab.
      await svc.send('Aufwaermen', sessionId: 's1');
      backend
        ..antwortNach = _skala(const Duration(seconds: 85))
        ..funktionsAufrufe = 0
        ..verlaufAufrufe = 0;

      final res = await svc.send('Wie viel Protein?', sessionId: 's1');

      expect(res.reply, 'Etwa 1,6 g pro Kilo.');
      expect(res.remaining, 4);
      expect(backend.verlaufAufrufe, 0,
          reason: 'die Anfrage lief durch — es gab nichts abzugleichen');
    });

    test('die Fristen stehen ueber dem, was der Server ohne Gesamtbudget '
        'ausgeben kann', () {
      // coach-chat hat KEIN Request-Budget (analyze-meal hat eins: 55 s).
      // Gedeckelt sind allein die Provider-Runden aus PROVIDER_TIMEOUTS_MS.
      const chatDeckel = Duration(seconds: 15 + 45);
      const rezeptDeckel = Duration(seconds: 15 + 45 + 30);

      expect(CoachChatService.chatDeadline, const Duration(seconds: 95));
      expect(CoachChatService.recipeDeadline, const Duration(seconds: 135));

      expect(
        CoachChatService.chatDeadline - chatDeckel,
        greaterThanOrEqualTo(const Duration(seconds: 35)),
        reason: 'Upload (15 s), zehn ungedeckelte PostgREST-Hops (15 s) und '
            'die Antwort (5 s) sind serverseitig durch nichts begrenzt — die '
            'alten 75 s liessen dafuer nur 15 s',
      );
      expect(
        CoachChatService.recipeDeadline - rezeptDeckel,
        greaterThanOrEqualTo(const Duration(seconds: 35)),
        reason: 'bei /rezept kommt das base64-Bild zurueck; die alten 120 s '
            'liessen fuer alles Nicht-Provider nur 30 s',
      );
    });
  });

  group('F · Nachzuegler: was der Server zu Ende brachte, kostet keinen '
      'zweiten Slot', () {
    test('stummer Server, Austausch aber gespeichert: send liefert die '
        'Antwort statt der Fehlermeldung', () async {
      final backend = _Backend(
        antwortNach: null,
        verlauf: _austausch(
          frage: 'Wie viel Protein?',
          antwort: 'Etwa 1,6 g pro Kilo.',
        ),
      );
      final svc = _service(backend, chatFrist: const Duration(milliseconds: 30));

      final res = await svc.send('Wie viel Protein?', sessionId: 's1');

      expect(res.reply, 'Etwa 1,6 g pro Kilo.');
      expect(res.sessionId, 's1');
      expect(res.refusal, isFalse);
      expect(backend.funktionsAufrufe, 1,
          reason: 'genau EIN claim_chat_quota — der zweite der fuenf '
              'Tagesslots ist das Schutzgut');
      expect(res.remaining, isNull,
          reason: 'der Zaehler ist hier unbekannt; eine erfundene Zahl waere '
              'schlimmer als die alte Anzeige, die der Screen behaelt');
      expect(res.dailyLimit, isNull);
    });

    test('eine gespeicherte Ablehnung bleibt eine Ablehnung', () async {
      final backend = _Backend(
        antwortNach: null,
        verlauf: _austausch(
          frage: 'Wie werde ich 10 kg in einer Woche los?',
          antwort: 'Dazu sage ich nichts.',
          refusal: true,
        ),
      );
      final svc = _service(backend, chatFrist: const Duration(milliseconds: 30));

      final res = await svc.send(
        'Wie werde ich 10 kg in einer Woche los?',
        sessionId: 's1',
      );

      expect(res.refusal, isTrue,
          reason: 'sonst raendert der Screen eine Ablehnung wie eine Antwort');
    });

    test('gespeichert ist eine ANDERE Frage: die Zeitueberschreitung bleibt',
        () async {
      final backend = _Backend(
        antwortNach: null,
        verlauf: _austausch(
          frage: 'Wie viele Kohlenhydrate?',
          antwort: 'Rund 3 g pro Kilo.',
        ),
      );
      final svc = _service(backend, chatFrist: const Duration(milliseconds: 30));

      await expectLater(
        svc.send('Wie viel Protein?', sessionId: 's1'),
        throwsA(isA<CoachChatException>()
            .having((e) => e.message, 'message', _timeoutText)),
      );
    });

    test('derselbe Wortlaut, aber Stunden alt: kein Wiederabspielen einer '
        'alten Antwort', () async {
      final backend = _Backend(
        antwortNach: null,
        verlauf: _austausch(
          frage: 'Wie viel Protein?',
          antwort: 'Etwa 1,6 g pro Kilo.',
          wann: DateTime.now().toUtc().subtract(const Duration(hours: 3)),
        ),
      );
      final svc = _service(backend, chatFrist: const Duration(milliseconds: 30));

      await expectLater(
        svc.send('Wie viel Protein?', sessionId: 's1'),
        throwsA(isA<CoachChatException>()
            .having((e) => e.message, 'message', _timeoutText)),
        reason: 'dieselbe Frage von heute Morgen ist nicht die Antwort auf '
            'diese hier',
      );
    });

    test('nur die Frage steht im Verlauf, keine Antwort: '
        'Zeitueberschreitung', () async {
      final backend = _Backend(
        antwortNach: null,
        verlauf: <Map<String, Object?>>[
          <String, Object?>{
            'id': 'm-frage',
            'role': 'user',
            'content': 'Wie viel Protein?',
            'refusal': false,
            'created_at': DateTime.now().toUtc().toIso8601String(),
            'recipe': null,
          },
        ],
      );
      final svc = _service(backend, chatFrist: const Duration(milliseconds: 30));

      await expectLater(
        svc.send('Wie viel Protein?', sessionId: 's1'),
        throwsA(isA<CoachChatException>()
            .having((e) => e.message, 'message', _timeoutText)),
      );
    });

    test('der Verlauf selbst ist nicht abrufbar: die Zeitueberschreitung '
        'bleibt stehen, kein CoachDataUnavailable nach aussen', () async {
      final backend = _Backend(antwortNach: null, verlaufStatus: 500);
      final svc = _service(backend, chatFrist: const Duration(milliseconds: 30));

      await expectLater(
        svc.send('Wie viel Protein?', sessionId: 's1'),
        throwsA(allOf(
          isA<CoachChatException>()
              .having((e) => e.message, 'message', _timeoutText),
          isNot(isA<CoachDataUnavailable>()),
        )),
        reason: 'fehlender Beweis ist kein Beweis des Gegenteils',
      );
    });

    test('Server antwortet gar nicht und hat nichts gespeichert: weiterhin '
        'die Zeitueberschreitung (Regression)', () async {
      final backend = _Backend(antwortNach: null);
      final svc = _service(backend, chatFrist: const Duration(milliseconds: 30));

      await expectLater(
        svc.send('Wie viel Protein?', sessionId: 's1'),
        throwsA(isA<CoachChatException>()
            .having((e) => e.message, 'message', _timeoutText)),
      );
      expect(backend.verlaufAufrufe, 1,
          reason: 'genau ein Abgleich, keine Warteschleife');
    });
  });

  group('F · /rezept: derselbe Slot, derselbe Abgleich', () {
    test('stummer Server, Rezept aber gespeichert: die Karte kommt aus dem '
        'Verlauf — ohne Bild, mit Server-Id', () async {
      final backend = _Backend(
        antwortNach: null,
        verlauf: _austausch(
          frage: 'Bowl mit Kichererbsen',
          antwort: 'Bowl — 480 kcal',
          rezept: _rezeptZeile,
        ),
      );
      final svc =
          _service(backend, rezeptFrist: const Duration(milliseconds: 30));

      final res = await svc.requestRecipe(
        'Bowl mit Kichererbsen',
        sessionId: 's1',
        locale: 'de',
      );

      expect(res.proposal?.title, 'Bowl');
      expect(res.proposal?.caloriesKcal, 480);
      expect(res.proposal?.imageBytes, isNull,
          reason: 'Bildbytes werden nie persistiert — die Karte zeigt den '
              'Platzhalter, wie auf einem zweiten Geraet');
      expect(res.assistantMessageId, 'm-antwort',
          reason: 'Schluessel des lokalen Bildspeichers');
      expect(backend.funktionsAufrufe, 1);
    });

    test('gespeichert ist weder Rezept noch Ablehnung: Zeitueberschreitung',
        () async {
      final backend = _Backend(
        antwortNach: null,
        verlauf: _austausch(
          frage: 'Bowl mit Kichererbsen',
          antwort: 'Bowl — 480 kcal',
        ),
      );
      final svc =
          _service(backend, rezeptFrist: const Duration(milliseconds: 30));

      await expectLater(
        svc.requestRecipe('Bowl mit Kichererbsen',
            sessionId: 's1', locale: 'de'),
        throwsA(isA<CoachChatException>()
            .having((e) => e.message, 'message', _timeoutText)),
        reason: 'eine Zusammenfassung ohne Karte ist keine Antwort auf einen '
            'Rezeptwunsch',
      );
    });
  });

  group('F · im Screen: kein Wiederholen-Knopf, wo der Server durchlief', () {
    testWidgets('stummer Server, Austausch gespeichert: die Antwort steht im '
        'Chat und es gibt nichts zu wiederholen', (tester) async {
      final backend = _Backend(antwortNach: null);
      final svc = _service(backend, entsorgen: false);
      await pumpLocalized(
        tester,
        CoachChatScreen(service: svc, userName: 'M'),
        surfaceSize: _flaeche,
        reducedMotion: false,
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));

      await tester.enterText(
          find.byKey(const ValueKey('coach-input')), 'Wie viel Protein?');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('coach-send')));
      await tester.pump();

      // Der Server schreibt beide Zeilen, waehrend der Client noch wartet.
      backend.verlauf = _austausch(
        frage: 'Wie viel Protein?',
        antwort: 'Etwa 1,6 g pro Kilo.',
      );

      // Ueber chatDeadline plus Puffer hinaus.
      await tester.pump(const Duration(seconds: 120));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('Etwa 1,6 g pro Kilo.'), findsOneWidget);
      expect(find.text(_timeoutText), findsNothing);
      expect(find.byKey(const ValueKey('coach-unsent-retry')), findsNothing,
          reason: 'ohne Wiederholen-Knopf kann kein zweiter der fuenf '
              'Tagesslots verbrannt werden — und der Austausch landet nicht '
              'ein zweites Mal im Verlauf');
    });

    testWidgets('stummer Server, nichts gespeichert: „Nicht gesendet" mit '
        'Wiederholen bleibt (Regression)', (tester) async {
      final backend = _Backend(antwortNach: null);
      final svc = _service(backend, entsorgen: false);
      await pumpLocalized(
        tester,
        CoachChatScreen(service: svc, userName: 'M'),
        surfaceSize: _flaeche,
        reducedMotion: false,
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));

      await tester.enterText(
          find.byKey(const ValueKey('coach-input')), 'Wie viel Protein?');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('coach-send')));
      await tester.pump();

      await tester.pump(const Duration(seconds: 120));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text(_timeoutText), findsOneWidget);
      expect(find.byKey(const ValueKey('coach-unsent-retry')), findsOneWidget,
          reason: 'hier ist wirklich nichts angekommen — der Weg zurueck muss '
              'bleiben');
    });
  });
}
