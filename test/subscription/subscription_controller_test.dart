// The account's plan and purchases (docs/PREMIUM.md 4.2): the cached plan
// shows first and the server's replaces it, a failed read keeps what was
// known, a read that started before a verified purchase cannot undo it, one
// account's plan never reaches another, every purchase or restore ends in one
// state, and the upgrade hint shows at most once per feature and UTC day.

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/app/subscription.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/plan_limit_hit.dart';
import 'package:eatova/src/models/plan_status.dart';
import 'package:eatova/src/services/billing/purchase_flow.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/services/subscription_sync.dart';
import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';

import '../flows/flow_test_helpers.dart'
    show FakeProductLookupService, settleFrames;
import '../support/fixlauf_a_helpers.dart' show FixlaufServer;
import '../support/subscription_fakes.dart';

void _noopSnack(
  String message, {
  IconData icon = Icons.info_outline_rounded,
  SnackTone tone = SnackTone.positive,
  Duration? duration,
  SnackBarAction? action,
}) {}

HomeStore _store(LocalCache cache) {
  final store = HomeStore(
    sync: null,
    health: const NoopHealthService(),
    notificationService: const NoopNotificationService(),
    initialUserName: 'Test',
    emitSnack: _noopSnack,
    debugCache: cache,
  );
  addTearDown(store.dispose);
  return store;
}

final PlanStatus _free = planOf(PlanTier.free);
final PlanStatus _premium = planOf(PlanTier.premium);

/// All plan timing on the fakes' day.
Future<void> _onPlanDay(Future<void> Function() body) =>
    withClock(Clock.fixed(kPlanDay), body);

void main() {
  test('erst der Cache, dann der Server, und der Cache folgt ihm', () {
    return _onPlanDay(() async {
      final log = FakeSubscriptionLog(plan: _free)..gate = Completer<void>();
      final cache = MemoryPlanCache(_premium);
      final controller = await subscriptionController(
        log: log,
        cache: cache,
        loaded: false,
      );
      addTearDown(controller.dispose);
      final tiers = <PlanTier>[];
      controller.tierChanges.listen((plan) => tiers.add(plan.tier));
      expect(controller.plan.assumed, isTrue);

      final loading = controller.load();
      await pumpEventQueue();
      expect(controller.loaded, isTrue);
      expect(controller.plan, _premium, reason: 'cached, server pending');

      log.gate!.complete();
      await loading;
      await pumpEventQueue();
      expect(controller.plan, _free);
      expect(cache.stored, _free);
      expect(tiers, [PlanTier.premium, PlanTier.free]);
      expect(identical(controller.load(), loading), isTrue);
    });
  });

  test('ein gescheiterter Abgleich behaelt das gecachte Premium', () {
    return _onPlanDay(() async {
      final log = FakeSubscriptionLog(plan: _free)..failReads = true;
      final cache = MemoryPlanCache(_premium);
      final controller = await subscriptionController(log: log, cache: cache);
      addTearDown(controller.dispose);

      await controller.refresh(force: true);

      expect(controller.isPremium, isTrue);
      expect(controller.plan, _premium);
      expect(cache.writes, 0);
      expect(log.fetchCalls, 2);
    });
  });

  test('ein alter Server-Stand ueberschreibt keinen neueren Kauf', () {
    return _onPlanDay(() async {
      final log = FakeSubscriptionLog(plan: _free)..gate = Completer<void>();
      final cache = MemoryPlanCache();
      final flow = FakePurchaseFlow()
        ..onBuy = [PurchaseVerified(active: true, plan: _premium)];
      final controller = await subscriptionController(
        log: log,
        cache: cache,
        flow: flow,
        loaded: false,
      );
      addTearDown(controller.dispose);

      // The read goes out while the account is still Free ...
      final loading = controller.load();
      await pumpEventQueue();
      expect(log.fetchCalls, 1);
      // ... the purchase is verified before it answers ...
      await controller.buy(PremiumPeriod.yearly);
      log.plan = _premium;
      expect(controller.purchaseState, PurchaseState.success);
      // ... and its stale answer lands last.
      log.gate!.complete();
      await loading;

      expect(controller.plan, _premium);
      expect(cache.stored, _premium);
      expect(flow.buys.single.token, kFakeAccountToken);
      expect(flow.buys.single.offer.period, PremiumPeriod.yearly);
      expect(flow.buys.single.current, isNull);
    });
  });

  test('der Cache-Stand verdraengt keinen frischeren Server-Plan', () {
    return _onPlanDay(() async {
      final log = FakeSubscriptionLog(plan: _premium);
      final cache = MemoryPlanCache(_free)..gate = Completer<void>();
      final controller = await subscriptionController(
        log: log,
        cache: cache,
        loaded: false,
      );
      addTearDown(controller.dispose);
      final tiers = <PlanTier>[];
      controller.tierChanges.listen((plan) => tiers.add(plan.tier));

      // The cache opens slowly; a resume refresh answers first ...
      final loading = controller.load();
      await controller.refresh();
      expect(controller.isPremium, isTrue);
      // ... and the forced read after the cache fails.
      log.failReads = true;
      cache.gate!.complete();
      await loading;
      await pumpEventQueue();

      expect(controller.plan, _premium);
      expect(tiers, [PlanTier.premium]);
    });
  });

  test('der Plan von Konto A erscheint nie bei Konto B', () {
    return _onPlanDay(() async {
      final storage = InMemoryKeyValueStore();
      final storeA = _store(LocalCache(storage, 'A'));
      final a = SubscriptionController(
        userId: 'A',
        cache: storeA,
        log: FakeSubscriptionLog(plan: _premium),
      );
      addTearDown(a.dispose);
      await a.load();
      await storeA.writePaywallPrompt(PaywallPromptState.answered);
      await storeA.writeLegacyNotice(DateTime.utc(2027, 1, 31));
      expect(a.takeUpsell(PlanFeature.coach), isTrue);
      await pumpEventQueue();
      expect(await storeA.readPlanStatus(), _premium);

      // B signs in on the same device, offline.
      final storeB = _store(LocalCache(storage, 'B'));
      final b = SubscriptionController(
        userId: 'B',
        cache: storeB,
        log: FakeSubscriptionLog(plan: _free)..failReads = true,
      );
      addTearDown(b.dispose);
      await b.load();

      expect(b.isPremium, isFalse);
      expect(b.plan.assumed, isTrue);
      expect(await storeB.readPlanStatus(), isNull);
      expect(await storeB.readPaywallPrompt(), isNull);
      expect(await storeB.readLegacyNotice(), isNull);
      expect(b.takeUpsell(PlanFeature.coach), isTrue);
      // A keeps its own slots.
      expect(await storeA.readPaywallPrompt(), PaywallPromptState.answered);
      expect(await storeA.readLegacyNotice(), DateTime.utc(2027, 1, 31));
      expect(await storeA.readUpsellDays(), {
        PlanFeature.coach: utcDay(kPlanDay),
      });
    });
  });

  testWidgets('die Shell bindet ihr Konto und gibt es beim Wechsel ab', (
    tester,
  ) async {
    final binding = SubscriptionBinding();
    final flow = FakePurchaseFlow();
    final client = SupabaseClient(
      'https://example.supabase.co',
      'test-anon-key',
      httpClient: FixlaufServer().client(),
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    final syncs = <String, EatovaSync>{
      for (final (user, plan) in [('user-a', _premium), ('user-b', _free)])
        user: EatovaSync.forUser(
          client,
          user,
          subscription: FakeSubscriptionLog(plan: plan),
        ),
    };
    Widget shell(String user) => SubscriptionScope(
      binding: binding,
      child: MaterialApp(
        theme: buildEatovaTheme(Brightness.light),
        locale: const Locale('en'),
        supportedLocales: const [Locale('de'), Locale('en')],
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: EatovaHomePage(
          key: ValueKey(user),
          productService: FakeProductLookupService(),
          sync: syncs[user],
          debugCache: LocalCache(InMemoryKeyValueStore(), user),
          purchaseFlow: flow,
        ),
      ),
    );

    await tester.pumpWidget(shell('user-a'));
    await settleFrames(tester);
    final a = binding.controller!;
    expect(a.userId, 'user-a');
    expect(identical(flow.bound, a), isTrue);
    expect(a.isPremium, isTrue, reason: 'loaded from its own server side');

    // The next account's shell mounts before the old one disposes.
    await tester.pumpWidget(shell('user-b'));
    await settleFrames(tester);
    final b = binding.controller!;
    expect(b.userId, 'user-b');
    expect(identical(flow.bound, b), isTrue);
    expect(b.isPremium, isFalse);

    await tester.pumpWidget(const SizedBox());
    expect(binding.controller, isNull);
    expect(flow.bound, isNull);
  });

  test('Kaufen und Wiederherstellen enden je in genau einem Zustand', () {
    return _onPlanDay(() async {
      final rows = <(String, bool, List<PurchaseEvent>, PurchaseState)>[
        (
          'Kauf',
          false,
          [
            const PurchasePending(),
            PurchaseVerified(active: true, plan: _premium),
          ],
          PurchaseState.success,
        ),
        ('abgebrochen', false, [const PurchaseCanceled()], PurchaseState.idle),
        ('ausstehend', false, [const PurchasePending()], PurchaseState.pending),
        (
          'fremdes Konto',
          false,
          [const PurchaseOwnedByOther()],
          PurchaseState.ownedByOther,
        ),
        (
          'Pruefung spaeter',
          false,
          [const PurchaseVerifyDeferred()],
          PurchaseState.verifyDeferred,
        ),
        (
          'abgelehnt',
          false,
          [const PurchaseInvalid(reason: 'bundle')],
          PurchaseState.failed,
        ),
        (
          'nicht entitled',
          false,
          [PurchaseVerified(active: false, plan: _free)],
          PurchaseState.failed,
        ),
        (
          'nichts gefunden',
          true,
          const <PurchaseEvent>[],
          PurchaseState.restoredNothing,
        ),
        (
          'abgelaufenes, dann aktives',
          true,
          [
            PurchaseVerified(active: false, plan: _free),
            PurchaseVerified(active: true, plan: _premium),
          ],
          PurchaseState.restored,
        ),
        (
          'nur abgelaufen',
          true,
          [PurchaseVerified(active: false, plan: _free)],
          PurchaseState.restoredNothing,
        ),
        (
          'fremdes Konto beim Wiederherstellen',
          true,
          [const PurchaseOwnedByOther(), const PurchaseRestoredNothing()],
          PurchaseState.ownedByOther,
        ),
        // In-app purchases carry the buyer's token: another account's
        // purchase is a 422 `account`, not a 409.
        (
          'Token eines anderen Kontos',
          true,
          [const PurchaseInvalid(reason: 'account')],
          PurchaseState.ownedByOther,
        ),
      ];
      for (final (name, restore, events, outcome) in rows) {
        final flow = FakePurchaseFlow();
        if (restore) {
          flow.onRestore = events;
        } else {
          flow.onBuy = events;
        }
        final controller = await subscriptionController(
          log: FakeSubscriptionLog(plan: _free),
          flow: flow,
        );
        if (restore) {
          await controller.restore();
        } else {
          await controller.buy(PremiumPeriod.monthly);
        }
        expect(controller.purchaseState, outcome, reason: name);
        controller.dispose();
      }

      // Without the store's prices nothing is sold; no sheet opens.
      final empty = FakePurchaseFlow()..offerList = const [];
      final controller = await subscriptionController(flow: empty);
      addTearDown(controller.dispose);
      await controller.buy(PremiumPeriod.yearly);
      expect(controller.purchaseState, PurchaseState.failed);
      expect(empty.buys, isEmpty);

      // Unasked results only update the plan.
      controller.clearPurchaseState();
      empty.bindAccount(controller);
      empty.emit(const PurchaseOwnedByOther());
      empty.emit(PurchaseVerified(active: true, plan: _premium));
      expect(controller.purchaseState, PurchaseState.idle);
      expect(controller.isPremium, isTrue);
    });
  });

  test('Mehr mit Premium hoechstens einmal pro Funktion und UTC-Tag, auch '
      'ueber einen Neustart', () async {
    var now = DateTime.utc(2026, 10, 25, 23, 58);
    await withClock(Clock(() => now), () async {
      final cache = MemoryPlanCache();
      final first = await subscriptionController(cache: cache);
      addTearDown(first.dispose);
      expect(first.takeUpsell(PlanFeature.coach), isTrue);
      expect(first.takeUpsell(PlanFeature.coach), isFalse);
      expect(first.takeUpsell(PlanFeature.mealAnalysis), isTrue);
      await pumpEventQueue();

      // The process is killed; the next start on the same UTC day knows.
      final second = await subscriptionController(cache: cache);
      addTearDown(second.dispose);
      expect(second.takeUpsell(PlanFeature.coach), isFalse);
      expect(second.takeUpsell(PlanFeature.recipeImport), isTrue);

      now = DateTime.utc(2026, 10, 26, 0, 1);
      expect(second.takeUpsell(PlanFeature.coach), isTrue);
      expect(second.takeUpsell(PlanFeature.mealAnalysis), isTrue);
      expect(second.takeUpsell(PlanFeature.mealAnalysis), isFalse);
    });
    expect(
      SubscriptionController.preview().takeUpsell(PlanFeature.coach),
      isFalse,
    );
  });

  test('der Abgleich ist gedrosselt und laesst Google kurz vor Ablauf und '
      'waehrend einer Sperre nachpruefen', () async {
    var now = kPlanDay;
    await withClock(Clock(() => now), () async {
      final log = FakeSubscriptionLog(plan: _free);
      final controller = await subscriptionController(log: log);
      addTearDown(controller.dispose);
      expect(log.fetchCalls, 1);

      await controller.refresh();
      expect(log.fetchCalls, 1, reason: 'within the interval');
      now = now.add(kPlanRefreshInterval);
      await controller.refresh();
      expect(log.fetchCalls, 2);
      expect(log.refreshCalls, 0, reason: 'nothing to re-check on Free');

      final expiring = planOf(
        PlanTier.premium,
        subscription: SubscriptionInfo(
          platform: StorePlatform.google,
          productId: 'eatova_premium',
          basePlanId: 'monthly',
          state: SubscriptionState.active,
          expiresAt: now.add(const Duration(hours: 20)),
          autoRenewing: true,
        ),
      );
      final renewed = planOf(PlanTier.premium);
      log
        ..plan = expiring
        ..refreshResult = VerifyResult(VerifyOutcome.active, plan: renewed);
      await controller.refresh(force: true);
      expect(log.refreshCalls, 1);
      expect(controller.plan, renewed);

      // A hold outlasts the 30 days behind; without a store notification
      // only the re-check closes the row once Google ends it.
      final held = planOf(
        PlanTier.free,
        subscription: SubscriptionInfo(
          platform: StorePlatform.google,
          productId: 'eatova_premium',
          basePlanId: 'monthly',
          state: SubscriptionState.onHold,
          expiresAt: now.subtract(const Duration(days: 40)),
          autoRenewing: true,
        ),
      );
      final closed = planOf(PlanTier.free);
      log
        ..plan = held
        ..refreshResult = VerifyResult(VerifyOutcome.inactive, plan: closed);
      await controller.refresh(force: true);
      expect(log.refreshCalls, 2);
      expect(controller.plan, closed);
    });
  });

  test(
    'Antworten der KI-Funktionen zaehlen mit, ein fremder Tarif liest neu',
    () {
      return _onPlanDay(() async {
        final log = FakeSubscriptionLog(plan: _free);
        final cache = MemoryPlanCache();
        final controller = await subscriptionController(log: log, cache: cache);
        addTearDown(controller.dispose);

        controller.noteUsage(PlanFeature.mealAnalysis, 2);
        controller.noteUsage(PlanFeature.mealAnalysis, 1);
        expect(controller.plan.remaining(PlanFeature.mealAnalysis), 1);
        expect(cache.stored!.usage.mealAnalysis, 2);

        // A server count that is behind does not take it back.
        await controller.refresh(force: true);
        expect(controller.plan.remaining(PlanFeature.mealAnalysis), 1);

        // Premium bought on another device: the server applied 20.
        log.plan = _premium;
        controller.noteLimitHit(
          PlanLimitHit(
            feature: PlanFeature.coach,
            tier: PlanTier.premium,
            limit: 20,
            resetAt: DateTime.utc(2026, 10, 26),
          ),
        );
        await pumpEventQueue();
        expect(controller.isPremium, isTrue);
        expect(controller.plan.remaining(PlanFeature.coach), 0);
      });
    },
  );
}
