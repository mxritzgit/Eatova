// The redesigned Coach start state through the REAL shell
// (eatova_home_page.dart): the "From today's log" card reads the same numbers
// as HomeStore.nutritionSummaryForFoodDate and follows every logged meal, the
// "Sees today's log" status follows whether the coach gets diary context, and
// a card pill reaches the coach service with the store's context.

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/chat_message.dart';
import 'package:eatova/src/models/chat_session.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/coach_chat_service.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/kcal_format.dart';
import 'package:eatova/src/services/local_cache.dart';

import '../fixlauf_a_helpers.dart';
import '../support/harness.dart';
import 'flow_test_helpers.dart'
    show FakeProductLookupService, pumpUntil, settleFrames, storeOf;

/// Monday, 28 September 2026, 19:00 — the design's evening, dinner open.
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
      carbs: '20 g',
      fat: '10 g',
      confidence: 'Mittel',
      portionNotes: '',
      sourceLabel: 'Test',
    );

class _ShellCoach extends CoachChatService {
  _ShellCoach(super.client, super.userId);

  /// `stopAutoRefresh()` is mandatory: GoTrue starts a periodic timer in its
  /// constructor that fails every widget test.
  static _ShellCoach create() => _ShellCoach(
    SupabaseClient(
      'https://example.supabase.co',
      'test-anon-key',
      httpClient: MockClient((_) async => http.Response('[]', 200)),
    )..auth.stopAutoRefresh(),
    'user-shell',
  );

  final List<({String message, String? userContext})> sent = [];

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
  }) async {
    sent.add((message: message, userContext: userContext));
    return CoachChatReply(
      reply: 'Salmon, rice and greens fit well.',
      refusal: false,
      remaining: 4,
      dailyLimit: 5,
      sessionId: sessionId,
    );
  }
}

/// The shell over a fake server, signed in with [coach] as the coach service,
/// or signed out (no sync) when [coach] is null.
Future<HomeStore> _pumpShell(WidgetTester tester, _ShellCoach? coach) async {
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
    coach == null
        ? EatovaHomePage(productService: FakeProductLookupService())
        : EatovaHomePage(
            productService: FakeProductLookupService(),
            sync: EatovaSync.forUser(client, kFixlaufUser, coachChat: coach),
            debugCache: LocalCache(InMemoryKeyValueStore(), kFixlaufUser),
            showWelcome: false,
          ),
    locale: const Locale('en'),
    scaffold: false,
    safeArea: false,
  );
  await pumpUntil(
    tester,
    () => find.byKey(const ValueKey('screen-welcome')).evaluate().isEmpty,
    'boot completes',
  );
  final store = storeOf(tester);
  if (coach == null) store.profile = _profile;
  store.setTab(4);
  await settleFrames(tester);
  return store;
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

AppLocalizations _l10n(WidgetTester tester) =>
    tester.element(find.byKey(const ValueKey('screen-coach'))).l10n;

String _kcal(WidgetTester tester, int value) =>
    _l10n(tester).coachLogKcal(formatThousands(value, 'en'));

String _protein(WidgetTester tester, int value) =>
    _l10n(tester).coachLogProtein(formatThousands(value, 'en'));

void main() {
  testWidgets('the day card follows the store: empty day, meals, over budget', (
    tester,
  ) async {
    await withClock(Clock.fixed(_now), () async {
      final store = await _pumpShell(tester, _ShellCoach.create());
      final l10n = _l10n(tester);

      // Nothing logged: the budget itself.
      var day = store.nutritionSummaryForFoodDate(_now);
      expect(day.budgetKcal, 2123);
      expect(
        _summary(tester),
        l10n.coachLogNothingLogged(
          _kcal(tester, day.budgetKcal),
          _protein(tester, day.proteinGoalG),
        ),
      );
      expect(find.text(l10n.coachLogSuggestMeal('dinner')), findsOneWidget);

      // The design scenario: 1,221 kcal and 111 g protein logged.
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
        store.addResultToDailyTotal(
          _meal('Skyr', 171, 21),
          slot: MealSlot.snack,
        ),
      );
      await settleFrames(tester);
      day = store.nutritionSummaryForFoodDate(_now);
      expect(day.remainingKcal, 902);
      expect(day.proteinLeftG, 51);
      expect(
        _summary(tester),
        '${l10n.coachLogLeft(_kcal(tester, 902), _protein(tester, 51))} '
        '${l10n.coachLogProteinHint('dinner')}',
      );

      // A big dinner: over budget, and the card stops suggesting food.
      unawaited(
        store.addResultToDailyTotal(
          _meal('Pizza', 1102, 20),
          slot: MealSlot.dinner,
        ),
      );
      await settleFrames(tester);
      day = store.nutritionSummaryForFoodDate(_now);
      expect(day.remainingKcal, -200);
      expect(
        _summary(tester),
        '${l10n.coachLogOver(_kcal(tester, 200))} '
        '${l10n.coachLogProteinOpen(_protein(tester, day.proteinLeftG))}',
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('coach-log-primary')),
          matching: find.text(l10n.coachLogPlanTomorrow),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('coach-log-secondary')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  testWidgets('signed in: the status shows and a pill sends the store\'s '
      'context', (tester) async {
    await withClock(Clock.fixed(_now), () async {
      final coach = _ShellCoach.create();
      final store = await _pumpShell(tester, coach);
      final l10n = _l10n(tester);
      expect(
        find.byKey(const ValueKey('coach-context-status')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('coach-log-primary')));
      await settleFrames(tester);
      expect(coach.sent, hasLength(1));
      expect(
        coach.sent.single.message,
        l10n.coachLogPromptSuggestMeal('dinner'),
      );
      expect(
        coach.sent.single.userContext,
        store.coachContext,
        reason: 'the pill goes through the same path as a typed question',
      );
      expect(find.byKey(const ValueKey('coach-empty')), findsNothing);
      expect(find.text('Salmon, rice and greens fit well.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  testWidgets('signed out: no context status, the card still reads the day, '
      'its pills are off', (tester) async {
    await withClock(Clock.fixed(_now), () async {
      final handle = tester.ensureSemantics();
      final store = await _pumpShell(tester, null);
      expect(find.byKey(const ValueKey('coach-context-status')), findsNothing);
      final day = store.nutritionSummaryForFoodDate(_now);
      expect(_summary(tester), contains(_kcal(tester, day.budgetKcal)));
      expect(
        tester.getSemantics(find.byKey(const ValueKey('coach-log-primary'))),
        isSemantics(isButton: true, isEnabled: false, hasEnabledState: true),
      );
      handle.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
