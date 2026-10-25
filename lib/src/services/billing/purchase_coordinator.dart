/// The app-level purchase pipeline (docs/PREMIUM.md 4.2): one per process,
/// listening to the store from construction on, verifying every purchase
/// through the bound account's [SubscriptionLog] and reporting the result to
/// that account only. The rules it keeps are [PurchaseFlow]'s.
library;

import 'dart:async';
import 'dart:developer' as dev;

import 'package:clock/clock.dart';
import 'package:flutter/widgets.dart';

import '../../models/plan_status.dart';
import '../subscription_sync.dart';
import 'billing_client.dart';
import 'purchase_flow.dart';
import 'store_billing_client.dart'
    show ExternalUrlOpener, manageSubscriptionsUri, openExternalUrl;

/// How long a restore waits for the store's answer on the purchase stream
/// after the store's call returned (both plugins send it right before).
const Duration kRestoreAnswerWait = Duration(seconds: 3);

class PurchaseCoordinator with WidgetsBindingObserver implements PurchaseFlow {
  PurchaseCoordinator(
    this.billing, {
    ExternalUrlOpener? openUrl,
    this.restoreAnswerWait = kRestoreAnswerWait,
    this.observeLifecycle = true,
  }) : _openUrl = openUrl ?? openExternalUrl {
    // Purchases can arrive at launch, before any account is bound.
    _updates = billing.purchases.listen(_onPurchases, onError: _onStoreError);
  }

  final BillingClient billing;
  final ExternalUrlOpener _openUrl;
  final Duration restoreAnswerWait;

  /// Registers for app resumes at the first bind (the binding exists by
  /// then); off in tests, which call [didChangeAppLifecycleState].
  final bool observeLifecycle;

  late final StreamSubscription<List<StorePurchase>> _updates;
  bool _observing = false;
  bool _disposed = false;

  PurchaseAccount? _account;

  /// Bumped by every bind and unbind: a verification that started under
  /// another epoch reports to nobody.
  int _epoch = 0;

  /// Purchases with a proof that are not finished yet: held without an
  /// account, deferred after `unavailable` or `pending`, or being verified.
  final Map<PurchaseProof, _Tracked> _tracked = <PurchaseProof, _Tracked>{};

  /// Google purchases this device holds that the server verified as active,
  /// by account: the old purchase of a plan change.
  final Map<PurchaseProof, ({String userId, StorePurchase purchase})>
  _activeGoogle = {};

  /// The store's sheet is open for the bound account; silent results wait so
  /// they cannot end the purchase in the account's eyes.
  bool _buyOpen = false;
  final List<({PurchaseAccount account, PurchaseEvent event})> _withheld = [];

  _RestoreRun? _restoreRun;
  Future<void> _restoreChain = Future<void>.value();

  @override
  Future<BillingAvailability> availability() => billing.availability();

  @override
  Future<List<PremiumOffer>> offers() => billing.offers();

  @override
  Future<void> buy(
    PremiumOffer offer, {
    required String accountToken,
    SubscriptionInfo? current,
  }) async {
    final store = billing.platform;
    if (store == null) throw UnsupportedError('No store on this device');
    StorePurchase? replacing;
    if (current != null &&
        current.isStorePurchase &&
        current.entitledAt(clock.now())) {
      if (current.platform != store) {
        // Billed by the other store: a purchase here would bill twice.
        throw StateError('The subscription is billed by the other store');
      }
      final change =
          store == StorePlatform.google &&
          current.period != null &&
          current.period != offer.period;
      if (change) {
        replacing = _activePurchase(current.productId);
        if (replacing == null) {
          await restore(silent: true);
          replacing = _activePurchase(current.productId);
        }
        // Not on this device (another Google account): no second one.
        if (replacing == null) {
          throw StateError('The current Google purchase is not on this device');
        }
      }
    }
    _buyOpen = true;
    try {
      await billing.buy(
        offer,
        accountToken: accountToken,
        replacing: replacing,
      );
    } catch (_) {
      _endBuy();
      rethrow;
    }
  }

  StorePurchase? _activePurchase(String productId) {
    final userId = _account?.userId;
    for (final entry in _activeGoogle.values) {
      if (entry.userId == userId && entry.purchase.productId == productId) {
        return entry.purchase;
      }
    }
    return null;
  }

  @override
  Future<void> restore({bool silent = false}) {
    // One restore at a time, so the store's answer belongs to one run.
    final next = _restoreChain.then((_) => _restore(silent));
    _restoreChain = next.catchError((Object e) => _log('restore', e));
    return next;
  }

  Future<void> _restore(bool silent) async {
    if (_disposed) return;
    final account = _account;
    final epoch = _epoch;
    final run = _RestoreRun(silent: silent);
    _restoreRun = run;
    var failed = false;
    try {
      await billing.restore();
    } catch (e) {
      failed = true;
      _log('restore', e);
    }
    if (!run.answered.isCompleted) {
      await run.answered.future.timeout(restoreAnswerWait, onTimeout: () {});
    }
    if (identical(_restoreRun, run)) _restoreRun = null;
    await Future.wait(run.verifications);
    if (silent || account == null || run.found) return;
    _deliver(
      account,
      epoch,
      failed ? const PurchaseFailed() : const PurchaseRestoredNothing(),
      full: true,
    );
  }

  @override
  Future<void> openManageSubscriptions({
    String? productId,
    StorePlatform? platform,
  }) async {
    final store = billing.platform;
    final target = platform ?? store;
    if (target == null || target == StorePlatform.manual) return;
    if (target == store) {
      return billing.openManageSubscriptions(productId: productId);
    }
    // Bought on the other store: its web page.
    final uri = manageSubscriptionsUri(target, productId: productId);
    if (uri == null || !await _openUrl(uri)) {
      throw StateError('Subscription management could not open');
    }
  }

  @override
  void bindAccount(PurchaseAccount account) {
    if (_disposed || identical(_account, account)) return;
    _account = account;
    _epoch++;
    _buyOpen = false;
    _withheld.clear();
    if (observeLifecycle && !_observing) {
      WidgetsBinding.instance.addObserver(this);
      _observing = true;
    }
    for (final tracked in _tracked.values.toList()) {
      unawaited(_verify(tracked));
    }
    unawaited(restore(silent: true));
  }

  @override
  void unbindAccount(PurchaseAccount account) {
    // The next account's shell binds before the old one disposes.
    if (!identical(_account, account)) return;
    _account = null;
    _epoch++;
    _buyOpen = false;
    _withheld.clear();
  }

  /// Deferred verifications are retried when the app comes back.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || _account == null) return;
    for (final tracked in _tracked.values.toList()) {
      unawaited(_verify(tracked));
    }
  }

  void _onPurchases(List<StorePurchase> batch) {
    if (_disposed) return;
    // A restore's answer: one batch of restored purchases, empty for none.
    final run = _restoreRun;
    final claim =
        run != null &&
            !run.answered.isCompleted &&
            batch.every((p) => p.status == StorePurchaseStatus.restored)
        ? run
        : null;
    for (final purchase in batch) {
      switch (purchase.status) {
        case StorePurchaseStatus.pending:
          _deliverNow(const PurchasePending(), full: true);
        case StorePurchaseStatus.canceled:
          _deliverNow(const PurchaseCanceled(), full: true);
        case StorePurchaseStatus.error:
          _deliverNow(const PurchaseFailed(), full: true);
        case StorePurchaseStatus.purchased || StorePurchaseStatus.restored:
          final proof = purchase.proof;
          if (proof == null) {
            _deliverNow(const PurchaseFailed(), full: true);
            continue;
          }
          final tracked = _tracked.putIfAbsent(proof, () => _Tracked(proof));
          tracked.purchase = purchase;
          // Restored purchases speak only through a user restore.
          if (purchase.status == StorePurchaseStatus.purchased ||
              (claim != null && !claim.silent)) {
            tracked.full = true;
          }
          final verifying = _verify(tracked);
          if (claim != null) {
            claim.found = true;
            claim.verifications.add(verifying);
          }
      }
    }
    claim?.answered.complete();
  }

  void _onStoreError(Object error) {
    _log('purchase stream', error);
    _deliverNow(const PurchaseFailed(), full: true);
  }

  /// Verifies [tracked] for the bound account, or holds it without one.
  /// Shares a verification already running.
  Future<void> _verify(_Tracked tracked) {
    final running = tracked.running;
    if (running != null) return running;
    final account = _account;
    if (account == null || _disposed) return Future<void>.value();
    final done = Completer<void>();
    tracked.running = done.future;
    unawaited(_verifyFor(tracked, account, _epoch).whenComplete(done.complete));
    return done.future;
  }

  Future<void> _verifyFor(
    _Tracked tracked,
    PurchaseAccount account,
    int epoch,
  ) async {
    VerifyResult result;
    try {
      result = await account.log.verify(tracked.proof);
    } catch (e) {
      _log('verify', e);
      result = const VerifyResult(VerifyOutcome.unavailable);
    }
    tracked.running = null;
    if (_disposed || !identical(_tracked[tracked.proof], tracked)) return;
    if (epoch != _epoch) {
      // The account changed while the server answered: the answer reaches
      // nobody, and the purchase is verified again for whoever is bound now.
      unawaited(_verify(tracked));
      return;
    }
    final purchase = tracked.purchase!;
    switch (result.outcome) {
      case VerifyOutcome.active || VerifyOutcome.inactive:
        final active = result.outcome == VerifyOutcome.active;
        _tracked.remove(tracked.proof);
        if (active && purchase.platform == StorePlatform.google) {
          _activeGoogle[tracked.proof] = (
            userId: account.userId,
            purchase: purchase,
          );
        }
        _deliver(
          account,
          epoch,
          PurchaseVerified(
            active: active,
            plan: result.plan,
            silent: !tracked.full,
          ),
          full: tracked.full,
        );
        await _complete(purchase);
      case VerifyOutcome.ownedByOther:
        _tracked.remove(tracked.proof);
        _deliver(
          account,
          epoch,
          const PurchaseOwnedByOther(),
          full: tracked.full,
        );
        // Valid in the store, only bound to another account.
        await _complete(purchase);
      case VerifyOutcome.pending:
        _deliver(
          account,
          epoch,
          PurchasePending(silent: !tracked.full),
          full: tracked.full,
        );
      case VerifyOutcome.invalid:
        // The same proof cannot pass later; the store redelivers it.
        _tracked.remove(tracked.proof);
        _deliver(
          account,
          epoch,
          PurchaseInvalid(reason: result.invalidReason),
          full: tracked.full,
        );
      case VerifyOutcome.unavailable || VerifyOutcome.unauthorized:
        // Kept open in the store; retried on the next bind or resume.
        _deliver(
          account,
          epoch,
          const PurchaseVerifyDeferred(),
          full: tracked.full,
        );
    }
  }

  /// Finishes the store transaction; only ever after `active`, `inactive` or
  /// `ownedByOther`.
  Future<void> _complete(StorePurchase purchase) async {
    if (!purchase.needsCompletion) return;
    try {
      await billing.complete(purchase);
    } catch (e) {
      // Google may already be acknowledged by the server; the store asks
      // again otherwise.
      _log('complete', e);
    }
  }

  void _deliverNow(PurchaseEvent event, {required bool full}) {
    final account = _account;
    if (account != null) _deliver(account, _epoch, event, full: full);
  }

  /// [event] to [account] while it is still the bound one under [epoch].
  /// Without [full], only verified and pending results go out (a silent
  /// restore shows no message), and they wait while a purchase sheet is open.
  void _deliver(
    PurchaseAccount account,
    int epoch,
    PurchaseEvent event, {
    required bool full,
  }) {
    if (_disposed || epoch != _epoch || !identical(_account, account)) return;
    if (!full) {
      if (event is! PurchaseVerified && event is! PurchasePending) return;
      if (_buyOpen) {
        _withheld.add((account: account, event: event));
        return;
      }
    }
    _send(account, event);
    if (!full) return;
    // Plans computed before this verified purchase would only move the
    // account's plan backwards.
    if (event is PurchaseVerified) {
      _withheld.removeWhere((w) => w.event is PurchaseVerified);
    }
    _endBuy();
  }

  void _endBuy() {
    if (!_buyOpen) return;
    _buyOpen = false;
    final withheld = List.of(_withheld);
    _withheld.clear();
    for (final (:account, :event) in withheld) {
      if (identical(_account, account)) _send(account, event);
    }
  }

  void _send(PurchaseAccount account, PurchaseEvent event) {
    try {
      account.onPurchaseEvent(event);
    } catch (e) {
      _log('event', e);
    }
  }

  void _log(String step, Object error) => dev.log(
    'Purchase $step failed (${error.runtimeType})',
    name: 'purchases',
  );

  /// Stops listening (tests; the app keeps one coordinator for good).
  Future<void> dispose() async {
    _disposed = true;
    _account = null;
    if (_observing) WidgetsBinding.instance.removeObserver(this);
    await _updates.cancel();
  }
}

/// A purchase the coordinator still owes an answer for.
class _Tracked {
  _Tracked(this.proof);

  final PurchaseProof proof;

  /// The latest delivery of it; its handle is the one completed.
  StorePurchase? purchase;

  /// Every result is reported; otherwise only verified and pending.
  bool full = false;

  Future<void>? running;
}

class _RestoreRun {
  _RestoreRun({required this.silent});

  final bool silent;
  final Completer<void> answered = Completer<void>();
  final List<Future<void>> verifications = <Future<void>>[];
  bool found = false;
}
