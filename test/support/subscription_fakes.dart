// Fakes for the Premium spine (2026-10-25): an in-memory server side, an
// in-memory account cache, a scripted purchase pipeline, a store in memory,
// plan builders and a helper that mounts an app below a SubscriptionScope,
// the way EatovaApp does.
// Deliberately no `_test` suffix — this file is not a suite.

import 'dart:async';

import 'package:flutter/widgets.dart';

import 'package:eatova/src/app/subscription.dart';
import 'package:eatova/src/models/plan_status.dart';
import 'package:eatova/src/services/billing/billing_client.dart';
import 'package:eatova/src/services/billing/purchase_flow.dart';
import 'package:eatova/src/services/subscription_sync.dart';

/// Noon UTC of the day the plans in these fakes are counted on.
final DateTime kPlanDay = DateTime.utc(2026, 10, 25, 12);

/// A server snapshot of [tier] on [day] (default [kPlanDay]); Premium comes
/// with an active yearly Google subscription.
PlanStatus planOf(
  PlanTier tier, {
  DateTime? day,
  int coachUsed = 0,
  int analysesUsed = 0,
  SubscriptionInfo? subscription,
}) {
  final at = day ?? kPlanDay;
  final premium = tier == PlanTier.premium;
  return PlanStatus(
    tier: tier,
    subscription:
        subscription ??
        (premium
            ? SubscriptionInfo(
                platform: StorePlatform.google,
                productId: 'eatova_premium',
                basePlanId: 'yearly',
                state: SubscriptionState.active,
                expiresAt: at.add(const Duration(days: 365)),
                autoRenewing: true,
              )
            : null),
    current: premium ? kAssumedPremiumLimits : kAssumedFreeLimits,
    free: kAssumedFreeLimits,
    premium: kAssumedPremiumLimits,
    usage: PlanUsage(
      day: utcDay(at),
      coach: coachUsed,
      mealAnalysis: analysesUsed,
      recipeImport: 0,
    ),
    resetAt: nextUtcMidnight(at),
  );
}

/// The server side in memory. [failReads] makes every plan read throw
/// (offline); [gate] holds plan reads until completed.
class FakeSubscriptionLog implements SubscriptionLog {
  FakeSubscriptionLog({this.plan, this.token = kFakeAccountToken});

  PlanStatus? plan;
  String token;
  bool failReads = false;
  Completer<void>? gate;
  int fetchCalls = 0;

  /// Answers of [refresh] (`subscription-verify`, action refresh).
  VerifyResult refreshResult = const VerifyResult(VerifyOutcome.unavailable);
  int refreshCalls = 0;
  final List<PurchaseProof> verified = <PurchaseProof>[];

  /// What [verify] answers, with [plan]; [verifyGate] holds the answer.
  VerifyOutcome verifyOutcome = VerifyOutcome.active;
  Completer<void>? verifyGate;

  @override
  Future<PlanStatus> fetchPlan() async {
    fetchCalls++;
    // Read before the gate: the answer is what the server had when the
    // request went out.
    final answer = plan;
    final hold = gate;
    if (hold != null) await hold.future;
    if (failReads || answer == null) throw const FakeOffline();
    return answer;
  }

  @override
  Future<String> accountToken() async => token;

  @override
  Future<VerifyResult> verify(PurchaseProof proof) async {
    verified.add(proof);
    final hold = verifyGate;
    if (hold != null) await hold.future;
    return VerifyResult(verifyOutcome, plan: plan);
  }

  @override
  Future<VerifyResult> refresh() async {
    refreshCalls++;
    return refreshResult;
  }
}

const String kFakeAccountToken = '00000000-0000-4000-8000-0000000000ab';

/// Stands in for a network error without touching dart:io.
class FakeOffline implements Exception {
  const FakeOffline();
}

/// The account cache slot in memory; [gate] holds reads until completed (a
/// slow cache open).
class MemoryPlanCache implements PlanStatusCache {
  MemoryPlanCache([this.stored]);

  PlanStatus? stored;
  int writes = 0;
  Completer<void>? gate;

  /// The `upsell_shown` slot.
  Map<PlanFeature, DateTime> upsellDays = <PlanFeature, DateTime>{};

  @override
  Future<PlanStatus?> readPlanStatus() async {
    // Read before the gate, like the server fake.
    final answer = stored;
    await gate?.future;
    return answer;
  }

  @override
  Future<void> writePlanStatus(PlanStatus status) async {
    writes++;
    stored = status;
  }

  @override
  Future<Map<PlanFeature, DateTime>> readUpsellDays() async =>
      Map.of(upsellDays);

  @override
  Future<void> writeUpsellDays(Map<PlanFeature, DateTime> days) async =>
      upsellDays = Map.of(days);
}

/// Both plans as a store would sell them.
const List<PremiumOffer> kFakeOffers = <PremiumOffer>[
  PremiumOffer(
    period: PremiumPeriod.yearly,
    productId: 'eatova_premium',
    basePlanId: 'yearly',
    priceLabel: '49,99 €',
    rawPrice: 49.99,
    currencyCode: 'EUR',
    trialDays: 7,
  ),
  PremiumOffer(
    period: PremiumPeriod.monthly,
    productId: 'eatova_premium',
    basePlanId: 'monthly',
    priceLabel: '7,99 €',
    rawPrice: 7.99,
    currencyCode: 'EUR',
  ),
];

/// A scripted purchase pipeline: [onBuy] and [onRestore] are delivered to
/// the bound account when [buy] or [restore] runs; [emit] delivers one more.
class FakePurchaseFlow implements PurchaseFlow {
  BillingAvailability availabilityAnswer = BillingAvailability.available;
  List<PremiumOffer> offerList = kFakeOffers;
  List<PurchaseEvent> onBuy = const <PurchaseEvent>[];
  List<PurchaseEvent> onRestore = const <PurchaseEvent>[];

  PurchaseAccount? bound;
  final List<({PremiumOffer offer, String token, SubscriptionInfo? current})>
  buys = [];
  int restores = 0;
  final List<({String? productId, StorePlatform? platform})> manageRequests =
      [];

  void emit(PurchaseEvent event) => bound?.onPurchaseEvent(event);

  @override
  Future<BillingAvailability> availability() async => availabilityAnswer;

  @override
  Future<List<PremiumOffer>> offers() async => offerList;

  @override
  Future<void> buy(
    PremiumOffer offer, {
    required String accountToken,
    SubscriptionInfo? current,
  }) async {
    buys.add((offer: offer, token: accountToken, current: current));
    onBuy.forEach(emit);
  }

  @override
  Future<void> restore({bool silent = false}) async {
    restores++;
    onRestore.forEach(emit);
  }

  @override
  Future<void> openManageSubscriptions({
    String? productId,
    StorePlatform? platform,
  }) async => manageRequests.add((productId: productId, platform: platform));

  @override
  void bindAccount(PurchaseAccount account) => bound = account;

  @override
  void unbindAccount(PurchaseAccount account) {
    if (identical(bound, account)) bound = null;
  }
}

/// A controller over [log], [cache] and [flow], bound to [flow]; [loaded]
/// runs its load first.
Future<SubscriptionController> subscriptionController({
  FakeSubscriptionLog? log,
  MemoryPlanCache? cache,
  PurchaseFlow? flow,
  String userId = 'user-a',
  bool loaded = true,
}) async {
  final purchases = flow ?? FakePurchaseFlow();
  final controller = SubscriptionController(
    userId: userId,
    cache: cache ?? MemoryPlanCache(),
    log: log ?? FakeSubscriptionLog(),
    flow: purchases,
  );
  // As the shell does.
  purchases.bindAccount(controller);
  if (loaded) await controller.load();
  return controller;
}

/// [app] below a [SubscriptionScope] bound to [controller] (null: a scope
/// with no account bound, as before sign-in) and [opener].
Widget withSubscription(
  SubscriptionController? controller,
  Widget app, {
  PremiumOpener? opener,
}) {
  final binding = SubscriptionBinding();
  if (controller != null) binding.bind(controller);
  if (opener != null) binding.registerOpener(opener);
  return SubscriptionScope(binding: binding, child: app);
}

/// A Google purchase of `eatova_premium` with [token] as its proof.
StorePurchase googlePurchase(
  String token, {
  StorePurchaseStatus status = StorePurchaseStatus.purchased,
}) => StorePurchase(
  platform: StorePlatform.google,
  productId: 'eatova_premium',
  status: status,
  proof: PurchaseProof.google(
    productId: 'eatova_premium',
    purchaseToken: token,
  ),
  handle: token,
  needsCompletion: true,
);

/// The end of a purchase flow without a purchase (cancel, error, pending).
StorePurchase googleFlowEnd(StorePurchaseStatus status) => StorePurchase(
  platform: StorePlatform.google,
  productId: 'eatova_premium',
  status: status,
);

/// The device's store in memory, as the plugins behave: [restore] answers
/// with one batch of [owned] (empty for none), [buy] with [onBuy];
/// [completed] records every finished transaction.
class FakeBillingClient implements BillingClient {
  FakeBillingClient({this.platform = StorePlatform.google});

  @override
  final StorePlatform? platform;

  final StreamController<List<StorePurchase>> _updates =
      StreamController<List<StorePurchase>>.broadcast();

  List<StorePurchase> owned = <StorePurchase>[];
  List<StorePurchase>? onBuy;
  final List<StorePurchase> completed = <StorePurchase>[];
  final List<({PremiumOffer offer, String token, StorePurchase? replacing})>
  buys = [];
  int restores = 0;

  /// One update from the store.
  void emit(List<StorePurchase> batch) => _updates.add(batch);

  @override
  Future<BillingAvailability> availability() async =>
      BillingAvailability.available;

  @override
  Future<List<PremiumOffer>> offers() async => kFakeOffers;

  @override
  Stream<List<StorePurchase>> get purchases => _updates.stream;

  @override
  Future<void> buy(
    PremiumOffer offer, {
    required String accountToken,
    StorePurchase? replacing,
  }) async {
    buys.add((offer: offer, token: accountToken, replacing: replacing));
    final answer = onBuy;
    if (answer != null) emit(answer);
  }

  @override
  Future<void> restore() async {
    restores++;
    emit(List<StorePurchase>.of(owned));
  }

  @override
  Future<void> complete(StorePurchase purchase) async =>
      completed.add(purchase);

  @override
  Future<void> openManageSubscriptions({String? productId}) async {}
}

/// A signed-in account as the purchase pipeline sees it, recording what it
/// is told.
class RecordingPurchaseAccount implements PurchaseAccount {
  RecordingPurchaseAccount(this.userId, this.log);

  @override
  final String userId;

  @override
  final FakeSubscriptionLog log;

  final List<PurchaseEvent> events = <PurchaseEvent>[];

  @override
  void onPurchaseEvent(PurchaseEvent event) => events.add(event);
}
