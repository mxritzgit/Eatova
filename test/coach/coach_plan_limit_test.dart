import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/chat_message.dart';
import 'package:eatova/src/models/chat_session.dart';
import 'package:eatova/src/models/plan_limit_hit.dart';
import 'package:eatova/src/models/plan_status.dart';
import 'package:eatova/src/screens/coach/coach_chat_controller.dart';
import 'package:eatova/src/screens/coach/coach_chat_screen.dart';
import 'package:eatova/src/services/billing/purchase_flow.dart';
import 'package:eatova/src/services/coach_chat_service.dart';
import 'package:eatova/src/services/coach_quota_reset.dart';

import '../support/harness.dart';
import '../support/subscription_fakes.dart';

// Premium in the Coach (docs/PREMIUM.md 4.5): the server's planLimit reaches
// the screen, the limit notice is built from the plan and offers Premium once
// a day on Free, and a tier change moves the lock at once. The clock stands
// at noon UTC of the fakes' plan day, so the quota day is the same in every
// device zone.

SupabaseClient _client(
  Future<http.Response> Function(http.Request request) handler,
) {
  final client = SupabaseClient(
    'https://example.supabase.co',
    'test-anon-key',
    httpClient: MockClient(handler),
  );
  // GoTrue's periodic refresh timer would trip every widget test.
  client.auth.stopAutoRefresh();
  return client;
}

/// A Coach whose every question ends in [failure].
class _Coach extends CoachChatService {
  _Coach(this.failure)
    : super(_client((req) async => http.Response('[]', 200)), 'user-a');

  final Object failure;
  int sends = 0;

  @override
  Future<List<ChatSession>> loadSessions() async => const <ChatSession>[];

  @override
  Future<String?> ensureDefaultSession() async => 's1';

  @override
  Future<List<ChatMessage>> loadHistory(
    String sessionId, {
    int limit = 100,
  }) async => const <ChatMessage>[];

  /// Only asked while no plan is known.
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
    throw failure;
  }
}

/// The quota 429 of a Premium-aware coach-chat, as the service maps it.
CoachQuotaExceeded _quota429(PlanTier tier, int limit, {int? premiumLimit}) =>
    CoachQuotaExceeded(
      message: deL10n.coachErrorDailyLimitReached(limit, '01:00'),
      dailyLimit: limit,
      planLimit: PlanLimitHit(
        feature: PlanFeature.coach,
        tier: tier,
        limit: limit,
        resetAt: nextUtcMidnight(kPlanDay),
        premiumLimit: premiumLimit,
      ),
    );

bool _composerTippbar(WidgetTester tester) =>
    tester
        .widget<TextField>(find.byKey(const ValueKey('coach-input')))
        .enabled ??
    true;

void main() {
  test('der Draht: planLimit im Tageslimit-429, image_locked im Rezept', () async {
    final antworten = <String, (int, Map<String, Object?>)>{
      'quota': (
        429,
        <String, Object?>{
          'error': 'quota_exceeded',
          'reply': 'Tageslimit erreicht.',
          'remaining': 0,
          'daily_limit': 2,
          'reset_at': '2026-10-26T00:00:00.000Z',
          'planLimit': <String, Object?>{
            'feature': 'coach',
            'tier': 'free',
            'limit': 2,
            'resetAt': '2026-10-26T00:00:00.000Z',
            'premiumLimit': 20,
          },
        },
      ),
      'recipe': (
        200,
        <String, Object?>{
          'reply': 'Rezeptvorschlag: Bowl.',
          'refusal': false,
          'remaining': 1,
          'daily_limit': 2,
          'session_id': 's1',
          'image_locked': true,
          'recipe': <String, Object?>{
            'title': 'Bowl',
            'description': 'Schnell.',
            'portion': '1 Portion',
            'ingredients': '- 200 g Kichererbsen',
            'preparation': '1. Mischen.',
            'calories_kcal': 480,
            'protein_g': 26,
            'carbs_g': 55,
            'fat_g': 14,
            'estimated_g': 400,
          },
        },
      ),
    };
    var fall = 'quota';
    final client = _client((req) async {
      final (status, body) = antworten[fall]!;
      return http.Response(
        jsonEncode(body),
        status,
        headers: const {'Content-Type': 'application/json'},
      );
    });
    addTearDown(client.dispose);
    final svc = CoachChatService(client, 'user-a');

    Object? failure;
    try {
      await svc.send('Frage', sessionId: 's1');
    } catch (e) {
      failure = e;
    }
    expect(failure, isA<CoachQuotaExceeded>());
    final hit = (failure as CoachQuotaExceeded).planLimit;
    expect(hit?.tier, PlanTier.free);
    expect(hit?.limit, 2);
    expect(hit?.premiumLimit, 20);
    expect(hit?.resetAt, DateTime.utc(2026, 10, 26));

    fall = 'recipe';
    final rezept = await svc.requestRecipe('Bowl', sessionId: 's1', locale: 'de');
    expect(rezept.imageLocked, isTrue);
    expect(rezept.proposal?.imageBytes, isNull);
  });

  test(
    'Free am Limit: der Hinweis nennt Premium einmal am Tag, danach nur das '
    'Warten',
    () => withClock(Clock.fixed(kPlanDay), () async {
      final plan = await subscriptionController(
        log: FakeSubscriptionLog(plan: planOf(PlanTier.free)),
      );
      addTearDown(plan.dispose);
      final svc = _Coach(_quota429(PlanTier.free, 2, premiumLimit: 20));
      final coach = CoachChatController(service: svc, subscription: plan);
      addTearDown(coach.dispose);
      await coach.bootstrap();
      final time = coachQuotaResetLabel('de');

      await coach.send('Frage');
      expect(coach.canType, isFalse);
      expect(coach.error, deL10n.planLimitCoachPremium(2, time, 20));
      expect(coach.limitUpsell, isTrue);
      expect(
        plan.plan.remaining(PlanFeature.coach),
        0,
        reason: 'the other counters learn the used-up day',
      );

      // Later the same day, back on the tab, another try.
      await coach.returnToChat(svc);
      await coach.send('Noch eine');
      expect(svc.sends, 1, reason: 'a known used-up day sends nothing');
      expect(coach.error, deL10n.planLimitCoach(2, time));
      expect(coach.limitUpsell, isFalse);
    }),
  );

  test(
    'ohne Angebot: Premium wartet nur, ein Server ohne planLimit sperrt wie '
    'bisher',
    () => withClock(Clock.fixed(kPlanDay), () async {
      for (final (name, serverPlan, failure, expected)
          in <(String, PlanStatus?, CoachQuotaExceeded, String)>[
            (
              'Premium am Limit',
              planOf(PlanTier.premium),
              _quota429(PlanTier.premium, 20),
              deL10n.planLimitCoach(20, coachQuotaResetLabel('de')),
            ),
            (
              'alter Server, Plan unbekannt',
              null,
              const CoachQuotaExceeded(
                message: 'Limit erreicht',
                dailyLimit: 5,
              ),
              'Limit erreicht',
            ),
          ]) {
        final plan = await subscriptionController(
          log: FakeSubscriptionLog(plan: serverPlan),
        );
        final coach = CoachChatController(
          service: _Coach(failure),
          subscription: plan,
        );
        await coach.bootstrap();
        await coach.send('Frage');
        expect(coach.quotaExhausted, isTrue, reason: name);
        expect(coach.canType, isFalse, reason: name);
        expect(coach.error, expected, reason: name);
        expect(coach.limitUpsell, isFalse, reason: name);
        coach.dispose();
        plan.dispose();
      }
    }),
  );

  testWidgets(
    'ein Upgrade entsperrt den gesperrten Composer sofort',
    (tester) => withClock(Clock.fixed(kPlanDay), () async {
      tester.view.devicePixelRatio = 3.0;
      tester.view.physicalSize = const Size(402, 781) * 3.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final flow = FakePurchaseFlow();
      final plan = await subscriptionController(
        log: FakeSubscriptionLog(plan: planOf(PlanTier.free)),
        flow: flow,
      );
      addTearDown(plan.dispose);
      final svc = _Coach(_quota429(PlanTier.free, 2, premiumLimit: 20));
      await pumpLocalized(
        tester,
        withSubscription(
          plan,
          CoachChatScreen(service: svc, userName: 'M', subscription: plan),
        ),
        safeArea: false,
        settle: true,
      );
      expect(find.text('2/2 heute frei'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('coach-input')), 'Frage');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('coach-send')));
      await tester.pumpAndSettle();
      expect(_composerTippbar(tester), isFalse);
      expect(find.byKey(const ValueKey('coach-limit-upgrade')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('coach-composer-upgrade')),
        findsOneWidget,
        reason: 'at 0 left on Free the pill takes the counter\'s place',
      );
      expect(find.byKey(const ValueKey('coach-quota-hint')), findsNothing);

      // The store purchase verified: the server's plan is Premium now.
      flow.emit(
        PurchaseVerified(
          active: true,
          plan: planOf(PlanTier.premium, coachUsed: 2),
        ),
      );
      await tester.pump();

      expect(_composerTippbar(tester), isTrue);
      expect(find.text('18/20 heute frei'), findsOneWidget);
      expect(find.byKey(const ValueKey('coach-limit-upgrade')), findsNothing);
      expect(find.byKey(const ValueKey('coach-composer-upgrade')), findsNothing);
      expect(find.byKey(const ValueKey('coach-unsent-retry')), findsOneWidget);
    }),
  );
}
