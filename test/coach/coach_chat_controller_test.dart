import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/chat_message.dart';
import 'package:eatova/src/models/chat_session.dart';
import 'package:eatova/src/screens/coach/coach_chat_controller.dart';
import 'package:eatova/src/services/coach_chat_service.dart';

// CoachChatController without widgets: the session, answer and wait fences
// that the Coach widget tests pin through the screen, here against a scripted
// service. Requests hang on completers, so a session switch can be placed
// inside the window each fence closes.

final DateTime _t0 = DateTime.utc(2026, 10, 18, 9);

ChatSession _session(String id) => ChatSession(
  id: id,
  title: 'Chat $id',
  createdAt: _t0,
  lastMessageAt: _t0,
  messageCount: 0,
);

ChatMessage _message(String id, String content, {ChatRole? role}) =>
    ChatMessage(
      id: id,
      role: role ?? ChatRole.assistant,
      content: content,
      createdAt: _t0,
    );

/// Shared by every fake: `stopAutoRefresh()` keeps GoTrue's periodic timer
/// out of the test.
final SupabaseClient _client = () {
  final client = SupabaseClient(
    'https://example.supabase.co',
    'test-anon-key',
    httpClient: MockClient((req) async => http.Response('[]', 200)),
  );
  client.auth.stopAutoRefresh();
  return client;
}();

class _Coach extends CoachChatService {
  _Coach() : super(_client, 'user-1');

  List<ChatSession> sessionList = <ChatSession>[_session('a'), _session('b')];
  Map<String, List<ChatMessage>> histories = <String, List<ChatMessage>>{};

  /// While true, every history load waits in [pendingHistory].
  bool holdHistory = false;
  final List<({String sessionId, Completer<List<ChatMessage>> load})>
  pendingHistory = <({String sessionId, Completer<List<ChatMessage>> load})>[];
  final List<String> historyLoads = <String>[];

  /// Thrown by the next history load instead of answering.
  Object? historyFailure;

  @override
  Future<List<ChatSession>> loadSessions() async => sessionList;

  @override
  Future<String?> ensureDefaultSession() async =>
      sessionList.isEmpty ? null : sessionList.first.id;

  @override
  Future<void> deleteSession(String sessionId) async {
    sessionList = [
      for (final session in sessionList)
        if (session.id != sessionId) session,
    ];
  }

  @override
  Future<List<ChatMessage>> loadHistory(
    String sessionId, {
    int limit = 100,
  }) async {
    historyLoads.add(sessionId);
    final failure = historyFailure;
    if (failure != null) {
      historyFailure = null;
      throw failure;
    }
    if (holdHistory) {
      final load = Completer<List<ChatMessage>>();
      pendingHistory.add((sessionId: sessionId, load: load));
      return load.future;
    }
    return histories[sessionId] ?? const <ChatMessage>[];
  }

  @override
  Future<ChatQuotaSnapshot> loadQuotaToday() async =>
      const ChatQuotaSnapshot(used: 1, remaining: 4, dailyLimit: 5);
}

class _Hooks extends CoachChatViewHooks {
  final List<String> calls = <String>[];

  @override
  void conversationShown() => calls.add('shown');

  @override
  void conversationReplaced() => calls.add('replaced');
}

const CoachDataUnavailable _offline = CoachDataUnavailable('offline');

void main() {
  group('sessions and history', () {
    test('A→B→A: only the latest visit of A renders its history', () async {
      final svc = _Coach();
      final coach = CoachChatController(service: svc);
      addTearDown(coach.dispose);
      await coach.bootstrap();
      expect(coach.activeSessionId, 'a');

      svc.holdHistory = true;
      unawaited(coach.switchToSession('b'));
      unawaited(coach.switchToSession('a'));
      unawaited(coach.switchToSession('b'));
      unawaited(coach.switchToSession('a'));
      expect(svc.pendingHistory.map((p) => p.sessionId), ['b', 'a', 'b', 'a']);

      // The latest visit answers first, the stale ones after it.
      svc.pendingHistory[3].load.complete([_message('neu', 'neu')]);
      await pumpEventQueue();
      expect(coach.messages.map((m) => m.id), ['neu']);
      expect(coach.loading, isFalse);

      svc.pendingHistory[1].load.complete([_message('alt', 'alt')]);
      svc.pendingHistory[2].load.complete([_message('b', 'b')]);
      svc.pendingHistory[0].load.complete([_message('b0', 'b0')]);
      await pumpEventQueue();
      expect(coach.activeSessionId, 'a');
      expect(coach.messages.map((m) => m.id), ['neu']);
    });

    test('a history error belongs to its session and can be retried',
        () async {
      final svc = _Coach();
      final coach = CoachChatController(service: svc);
      addTearDown(coach.dispose);
      await coach.bootstrap();

      svc.historyFailure = _offline;
      await coach.switchToSession('b');
      expect(coach.historyUnavailable, isTrue);
      expect(coach.error, deL10n.coachErrorHistoryUnavailable);
      expect(coach.loading, isFalse);

      // Picking the failed conversation again is the retry.
      svc.histories['b'] = [_message('b1', 'zurück')];
      await coach.switchToSession('b');
      expect(svc.historyLoads, ['a', 'b', 'b']);
      expect(coach.historyUnavailable, isFalse);
      expect(coach.error, isNull);
      expect(coach.messages.map((m) => m.id), ['b1']);

      // A loaded conversation picked again loads nothing.
      await coach.switchToSession('b');
      expect(svc.historyLoads, ['a', 'b', 'b']);
    });

    test('a late history error of A does not follow the user into B',
        () async {
      final svc = _Coach();
      final coach = CoachChatController(service: svc);
      addTearDown(coach.dispose);
      await coach.bootstrap();

      svc.holdHistory = true;
      unawaited(coach.switchToSession('b'));
      unawaited(coach.switchToSession('a'));
      svc.pendingHistory[1].load.complete(const <ChatMessage>[]);
      await pumpEventQueue();
      svc.pendingHistory[0].load.completeError(_offline);
      await pumpEventQueue();

      expect(coach.activeSessionId, 'a');
      expect(coach.error, isNull);
      expect(coach.historyUnavailable, isFalse);
    });

    test('the bootstrap history error keeps the list for a retry', () async {
      final svc = _Coach()..historyFailure = _offline;
      final coach = CoachChatController(service: svc);
      addTearDown(coach.dispose);
      await coach.bootstrap();

      expect(coach.loading, isFalse);
      expect(coach.historyUnavailable, isTrue);
      expect(coach.error, deL10n.coachErrorHistoryUnavailable);
      expect(coach.sessions.map((s) => s.id), ['a', 'b']);

      await coach.switchToSession('a');
      expect(coach.activeSessionId, 'a');
      expect(coach.historyUnavailable, isFalse);
      expect(coach.error, isNull);
    });

    test('loads and switches tell the screen to show or drop the view',
        () async {
      final svc = _Coach();
      final hooks = _Hooks();
      final coach = CoachChatController(service: svc, hooks: hooks);
      addTearDown(coach.dispose);
      await coach.bootstrap();
      expect(hooks.calls, ['shown']);
      await coach.switchToSession('b');
      expect(hooks.calls, ['shown', 'replaced', 'shown']);
    });

    test('a load that ends after dispose changes nothing and notifies no one',
        () async {
      final svc = _Coach();
      final hooks = _Hooks();
      final coach = CoachChatController(service: svc, hooks: hooks);
      await coach.bootstrap();
      svc.holdHistory = true;
      unawaited(coach.switchToSession('b'));
      var notified = 0;
      coach.addListener(() => notified++);
      final calls = List<String>.of(hooks.calls);
      coach.dispose();

      // A notification after dispose would throw here.
      svc.pendingHistory.single.load.complete([_message('b1', 'spät')]);
      await pumpEventQueue();
      expect(notified, 0);
      expect(hooks.calls, calls);
    });

    test('deleting the open conversation opens the next one', () async {
      final svc = _Coach()..histories['b'] = [_message('b1', 'B')];
      final coach = CoachChatController(service: svc);
      addTearDown(coach.dispose);
      await coach.bootstrap();

      expect(await coach.deleteSession('a'), isTrue);
      expect(coach.sessions.map((s) => s.id), ['b']);
      expect(coach.activeSessionId, 'b');
      expect(coach.messages.map((m) => m.id), ['b1']);
    });
  });
}
