// "An upgrade unlocks the Coach at once" (docs/PREMIUM.md 4.5) through the
// REAL shell: it runs through two wirings in eatova_home_page.dart, the
// `subscription:` argument to the Coach screen (the composer and counter)
// and the tierChanges -> CoachChatService.adoptPlanLimit listener (the limit
// the service asks the quota RPC with). Each one alone breaks the guarantee.

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/chat_message.dart';
import 'package:eatova/src/models/chat_session.dart';
import 'package:eatova/src/models/plan_limit_hit.dart';
import 'package:eatova/src/models/plan_status.dart';
import 'package:eatova/src/services/billing/purchase_flow.dart';
import 'package:eatova/src/services/coach_chat_service.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/local_cache.dart';

import '../support/fixlauf_a_helpers.dart';
import '../support/harness.dart';
import '../support/subscription_fakes.dart';
import 'flow_test_helpers.dart'
    show FakeProductLookupService, pumpUntil, settleFrames, storeOf;

/// A Coach on Free at 2/2: every question ends in the tier 429, after which
/// the service remembers the limit 2, as the real one does.
class _UsedUpCoach extends CoachChatService {
  _UsedUpCoach(super.client, super.userId);

  /// `stopAutoRefresh()` is mandatory: GoTrue starts a periodic timer in its
  /// constructor that fails every widget test.
  static _UsedUpCoach create() => _UsedUpCoach(
    SupabaseClient(
      'https://example.supabase.co',
      'test-anon-key',
      httpClient: MockClient((_) async => http.Response('[]', 200)),
    )..auth.stopAutoRefresh(),
    kFixlaufUser,
  );

  @override
  Future<List<ChatSession>> loadSessions() async => <ChatSession>[
    ChatSession(
      id: 's1',
      title: 'Heute',
      createdAt: kPlanDay,
      lastMessageAt: kPlanDay,
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
  Future<CoachChatReply> send(
    String message, {
    required String sessionId,
    String? imageBase64,
    String? imageMimeType,
    String? userContext,
    void Function(String text)? onPartialReply,
  }) async {
    serverDailyLimit = 2;
    throw CoachQuotaExceeded(
      message: deL10n.coachErrorDailyLimitReached(2, '01:00'),
      dailyLimit: 2,
      planLimit: PlanLimitHit(
        feature: PlanFeature.coach,
        tier: PlanTier.free,
        limit: 2,
        resetAt: nextUtcMidnight(kPlanDay),
        premiumLimit: 20,
      ),
    );
  }
}

bool _composerTypeable(WidgetTester tester) =>
    tester
        .widget<TextField>(find.byKey(const ValueKey('coach-input')))
        .enabled ??
    true;

void main() {
  testWidgets('ein Upgrade in der Shell entsperrt den Coach und hebt das '
      'gemerkte Limit', (tester) async {
    await withClock(Clock.fixed(kPlanDay), () async {
      pinPhoneViewport(tester);
      final server = FixlaufServer()
        ..profileRow = serverProfileRow(completedProfile);
      // Mock transport owns no sockets; not disposed (see pumpSignedIn).
      final client = SupabaseClient(
        'https://example.supabase.co',
        'test-anon-key',
        httpClient: server.client(),
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      final coach = _UsedUpCoach.create();
      final flow = FakePurchaseFlow();
      await pumpLocalized(
        tester,
        EatovaHomePage(
          productService: FakeProductLookupService(),
          sync: EatovaSync.forUser(
            client,
            kFixlaufUser,
            coachChat: coach,
            subscription: FakeSubscriptionLog(plan: planOf(PlanTier.free)),
          ),
          debugCache: LocalCache(InMemoryKeyValueStore(), kFixlaufUser),
          purchaseFlow: flow,
          showWelcome: false,
        ),
        scaffold: false,
        safeArea: false,
      );
      await pumpUntil(
        tester,
        () => find.byKey(const ValueKey('screen-welcome')).evaluate().isEmpty,
        'boot completes',
      );
      storeOf(tester).setTab(4);
      await settleFrames(tester);

      await tester.enterText(
        find.byKey(const ValueKey('coach-input')),
        'Frage',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('coach-send')));
      await settleFrames(tester);
      expect(_composerTypeable(tester), isFalse, reason: 'Free at 2/2');
      expect(coach.serverDailyLimit, 2);

      // The store purchase verified: the server's plan is Premium now.
      flow.emit(
        PurchaseVerified(
          active: true,
          plan: planOf(PlanTier.premium, coachUsed: 2),
        ),
      );
      await settleFrames(tester);

      // `subscription: _subscription` reaches the Coach screen ...
      expect(_composerTypeable(tester), isTrue);
      expect(find.text(deL10n.coachQuotaCounter(18, 20)), findsOneWidget);
      // ... and the shell's tierChanges listener moved the service's limit,
      // which the UI alone cannot show.
      expect(coach.serverDailyLimit, 20);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
