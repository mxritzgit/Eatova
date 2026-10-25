/// The `in_app_purchase` implementation of [BillingClient] (docs/PREMIUM.md
/// 4.2): Google Play Billing on Android, StoreKit 2 on iOS.
///
/// The plugin connects on first use, not at construction: building the app
/// (and every test that builds it) touches no platform channel. The first
/// store call (the silent restore when an account binds, the paywall's
/// offers) attaches the purchase stream before it asks the store, so nothing
/// the store delivers is missed; until then the stores keep their purchases.
///
/// The mapping from plugin types sits in small pure functions below, so it is
/// testable with constructed plugin data classes.
library;

import 'dart:async';
import 'dart:developer' as dev;

import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/billing_client_wrappers.dart'
    show
        PricingPhaseWrapper,
        RecurrenceMode,
        ReplacementMode,
        SubscriptionOfferDetailsWrapper;
import 'package:in_app_purchase_android/in_app_purchase_android.dart';
import 'package:in_app_purchase_storekit/in_app_purchase_storekit.dart';
import 'package:in_app_purchase_storekit/store_kit_2_wrappers.dart';
import 'package:url_launcher/url_launcher.dart';

import 'billing_client.dart';

/// Google: one subscription with the base plans `monthly` and `yearly`
/// (docs/PREMIUM.md 1.3.4).
const String kGooglePremiumProductId = 'eatova_premium';

/// Apple: one subscription group with both products.
const String kAppleMonthlyProductId = 'eatova_premium_monthly';
const String kAppleYearlyProductId = 'eatova_premium_yearly';

/// The Play package for the subscription management link.
const String kPlayPackageName = 'com.eatova.app';

/// The device's store: [StoreBillingClient] on Android and iOS,
/// [NoBillingClient] everywhere else.
BillingClient createBillingClient({TargetPlatform? platform}) {
  if (kIsWeb) return const NoBillingClient();
  return switch (platform ?? defaultTargetPlatform) {
    TargetPlatform.android => StoreBillingClient(
      platform: StorePlatform.google,
    ),
    TargetPlatform.iOS => StoreBillingClient(platform: StorePlatform.apple),
    _ => const NoBillingClient(),
  };
}

/// Opens [uri] outside the app; false when nothing could open it.
typedef ExternalUrlOpener = Future<bool> Function(Uri uri);

/// The default [ExternalUrlOpener]: the browser or the store app.
Future<bool> openExternalUrl(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

final RegExp _canonicalUuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

class StoreBillingClient implements BillingClient {
  StoreBillingClient({
    required StorePlatform platform,
    InAppPurchase Function()? plugin,
    ExternalUrlOpener? openUrl,
  }) : assert(platform != StorePlatform.manual),
       _platform = platform,
       _pluginFactory = plugin ?? (() => InAppPurchase.instance),
       _openUrl = openUrl ?? openExternalUrl;

  final StorePlatform _platform;
  final InAppPurchase Function() _pluginFactory;
  final ExternalUrlOpener _openUrl;

  final StreamController<List<StorePurchase>> _updates =
      StreamController<List<StorePurchase>>.broadcast();
  InAppPurchase? _plugin;
  StreamSubscription<List<PurchaseDetails>>? _pluginUpdates;

  /// The plugin, its purchase stream attached before the first call.
  InAppPurchase get _store {
    final known = _plugin;
    if (known != null) return known;
    final store = _pluginFactory();
    _pluginUpdates = store.purchaseStream.listen(
      _forward,
      // The plugin's error may carry store details; only its type is kept.
      onError: (Object error) {
        _log('purchase stream', error);
        _updates.addError(StateError('Purchase stream failed'));
      },
    );
    return _plugin = store;
  }

  @override
  StorePlatform get platform => _platform;

  @override
  Stream<List<StorePurchase>> get purchases => _updates.stream;

  void _forward(List<PurchaseDetails> batch) {
    final mapped = [
      for (final details in batch) storePurchaseFrom(details, _platform),
    ].nonNulls.toList();
    // An empty batch is the store's "restored nothing"; a batch that only
    // held other products' purchases is no answer at all.
    if (mapped.isEmpty && batch.isNotEmpty) return;
    _updates.add(mapped);
  }

  @override
  Future<BillingAvailability> availability() async {
    try {
      return await _store.isAvailable()
          ? BillingAvailability.available
          : BillingAvailability.unavailable;
    } catch (e) {
      _log('availability', e);
      return BillingAvailability.unavailable;
    }
  }

  @override
  Future<List<PremiumOffer>> offers() async {
    final store = _store;
    final response = await store.queryProductDetails(
      _platform == StorePlatform.apple
          ? const {kAppleMonthlyProductId, kAppleYearlyProductId}
          : const {kGooglePremiumProductId},
    );
    final error = response.error;
    // StoreKit reports "no products" (not configured yet) as this error.
    if (response.productDetails.isEmpty &&
        error != null &&
        error.code != 'storekit_no_response') {
      throw StateError('Product query failed (${error.code})');
    }
    if (_platform == StorePlatform.google) {
      return googleOffersFrom(response.productDetails);
    }
    final eligible = <String>{};
    for (final product in response.productDetails) {
      if (product is! AppStoreProduct2Details ||
          appleTrialDays(product.sk2Product.subscription) == null) {
        continue;
      }
      try {
        if (await SK2Product.isIntroductoryOfferEligible(product.id)) {
          eligible.add(product.id);
        }
      } catch (e) {
        // Without an answer no trial is promised.
        _log('trial eligibility', e);
      }
    }
    return appleOffersFrom(response.productDetails, trialEligible: eligible);
  }

  @override
  Future<void> buy(
    PremiumOffer offer, {
    required String accountToken,
    StorePurchase? replacing,
  }) async {
    // Apple drops a token that is no UUID and sells without it.
    if (!_canonicalUuid.hasMatch(accountToken)) {
      throw ArgumentError('The account token is not a canonical UUID');
    }
    final param = purchaseParamFor(
      offer,
      platform: _platform,
      accountToken: accountToken,
      replacing: replacing,
    );
    if (!await _store.buyNonConsumable(purchaseParam: param)) {
      throw StateError('The store did not open its purchase sheet');
    }
  }

  @override
  Future<void> restore() => _store.restorePurchases();

  @override
  Future<void> complete(StorePurchase purchase) async {
    final handle = purchase.handle;
    if (!purchase.needsCompletion || handle is! PurchaseDetails) return;
    // StoreKit finishes by transaction id; pending and canceled have none.
    if (_platform == StorePlatform.apple && handle.purchaseID == null) return;
    await _store.completePurchase(handle);
  }

  @override
  Future<void> openManageSubscriptions({String? productId}) async {
    if (_platform == StorePlatform.apple) {
      try {
        await _store
            .getPlatformAddition<InAppPurchaseStoreKitPlatformAddition>()
            .showManageSubscriptions();
        return;
      } catch (e) {
        // No window scene, or an iOS without the sheet: the web page.
        _log('manage subscriptions sheet', e);
      }
    }
    final uri = manageSubscriptionsUri(_platform, productId: productId);
    if (uri == null || !await _openUrl(uri)) {
      throw StateError('Subscription management could not open');
    }
  }

  /// Detaches from the plugin (tests; the app keeps one client for good).
  Future<void> dispose() async {
    await _pluginUpdates?.cancel();
    await _updates.close();
  }

  void _log(String step, Object error) =>
      dev.log('Store $step failed (${error.runtimeType})', name: 'billing');
}

/// The store's subscription management page for [platform]; null for a
/// manual grant, which no store manages.
Uri? manageSubscriptionsUri(
  StorePlatform platform, {
  String? productId,
}) => switch (platform) {
  StorePlatform.google => Uri.https(
    'play.google.com',
    '/store/account/subscriptions',
    productId == null ? null : {'sku': productId, 'package': kPlayPackageName},
  ),
  StorePlatform.apple => Uri.https('apps.apple.com', '/account/subscriptions'),
  StorePlatform.manual => null,
};

/// One [StorePurchase] per plugin update, null for another product's.
StorePurchase? storePurchaseFrom(
  PurchaseDetails details,
  StorePlatform platform,
) {
  final productId = details.productID;
  var status = switch (details.status) {
    PurchaseStatus.pending => StorePurchaseStatus.pending,
    PurchaseStatus.purchased => StorePurchaseStatus.purchased,
    PurchaseStatus.restored => StorePurchaseStatus.restored,
    PurchaseStatus.canceled => StorePurchaseStatus.canceled,
    PurchaseStatus.error => StorePurchaseStatus.error,
  };
  if (productId.isEmpty) {
    // The end of a purchase flow without a purchase: Google reports cancels
    // and errors this way.
    if (status == StorePurchaseStatus.purchased ||
        status == StorePurchaseStatus.restored) {
      status = StorePurchaseStatus.error;
    }
    return StorePurchase(
      platform: platform,
      productId: productId,
      status: status,
      errorCode: details.error?.code,
    );
  }
  final ours = platform == StorePlatform.apple
      ? productId == kAppleMonthlyProductId ||
            productId == kAppleYearlyProductId
      : productId == kGooglePremiumProductId;
  if (!ours) return null;
  PurchaseProof? proof;
  if (status == StorePurchaseStatus.purchased ||
      status == StorePurchaseStatus.restored) {
    // Google: the purchase token; StoreKit 2: the signed transaction (JWS).
    final data = details.verificationData.serverVerificationData;
    if (data.isEmpty) {
      status = StorePurchaseStatus.error;
    } else {
      proof = platform == StorePlatform.apple
          ? PurchaseProof.apple(productId: productId, signedTransaction: data)
          : PurchaseProof.google(productId: productId, purchaseToken: data);
    }
  }
  return StorePurchase(
    platform: platform,
    productId: productId,
    status: status,
    proof: proof,
    handle: details,
    needsCompletion: proof != null && details.pendingCompletePurchase,
    errorCode: status == StorePurchaseStatus.error ? details.error?.code : null,
  );
}

/// Both plans from Play's product details (one entry per base plan and per
/// eligible offer). The price is the base plan's recurring price; an offer is
/// used only as a free trial that then renews at exactly that price, so the
/// paywall never shows a price the store does not charge.
List<PremiumOffer> googleOffersFrom(Iterable<ProductDetails> products) {
  final plans = <GooglePlayProductDetails>[
    for (final product in products)
      if (product is GooglePlayProductDetails &&
          product.id == kGooglePremiumProductId)
        product,
  ];
  return [
    for (final period in const [PremiumPeriod.yearly, PremiumPeriod.monthly])
      ?_googleOffer(period, plans),
  ];
}

PremiumOffer? _googleOffer(
  PremiumPeriod period,
  List<GooglePlayProductDetails> plans,
) {
  final basePlanId = period.name;
  GooglePlayProductDetails? base;
  PricingPhaseWrapper? recurring;
  for (final plan in plans) {
    final details = _offerDetails(plan);
    if (details == null ||
        details.basePlanId != basePlanId ||
        details.offerId != null) {
      continue;
    }
    final phases = details.pricingPhases;
    if (phases.length == 1 &&
        phases.single.recurrenceMode == RecurrenceMode.infiniteRecurring &&
        phases.single.priceAmountMicros > 0) {
      base = plan;
      recurring = phases.single;
      break;
    }
  }
  if (base == null || recurring == null) return null;
  var chosen = base;
  int? trialDays;
  for (final plan in plans) {
    final details = _offerDetails(plan);
    if (details == null ||
        details.basePlanId != basePlanId ||
        details.offerId == null) {
      continue;
    }
    final days = _googleTrialDays(details.pricingPhases, recurring);
    if (days != null) {
      chosen = plan;
      trialDays = days;
      break;
    }
  }
  return PremiumOffer(
    period: period,
    productId: kGooglePremiumProductId,
    basePlanId: basePlanId,
    offerToken: chosen.offerToken,
    priceLabel: recurring.formattedPrice,
    rawPrice: recurring.priceAmountMicros / 1000000,
    currencyCode: recurring.priceCurrencyCode,
    trialDays: trialDays,
    handle: chosen,
  );
}

SubscriptionOfferDetailsWrapper? _offerDetails(GooglePlayProductDetails plan) {
  final index = plan.subscriptionIndex;
  final all = plan.productDetails.subscriptionOfferDetails;
  if (index == null || all == null || index < 0 || index >= all.length) {
    return null;
  }
  return all[index];
}

/// The free days of a trial offer: free phases, then the base plan's price
/// for good. Null for any other offer (a discount, an unknown period).
int? _googleTrialDays(
  List<PricingPhaseWrapper> phases,
  PricingPhaseWrapper recurring,
) {
  if (phases.length < 2) return null;
  final last = phases.last;
  if (last.recurrenceMode != RecurrenceMode.infiniteRecurring ||
      last.priceAmountMicros != recurring.priceAmountMicros ||
      last.priceCurrencyCode != recurring.priceCurrencyCode ||
      last.billingPeriod != recurring.billingPeriod) {
    return null;
  }
  var days = 0;
  for (final phase in phases.sublist(0, phases.length - 1)) {
    final perCycle = _isoDays(phase.billingPeriod);
    if (phase.priceAmountMicros != 0 || perCycle == null) return null;
    final cycles = phase.recurrenceMode == RecurrenceMode.finiteRecurring
        ? phase.billingCycleCount
        : 1;
    if (cycles < 1) return null;
    days += perCycle * cycles;
  }
  return days > 0 ? days : null;
}

final RegExp _isoDayPeriod = RegExp(r'^P(?:(\d+)W)?(?:(\d+)D)?$');

/// Days of an ISO 8601 period in weeks and days (`P7D`, `P1W`); null for
/// months or years, which have no fixed length.
int? _isoDays(String period) {
  final match = _isoDayPeriod.firstMatch(period);
  if (match == null || (match[1] == null && match[2] == null)) return null;
  return int.parse(match[1] ?? '0') * 7 + int.parse(match[2] ?? '0');
}

/// Both plans from StoreKit 2. [trialEligible] holds the product ids whose
/// introductory offer this Apple ID may still take.
List<PremiumOffer> appleOffersFrom(
  Iterable<ProductDetails> products, {
  required Set<String> trialEligible,
}) {
  PremiumOffer? offerFor(PremiumPeriod period, String productId) {
    for (final product in products) {
      if (product is! AppStoreProduct2Details ||
          product.id != productId ||
          product.sk2Product.type != SK2ProductType.autoRenewable) {
        continue;
      }
      return PremiumOffer(
        period: period,
        productId: productId,
        priceLabel: product.price,
        rawPrice: product.rawPrice,
        currencyCode: product.currencyCode,
        trialDays: trialEligible.contains(productId)
            ? appleTrialDays(product.sk2Product.subscription)
            : null,
        handle: product,
      );
    }
    return null;
  }

  return [
    ?offerFor(PremiumPeriod.yearly, kAppleYearlyProductId),
    ?offerFor(PremiumPeriod.monthly, kAppleMonthlyProductId),
  ];
}

/// The days of the product's introductory free trial; null without one (or
/// with a trial in months, which has no fixed length).
int? appleTrialDays(SK2SubscriptionInfo? subscription) {
  for (final offer
      in subscription?.promotionalOffers ?? const <SK2SubscriptionOffer>[]) {
    if (offer.type != SK2SubscriptionOfferType.introductory ||
        offer.paymentMode != SK2SubscriptionOfferPaymentMode.freeTrial) {
      continue;
    }
    final unit = switch (offer.period.unit) {
      SK2SubscriptionPeriodUnit.day => 1,
      SK2SubscriptionPeriodUnit.week => 7,
      SK2SubscriptionPeriodUnit.month || SK2SubscriptionPeriodUnit.year => 0,
    };
    final days = unit * offer.period.value * offer.periodCount;
    return days > 0 ? days : null;
  }
  return null;
}

/// How a Google plan change takes effect (docs/PREMIUM.md 4.2): to yearly at
/// once with the unused time credited, to monthly at the next renewal.
ReplacementMode replacementModeFor(PremiumPeriod target) =>
    target == PremiumPeriod.yearly
    ? ReplacementMode.withTimeProration
    : ReplacementMode.deferred;

/// The plugin's purchase request for [offer]; [accountToken] becomes
/// Google's `obfuscatedAccountId` or Apple's `appAccountToken`.
PurchaseParam purchaseParamFor(
  PremiumOffer offer, {
  required StorePlatform platform,
  required String accountToken,
  StorePurchase? replacing,
}) {
  final product = offer.handle;
  if (platform == StorePlatform.apple) {
    if (product is! AppStoreProduct2Details) {
      throw ArgumentError('The offer carries no App Store product');
    }
    return Sk2PurchaseParam(
      productDetails: product,
      applicationUserName: accountToken,
    );
  }
  if (product is! GooglePlayProductDetails) {
    throw ArgumentError('The offer carries no Play product');
  }
  ChangeSubscriptionParam? change;
  if (replacing != null) {
    final old = replacing.handle;
    // Never a second subscription instead of the change.
    if (old is! GooglePlayPurchaseDetails) {
      throw ArgumentError('The replaced purchase carries no Play purchase');
    }
    change = ChangeSubscriptionParam(
      oldPurchaseDetails: old,
      replacementMode: replacementModeFor(offer.period),
    );
  }
  return GooglePlayPurchaseParam(
    productDetails: product,
    applicationUserName: accountToken,
    offerToken: offer.offerToken,
    changeSubscriptionParam: change,
  );
}
