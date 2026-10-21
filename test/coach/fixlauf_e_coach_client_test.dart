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

import '../support/harness.dart';

// Coach client (fix run 2026-08-27, package E):
//
//  F5-01  a failed question lives ONLY in the unsent marker — the field is not
//         refilled; a different question leaves the failed bubble marked and
//         its retry still targets it.
//  F5-09  "new conversation" carries the localized title; stored placeholders
//         display localized.
//  F5-11  thinking dots show in the session that is sending, not in the one
//         the user switched to.

class _ECoach extends CoachChatService {
  _ECoach(super.client, super.userId);

  /// `stopAutoRefresh()` is mandatory: GoTrue's constructor timer trips every
  /// widget test.
  static _ECoach create() {
    final client = SupabaseClient(
      'https://example.supabase.co',
      'test-anon-key',
      httpClient: MockClient((req) async => http.Response('[]', 200)),
    );
    client.auth.stopAutoRefresh();
    return _ECoach(client, 'user-123');
  }

  List<ChatSession> sessions = <ChatSession>[
    ChatSession(
      id: 's1',
      title: 'Chat A',
      createdAt: DateTime(2026, 8, 1),
      lastMessageAt: DateTime(2026, 8, 27),
      messageCount: 1,
    ),
    ChatSession(
      id: 's2',
      title: 'Chat B',
      createdAt: DateTime(2026, 8, 2),
      lastMessageAt: DateTime(2026, 8, 26),
      messageCount: 1,
    ),
  ];

  final List<String> gesendeteTexte = <String>[];
  final List<Completer<CoachChatReply>> offen = <Completer<CoachChatReply>>[];
  final List<String> neueSessionTitel = <String>[];

  @override
  Future<List<ChatSession>> loadSessions() async => sessions;

  @override
  Future<String?> ensureDefaultSession() async => 's1';

  @override
  Future<String?> createSession({required String title}) async {
    neueSessionTitel.add(title);
    return 's-neu';
  }

  @override
  Future<List<ChatMessage>> loadHistory(String sessionId,
      {int limit = 100}) async {
    return <ChatMessage>[
      ChatMessage(
        id: 'm-$sessionId',
        role: ChatRole.assistant,
        content: 'Verlauf $sessionId',
        createdAt: DateTime(2026, 8, 26),
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
  }) {
    gesendeteTexte.add(message);
    final auftrag = Completer<CoachChatReply>();
    offen.add(auftrag);
    return auftrag.future;
  }
}

const Size _usableSize = Size(402, 781);

Future<void> _pumpCoach(
  WidgetTester tester,
  _ECoach service, {
  Locale locale = const Locale('de'),
}) async {
  tester.view.devicePixelRatio = 3.0;
  tester.view.physicalSize = _usableSize * 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  // reducedMotion (harness default): motion off, or `pumpAndSettle` never
  // returns while sending.
  await pumpLocalized(
    tester,
    CoachChatScreen(service: service, userName: 'Moritz'),
    locale: locale,
    // The coach tab owns its gutters (the shell passes no padding).
    padding: EdgeInsets.zero,
    safeArea: false,
    settle: true,
  );
}

Future<void> _tippenUndSenden(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const ValueKey('coach-input')), text);
  await tester.pump();
  await tester.tap(find.byKey(const ValueKey('coach-send')));
  await tester.pumpAndSettle();
}

/// Bubbles only: `find.text` would also match the composer.
int _blasenMit(WidgetTester tester, String text) => tester
    .widgetList<Text>(find.byType(Text))
    .where((w) => w.data == text)
    .length;

TextField _feld(WidgetTester tester) =>
    tester.widget<TextField>(find.byKey(const ValueKey('coach-input')));

const CoachChatReply _antwort = CoachChatReply(
  reply: 'Antwort vom Coach.',
  refusal: false,
  sessionId: 's1',
  remaining: 4,
  dailyLimit: 5,
);

void main() {
  // Retry and retyped-same-text both REPLACE the failed bubble:
  // coach_chat_fix_2026_08_19_test.dart (its first two cases).
  group('F5-01 Fehlschlag: Marker statt Entwurf', () {
    testWidgets(
        'anderer Text nach dem Fehlschlag: die alte Blase bleibt MIT Marker, '
        'die neue steht daneben; der Retry gilt weiter der alten',
        (tester) async {
      final svc = _ECoach.create();
      await _pumpCoach(tester, svc);

      await _tippenUndSenden(tester, 'Frage A');
      svc.offen.first.completeError(const CoachChatException('Fehler'));
      await tester.pumpAndSettle();
      expect(_feld(tester).controller?.text, '',
          reason: 'Draft-Restore UND Marker waren doppelt — der Marker bleibt');

      await _tippenUndSenden(tester, 'Frage B');

      expect(_blasenMit(tester, 'Frage A'), 1);
      expect(_blasenMit(tester, 'Frage B'), 1);
      expect(find.byKey(const ValueKey('coach-unsent')), findsOneWidget,
          reason: 'A ging nie raus — ohne Marker saehe die Blase zugestellt '
              'aus');
      expect(svc.gesendeteTexte, <String>['Frage A', 'Frage B']);

      svc.offen.last.complete(_antwort);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('coach-unsent')), findsOneWidget);
      expect(find.byKey(const ValueKey('coach-unsent-retry')), findsOneWidget,
          reason: 'B ist zugestellt, A wartet weiter auf den Wiederholversuch');

      // The retry still targets A: it resends A and replaces A's bubble.
      await tester.tap(find.byKey(const ValueKey('coach-unsent-retry')));
      await tester.pumpAndSettle();
      expect(svc.gesendeteTexte, <String>['Frage A', 'Frage B', 'Frage A']);
      expect(_blasenMit(tester, 'Frage A'), 1);
      expect(find.byKey(const ValueKey('coach-unsent')), findsNothing);
    });
  });

  // Dictation fills the field and never sends by itself (F5-06):
  // coach_dictation_test.dart, against the real speech adapter.

  group('F5-09 Session-Titel lokalisiert', () {
    // English only: the German default would pass even with a hard-coded
    // German title, which is exactly the bug.
    for (final (locale, erwartet) in <(Locale, String)>[
      (const Locale('en'), 'New conversation'),
    ]) {
      testWidgets('„Neu" uebergibt unter ${locale.languageCode} „$erwartet"',
          (tester) async {
        final svc = _ECoach.create();
        await _pumpCoach(tester, svc, locale: locale);

        await tester.tap(find.byKey(const ValueKey('coach-sessions-open')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('coach-sessions-new')));
        await tester.pumpAndSettle();

        expect(svc.neueSessionTitel, <String>[erwartet]);
      });

      testWidgets(
          'gespeicherte Platzhalter zeigen unter ${locale.languageCode} '
          '„$erwartet", echte Titel bleiben', (tester) async {
        final svc = _ECoach.create()
          ..sessions = <ChatSession>[
            for (final (i, titel) in <String>[
              'Neue Unterhaltung',
              'New conversation',
              'Allgemein',
              '',
              'Protein am Abend',
            ].indexed)
              ChatSession(
                id: 's$i',
                title: titel,
                createdAt: DateTime(2026, 8, 1),
                lastMessageAt: DateTime(2026, 8, 27),
                messageCount: 1,
              ),
          ];
        await _pumpCoach(tester, svc, locale: locale);

        await tester.tap(find.byKey(const ValueKey('coach-sessions-open')));
        await tester.pumpAndSettle();

        expect(find.text(erwartet), findsNWidgets(4));
        expect(find.text('Protein am Abend'), findsOneWidget);
        expect(find.text('Allgemein'), findsNothing);
      });
    }
  });

  group('F5-11 Denk-Punkte nur in der sendenden Session', () {
    testWidgets('Sitzungswechsel waehrend der Antwort zeigt in B keine Punkte',
        (tester) async {
      final svc = _ECoach.create();
      await _pumpCoach(tester, svc);

      await _tippenUndSenden(tester, 'Frage in A');
      expect(find.byKey(const ValueKey('coach-thinking')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('coach-sessions-open')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Chat B'));
      await tester.pumpAndSettle();

      expect(find.text('Verlauf s2'), findsOneWidget);
      expect(find.byKey(const ValueKey('coach-thinking')), findsNothing,
          reason: 'B wartet auf nichts — die Punkte gehoeren zu A');

      await tester.tap(find.byKey(const ValueKey('coach-sessions-open')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Chat A'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('coach-thinking')), findsOneWidget,
          reason: 'zurueck in A laeuft die Anfrage noch');

      svc.offen.first.complete(_antwort);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('coach-thinking')), findsNothing);
    });
  });
}
