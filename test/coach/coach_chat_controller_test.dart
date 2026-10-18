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

  int quotaLoads = 0;

  @override
  Future<ChatQuotaSnapshot> loadQuotaToday() async {
    quotaLoads++;
    return const ChatQuotaSnapshot(used: 1, remaining: 4, dailyLimit: 5);
  }

  /// Every chat send waits here until the test answers it.
  final List<_Send> sends = <_Send>[];

  @override
  Future<CoachChatReply> send(
    String message, {
    required String sessionId,
    String? imageBase64,
    String? imageMimeType,
    String? userContext,
    void Function(String text)? onPartialReply,
  }) {
    final send = _Send(message, sessionId, userContext, onPartialReply);
    sends.add(send);
    return send.reply.future;
  }

  /// Every /recipe request waits here.
  final List<Completer<CoachRecipeReply>> recipes =
      <Completer<CoachRecipeReply>>[];
  final List<String> recipeWishes = <String>[];

  @override
  Future<CoachRecipeReply> requestRecipe(
    String wish, {
    required String sessionId,
    required String locale,
  }) {
    recipeWishes.add(wish);
    final reply = Completer<CoachRecipeReply>();
    recipes.add(reply);
    return reply.future;
  }
}

class _Send {
  _Send(this.message, this.sessionId, this.userContext, this.partial);

  final String message;
  final String sessionId;
  final String? userContext;
  final void Function(String text)? partial;
  final Completer<CoachChatReply> reply = Completer<CoachChatReply>();

  void answer(String text, {String? sessionId, int? remaining, int? limit}) =>
      reply.complete(
        CoachChatReply(
          reply: text,
          refusal: false,
          sessionId: sessionId ?? this.sessionId,
          remaining: remaining,
          dailyLimit: limit,
        ),
      );
}

class _Hooks extends CoachChatViewHooks {
  final List<String> calls = <String>[];

  @override
  void conversationShown() => calls.add('shown');

  @override
  void conversationReplaced() => calls.add('replaced');

  @override
  void questionSent() => calls.add('sent');

  @override
  void previewStarted() => calls.add('preview');

  @override
  void answerArrived() => calls.add('answer');

  @override
  void sendFinished() => calls.add('finished');

  @override
  void draftReturned(String text) => calls.add('draft:$text');
}

/// A controller on [svc] with the bootstrap done (session `a` open).
Future<CoachChatController> _ready(
  _Coach svc, {
  _Hooks? hooks,
  CoachRequestInputs Function()? inputs,
}) async {
  final coach = CoachChatController(
    service: svc,
    hooks: hooks ?? _Hooks(),
    requestInputs: inputs,
  );
  addTearDown(coach.dispose);
  await coach.bootstrap();
  return coach;
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

  group('sending', () {
    test('a question becomes a bubble at once and its answer follows',
        () async {
      final svc = _Coach();
      final hooks = _Hooks();
      final coach = await _ready(
        svc,
        hooks: hooks,
        inputs: () => const CoachRequestInputs(userContext: 'Kontext'),
      );
      hooks.calls.clear();

      unawaited(coach.send('  Wie viel Protein?  '));
      expect(coach.messages.single.content, 'Wie viel Protein?');
      expect(coach.messages.single.role, ChatRole.user);
      expect(coach.sendingInActiveSession, isTrue);
      expect(coach.canInteract, isFalse, reason: 'one request per user');
      expect(coach.canType, isTrue, reason: 'typing stays allowed');
      expect(hooks.calls, ['sent']);
      expect(svc.sends.single.userContext, 'Kontext');

      svc.sends.single.partial!('Etwa');
      expect(coach.preview.value, 'Etwa');
      expect(coach.previewShown, isTrue);
      svc.sends.single.answer('Etwa 25 g.', remaining: 2, limit: 10);
      await pumpEventQueue();

      expect(coach.messages.map((m) => m.content),
          ['Wie viel Protein?', 'Etwa 25 g.']);
      expect(coach.sending, isFalse);
      expect(coach.preview.value, isEmpty);
      expect(hooks.calls, ['sent', 'preview', 'answer', 'finished']);
      // The quota the answer named, a real limit now.
      expect(coach.quota?.remaining, 2);
      expect(coach.quota?.dailyLimit, 10);
      expect(coach.quota?.limitAssumed, isFalse);
    });

    test('an answer for A never lands in B, not even as a preview', () async {
      final svc = _Coach();
      final hooks = _Hooks();
      final coach = await _ready(svc, hooks: hooks);
      unawaited(coach.send('Frage in A'));
      await coach.switchToSession('b');
      expect(coach.sending, isTrue);
      expect(coach.sendingInActiveSession, isFalse);
      hooks.calls.clear();

      svc.sends.single.partial!('Antwort');
      expect(coach.preview.value, isEmpty);
      svc.sends.single.answer('Antwort für A', remaining: 3, limit: 5);
      await pumpEventQueue();

      expect(coach.activeSessionId, 'b');
      expect(coach.messages, isEmpty);
      expect(coach.error, isNull);
      expect(coach.failedSend, isNull);
      expect(coach.sending, isFalse, reason: 'the counter is freed anyway');
      expect(hooks.calls, isEmpty);
      // The slot was spent by this user, whichever chat is open.
      expect(coach.quota?.remaining, 3);
    });

    test('an error of A does not follow the user into B', () async {
      final svc = _Coach();
      final coach = await _ready(svc);
      unawaited(coach.send('Frage in A'));
      await coach.switchToSession('b');

      svc.sends.single.reply.completeError(
        CoachChatException(deL10n.coachErrorNoConnection),
      );
      await pumpEventQueue();
      expect(coach.error, isNull);
      expect(coach.failedSend, isNull);
      expect(coach.messages, isEmpty);
    });

    test('A→B→A: the late answer comes from the reloaded history, once',
        () async {
      final svc = _Coach();
      final coach = await _ready(svc);
      unawaited(coach.send('Frage'));
      await coach.switchToSession('b');
      await coach.switchToSession('a');
      expect(coach.messages, isEmpty, reason: 'the new visit loaded A');

      // Meanwhile the server stored the exchange.
      svc.histories['a'] = [
        _message('q1', 'Frage', role: ChatRole.user),
        _message('r1', 'Antwort'),
      ];
      svc.sends.single.answer('Antwort');
      await pumpEventQueue();
      expect(coach.messages.map((m) => m.id), ['q1', 'r1']);
      expect(coach.error, isNull);
    });

    test('A→B→A: a failed question comes back with its marker', () async {
      final svc = _Coach();
      final coach = await _ready(svc);
      unawaited(coach.send('Frage'));
      await coach.switchToSession('b');
      await coach.switchToSession('a');

      svc.sends.single.reply.completeError(
        CoachChatException(deL10n.coachErrorNoConnection),
      );
      await pumpEventQueue();
      expect(coach.error, deL10n.coachErrorNoConnection);
      expect(coach.failedSend?.text, 'Frage');
      expect(coach.messages.map((m) => m.content), ['Frage']);
    });

    test('an account switch fences answer, quota and error out', () async {
      final svc = _Coach();
      final hooks = _Hooks();
      final coach = await _ready(svc, hooks: hooks);
      unawaited(coach.send('Frage'));
      final quotaBefore = coach.quota;
      final loadsBefore = svc.quotaLoads;
      coach.updateService(_Coach());
      expect(coach.accountRevision, 1);
      hooks.calls.clear();

      svc.sends.single.answer('Antwort des alten Kontos', remaining: 0, limit: 5);
      await pumpEventQueue();
      expect(
        coach.messages.where((m) => m.role == ChatRole.assistant),
        isEmpty,
      );
      expect(coach.quota, same(quotaBefore));
      expect(coach.quotaExhausted, isFalse);
      expect(coach.error, isNull);
      expect(coach.sending, isFalse);
      expect(svc.quotaLoads, loadsBefore);
      expect(hooks.calls, isEmpty);
    });

    test('an answer without a count asks the server for the quota', () async {
      final svc = _Coach();
      final coach = await _ready(svc);
      final loads = svc.quotaLoads;
      unawaited(coach.send('Frage'));
      svc.sends.single.answer('Antwort');
      await pumpEventQueue();
      expect(svc.quotaLoads, loads + 1);
    });

    test('a failure that may have spent the slot asks for the quota too',
        () async {
      final svc = _Coach();
      final coach = await _ready(svc);
      final loads = svc.quotaLoads;
      unawaited(coach.send('Frage'));
      svc.sends.single.reply.completeError(
        CoachChatException(deL10n.coachErrorTimeout),
      );
      await pumpEventQueue();
      expect(svc.quotaLoads, loads + 1);
      expect(coach.error, deL10n.coachErrorTimeout);
      expect(coach.failedSend?.text, 'Frage');
      expect(coach.canInteract, isTrue);
    });

    test('a quota 429 locks the composer and keeps the marker', () async {
      final svc = _Coach();
      final coach = await _ready(svc);
      unawaited(coach.send('Frage'));
      svc.sends.single.reply.completeError(
        const CoachQuotaExceeded(message: 'Limit erreicht', dailyLimit: 5),
      );
      await pumpEventQueue();
      expect(coach.quotaExhausted, isTrue);
      expect(coach.canType, isFalse);
      expect(coach.error, 'Limit erreicht');
      expect(coach.failedSend, isNotNull);

      // A known-empty quota blocks locally: no request, no slot.
      await coach.send('Noch eine');
      expect(svc.sends, hasLength(1));
      expect(coach.error, deL10n.coachErrorDailyLimitReached(5));
    });

    test('the retry replaces the failed bubble instead of adding one',
        () async {
      final svc = _Coach();
      final coach = await _ready(svc);
      unawaited(coach.send('Frage'));
      svc.sends.single.reply.completeError(
        CoachChatException(deL10n.coachErrorNoConnection),
      );
      await pumpEventQueue();

      final job = coach.withdrawFailedSend()!;
      expect(coach.messages, isEmpty);
      expect(coach.error, isNull);
      unawaited(coach.send(job.text));
      svc.sends.last.answer('Antwort');
      await pumpEventQueue();
      expect(coach.messages.map((m) => m.content), ['Frage', 'Antwort']);
      expect(coach.failedSend, isNull);
    });

    test('commands without a wish stay local and cost nothing', () async {
      final svc = _Coach();
      final coach = await _ready(svc);
      await coach.send('/recipe');
      expect(coach.error, deL10n.coachRecipeEmptyHint);
      await coach.send('/unbekannt');
      expect(coach.error, deL10n.coachPlanUnknownCommandHint);
      expect(svc.sends, isEmpty);
      expect(svc.recipes, isEmpty);
      expect(coach.messages, isEmpty);
    });

    test('/recipe sends only the wish and fences the card like chat',
        () async {
      final svc = _Coach();
      final coach = await _ready(svc);
      unawaited(coach.send('/recipe Bowl mit Reis'));
      expect(svc.recipeWishes, ['Bowl mit Reis']);
      expect(coach.messages.single.content, '/recipe Bowl mit Reis');
      await coach.switchToSession('b');

      svc.recipes.single.complete(
        const CoachRecipeReply(
          reply: 'Hier ist dein Rezept.',
          refusal: true,
          sessionId: 'a',
          remaining: 1,
          dailyLimit: 5,
        ),
      );
      await pumpEventQueue();
      expect(coach.messages, isEmpty);
      expect(coach.quota?.remaining, 1);
      expect(coach.sending, isFalse);
    });

    test('an answer after dispose touches nothing', () async {
      final svc = _Coach();
      final hooks = _Hooks();
      final coach = CoachChatController(service: svc, hooks: hooks);
      await coach.bootstrap();
      unawaited(coach.send('Frage'));
      final calls = List<String>.of(hooks.calls);
      coach.dispose();

      svc.sends.single.partial!('Ant');
      svc.sends.single.answer('Antwort', remaining: 0, limit: 5);
      await pumpEventQueue();
      expect(hooks.calls, calls);
      expect(svc.quotaLoads, 1, reason: 'only the bootstrap asked');
    });
  });
}
