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

// The "Not sent · Send again" line sat in one Row. At 2x text on a 320 px
// phone the German line overflowed by 82 px (English by 13 px), so the retry
// button was cut off at the screen edge.

class _FailingCoach extends CoachChatService {
  _FailingCoach(super.client, super.userId);

  static _FailingCoach create() {
    final client = SupabaseClient(
      'https://example.supabase.co',
      'test-anon-key',
      httpClient: MockClient((req) async => http.Response('[]', 200)),
    );
    client.auth.stopAutoRefresh();
    return _FailingCoach(client, 'user-123');
  }

  int sends = 0;

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
    sends++;
    throw const CoachChatException('Offline');
  }
}

void main() {
  for (final locale in const [Locale('de'), Locale('en')]) {
    testWidgets('"Send again" stays whole at 2x text on 320 px ($locale)', (
      tester,
    ) async {
      const width = 320.0;
      final coach = _FailingCoach.create();
      await pumpLocalized(
        tester,
        CoachChatScreen(service: coach, userName: 'M'),
        surfaceSize: const Size(width, 640),
        textScale: 2.0,
        locale: locale,
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.enterText(find.byKey(const ValueKey('coach-input')), 'Hi');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('coach-send')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(tester.takeException(), isNull);
      final retry = find.byKey(const ValueKey('coach-unsent-retry'));
      expect(retry, findsOneWidget);
      final box = tester.getRect(retry);
      expect(box.left, greaterThanOrEqualTo(0));
      expect(box.right, lessThanOrEqualTo(width));

      await tester.tap(retry);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(coach.sends, 2);
    });
  }
}
