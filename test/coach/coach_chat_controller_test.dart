import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';
import 'package:yet_another_json_isolate/yet_another_json_isolate.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/chat_message.dart';
import 'package:eatova/src/models/chat_session.dart';
import 'package:eatova/src/screens/coach/coach_chat_controller.dart';
import 'package:eatova/src/services/coach_chat_service.dart';
import 'package:eatova/src/services/coach_quota_reset.dart';

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
  ChatQuotaSnapshot quota = const ChatQuotaSnapshot(
    used: 1,
    remaining: 4,
    dailyLimit: 5,
  );

  @override
  Future<ChatQuotaSnapshot> loadQuotaToday() async {
    quotaLoads++;
    return quota;
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

  @override
  void mealDescribeRequested(String text) => calls.add('meal:$text');
}

/// The real [CoachChatService] transcript loop behind a connection that dies
/// after the server stored the question (COACH-4). Only the screen's own
/// loads are scripted; the request and its transcript checks go through
/// HTTP.
class _LostConnection {
  _LostConnection(this.question);

  /// What the server stored for the request (the wish, without a command).
  final String question;

  /// The transcript check that first shows the answer; null: never.
  int? answerAtCheck;

  int functionCalls = 0;
  int checks = 0;

  late final SupabaseClient client = SupabaseClient(
    'https://example.supabase.co',
    'test-anon-key',
    httpClient: MockClient(_handle),
    authOptions: const AuthClientOptions(autoRefreshToken: false),
    isolate: _InlineJson(),
  );

  late final _LostCoach service = _LostCoach(client);

  Future<http.Response> _handle(http.Request req) async {
    final path = req.url.path;
    if (path.contains('coach-chat')) {
      functionCalls++;
      throw http.ClientException('Software caused connection abort', req.url);
    }
    if (path.endsWith('/rest/v1/chat_messages')) {
      checks++;
      final answered = answerAtCheck != null && checks >= answerAtCheck!;
      // Newest first, as loadHistory asks for them.
      return _json(req, <Map<String, Object?>>[
        if (answered) _row('r1', 'assistant', 'Etwa 25 g.', _t0),
        _row('q1', 'user', question, _t0),
      ]);
    }
    return _json(req, const <Object?>[]);
  }

  static Map<String, Object?> _row(
    String id,
    String role,
    String content,
    DateTime at,
  ) => <String, Object?>{
    'id': id,
    'role': role,
    'content': content,
    'refusal': false,
    'created_at': at.toIso8601String(),
    'recipe': null,
    'training_plan': null,
    'workout_log': null,
  };

  static http.Response _json(http.Request req, Object? data) => http.Response(
    jsonEncode(data),
    200,
    request: req,
    headers: const <String, String>{
      'content-type': 'application/json; charset=utf-8',
    },
  );
}

/// JSON on the calling isolate. The SDK's default codec answers through a
/// real isolate port, which fake time cannot advance.
class _InlineJson implements YAJsonIsolate {
  @override
  String? get debugName => null;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> dispose() async {}

  @override
  Future<dynamic> decode(String json) async => jsonDecode(json);

  @override
  Future<String> encode(Object? json) async => jsonEncode(json);
}

class _LostCoach extends CoachChatService {
  _LostCoach(SupabaseClient client) : super(client, 'user-1');

  @override
  Future<List<ChatSession>> loadSessions() async =>
      <ChatSession>[_session('a'), _session('b')];

  @override
  Future<String?> ensureDefaultSession() async => 'a';

  @override
  Future<List<ChatMessage>> loadHistory(
    String sessionId, {
    int limit = 100,
  }) async => const <ChatMessage>[];

  @override
  Future<ChatQuotaSnapshot> loadQuotaToday() async =>
      const ChatQuotaSnapshot(used: 1, remaining: 4, dailyLimit: 5);
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
      expect(
        coach.error,
        deL10n.coachErrorDailyLimitReached(5, coachQuotaResetLabel('de')),
      );
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

    test('/meal hands its text to the describe sheet and costs nothing, '
        'even with the day used up', () async {
      final svc = _Coach()
        ..quota = const ChatQuotaSnapshot(used: 5, remaining: 0, dailyLimit: 5);
      final hooks = _Hooks();
      final coach = await _ready(svc, hooks: hooks);
      expect(coach.quotaExhausted, isTrue);

      await coach.send('/meal 2 Eier und Toast');
      await coach.send('/MEAL');
      expect(hooks.calls.where((call) => call.startsWith('meal:')),
          <String>['meal:2 Eier und Toast', 'meal:']);
      expect(coach.error, isNull);

      // A photo would make it a paid question with a /meal caption.
      await coach.send('/meal Eier', imageBytes: Uint8List.fromList([1, 2]));
      expect(coach.error, deL10n.coachMealPhotoUnsupported);
      expect(hooks.calls.where((call) => call.startsWith('meal:')), hasLength(2));
      expect(svc.sends, isEmpty);
      expect(svc.recipes, isEmpty);
      expect(coach.messages, isEmpty);
      expect(coach.quota?.remaining, 0);
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

  group('waiting for a stored answer (COACH-4)', () {
    const abstand = Duration(seconds: 3);

    /// Bootstraps [net]'s controller on fake time and sends [typed]; the
    /// connection dies and the first transcript check finds the question.
    CoachChatController start(
      FakeAsync async,
      _LostConnection net,
      String typed, {
      bool Function()? inBackground,
    }) {
      final coach = CoachChatController(
        service: net.service,
        inBackground: inBackground,
      );
      unawaited(coach.bootstrap());
      async.flushMicrotasks();
      unawaited(coach.send(typed));
      // Zero-length timers of the HTTP stack run too, the 3 s pause not.
      async.elapse(Duration.zero);
      expect(net.functionCalls, 1);
      expect(net.checks, 1);
      expect(coach.sendingInActiveSession, isTrue);
      expect(coach.error, isNull);
      // The pause between two checks is the only timer.
      expect(
        async.pendingTimers.map((timer) => timer.duration),
        [const Duration(seconds: 3)],
      );
      return coach;
    }

    final kinds = <String, ({Duration deadline, String stored, String typed})>{
      'chat': (
        deadline: CoachChatService.chatDeadline,
        stored: 'Wie viel Protein?',
        typed: 'Wie viel Protein?',
      ),
      '/recipe': (
        deadline: CoachChatService.recipeDeadline,
        stored: 'Bowl mit Kichererbsen',
        typed: '/recipe Bowl mit Kichererbsen',
      ),
      '/plan': (
        deadline: CoachChatService.planDeadline,
        stored: 'Kraft für Anfänger',
        typed: '/plan Kraft für Anfänger',
      ),
      '/log': (
        deadline: CoachChatService.workoutLogDeadline,
        stored: 'heute Kniebeugen 1x8 100 kg',
        typed: '/log heute Kniebeugen 1x8 100 kg',
      ),
    };
    for (final MapEntry(key: name, value: kind) in kinds.entries) {
      test('$name: checks every 3 s up to its deadline '
          '(${kind.deadline.inSeconds} s), then the error', () {
        fakeAsync((async) {
          final net = _LostConnection(kind.stored);
          final coach = start(async, net, kind.typed);

          async.elapse(abstand);
          expect(net.checks, 2);
          async.elapse(kind.deadline - abstand - const Duration(seconds: 1));
          expect(coach.error, isNull, reason: 'the answer may still come');
          expect(coach.failedSend, isNull, reason: 'a retry buys a 2nd slot');
          expect(coach.sendingInActiveSession, isTrue);

          async.elapse(const Duration(seconds: 2));
          expect(coach.error, deL10n.coachErrorNoConnection);
          expect(coach.failedSend, isNotNull);
          expect(coach.sending, isFalse);
          // At once, then every 3 s, the last one at the deadline itself.
          expect(net.checks, (kind.deadline.inSeconds / 3).ceil() + 1);
          expect(net.functionCalls, 1, reason: 'no second paid request');
          expect(async.pendingTimers, isEmpty);
          coach.dispose();
          net.client.dispose();
        }, initialTime: _t0);
      });
    }

    test('the stored answer arrives: no error, one request', () {
      fakeAsync((async) {
        final net = _LostConnection('Wie viel Protein?')..answerAtCheck = 3;
        final coach = start(async, net, 'Wie viel Protein?');
        async.elapse(abstand);
        expect(coach.sendingInActiveSession, isTrue);
        async.elapse(abstand);

        expect(net.checks, 3);
        expect(
          coach.messages.map((m) => m.content),
          ['Wie viel Protein?', 'Etwa 25 g.'],
        );
        expect(coach.error, isNull);
        expect(coach.failedSend, isNull);
        expect(coach.sending, isFalse);
        expect(net.functionCalls, 1);
        expect(async.pendingTimers, isEmpty);
        coach.dispose();
        net.client.dispose();
      }, initialTime: _t0);
    });

    test('in the background no timer runs; the resume checks at once', () {
      fakeAsync((async) {
        var background = false;
        final net = _LostConnection('Wie viel Protein?')..answerAtCheck = 2;
        final coach = start(
          async,
          net,
          'Wie viel Protein?',
          inBackground: () => background,
        );

        background = true;
        coach.appPaused();
        expect(async.pendingTimers, isEmpty);
        async.elapse(const Duration(seconds: 60));
        expect(net.checks, 1, reason: 'no transcript checks in the background');

        background = false;
        coach.appResumed();
        async.flushMicrotasks();
        expect(net.checks, 2);
        expect(coach.messages.last.content, 'Etwa 25 g.');
        expect(coach.error, isNull);
        coach.dispose();
        net.client.dispose();
      }, initialTime: _t0);
    });

    test('a connection lost while in the background starts no timer', () {
      fakeAsync((async) {
        var background = false;
        final net = _LostConnection('Wie viel Protein?')..answerAtCheck = 2;
        final coach = CoachChatController(
          service: net.service,
          inBackground: () => background,
        );
        unawaited(coach.bootstrap());
        async.flushMicrotasks();
        // iOS reclaims the socket of an app the user has just left.
        unawaited(coach.send('Wie viel Protein?'));
        background = true;
        coach.appPaused();
        async.elapse(Duration.zero);
        expect(net.checks, 1);
        expect(async.pendingTimers, isEmpty);
        async.elapse(const Duration(seconds: 60));
        expect(net.checks, 1);
        expect(coach.sendingInActiveSession, isTrue);

        background = false;
        coach.appResumed();
        async.flushMicrotasks();
        expect(net.checks, 2);
        expect(coach.messages.last.content, 'Etwa 25 g.');
        coach.dispose();
        net.client.dispose();
      }, initialTime: _t0);
    });

    test('leaving the conversation ends the wait at once, its error stays '
        'behind', () {
      fakeAsync((async) {
        final net = _LostConnection('Wie viel Protein?');
        final coach = start(async, net, 'Wie viel Protein?');

        unawaited(coach.switchToSession('b'));
        async.flushMicrotasks();
        expect(coach.sending, isFalse, reason: 'the composer is free at once');
        expect(async.pendingTimers, isEmpty);
        expect(coach.error, isNull, reason: 'the error belongs to chat a');
        expect(coach.failedSend, isNull);

        async.elapse(const Duration(seconds: 30));
        expect(net.checks, 1, reason: 'no checks for a conversation left');
        coach.dispose();
        net.client.dispose();
      }, initialTime: _t0);
    });

    test('an account switch ends the wait; no timer, no error', () {
      fakeAsync((async) {
        final net = _LostConnection('Wie viel Protein?');
        final coach = start(async, net, 'Wie viel Protein?');
        final next = _LostConnection('anders');

        coach.updateService(next.service);
        async.flushMicrotasks();
        expect(net.service.answerWaiter, isNull);
        expect(next.service.answerWaiter, isNotNull);
        expect(async.pendingTimers, isEmpty);
        expect(coach.error, isNull);
        expect(coach.failedSend, isNull);
        expect(coach.sending, isFalse);
        async.elapse(const Duration(seconds: 30));
        expect(net.checks, 1);
        coach.dispose();
        net.client.dispose();
        next.client.dispose();
      }, initialTime: _t0);
    });

    test('dispose ends the wait; no timer, no callback', () {
      fakeAsync((async) {
        final net = _LostConnection('Wie viel Protein?');
        final coach = start(async, net, 'Wie viel Protein?');
        var notified = 0;
        coach.addListener(() => notified++);

        coach.dispose();
        async.flushMicrotasks();
        expect(net.service.answerWaiter, isNull);
        expect(async.pendingTimers, isEmpty);
        async.elapse(const Duration(seconds: 30));
        expect(net.checks, 1);
        expect(notified, 0);
        net.client.dispose();
      }, initialTime: _t0);
    });
  });

  group('return to the tab', () {
    test('a send error goes, a history error stays and can be retried',
        () async {
      final svc = _Coach();
      final coach = await _ready(svc);
      unawaited(coach.send('Frage'));
      svc.sends.single.reply.completeError(
        CoachChatException(deL10n.coachErrorTimeout),
      );
      await pumpEventQueue();
      expect(coach.error, deL10n.coachErrorTimeout);

      // The banner is feedback on an action; the marker stays.
      final loads = svc.quotaLoads;
      await coach.returnToChat(svc);
      expect(coach.error, isNull);
      expect(coach.failedSend, isNotNull);
      expect(svc.quotaLoads, loads + 1, reason: 'the quota is asked again');

      // A failed history keeps its banner: nothing else would reload it.
      svc.historyFailure = _offline;
      await coach.switchToSession('b');
      expect(coach.historyUnavailable, isTrue);
      await coach.returnToChat(svc);
      expect(coach.error, deL10n.coachErrorHistoryUnavailable);
      expect(coach.historyUnavailable, isTrue);

      await coach.switchToSession('b');
      expect(coach.error, isNull);
      expect(coach.historyUnavailable, isFalse);
    });

    test('without a session the return runs the bootstrap again', () async {
      final svc = _Coach()..sessionList = <ChatSession>[];
      final coach = await _ready(svc);
      expect(coach.activeSessionId, isNull);
      expect(coach.error, deL10n.coachErrorNoSession);
      expect(coach.lockReason, deL10n.coachErrorNoSession);

      svc.sessionList = [_session('a')];
      await coach.returnToChat(svc);
      expect(coach.activeSessionId, 'a');
      expect(coach.error, isNull);
      expect(coach.lockReason, isNull);
    });

    test('a quota answer of the old account is dropped', () async {
      final svc = _Coach();
      final coach = await _ready(svc);
      final next = _Coach();
      coach.updateService(next);
      // The old account's server reports a different count than the one on
      // screen, so taking it over would show.
      svc.quota = const ChatQuotaSnapshot(used: 5, remaining: 0, dailyLimit: 5);
      final loads = svc.quotaLoads;
      await coach.returnToChat(svc);
      expect(svc.quotaLoads, loads + 1, reason: 'the old answer did arrive');
      expect(coach.quota?.remaining, 4);
      expect(coach.quotaExhausted, isFalse);
    });
  });
}
