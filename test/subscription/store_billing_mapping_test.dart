// The store plugins' data as the app reads it (docs/PREMIUM.md 1.2, 4.2):
// prices are the stores' own, a trial shows only where the store offers a
// free phase, every purchase carries its platform's proof, and a purchase
// request carries the account token and the plan change.

import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/billing_client_wrappers.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';
import 'package:in_app_purchase_storekit/in_app_purchase_storekit.dart';
import 'package:in_app_purchase_storekit/store_kit_2_wrappers.dart';

import 'package:eatova/src/services/billing/billing_client.dart';
import 'package:eatova/src/services/billing/store_billing_client.dart';

import '../support/subscription_fakes.dart';

PricingPhaseWrapper _phase(
  String period,
  int micros, {
  RecurrenceMode mode = RecurrenceMode.infiniteRecurring,
  int cycles = 0,
}) => PricingPhaseWrapper(
  billingCycleCount: cycles,
  billingPeriod: period,
  formattedPrice: micros == 0 ? 'Kostenlos' : '${micros ~/ 10000 / 100} €',
  priceAmountMicros: micros,
  priceCurrencyCode: 'EUR',
  recurrenceMode: mode,
);

SubscriptionOfferDetailsWrapper _plan(
  String basePlanId,
  List<PricingPhaseWrapper> phases, {
  String? offerId,
}) => SubscriptionOfferDetailsWrapper(
  basePlanId: basePlanId,
  offerId: offerId,
  offerTags: const <String>[],
  offerIdToken: 'token-$basePlanId-${offerId ?? 'base'}',
  pricingPhases: phases,
);

/// What Play returns for `eatova_premium`: one entry per base plan and offer.
List<ProductDetails> _play(List<SubscriptionOfferDetailsWrapper> plans) =>
    GooglePlayProductDetails.fromProductDetails(
      ProductDetailsWrapper(
        description: '',
        name: 'Eatova Premium',
        productId: kGooglePremiumProductId,
        productType: ProductType.subs,
        subscriptionOfferDetails: plans,
        title: 'Eatova Premium',
      ),
    );

ProductDetails _appStore(
  String id,
  double price,
  String label, {
  SK2SubscriptionOffer? intro,
}) => AppStoreProduct2Details.fromSK2Product(
  SK2Product(
    id: id,
    displayName: 'Eatova Premium',
    displayPrice: label,
    description: '',
    price: price,
    type: SK2ProductType.autoRenewable,
    priceLocale: SK2PriceLocale(currencyCode: 'EUR', currencySymbol: '€'),
    subscription: SK2SubscriptionInfo(
      subscriptionGroupID: 'group',
      promotionalOffers: [?intro],
      subscriptionPeriod: SK2SubscriptionPeriod(
        value: 1,
        unit: id == kAppleYearlyProductId
            ? SK2SubscriptionPeriodUnit.year
            : SK2SubscriptionPeriodUnit.month,
      ),
    ),
  ),
);

PurchaseWrapper _playPurchase(String token, {required bool acknowledged}) =>
    PurchaseWrapper(
      orderId: 'GPA.$token',
      packageName: kPlayPackageName,
      purchaseTime: 0,
      purchaseToken: token,
      signature: '',
      products: const [kGooglePremiumProductId],
      isAutoRenewing: true,
      originalJson: '{}',
      isAcknowledged: acknowledged,
      purchaseState: PurchaseStateWrapper.purchased,
    );

/// A plugin update; the mapping reads only the fields both stores share.
PurchaseDetails _details(
  PurchaseStatus status, {
  String productId = kAppleYearlyProductId,
  String proof = 'header.payload.signature',
}) => SK2PurchaseDetails(
  productID: productId,
  purchaseID: '7',
  verificationData: PurchaseVerificationData(
    localVerificationData: '{}',
    serverVerificationData: proof,
    source: 'app_store',
  ),
  transactionDate: '0',
  status: status,
);

/// Period, offer token, price label, raw price and trial days.
String _offer(PremiumOffer o) =>
    '${o.period.name} ${o.offerToken} ${o.priceLabel} ${o.rawPrice} '
    'trial ${o.trialDays}';

void main() {
  test('Google: Basispreis je Plan, ein Angebot nur als Gratisphase', () {
    final yearly = _plan('yearly', [_phase('P1Y', 49990000)]);
    final monthly = _plan('monthly', [_phase('P1M', 7990000)]);
    final trial = _plan('yearly', offerId: 'trial', [
      _phase('P1W', 0, mode: RecurrenceMode.finiteRecurring, cycles: 1),
      _phase('P1Y', 49990000),
    ]);
    final discount = _plan('monthly', offerId: 'intro', [
      _phase('P1M', 3990000, mode: RecurrenceMode.finiteRecurring, cycles: 3),
      _phase('P1M', 7990000),
    ]);
    final rows =
        <(String, List<SubscriptionOfferDetailsWrapper>, List<String>)>[
          (
            'ohne Angebot',
            [yearly, monthly],
            [
              'yearly token-yearly-base 49.99 € 49.99 trial null',
              'monthly token-monthly-base 7.99 € 7.99 trial null',
            ],
          ),
          (
            'Testphase und Rabatt',
            [monthly, discount, trial, yearly],
            [
              'yearly token-yearly-trial 49.99 € 49.99 trial 7',
              'monthly token-monthly-base 7.99 € 7.99 trial null',
            ],
          ),
          ('nur ein Angebot, kein Basisplan', [trial], []),
        ];
    for (final (name, plans, expected) in rows) {
      final offers = googleOffersFrom(_play(plans));
      expect(offers.map(_offer), expected, reason: name);
      for (final offer in offers) {
        expect(offer.basePlanId, offer.period.name);
        expect(offer.currencyCode, 'EUR');
        // The purchase uses the offer that is shown.
        expect(
          (offer.handle! as GooglePlayProductDetails).offerToken,
          offer.offerToken,
        );
      }
    }
  });

  test('iOS: beide Produkte, die Testphase nur mit Berechtigung', () {
    final weekFree = SK2SubscriptionOffer(
      price: 0,
      type: SK2SubscriptionOfferType.introductory,
      period: const SK2SubscriptionPeriod(
        value: 1,
        unit: SK2SubscriptionPeriodUnit.week,
      ),
      periodCount: 1,
      paymentMode: SK2SubscriptionOfferPaymentMode.freeTrial,
    );
    final products = [
      _appStore(kAppleMonthlyProductId, 7.99, '7,99 €'),
      _appStore(kAppleYearlyProductId, 49.99, '49,99 €', intro: weekFree),
    ];
    final rows = <(Set<String>, int?)>[
      ({kAppleYearlyProductId}, 7),
      (<String>{}, null),
    ];
    for (final (eligible, trialDays) in rows) {
      final offers = appleOffersFrom(products, trialEligible: eligible);
      expect(offers.map(_offer), [
        'yearly null 49,99 € 49.99 trial $trialDays',
        'monthly null 7,99 € 7.99 trial null',
      ], reason: '$eligible');
      expect(offers.map((o) => o.productId), [
        kAppleYearlyProductId,
        kAppleMonthlyProductId,
      ]);
    }
  });

  test('jeder Kauf traegt den Beleg seiner Plattform', () {
    final rows = <(PurchaseDetails, StorePlatform, String?)>[
      (
        GooglePlayPurchaseDetails.fromPurchase(
          _playPurchase('play-token', acknowledged: false),
        ).single,
        StorePlatform.google,
        'purchased google:play-token finish',
      ),
      (
        _details(PurchaseStatus.purchased),
        StorePlatform.apple,
        'purchased apple:header.payload.signature finish',
      ),
      // StoreKit 2 restores entitlements that are finished already.
      (
        _details(PurchaseStatus.restored),
        StorePlatform.apple,
        'restored apple:header.payload.signature keep',
      ),
      (
        _details(PurchaseStatus.canceled, productId: '', proof: ''),
        StorePlatform.google,
        'canceled null:null keep',
      ),
      (
        _details(PurchaseStatus.purchased, proof: ''),
        StorePlatform.apple,
        'error null:null keep',
      ),
      (
        _details(PurchaseStatus.purchased, productId: 'other_product'),
        StorePlatform.apple,
        null,
      ),
    ];
    for (final (details, platform, expected) in rows) {
      final p = storePurchaseFrom(details, platform);
      expect(
        p == null
            ? null
            : '${p.status.name} ${p.proof?.platform.wire}:'
                  '${p.proof?.verificationData} '
                  '${p.needsCompletion ? 'finish' : 'keep'}',
        expected,
        reason: '${details.productID} ${details.status}',
      );
    }
  });

  test('Kaufauftrag und Verwaltung gehen an den richtigen Store', () {
    final [yearly, monthly] = googleOffersFrom(
      _play([
        _plan('yearly', [_phase('P1Y', 49990000)]),
        _plan('monthly', [_phase('P1M', 7990000)]),
      ]),
    );
    final old = GooglePlayPurchaseDetails.fromPurchase(
      _playPurchase('old-token', acknowledged: true),
    ).single;
    final current = StorePurchase(
      platform: StorePlatform.google,
      productId: kGooglePremiumProductId,
      status: StorePurchaseStatus.restored,
      handle: old,
    );
    final rows = <(PremiumOffer, StorePurchase?, ReplacementMode?)>[
      (yearly, null, null),
      (yearly, current, ReplacementMode.withTimeProration),
      (monthly, current, ReplacementMode.deferred),
    ];
    for (final (offer, replacing, mode) in rows) {
      final param =
          purchaseParamFor(
                offer,
                platform: StorePlatform.google,
                accountToken: kFakeAccountToken,
                replacing: replacing,
              )
              as GooglePlayPurchaseParam;
      expect(param.applicationUserName, kFakeAccountToken);
      expect(param.offerToken, offer.offerToken);
      expect(param.productDetails, same(offer.handle));
      final change = param.changeSubscriptionParam;
      expect(change?.replacementMode, mode);
      expect(change?.oldPurchaseDetails, replacing == null ? null : same(old));
    }

    final [appleYearly, _] = appleOffersFrom([
      _appStore(kAppleYearlyProductId, 49.99, '49,99 €'),
      _appStore(kAppleMonthlyProductId, 7.99, '7,99 €'),
    ], trialEligible: const {});
    final apple = purchaseParamFor(
      appleYearly,
      platform: StorePlatform.apple,
      accountToken: kFakeAccountToken,
    );
    expect(apple, isA<Sk2PurchaseParam>());
    expect(apple.applicationUserName, kFakeAccountToken);

    expect(
      [
        manageSubscriptionsUri(
          StorePlatform.google,
          productId: kGooglePremiumProductId,
        ),
        manageSubscriptionsUri(StorePlatform.apple),
        manageSubscriptionsUri(StorePlatform.manual),
      ].map((uri) => '$uri'),
      [
        'https://play.google.com/store/account/subscriptions'
            '?sku=eatova_premium&package=com.eatova.app',
        'https://apps.apple.com/account/subscriptions',
        'null',
      ],
    );
  });
}
