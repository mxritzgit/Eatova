// The coach chat scrolls under a finger in the REAL shell
// (eatova_home_page.dart). Regression 2026-09-30: every conversation was
// stuck at its end. The pin answered the first pixel of a drag (a metrics
// notification that only reported the new offset) with a jump back to the
// end, and the jump cancelled the drag.

import 'package:clock/clock.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/models/chat_message.dart';
import 'package:eatova/src/models/chat_session.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/coach_chat_service.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/local_cache.dart';

import '../fixlauf_a_helpers.dart';
import '../support/harness.dart';
import 'flow_test_helpers.dart'
    show FakeProductLookupService, pumpUntil, settleFrames, storeOf;

final DateTime _now = DateTime(2026, 9, 28, 19);

const UserProfile _profile = UserProfile(
  weightKg: 80,
  heightCm: 180,
  dailyKcalGoal: 2123,
  proteinGoalG: 162,
  onboardingCompleted: true,
  manualEnergy: true,
);

/// A coach whose saved conversation is long enough to scroll.
class _LongChatCoach extends CoachChatService {
  _LongChatCoach(super.client, super.userId);

  /// `stopAutoRefresh()` is mandatory: GoTrue starts a periodic timer in its
  /// constructor that fails every widget test.
  static _LongChatCoach create() => _LongChatCoach(
    SupabaseClient(
      'https://example.supabase.co',
      'test-anon-key',
      httpClient: MockClient((_) async => http.Response('[]', 200)),
    )..auth.stopAutoRefresh(),
    'user-shell',
  );

  @override
  Future<List<ChatSession>> loadSessions() async => <ChatSession>[
    ChatSession(
      id: 's1',
      title: 'Evening',
      createdAt: _now,
      lastMessageAt: _now,
      messageCount: 12,
    ),
  ];

  @override
  Future<String?> ensureDefaultSession() async => 's1';

  @override
  Future<List<ChatMessage>> loadHistory(
    String sessionId, {
    int limit = 100,
  }) async => List<ChatMessage>.generate(
    12,
    (i) => ChatMessage(
      id: 'm$i',
      role: i.isEven ? ChatRole.user : ChatRole.assistant,
      content: i.isEven
          ? 'Question $i: how much protein today?'
          : 'Answer $i: about 1.6 to 2 g per kilogram of body weight, '
                    'spread over three to four meals a day. ' *
                3,
      createdAt: DateTime(2026, 9, 28, 8, i),
    ),
  );

  @override
  Future<ChatQuotaSnapshot> loadQuotaToday() async =>
      const ChatQuotaSnapshot(used: 0, remaining: 5, dailyLimit: 5);
}

/// A fresh conversation (the start state) whose one answer is a long plan,
/// like the user's report: "Plan tomorrow" from the day card.
class _FreshChatCoach extends _LongChatCoach {
  _FreshChatCoach(super.client, super.userId);

  static _FreshChatCoach create() => _FreshChatCoach(
    SupabaseClient(
      'https://example.supabase.co',
      'test-anon-key',
      httpClient: MockClient((_) async => http.Response('[]', 200)),
    )..auth.stopAutoRefresh(),
    'user-shell',
  );

  final List<String> sent = <String>[];

  @override
  Future<List<ChatMessage>> loadHistory(
    String sessionId, {
    int limit = 100,
  }) async => const <ChatMessage>[];

  @override
  Future<CoachChatReply> send(
    String message, {
    required String sessionId,
    String? imageBase64,
    String? imageMimeType,
    String? userContext,
    void Function(String text)? onPartialReply,
  }) async {
    sent.add(message);
    return CoachChatReply(
      reply: List<String>.generate(
        14,
        (i) =>
            '- Meal ${i + 1}: oats, skyr and berries, about 450 kcal '
            'and 35 g protein.',
      ).join('\n'),
      refusal: false,
      remaining: 4,
      dailyLimit: 5,
      sessionId: sessionId,
    );
  }
}

Future<void> _pumpShellOnCoach(
  WidgetTester tester, {
  CoachChatService? coach,
}) async {
  pinPhoneViewport(tester);
  final server = FixlaufServer()..profileRow = serverProfileRow(_profile);
  // Mock transport owns no sockets; not disposed (see pumpSignedIn).
  final client = SupabaseClient(
    'https://example.supabase.co',
    'test-anon-key',
    httpClient: server.client(),
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  await pumpLocalized(
    tester,
    EatovaHomePage(
      productService: FakeProductLookupService(),
      sync: EatovaSync.forUser(
        client,
        kFixlaufUser,
        coachChat: coach ?? _LongChatCoach.create(),
      ),
      debugCache: LocalCache(InMemoryKeyValueStore(), kFixlaufUser),
      showWelcome: false,
    ),
    locale: const Locale('en'),
    scaffold: false,
    safeArea: false,
    reducedMotion: false,
  );
  await pumpUntil(
    tester,
    () => find.byKey(const ValueKey('screen-welcome')).evaluate().isEmpty,
    'boot completes',
  );
  storeOf(tester).setTab(4);
  await settleFrames(tester);
  await tester.pump(const Duration(seconds: 1));
}

ScrollPosition _chat(WidgetTester tester) => tester
    .state<ScrollableState>(
      find.descendant(
        of: find.byKey(const ValueKey('coach-message-list')),
        matching: find.byType(Scrollable),
      ),
    )
    .position;

/// A finger-like drag by [dy]: small moves with a frame between them.
Future<void> _fingerDrag(WidgetTester tester, double dy) async {
  const steps = 40;
  final gesture = await tester.startGesture(
    tester.getCenter(find.byKey(const ValueKey('coach-message-list'))),
    kind: PointerDeviceKind.touch,
  );
  for (var i = 0; i < steps; i++) {
    await gesture.moveBy(Offset(0, dy / steps));
    await tester.pump(const Duration(milliseconds: 16));
  }
  await gesture.up();
  for (var i = 0; i < 60; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  testWidgets('a saved conversation scrolls up under a finger and back down', (
    tester,
  ) async {
    await withClock(Clock.fixed(_now), () async {
      await _pumpShellOnCoach(tester);
      final end = _chat(tester).maxScrollExtent;
      expect(end, greaterThan(600), reason: 'precondition: long history');
      expect(
        _chat(tester).pixels,
        moreOrLessEquals(end, epsilon: 0.5),
        reason: 'the chat opens at its newest message',
      );

      await _fingerDrag(tester, 320);
      final read = _chat(tester).pixels;
      expect(
        read,
        lessThan(end - 200),
        reason: 'the pin must not cancel the drag and snap back',
      );

      await _fingerDrag(tester, 160);
      expect(
        _chat(tester).pixels,
        lessThan(read - 80),
        reason: 'a second drag keeps scrolling further up',
      );

      await _fingerDrag(tester, -2000);
      expect(
        _chat(tester).pixels,
        moreOrLessEquals(_chat(tester).maxScrollExtent, epsilon: 0.5),
        reason: 'dragging down reaches the newest message again',
      );
    });
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('the same on Android (clamping physics)', (tester) async {
    await withClock(Clock.fixed(_now), () async {
      await _pumpShellOnCoach(tester);
      final end = _chat(tester).maxScrollExtent;
      await _fingerDrag(tester, 320);
      expect(_chat(tester).pixels, lessThan(end - 200));
    });
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('after "Plan tomorrow" from the day card the answer scrolls', (
    tester,
  ) async {
    // 22:00, nothing logged: no main meal is ahead, so the card offers
    // "Plan tomorrow".
    await withClock(Clock.fixed(DateTime(2026, 9, 28, 22)), () async {
      final coach = _FreshChatCoach.create();
      await _pumpShellOnCoach(tester, coach: coach);
      await tester.tap(find.text('Plan tomorrow'));
      for (var i = 0; i < 90; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(coach.sent, ['Help me plan my meals for tomorrow.']);
      final end = _chat(tester).maxScrollExtent;
      expect(end, greaterThan(300), reason: 'precondition: long answer');
      expect(
        _chat(tester).pixels,
        moreOrLessEquals(end, epsilon: 0.5),
        reason: 'the answer glided into view',
      );

      await _fingerDrag(tester, 320);
      expect(
        _chat(tester).pixels,
        lessThan(end - 200),
        reason: 'the answer can be scrolled back up',
      );
    });
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
}
