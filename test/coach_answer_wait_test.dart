import 'package:clock/clock.dart';
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

// COACH-4, client half: a connection that dies after the server stored the
// question used to end in "No connection" with a retry marker at once, while
// the server was still writing the answer — the retry bought a second daily
// slot. Now the screen keeps its thinking state while the service re-checks
// the transcript, up to the request deadline. The wait itself (answer,
// deadline, leaving the chat, account switch, dispose) is pinned without
// widgets in test/coach/coach_chat_controller_test.dart, the transcript loop
// in coach_connection_loss_test.dart. This file keeps the one part only the
// screen owns: it tells the wait when the app goes to the background.

const String _frage = 'Wie viel Protein nach dem Training?';
const String _antwort = 'Etwa 25 bis 30 g reichen.';
const Duration _abstand = Duration(seconds: 3);

/// A send whose connection died after the server stored the question. From
/// there it runs the service's transcript loop with a scripted transcript:
/// the answer shows at check [answerAtCheck] (null: never).
class _LostConnectionCoach extends CoachChatService {
  _LostConnectionCoach(super.client, super.userId);

  static _LostConnectionCoach create() {
    final client = SupabaseClient(
      'https://example.supabase.co',
      'test-anon-key',
      httpClient: MockClient((req) async => http.Response('[]', 200)),
    );
    client.auth.stopAutoRefresh();
    return _LostConnectionCoach(client, 'user-123');
  }

  int? answerAtCheck;
  int sends = 0;
  int checks = 0;

  @override
  Future<List<ChatSession>> loadSessions() async => <ChatSession>[
        ChatSession(
          id: 's1',
          title: 'Chat A',
          createdAt: DateTime(2026, 10, 1),
          lastMessageAt: DateTime(2026, 10, 11),
          messageCount: 0,
        ),
      ];

  @override
  Future<String?> ensureDefaultSession() async => 's1';

  @override
  Future<List<ChatMessage>> loadHistory(String sessionId, {int limit = 100}) async =>
      const <ChatMessage>[];

  @override
  Future<ChatQuotaSnapshot> loadQuotaToday() async =>
      const ChatQuotaSnapshot(used: 1, remaining: 4, dailyLimit: 5);

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
    final bis = clock.now().add(CoachChatService.chatDeadline);
    for (;;) {
      checks++;
      final at = answerAtCheck;
      if (at != null && checks >= at) {
        return CoachChatReply(reply: _antwort, refusal: false, sessionId: sessionId);
      }
      final waiter = answerWaiter;
      final rest = bis.difference(clock.now());
      if (waiter == null || rest <= Duration.zero) {
        throw CoachChatException(deL10n.coachErrorNoConnection);
      }
      if (!await waiter.pause(sessionId, rest < _abstand ? rest : _abstand)) {
        throw CoachChatException(deL10n.coachErrorNoConnection);
      }
    }
  }
}

Future<void> _pumpCoach(WidgetTester tester, _LostConnectionCoach svc) async {
  tester.view.devicePixelRatio = 3.0;
  tester.view.physicalSize = const Size(402, 781) * 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await pumpLocalized(
    tester,
    CoachChatScreen(service: svc, userName: 'Moritz'),
    padding: EdgeInsets.zero,
    safeArea: false,
  );
  await tester.pumpAndSettle();
}

Future<void> _senden(WidgetTester tester) async {
  await tester.enterText(find.byKey(const ValueKey('coach-input')), _frage);
  await tester.pump();
  await tester.tap(find.byKey(const ValueKey('coach-send')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('in the background no timer runs; the resume checks at once',
      (tester) async {
    final svc = _LostConnectionCoach.create()..answerAtCheck = 2;
    await _pumpCoach(tester, svc);

    await _senden(tester);
    expect(svc.checks, 1);
    tester.binding
      ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
      ..handleAppLifecycleStateChanged(AppLifecycleState.hidden)
      ..handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 60));
    expect(svc.checks, 1, reason: 'no transcript checks in the background');

    tester.binding
      ..handleAppLifecycleStateChanged(AppLifecycleState.hidden)
      ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
      ..handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(svc.checks, 2);
    expect(find.text(_antwort), findsOneWidget);
    expect(find.text(deL10n.coachErrorNoConnection), findsNothing);
  });
}
