/// The contract between the per-account `SubscriptionController` and the
/// app-level purchase pipeline (`PurchaseCoordinator`, docs/PREMIUM.md 4.2).
///
/// Store purchases are device-level and can arrive at any time (a renewal, a
/// payment that cleared, a transaction the store redelivers on launch), also
/// while no account is signed in. So one [PurchaseFlow] lives as long as the
/// app; the signed-in shell binds its account as a [PurchaseAccount], and the
/// flow verifies every purchase through that account's [SubscriptionLog]
/// (its bearer) and reports the result to it as a [PurchaseEvent].
library;

import '../../models/plan_status.dart';
import '../subscription_sync.dart';
import 'billing_client.dart';

export 'billing_client.dart'
    show BillingAvailability, PremiumOffer, PremiumPeriod, StorePlatform;

/// The signed-in account as the purchase pipeline sees it.
abstract interface class PurchaseAccount {
  /// The Eatova user id, so the flow can tell accounts apart. Never sent to
  /// a store (the store gets the account token).
  String get userId;

  /// The account's server side: the account token for a purchase and the
  /// verification of every proof, both with this account's bearer.
  SubscriptionLog get log;

  /// A result for this account. Called on the main isolate, never after the
  /// account was unbound.
  void onPurchaseEvent(PurchaseEvent event);
}

/// The app-level purchase pipeline.
///
/// Rules every implementation keeps:
/// - Purchases are verified only through the bound account's
///   [PurchaseAccount.log]; without a bound account they wait. The client
///   never grants Premium itself.
/// - A store transaction is completed (finished, acknowledged) only after
///   the server answered `active`, `inactive` or `ownedByOther`; never after
///   `unavailable`, `pending`, `invalid` or `unauthorized`, so the store
///   redelivers it.
/// - Events go to the account that was bound when the result arrived, and
///   only to it. A result that arrives after its account was unbound is
///   dropped; the purchase is verified again for the next account.
/// - Proofs and tokens never reach a log or the crash reporter.
abstract interface class PurchaseFlow {
  /// Whether purchases can be made on this device now.
  Future<BillingAvailability> availability();

  /// Both Premium plans as the store sells them; empty without a store or
  /// products.
  Future<List<PremiumOffer>> offers();

  /// Opens the store's sheet for [offer] with the account token as
  /// `applicationUserName`. [current] is the account's subscription: on the
  /// same store a Google plan change replaces it (monthly to yearly with time
  /// proration, yearly to monthly deferred); bought on the other store, the
  /// implementation must not start a second subscription. Completes once the
  /// sheet is up; the outcome arrives as an event ([PurchaseCanceled] when
  /// the user closes the sheet). Throws when the sheet cannot open.
  Future<void> buy(
    PremiumOffer offer, {
    required String accountToken,
    SubscriptionInfo? current,
  });

  /// Asks the store for this device's purchases and verifies them for the
  /// bound account.
  ///
  /// A user restore ([silent] false) completes only after every restored
  /// purchase was answered for the account: [PurchaseVerified] (and the
  /// state events) per purchase, or [PurchaseRestoredNothing] when the store
  /// had none. A [silent] restore (on bind, on start) reports only
  /// [PurchaseVerified] and [PurchasePending]; nothing it finds may show a
  /// message.
  Future<void> restore({bool silent = false});

  /// The store's subscription management for [productId] on [platform]
  /// (default: this device's store).
  Future<void> openManageSubscriptions({
    String? productId,
    StorePlatform? platform,
  });

  /// Makes [account] the one that purchases are verified for and reported
  /// to, replacing any other. Held purchases are verified for it, and one
  /// silent restore runs per bind.
  void bindAccount(PurchaseAccount account);

  /// Unbinds [account] if it is the bound one; a newer account's binding
  /// stays (the next shell binds before the old one disposes).
  void unbindAccount(PurchaseAccount account);
}

/// A purchase result for the bound account.
sealed class PurchaseEvent {
  const PurchaseEvent();
}

/// The store reports a pending payment; nothing is granted yet. [silent]:
/// found by a silent restore, not the outcome of the account's own purchase.
final class PurchasePending extends PurchaseEvent {
  const PurchasePending({this.silent = false});

  final bool silent;
}

/// The server verified a purchase. [active]: it entitles to Premium. [plan]
/// is the account's plan after the verification (null when the answer had
/// no valid plan; the controller then reads it). [silent]: found by a silent
/// restore, not the outcome of the account's own purchase.
final class PurchaseVerified extends PurchaseEvent {
  const PurchaseVerified({
    required this.active,
    this.plan,
    this.silent = false,
  });

  final bool active;
  final PlanStatus? plan;
  final bool silent;
}

/// A purchase without an account token that is already bound to another
/// Eatova account (409). Completed: it is valid in the store.
final class PurchaseOwnedByOther extends PurchaseEvent {
  const PurchaseOwnedByOther();
}

/// The server rejected the proof (400, 422). Never completed.
final class PurchaseInvalid extends PurchaseEvent {
  const PurchaseInvalid({this.reason});

  /// The 422 reason. `account` (the purchase carries another Eatova
  /// account's token) is shown as owned by another account; the others are
  /// a failure.
  final String? reason;
}

/// The purchase arrived but could not be verified yet (offline, 503); the
/// flow retries and the store keeps the transaction open.
final class PurchaseVerifyDeferred extends PurchaseEvent {
  const PurchaseVerifyDeferred();
}

/// The store reported an error, or the sheet failed.
final class PurchaseFailed extends PurchaseEvent {
  const PurchaseFailed();
}

/// The user closed the store's sheet.
final class PurchaseCanceled extends PurchaseEvent {
  const PurchaseCanceled();
}

/// A user restore found no purchase on this device.
final class PurchaseRestoredNothing extends PurchaseEvent {
  const PurchaseRestoredNothing();
}

/// No purchases: tests, previews and builds without the pipeline.
class NoPurchaseFlow implements PurchaseFlow {
  const NoPurchaseFlow();

  @override
  Future<BillingAvailability> availability() =>
      Future<BillingAvailability>.value(BillingAvailability.unsupported);

  @override
  Future<List<PremiumOffer>> offers() =>
      Future<List<PremiumOffer>>.value(const <PremiumOffer>[]);

  @override
  Future<void> buy(
    PremiumOffer offer, {
    required String accountToken,
    SubscriptionInfo? current,
  }) => Future<void>.error(UnsupportedError('No store on this device'));

  @override
  Future<void> restore({bool silent = false}) => Future<void>.value();

  @override
  Future<void> openManageSubscriptions({
    String? productId,
    StorePlatform? platform,
  }) => Future<void>.value();

  @override
  void bindAccount(PurchaseAccount account) {}

  @override
  void unbindAccount(PurchaseAccount account) {}
}
