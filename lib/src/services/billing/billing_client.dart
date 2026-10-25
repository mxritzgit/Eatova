/// The device's store, seen through the app (docs/PREMIUM.md 4.2): Google
/// Play Billing or StoreKit 2 behind one interface. The `in_app_purchase`
/// implementation lives in `store_billing_client.dart`; [NoBillingClient]
/// stands in for tests and platforms without a store.
///
/// The store only sells. Whether a purchase grants Premium is decided by the
/// server after it verified the [PurchaseProof]; nothing here grants a tier.
library;

import '../../models/plan_status.dart';

export '../../models/plan_status.dart' show PremiumPeriod, StorePlatform;

/// Whether purchases can be made on this device right now.
enum BillingAvailability {
  available,

  /// The store exists but does not answer (offline, Play Store blocked or
  /// signed out).
  unavailable,

  /// No store on this platform or build (desktop, tests, preview).
  unsupported,
}

/// One Premium plan as the store sells it, prices exactly as the store
/// formats them (PAngV: never computed from constants).
class PremiumOffer {
  const PremiumOffer({
    required this.period,
    required this.productId,
    this.basePlanId,
    this.offerToken,
    required this.priceLabel,
    required this.rawPrice,
    required this.currencyCode,
    this.trialDays,
    this.handle,
  });

  final PremiumPeriod period;

  /// Google `eatova_premium`, Apple `eatova_premium_monthly|yearly`.
  final String productId;

  /// Google's base plan (`monthly`, `yearly`); null on Apple.
  final String? basePlanId;

  /// Google's offer token for this base plan or its trial offer.
  final String? offerToken;

  /// The billed amount per period, formatted by the store ("49,99 €").
  final String priceLabel;

  /// The billed amount per period as a number, for the monthly equivalent
  /// and the savings; formatted again with [currencyCode].
  final double rawPrice;
  final String currencyCode;

  /// The free trial this account is eligible for, null without one.
  final int? trialDays;

  /// The plugin's product object, handed back to [BillingClient.buy].
  /// Opaque outside the billing client.
  final Object? handle;

  bool get hasTrial => (trialDays ?? 0) > 0;

  /// The amount per month: the yearly price over twelve months.
  double get monthlyEquivalent =>
      period == PremiumPeriod.yearly ? rawPrice / 12 : rawPrice;
}

/// How much less the yearly plan costs than twelve monthly payments, in whole
/// percent; null when the prices cannot be compared (another currency, no
/// saving).
int? yearlySavingsPercent({
  required PremiumOffer yearly,
  required PremiumOffer monthly,
}) {
  if (yearly.period != PremiumPeriod.yearly ||
      monthly.period != PremiumPeriod.monthly ||
      yearly.currencyCode != monthly.currencyCode ||
      monthly.rawPrice <= 0) {
    return null;
  }
  final percent = ((1 - yearly.rawPrice / (monthly.rawPrice * 12)) * 100)
      .round();
  return percent > 0 ? percent : null;
}

/// What the server verifies (`subscription-verify`, 3.4): Google's purchase
/// token or Apple's signed transaction (JWS). Both are store secrets: never
/// log them, never send them anywhere but the verify function.
class PurchaseProof {
  const PurchaseProof.google({
    required this.productId,
    required String purchaseToken,
  }) : platform = StorePlatform.google,
       verificationData = purchaseToken;

  const PurchaseProof.apple({
    required this.productId,
    required String signedTransaction,
  }) : platform = StorePlatform.apple,
       verificationData = signedTransaction;

  final StorePlatform platform;
  final String productId;

  /// The purchase token or the JWS.
  final String verificationData;

  /// The `verify` request body.
  Map<String, Object> toVerifyBody() => platform == StorePlatform.apple
      ? <String, Object>{
          'action': 'verify',
          'platform': 'apple',
          'signedTransaction': verificationData,
        }
      : <String, Object>{
          'action': 'verify',
          'platform': 'google',
          'productId': productId,
          'purchaseToken': verificationData,
        };

  @override
  bool operator ==(Object other) =>
      other is PurchaseProof &&
      other.platform == platform &&
      other.productId == productId &&
      other.verificationData == verificationData;

  @override
  int get hashCode => Object.hash(platform, productId, verificationData);

  /// Without the secret, so an accidental log line leaks nothing.
  @override
  String toString() => 'PurchaseProof(${platform.wire}, $productId)';
}

enum StorePurchaseStatus { pending, purchased, restored, canceled, error }

/// One update from the store's purchase stream.
class StorePurchase {
  const StorePurchase({
    required this.platform,
    required this.productId,
    required this.status,
    this.proof,
    this.handle,
    this.needsCompletion = false,
    this.errorCode,
  });

  final StorePlatform platform;
  final String productId;
  final StorePurchaseStatus status;

  /// Present for `purchased` and `restored`.
  final PurchaseProof? proof;

  /// The plugin's purchase object, handed back to [BillingClient.complete]
  /// and as a plan change's old purchase. Opaque outside the billing client.
  final Object? handle;

  /// The store waits for [BillingClient.complete] (Apple finishes the
  /// transaction; Google acknowledges unless the server already did).
  final bool needsCompletion;

  /// The store's error code for `error`, for diagnostics only (no message
  /// text, which may carry account details).
  final String? errorCode;

  @override
  String toString() =>
      'StorePurchase(${platform.wire}, $productId, ${status.name})';
}

/// The store on this device.
abstract interface class BillingClient {
  /// The store this device sells through; null where nothing is sold.
  StorePlatform? get platform;

  Future<BillingAvailability> availability();

  /// Both Premium plans with the account's trial eligibility; empty when the
  /// store has none (products not configured yet).
  Future<List<PremiumOffer>> offers();

  /// Every update from the store, from app start on: new purchases, restored
  /// ones, pending payments, cancels and errors, also for purchases made
  /// while no account was signed in.
  Stream<List<StorePurchase>> get purchases;

  /// Opens the store's purchase sheet for [offer]. [accountToken] goes to the
  /// store as `applicationUserName` (Google `obfuscatedAccountId`, Apple
  /// `appAccountToken`; a canonical UUID). [replacing] is the account's
  /// current Google purchase for a plan change. Completes once the sheet is
  /// up; the result arrives on [purchases]. Throws when the sheet cannot
  /// open.
  Future<void> buy(
    PremiumOffer offer, {
    required String accountToken,
    StorePurchase? replacing,
  });

  /// Asks the store for this device's owned purchases without any sign-in
  /// prompt; they arrive on [purchases] as `restored`.
  Future<void> restore();

  /// Finishes or acknowledges [purchase]. Only after the server answered
  /// `active`, `inactive` or `ownedByOther`.
  Future<void> complete(StorePurchase purchase);

  /// The store's subscription management (iOS sheet, Play subscriptions).
  Future<void> openManageSubscriptions({String? productId});
}

/// No store: tests, previews and unsupported platforms.
class NoBillingClient implements BillingClient {
  const NoBillingClient();

  @override
  StorePlatform? get platform => null;

  @override
  Future<BillingAvailability> availability() =>
      Future<BillingAvailability>.value(BillingAvailability.unsupported);

  @override
  Future<List<PremiumOffer>> offers() =>
      Future<List<PremiumOffer>>.value(const <PremiumOffer>[]);

  @override
  Stream<List<StorePurchase>> get purchases =>
      const Stream<List<StorePurchase>>.empty();

  @override
  Future<void> buy(
    PremiumOffer offer, {
    required String accountToken,
    StorePurchase? replacing,
  }) => Future<void>.error(UnsupportedError('No store on this device'));

  @override
  Future<void> restore() => Future<void>.value();

  @override
  Future<void> complete(StorePurchase purchase) => Future<void>.value();

  @override
  Future<void> openManageSubscriptions({String? productId}) =>
      Future<void>.value();
}
