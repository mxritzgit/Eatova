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

import 'support/harness.dart';

// The counter followed only answers that named `remaining`. A failed request
// can still have spent its slot: the server keeps it when the client gave up
// (deadline, lost connection) and for input the provider already billed. A
// transcript-recovered answer names no count either. The composer then
// promised one question more than the server would take, until the next tab
// switch. Now the screen asks the server again after such a request.

class _Coach extends CoachChatService {
  _Coach(super.client, super.userId);

  static _Coach create() {
    final client = SupabaseClient(
      'https://example.supabase.co',
      'test-anon-key',
      httpClient: MockClient((req) async => http.Response('[]', 200)),
    );
    client.auth.stopAutoRefresh();
    return _Coach(client, 'user-123');
  }

  /// What the server reports: two left until the request spends one.
  int serverRemaining = 2;
  int quotaCalls = 0;

  /// null: the request fails; otherwise the answer, without a count.
  String? answer;

  @override
  Future<List<ChatSession>> loadSessions() async => <ChatSession>[
    ChatSession(
      id: 's1',
      title: 'Chat',
      createdAt: DateTime(2026, 10, 1),
      lastMessageAt: DateTime(2026, 10, 3),
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
      id: 'm1',
      role: ChatRole.assistant,
      content: 'Hallo',
      createdAt: DateTime(2026, 10, 3),
    ),
  ];

  @override
  Future<ChatQuotaSnapshot> loadQuotaToday() async {
    quotaCalls++;
    return ChatQuotaSnapshot(
      used: 5 - serverRemaining,
      remaining: serverRemaining,
      dailyLimit: 5,
    );
  }

  @override
  Future<CoachChatReply> send(
    String message, {
    required String sessionId,
    String? imageBase64,
    String? imageMimeType,
    String? userContext,
    void Function(String text)? onPartialReply,
  }) async {
    serverRemaining = 1;
    final reply = answer;
    if (reply == null) {
      throw CoachChatException(deL10n.coachErrorTimeout);
    }
    return CoachChatReply(reply: reply, refusal: false, sessionId: sessionId);
  }

  @override
  Future<CoachRecipeReply> requestRecipe(
    String wish, {
    required String sessionId,
    required String locale,
  }) async {
    serverRemaining = 1;
    throw CoachChatException(deL10n.coachErrorNoConnection);
  }

  @override
  Future<CoachPlanReply> requestPlan(
    String wish, {
    required String sessionId,
    required String locale,
  }) async {
    serverRemaining = 1;
    throw CoachChatException(deL10n.coachErrorNoConnection);
  }
}

Future<void> _ask(WidgetTester tester, _Coach coach, String text) async {
  await pumpLocalized(
    tester,
    CoachChatScreen(service: coach, userName: 'M'),
    surfaceSize: const Size(402, 781),
  );
  await tester.pump(const Duration(milliseconds: 500));
  expect(find.text(deL10n.coachQuotaHint(2)), findsOneWidget);
  await tester.enterText(find.byKey(const ValueKey('coach-input')), text);
  await tester.pump();
  await tester.tap(find.byKey(const ValueKey('coach-send')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  final requests = <String, String>{
    'a question': 'Wie viel Protein?',
    '/recipe': '/recipe Bowl',
    '/plan': '/plan Kraft',
  };
  for (final MapEntry(key: name, value: text) in requests.entries) {
    testWidgets('after $name fails, the counter shows what the server says', (
      tester,
    ) async {
      final coach = _Coach.create();
      await _ask(tester, coach, text);

      expect(find.byKey(const ValueKey('coach-unsent')), findsOneWidget);
      expect(coach.quotaCalls, 2, reason: 'asked once more after the failure');
      expect(find.text(deL10n.coachQuotaHint(1)), findsOneWidget);
      expect(find.text(deL10n.coachQuotaHint(2)), findsNothing);
    });
  }

  testWidgets('an answer without a count refreshes the counter', (
    tester,
  ) async {
    final coach = _Coach.create()..answer = 'Etwa 1,6 g pro Kilo.';
    await _ask(tester, coach, 'Wie viel Protein?');

    expect(find.text('Etwa 1,6 g pro Kilo.'), findsOneWidget);
    expect(coach.quotaCalls, 2);
    expect(find.text(deL10n.coachQuotaHint(1)), findsOneWidget);
  });
}
