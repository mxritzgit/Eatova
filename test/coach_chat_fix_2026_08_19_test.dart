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

// Full review 2026-08-19, coach package — three findings:
//
//  1. A failed send stayed an ordinary bubble, and retyping produced a SECOND
//     bubble with the same text.
//  2. Every `_Conversation` in the 220 ms AnimatedSwitcher shares one
//     ScrollController, so a session switch attaches two ListViews and
//     `ScrollController.position` throws; `hasClients` does not catch it.
//  3. The daily counter only refreshed on a TickerMode edge, so backgrounding
//     on the coach tab left the composer locked until restart.

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

  /// Distinguishable messages per session; without history the hero shows.
  static const String verlaufA = 'Das ist der Verlauf von Sitzung A.';
  static const String verlaufB = 'Das ist der Verlauf von Sitzung B.';

  /// `send()` texts in order — proof the retry sends the same bits.
  final List<String> gesendeteTexte = <String>[];

  /// Pending send jobs; the test resolves them by hand.
  final List<Completer<CoachChatReply>> offen = <Completer<CoachChatReply>>[];

  /// While true `loadHistory` hangs, so history can land mid-transition.
  bool verlaufHaengt = false;

  final Map<String, Completer<List<ChatMessage>>> offeneVerlaeufe =
      <String, Completer<List<ChatMessage>>>{};

  int quotaAufrufe = 0;

  /// States the server reports in order; the last entry repeats.
  List<ChatQuotaSnapshot> quotaFolge = const <ChatQuotaSnapshot>[
    ChatQuotaSnapshot(used: 0, remaining: 5, dailyLimit: 5),
  ];

  @override
  Future<List<ChatSession>> loadSessions() async => <ChatSession>[
        ChatSession(
          id: 's1',
          title: 'Chat A',
          createdAt: DateTime(2026, 8, 1),
          lastMessageAt: DateTime(2026, 8, 19),
          messageCount: 1,
        ),
        ChatSession(
          id: 's2',
          title: 'Chat B',
          createdAt: DateTime(2026, 8, 2),
          lastMessageAt: DateTime(2026, 8, 18),
          messageCount: 1,
        ),
      ];

  @override
  Future<String?> ensureDefaultSession() async => 's1';

  static List<ChatMessage> verlaufVon(String sessionId) => switch (sessionId) {
        's2' => <ChatMessage>[
            ChatMessage(
              id: 'm-b1',
              role: ChatRole.assistant,
              content: verlaufB,
              createdAt: DateTime(2026, 8, 18),
            ),
          ],
        _ => <ChatMessage>[
            ChatMessage(
              id: 'm-a1',
              role: ChatRole.assistant,
              content: verlaufA,
              createdAt: DateTime(2026, 8, 19),
            ),
          ],
      };

  @override
  Future<List<ChatMessage>> loadHistory(String sessionId, {int limit = 100}) {
    if (!verlaufHaengt) {
      return Future<List<ChatMessage>>.value(verlaufVon(sessionId));
    }
    final auftrag = Completer<List<ChatMessage>>();
    offeneVerlaeufe[sessionId] = auftrag;
    return auftrag.future;
  }

  @override
  Future<ChatQuotaSnapshot> loadQuotaToday() async {
    quotaAufrufe++;
    final index = quotaAufrufe - 1;
    return index < quotaFolge.length ? quotaFolge[index] : quotaFolge.last;
  }

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

Future<void> _pumpApp(
  WidgetTester tester,
  _FixCoach service, {
  required bool bewegungAus,
}) =>
    pumpLocalized(
      tester,
      CoachChatScreen(service: service, userName: 'Moritz'),
      reducedMotion: bewegungAus,
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
      safeArea: false,
    );

/// Motion disabled, or `pumpAndSettle` never returns while `_sending` runs.
Future<void> _pumpCoachRuhig(WidgetTester tester, _FixCoach service) async {
  tester.view.devicePixelRatio = 3.0;
  tester.view.physicalSize = _usableSize * 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await _pumpApp(tester, service, bewegungAus: true);
  await tester.pumpAndSettle();
}

/// Setup WITH motion, the only way into the 220 ms window of finding 2 —
/// hence fixed pumps instead of `pumpAndSettle`.
Future<void> _pumpCoachBewegt(WidgetTester tester, _FixCoach service) async {
  tester.view.devicePixelRatio = 3.0;
  tester.view.physicalSize = _usableSize * 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await _pumpApp(tester, service, bewegungAus: false);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

Future<void> _tippenUndSenden(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const ValueKey('coach-input')), text);
  await tester.pump();
  await tester.tap(find.byKey(const ValueKey('coach-send')));
  await tester.pumpAndSettle();
}

/// Counts bubbles ONLY: `find.text` also matches the composer, which holds
/// the draft again after a failure.
int _blasenMit(WidgetTester tester, String text) => tester
    .widgetList<Text>(find.byType(Text))
    .where((w) => w.data == text)
    .length;

void main() {
  // ─────────────────────────────────────────────────────────────────────────
  // Finding 1 — the failed message
  // ─────────────────────────────────────────────────────────────────────────
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

  // ─────────────────────────────────────────────────────────────────────────
  // Finding 2 — two histories on the same ScrollController
  // ─────────────────────────────────────────────────────────────────────────
  testWidgets(
    'Sitzungswechsel MITTEN im 220-ms-Uebergang sprengt _scrollToEnd nicht',
    (tester) async {
      final svc = _FixCoach.create();
      await _pumpCoachBewegt(tester, svc);
      expect(find.text(_FixCoach.verlaufA), findsOneWidget);

      // History hangs so the test decides when the second ListView appears.
      svc.verlaufHaengt = true;
      await tester.tap(find.byKey(const ValueKey('coach-sessions-open')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Chat B'));
      // No pumpAndSettle: A's outgoing history stays attached for 220 ms.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));

      svc.offeneVerlaeufe['s2']!.complete(_FixCoach.verlaufVon('s2'));
      // This frame builds B's history: two positions, then _scrollToEnd.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));

      expect(
        tester.takeException(),
        isNull,
        reason: '`ScrollController.position` ist `_positions.single` und '
            'wirft, sobald zwei Listen angehaengt sind',
      );

      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text(_FixCoach.verlaufB), findsOneWidget);
    },
  );

  // ─────────────────────────────────────────────────────────────────────────
  // Finding 3 — midnight lockout
  // ─────────────────────────────────────────────────────────────────────────
  testWidgets(
    'Resume zieht den Tageszaehler nach — der Tab-Wechsel allein reicht '
    'nicht, wenn der Coach-Tab die ganze Nacht oben lag',
    (tester) async {
      final svc = _FixCoach.create()
        ..quotaFolge = const <ChatQuotaSnapshot>[
          ChatQuotaSnapshot(used: 5, remaining: 0, dailyLimit: 5),
          ChatQuotaSnapshot(used: 0, remaining: 5, dailyLimit: 5),
        ];
      await _pumpCoachRuhig(tester, svc);

      expect(svc.quotaAufrufe, 1);
      expect(
        find.text('Limit für heute erreicht'),
        findsOneWidget,
        reason: 'Ausgangslage: der letzte Slot ist um 23:50 verbraucht',
      );

      (tester.state(find.byType(CoachChatScreen)) as WidgetsBindingObserver)
          .didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(svc.quotaAufrufe, 2, reason: 'der Resume muss neu fragen');
      expect(
        find.text('Limit für heute erreicht'),
        findsNothing,
        reason: 'nach der Tagesgrenze vergibt der Server wieder Slots',
      );
    },
  );

  testWidgets(
    'der Gang in den Hintergrund fragt nichts ab',
    (tester) async {
      final svc = _FixCoach.create();
      await _pumpCoachRuhig(tester, svc);
      expect(svc.quotaAufrufe, 1);

      final beobachter =
          tester.state(find.byType(CoachChatScreen)) as WidgetsBindingObserver;
      beobachter.didChangeAppLifecycleState(AppLifecycleState.inactive);
      beobachter.didChangeAppLifecycleState(AppLifecycleState.paused);
      await tester.pumpAndSettle();

      expect(
        svc.quotaAufrufe,
        1,
        reason: 'ein Request im Hintergrund waere reine Verschwendung',
      );
    },
  );
}
