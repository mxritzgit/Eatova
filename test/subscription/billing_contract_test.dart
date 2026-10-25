// The store side of Premium as the app sees it (docs/PREMIUM.md 1.2, 4.2):
// savings come from the store's prices, a proof never prints its secret,
// a device without a store sells nothing, and the scope helpers reach the
// bound account or do nothing.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/subscription.dart';
import 'package:eatova/src/models/plan_status.dart';
import 'package:eatova/src/services/billing/billing_client.dart';
import 'package:eatova/src/services/billing/purchase_flow.dart';

import '../support/subscription_fakes.dart';

class _BrokenStore extends FakePurchaseFlow {
  @override
  Future<BillingAvailability> availability() =>
      Future<BillingAvailability>.error(StateError('billing service gone'));
}

void main() {
  test('die Ersparnis kommt aus den Store-Preisen', () {
    final [yearly, monthly] = kFakeOffers;
    expect(yearlySavingsPercent(yearly: yearly, monthly: monthly), 48);
    expect(yearly.monthlyEquivalent, closeTo(4.17, 0.005));
    expect(yearly.hasTrial, isTrue);
    expect(monthly.hasTrial, isFalse);
    const dollars = PremiumOffer(
      period: PremiumPeriod.monthly,
      productId: 'eatova_premium',
      priceLabel: r'$8.99',
      rawPrice: 8.99,
      currencyCode: 'USD',
    );
    expect(yearlySavingsPercent(yearly: yearly, monthly: dollars), isNull);
    expect(yearlySavingsPercent(yearly: monthly, monthly: yearly), isNull);
  });

  test('ein Kaufbeleg nennt sein Geheimnis nie', () {
    const proofs = [
      PurchaseProof.google(
        productId: 'eatova_premium',
        purchaseToken: 'secret-play-token',
      ),
      PurchaseProof.apple(
        productId: 'eatova_premium_yearly',
        signedTransaction: 'secret.jws.value',
      ),
    ];
    for (final proof in proofs) {
      expect('$proof', isNot(contains('secret')), reason: proof.productId);
    }
    final purchase = StorePurchase(
      platform: StorePlatform.google,
      productId: 'eatova_premium',
      status: StorePurchaseStatus.purchased,
      proof: proofs.first,
    );
    expect('$purchase', isNot(contains('secret')));
  });

  test('ohne Store wird nichts verkauft', () async {
    final rows = <(String, PurchaseFlow, BillingAvailability)>[
      ('kein Store', const NoPurchaseFlow(), BillingAvailability.unsupported),
      ('Store kaputt', _BrokenStore(), BillingAvailability.unavailable),
      ('Store da', FakePurchaseFlow(), BillingAvailability.available),
    ];
    for (final (name, flow, availability) in rows) {
      final controller = await subscriptionController(flow: flow);
      await controller.loadOffers();
      expect(controller.availability, availability, reason: name);
      expect(
        controller.storeReady,
        availability == BillingAvailability.available,
        reason: name,
      );
      if (!controller.storeReady) {
        await controller.buy(PremiumPeriod.yearly);
        expect(controller.purchaseState, PurchaseState.failed, reason: name);
      }
      controller.dispose();
    }

    const store = NoBillingClient();
    expect(store.platform, isNull);
    expect(await store.availability(), BillingAvailability.unsupported);
    expect(await store.offers(), isEmpty);
    await expectLater(
      store.buy(kFakeOffers.first, accountToken: kFakeAccountToken),
      throwsA(isA<UnsupportedError>()),
    );
  });

  testWidgets('openPremium und Abo verwalten erreichen das gebundene Konto', (
    tester,
  ) async {
    final flow = FakePurchaseFlow();
    final controller = await subscriptionController(
      flow: flow,
      log: FakeSubscriptionLog(plan: planOf(PlanTier.premium)),
    );
    addTearDown(controller.dispose);
    final opened = <PremiumSource>[];
    Future<void> opener(BuildContext context, PremiumSource source) async =>
        opened.add(source);
    late BuildContext bound;
    late BuildContext unbound;

    await tester.pumpWidget(
      Column(
        textDirection: TextDirection.ltr,
        children: [
          withSubscription(
            controller,
            Builder(
              builder: (context) {
                bound = context;
                return const SizedBox();
              },
            ),
            opener: opener,
          ),
          Builder(
            builder: (context) {
              unbound = context;
              return const SizedBox();
            },
          ),
        ],
      ),
    );

    await openPremium(bound, source: PremiumSource.coach);
    await openManageSubscription(bound);
    await openPremium(unbound, source: PremiumSource.profile);
    await openManageSubscription(unbound);

    expect(opened, [PremiumSource.coach]);
    expect(flow.manageRequests, [
      (productId: 'eatova_premium', platform: StorePlatform.google),
    ]);
    expect(SubscriptionScope.controllerOf(unbound), isNull);
  });
}
