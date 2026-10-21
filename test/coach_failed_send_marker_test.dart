import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/models/chat_message.dart';
import 'package:eatova/src/models/chat_session.dart';
import 'package:eatova/src/screens/coach/coach_chat_screen.dart';
import 'package:eatova/src/services/coach_chat_service.dart';

import 'support/harness.dart';

// A question that did not go out (review 2026-08-19): it stays as a bubble
// with a "not sent" marker and a retry, never a second bubble with the same
// text, and the composer stays empty so the marker is its only home.

class _FixCoach extends CoachChatService {
  _FixCoach(super.client, super.userId);

  /// `stopAutoRefresh()` is mandatory: GoTrue's constructor timer trips every
  /// widget test.
  static _FixCoach create() {
    final client = SupabaseClient(
      'https://example.supabase.co',
      'test-anon-key',
      httpClient: MockClient((req) async => http.Response('[]', 200)),
    );
    client.auth.stopAutoRefresh();
    return _FixCoach(client, 'user-123');
  }

  /// `send()` texts in order — proof the retry sends the same bits.
  final List<String> gesendeteTexte = <String>[];

  /// Pending send jobs; the test resolves them by hand.
  final List<Completer<CoachChatReply>> offen = <Completer<CoachChatReply>>[];

  @override
  Future<List<ChatSession>> loadSessions() async => <ChatSession>[
    ChatSession(
      id: 's1',
      title: 'Chat A',
      createdAt: DateTime(2026, 8, 1),
      lastMessageAt: DateTime(2026, 8, 19),
      messageCount: 1,
    ),
  ];

  @override
  Future<String?> ensureDefaultSession() async => 's1';

  @override
  Future<List<ChatMessage>> loadHistory(
    String sessionId, {
    int limit = 100,
  }) async => <ChatMessage>[
    ChatMessage(
      id: 'm-a1',
      role: ChatRole.assistant,
      content: 'Das ist der Verlauf von Sitzung A.',
      createdAt: DateTime(2026, 8, 19),
    ),
  ];

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
  }) {
    gesendeteTexte.add(message);
    final auftrag = Completer<CoachChatReply>();
    offen.add(auftrag);
    return auftrag.future;
  }
}

const Size _usableSize = Size(402, 781);

/// Motion disabled, or `pumpAndSettle` never returns while `_sending` runs.
Future<void> _pumpCoachRuhig(WidgetTester tester, _FixCoach service) async {
  tester.view.devicePixelRatio = 3.0;
  tester.view.physicalSize = _usableSize * 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await pumpLocalized(
    tester,
    CoachChatScreen(service: service, userName: 'Moritz'),
    // The coach tab owns its gutters (the shell passes no padding).
    padding: EdgeInsets.zero,
    safeArea: false,
  );
  await tester.pumpAndSettle();
}

Future<void> _tippenUndSenden(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const ValueKey('coach-input')), text);
  await tester.pump();
  await tester.tap(find.byKey(const ValueKey('coach-send')));
  await tester.pumpAndSettle();
}

String _feldText(WidgetTester tester) => tester
    .widget<TextField>(find.byKey(const ValueKey('coach-input')))
    .controller!
    .text;

/// Counts bubbles ONLY: `find.text` also matches the composer.
int _blasenMit(WidgetTester tester, String text) => tester
    .widgetList<Text>(find.byType(Text))
    .where((w) => w.data == text)
    .length;

void main() {
  testWidgets(
    'Fehlschlag: die Frage wird als „nicht gesendet" gekennzeichnet, und der '
    'Wiederholversuch ersetzt dieselbe Blase statt eine zweite anzulegen',
    (tester) async {
      final svc = _FixCoach.create();
      await _pumpCoachRuhig(tester, svc);

      const frage = 'Wie viel Protein fehlt mir heute noch?';
      await _tippenUndSenden(tester, frage);
      expect(svc.gesendeteTexte, <String>[frage]);

      svc.offen.first.completeError(
        const CoachChatException('Verbindung fehlgeschlagen.'),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('coach-unsent')),
        findsOneWidget,
        reason: 'ohne Kennzeichnung sieht die Blase aus wie abgeschickt',
      );
      expect(find.text('Verbindung fehlgeschlagen.'), findsOneWidget);
      expect(
        _feldText(tester),
        isEmpty,
        reason: 'die Frage lebt in der Blase mit „Nicht gesendet" weiter, '
            'nicht ein zweites Mal im Feld',
      );
      expect(find.text('Nicht gesendet'), findsOneWidget);
      expect(find.text('Erneut senden'), findsOneWidget);
      expect(_blasenMit(tester, frage), 1);

      await tester.tap(find.byKey(const ValueKey('coach-unsent-retry')));
      await tester.pumpAndSettle();

      expect(
        svc.gesendeteTexte,
        <String>[frage, frage],
        reason: 'derselbe Text, bitgleich — nicht aus dem Feld rekonstruiert',
      );
      expect(
        _blasenMit(tester, frage),
        1,
        reason: 'DAS ist der Befund: der zweite Versuch darf keine zweite '
            'Blase mit demselben Text erzeugen',
      );

      svc.offen.last.complete(
        const CoachChatReply(
          reply: 'Dir fehlen noch 38 g.',
          refusal: false,
          sessionId: 's1',
          remaining: 4,
          dailyLimit: 5,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('coach-unsent')),
        findsNothing,
        reason: 'zugestellt ist zugestellt — die Kennzeichnung muss weg',
      );
      expect(_blasenMit(tester, frage), 1);
      expect(find.text('Dir fehlen noch 38 g.'), findsOneWidget);
    },
  );

  testWidgets(
    'dieselbe Frage NEU GETIPPT ersetzt die fehlgeschlagene Blase — eine '
    'andere laesst sie samt Kennzeichnung stehen',
    (tester) async {
      // Der zweite Weg des Befunds, und der wortwoertliche: „retyping produced
      // a SECOND bubble with the same text". Der Test darueber nimmt den
      // Wiederhol-Knopf, und der raeumt die Blase selbst weg — diese Zeile
      // haengt allein an `_ohneAltenFehlschlag`.
      final svc = _FixCoach.create();
      await _pumpCoachRuhig(tester, svc);

      const frage = 'Wie viel Protein fehlt mir heute noch?';
      await _tippenUndSenden(tester, frage);
      svc.offen.first.completeError(
        const CoachChatException('Verbindung fehlgeschlagen.'),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('coach-unsent')), findsOneWidget);

      await _tippenUndSenden(tester, frage);

      expect(svc.gesendeteTexte, <String>[frage, frage]);
      expect(
        _blasenMit(tester, frage),
        1,
        reason: 'derselbe Text darf keine zweite Blase erzeugen, nur weil der '
            'Nutzer ihn getippt statt den Knopf gedrueckt hat',
      );
      expect(
        find.byKey(const ValueKey('coach-unsent')),
        findsNothing,
        reason: 'die Kennzeichnung gehoerte der Blase, die gerade ersetzt wurde',
      );

      // Gegenprobe: eine ANDERE Frage darf die alte Blase nicht mitreissen —
      // sie wurde nie zugestellt und muss weiter danach aussehen.
      svc.offen.last.completeError(
        const CoachChatException('Verbindung fehlgeschlagen.'),
      );
      await tester.pumpAndSettle();
      const andere = 'Und wie viel Fett?';
      await _tippenUndSenden(tester, andere);

      expect(_blasenMit(tester, frage), 1);
      expect(_blasenMit(tester, andere), 1);
      expect(
        find.byKey(const ValueKey('coach-unsent')),
        findsOneWidget,
        reason: 'die alte, nie zugestellte Frage behaelt ihre Kennzeichnung — '
            'ohne sie saehe sie aus wie abgeschickt',
      );
    },
  );

  testWidgets(
    'erschoepftes Kontingent: gekennzeichnet, aber ohne Wiederhol-Knopf',
    (tester) async {
      final svc = _FixCoach.create();
      await _pumpCoachRuhig(tester, svc);

      await _tippenUndSenden(tester, 'Noch eine Frage');
      svc.offen.first.completeError(
        const CoachQuotaExceeded(
          message: 'Tageslimit erreicht. Morgen geht es weiter.',
          dailyLimit: 5,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('coach-unsent')),
        findsOneWidget,
        reason: 'gesendet wurde sie nicht — das gilt auch beim Tageslimit',
      );
      expect(
        find.byKey(const ValueKey('coach-unsent-retry')),
        findsNothing,
        reason: 'ein Knopf, der nichts ausloesen kann, ist eine Aufforderung, '
            'die nicht eingeloest wird',
      );
    },
  );
}
