// Coach flow: type a question, send it, see the own bubble, the coach's
// answer and the updated quota line.
//
// The coach service hangs off `EatovaSync`, which EatovaApp builds from the
// Supabase singleton, so the flow pumps `CoachChatScreen` with a fake service
// inside the same shell padding the home page uses (pattern of
// test/coach_design_test.dart). The CoachOrb animates endlessly, so every
// wait is a bounded pump loop, never pumpAndSettle. Runs in English.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/chat_message.dart';
import 'package:eatova/src/models/chat_session.dart';
import 'package:eatova/src/screens/coach/coach_chat_screen.dart';
import 'package:eatova/src/services/coach_chat_service.dart';

// `testWidgetsRobust` exists in both files; the flows keep their own.
import '../support/harness.dart' hide testWidgetsRobust;
import 'flow_test_helpers.dart';

const String _question = 'What should I eat tonight?';
const String _answer = 'Try salmon with sweet potato and broccoli.';

/// In-memory coach: one session, a growing history and a quota that counts
/// down per question, so the quota line has something to change.
class _FlowCoach extends CoachChatService {
  _FlowCoach(super.client, super.userId);

  /// `stopAutoRefresh()` is mandatory: GoTrue starts a periodic timer in its
  /// constructor that fails every widget test.
  static _FlowCoach create() {
    final client = SupabaseClient(
      'https://example.supabase.co',
      'test-anon-key',
      httpClient: MockClient((req) async => http.Response('[]', 200)),
    );
    client.auth.stopAutoRefresh();
    return _FlowCoach(client, 'user-coach-flow');
  }

  static const int _dailyLimit = 5;

  final List<ChatMessage> history = <ChatMessage>[];
  // Starts at 2 so the quota line is visible before AND after the question
  // (the composer shows it only for 1..2 remaining).
  int remaining = 2;
  int sendCalls = 0;

  @override
  Future<List<ChatSession>> loadSessions() async => <ChatSession>[
        ChatSession(
          id: 's1',
          title: 'Evening plan',
          createdAt: DateTime(2026, 8, 27),
          lastMessageAt: DateTime(2026, 8, 27),
          messageCount: history.length,
        ),
      ];

  @override
  Future<String?> ensureDefaultSession() async => 's1';

  @override
  Future<List<ChatMessage>> loadHistory(String sessionId,
          {int limit = 100}) async =>
      List<ChatMessage>.of(history);

  @override
  Future<ChatQuotaSnapshot> loadQuotaToday() async => ChatQuotaSnapshot(
        used: _dailyLimit - remaining,
        remaining: remaining,
        dailyLimit: _dailyLimit,
      );

  @override
  Future<CoachChatReply> send(
    String message, {
    required String sessionId,
    String? imageBase64,
    String? imageMimeType,
    String? userContext,
    void Function(String text)? onPartialReply,
  }) async {
    sendCalls++;
    remaining--;
    history
      ..add(_msg('u$sendCalls', message, ChatRole.user))
      ..add(_msg('a$sendCalls', _answer, ChatRole.assistant));
    return CoachChatReply(
      reply: _answer,
      refusal: false,
      remaining: remaining,
      dailyLimit: _dailyLimit,
      sessionId: sessionId,
    );
  }

  static ChatMessage _msg(String id, String content, ChatRole role) =>
      ChatMessage(
        id: id,
        role: role,
        content: content,
        createdAt: DateTime(2026, 8, 27, 18),
      );
}

/// Bounded "settle" for the animating orb.
Future<void> _pumpFrames(WidgetTester tester, {int rounds = 20}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Finder _inList(Finder matching) => find.descendant(
      of: find.byKey(const ValueKey('coach-message-list')),
      matching: matching,
    );

/// The quota line as the composer renders it, resolved through the live
/// localizations instead of a hard-coded English sentence.
Finder _quotaLine(WidgetTester tester, int remaining) {
  final l10n = AppLocalizations.of(
    tester.element(find.byKey(const ValueKey('screen-coach'))),
  );
  return find.descendant(
    of: find.byKey(const ValueKey('coach-quota-hint')),
    matching: find.text(l10n.coachQuotaHint(remaining)),
  );
}

void main() {
  testWidgetsRobust('Coach: Frage tippen, senden, Antwort und Quota-Zeile', (
    WidgetTester tester,
  ) async {
    final svc = _FlowCoach.create();

    await pumpLocalized(
      tester,
      CoachChatScreen(service: svc, userName: 'Moritz', streak: 3),
      locale: const Locale('en'),
      // Same shell as eatova_home_page.dart.
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
    );
    await _pumpFrames(tester);

    expect(find.byKey(const ValueKey('screen-coach')), findsOneWidget);
    expect(find.byKey(const ValueKey('coach-empty')), findsOneWidget);
    expect(find.byKey(const ValueKey('coach-input')), findsOneWidget);
    // Quota from the service, before any question.
    expect(find.byKey(const ValueKey('coach-quota-hint')), findsOneWidget);
    expect(_quotaLine(tester, 2), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('coach-input')), _question);
    await _pumpFrames(tester, rounds: 2);
    await tester.tap(find.byKey(const ValueKey('coach-send')));
    await _pumpFrames(tester);

    expect(svc.sendCalls, 1);
    // Own bubble and the answer bubble, in the history list.
    expect(_inList(find.text(_question)), findsOneWidget,
        reason: 'die eigene Frage fehlt als Blase');
    expect(_inList(find.text(_answer)), findsOneWidget,
        reason: 'die Coach-Antwort fehlt als Blase');
    expect(find.byKey(const ValueKey('coach-thinking')), findsNothing);
    expect(find.byKey(const ValueKey('coach-unsent')), findsNothing);
    // Hero gone, composer cleared.
    expect(find.byKey(const ValueKey('coach-empty')), findsNothing);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('coach-input')))
          .controller
          ?.text,
      isEmpty,
    );
    // Quota line counted down with the server's answer.
    expect(_quotaLine(tester, 1), findsOneWidget);
    expect(_quotaLine(tester, 2), findsNothing);
  });
}
