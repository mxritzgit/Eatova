// Visual evidence for the redesigned Coach tab (dark redesign, Task 6).
//
// Mounts the REAL signed-in shell at the design's reference geometry with the
// design scenario — Mon 2026-09-28 19:00, budget 2,123 kcal, 1,221 kcal and
// 111 of 162 g protein logged, dinner open — and a fake coach service:
//
//   coach-00  the start state (design/shots/coach-00.png)
//   coach-01  a short conversation, started from the card's primary pill
//
// With --dart-define=DARK_REDESIGN_CAPTURE=true the shots land in
// build/dark-redesign/. Without it the suite still checks the geometry the
// design fixes (title line, capsule on the bar's band, 14 px from the edges).

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/models/chat_message.dart';
import 'package:eatova/src/models/chat_session.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/coach/coach_chat_screen.dart';
import 'package:eatova/src/services/coach_chat_service.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/widgets/design/design.dart';

import '../fixlauf_a_helpers.dart';
import '../flows/flow_test_helpers.dart'
    show FakeProductLookupService, pumpUntil, settleFrames, storeOf;
import '../support/design_capture.dart';
import '../support/harness.dart';

final DateTime _now = DateTime(2026, 9, 28, 19);

const UserProfile _profile = UserProfile(
  weightKg: 80,
  heightCm: 180,
  dailyKcalGoal: 2123,
  proteinGoalG: 162,
  onboardingCompleted: true,
  manualEnergy: true,
);

MealAnalysisResult _meal(String name, int kcal, int proteinG) =>
    MealAnalysisResult(
      mealName: name,
      caloriesKcal: kcal,
      estimatedGrams: 300,
      kcalPer100G: kcal / 3,
      protein: '$proteinG g',
      carbs: '30 g',
      fat: '10 g',
      confidence: 'Mittel',
      portionNotes: '',
      sourceLabel: 'Test',
    );

/// Answers in the order the capture asks.
const List<String> _answers = <String>[
  'Try a turkey steak with quinoa and roasted vegetables: about 610 kcal and '
      '58 g protein. It closes your protein gap and still leaves around '
      '290 kcal for today.',
  'Yes. 150 g of cooked rice has about the same kcal as the quinoa, just '
      '4 g less protein, so you still land close to your goal.',
];

class _CaptureCoach extends CoachChatService {
  _CaptureCoach(super.client, super.userId);

  static _CaptureCoach create() => _CaptureCoach(
    SupabaseClient(
      'https://example.supabase.co',
      'test-anon-key',
      httpClient: MockClient((_) async => http.Response('[]', 200)),
    )..auth.stopAutoRefresh(),
    'user-capture',
  );

  int _asked = 0;

  @override
  Future<List<ChatSession>> loadSessions() async => <ChatSession>[
    ChatSession(
      id: 's1',
      title: 'Evening',
      createdAt: _now,
      lastMessageAt: _now,
      messageCount: 0,
    ),
  ];

  @override
  Future<String?> ensureDefaultSession() async => 's1';

  @override
  Future<List<ChatMessage>> loadHistory(
    String sessionId, {
    int limit = 100,
  }) async => const <ChatMessage>[];

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
  }) async => CoachChatReply(
    reply: _answers[_asked++ % _answers.length],
    refusal: false,
    remaining: 5 - _asked,
    dailyLimit: 5,
    sessionId: sessionId,
  );
}

Future<void> _pumpCoachTab(WidgetTester tester) async {
  pinDesignViewport(tester);
  final server = FixlaufServer()..profileRow = serverProfileRow(_profile);
  final client = SupabaseClient(
    'https://example.supabase.co',
    'test-anon-key',
    httpClient: server.client(),
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  await tester.pumpWidget(
    designCaptureBoundary(
      localizedApp(
        EatovaHomePage(
          productService: FakeProductLookupService(),
          sync: EatovaSync.forUser(
            client,
            kFixlaufUser,
            coachChat: _CaptureCoach.create(),
          ),
          debugCache: LocalCache(InMemoryKeyValueStore(), kFixlaufUser),
          showWelcome: false,
        ),
        locale: const Locale('en'),
        safeArea: false,
        scaffold: false,
      ),
    ),
  );
  await pumpUntil(
    tester,
    () => find.byKey(const ValueKey('screen-welcome')).evaluate().isEmpty,
    'boot completes',
  );
  final store = storeOf(tester);
  unawaited(
    store.addResultToDailyTotal(
      _meal('Oats', 410, 32),
      slot: MealSlot.breakfast,
    ),
  );
  unawaited(
    store.addResultToDailyTotal(
      _meal('Chicken bowl', 640, 58),
      slot: MealSlot.lunch,
    ),
  );
  unawaited(
    store.addResultToDailyTotal(_meal('Skyr', 171, 21), slot: MealSlot.snack),
  );
  await tester.tap(find.byKey(const ValueKey('nav-Coach')));
  await settleFrames(tester, rounds: 60);
}

String _summary(WidgetTester tester) => tester
    .widget<RichText>(
      find.descendant(
        of: find.byKey(const ValueKey('coach-log-summary')),
        matching: find.byType(RichText),
      ),
    )
    .text
    .toPlainText();

void main() {
  setUpAll(loadDesignFonts);

  testWidgets('coach-00 and coach-01: start state and a short conversation', (
    tester,
  ) async {
    await withClock(Clock.fixed(_now), () async {
      await _pumpCoachTab(tester);

      // The design scenario, read from the real store.
      expect(find.text('Good evening, Moritz'), findsOneWidget);
      expect(
        _summary(tester),
        'You have 902 kcal and 51 g protein left. A lean dinner closes the '
        'protein gap without going over.',
      );
      expect(
        find.byKey(const ValueKey('coach-context-status')),
        findsOneWidget,
      );
      expect(find.text('Suggest a dinner'), findsOneWidget);
      expect(find.text('Plan tomorrow'), findsOneWidget);

      // Geometry the design fixes: the capsule on the bar's band and 14 px
      // from the screen edges, like the bar. The title line is the shell's
      // (59 px on every tab, 3 px above the design's 62).
      expect(tester.getTopLeft(find.text('Coach').first).dy, 59);
      final capsule = tester.getRect(
        find.ancestor(
          of: find.byKey(const ValueKey('coach-input')),
          matching: find.byType(FieldCapsule),
        ),
      );
      final band = AppNavBar.reservedHeightFor(kDesignSafeArea.bottom);
      expect(capsule.bottom, kDesignViewport.height - band);
      expect(capsule.height, 56);
      expect(capsule.left, AppNavBar.sideGap);
      expect(capsule.right, kDesignViewport.width - AppNavBar.sideGap);
      // The whole start state fits above the composer, like the design.
      expect(
        tester.getRect(find.byKey(const ValueKey('coach-ai-note'))).bottom,
        lessThan(capsule.top),
      );

      // The design's vertical rhythm (design/coach/template.html at 390 px):
      // orb at 148, the card at 316, the chip row at 542 — each 3 px higher
      // with the shell's title line.
      expect(tester.getTopLeft(find.byType(CoachOrb)).dy, 145);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('coach-log-card'))).dy,
        313,
      );
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('coach-try-recipe'))).dy,
        539,
      );

      await captureDesignShot(tester, 'coach-00');

      await tester.tap(find.byKey(const ValueKey('coach-log-primary')));
      await settleFrames(tester, rounds: 60);
      await tester.enterText(
        find.byKey(const ValueKey('coach-input')),
        'Can I swap the quinoa for rice?',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('coach-send')));
      await settleFrames(tester, rounds: 60);

      expect(find.byKey(const ValueKey('coach-empty')), findsNothing);
      for (final text in <String>[
        'Suggest a dinner that fits the rest of my day.',
        _answers[0],
        'Can I swap the quinoa for rice?',
        _answers[1],
      ]) {
        expect(find.text(text), findsOneWidget, reason: text);
      }
      await captureDesignShot(tester, 'coach-01');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
