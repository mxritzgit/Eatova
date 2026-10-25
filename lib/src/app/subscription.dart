import 'dart:async';
import 'dart:developer' as dev;

import 'package:clock/clock.dart';
import 'package:flutter/widgets.dart';

import '../models/plan_limit_hit.dart';
import '../models/plan_status.dart';
import '../services/billing/billing_client.dart' show PurchaseProof;
import '../services/billing/purchase_flow.dart';
import '../services/subscription_sync.dart';

/// The account's cached plan and upgrade-hint days (the encrypted account
/// cache, slots `plan_status` and `upsell_shown`; `HomeStore` in the app).
abstract interface class PlanStatusCache {
  Future<PlanStatus?> readPlanStatus();

  /// Never called with an assumed plan.
  Future<void> writePlanStatus(PlanStatus status);

  /// The UTC day each upgrade hint was last offered; empty when none was.
  Future<Map<PlanFeature, DateTime>> readUpsellDays();

  Future<void> writeUpsellDays(Map<PlanFeature, DateTime> days);
}

/// The onboarding paywall's answer for this account (slot `paywall_prompt`,
/// 4.3): set to [pending] by a fresh onboarding, [answered] by "Weiter mit
/// Free", close, Back or a finished purchase.
enum PaywallPromptState {
  pending('pending'),
  answered('answered');

  const PaywallPromptState(this.wire);

  final String wire;

  static PaywallPromptState? fromWire(Object? value) {
    for (final state in values) {
      if (state.wire == value) return state;
    }
    return null;
  }
}

/// Where the Premium screen was opened from (`PaywallMode.upsell`, 4.3).
enum PremiumSource {
  profile,
  settings,
  coach,
  mealAnalysis,
  recipeImport,
  recipePicture,
}

/// Where the account stands with a purchase or restore. The terminal states
/// stay until [SubscriptionController.clearPurchaseState] or the next action.
enum PurchaseState {
  idle,
  loadingOffers,

  /// The store's sheet is open, or its purchase is being verified.
  purchasing,
  restoring,

  /// The store reports a pending payment.
  pending,

  /// A purchase was verified and Premium is active ("Willkommen bei
  /// Premium").
  success,

  /// A restore found an active subscription ("Premium ist wieder aktiv").
  restored,

  /// A restore found nothing active ("Kein aktives Abo gefunden").
  restoredNothing,

  /// The purchase belongs to another Eatova account.
  ownedByOther,

  /// The purchase arrived, the server confirmation follows (retried
  /// automatically).
  verifyDeferred,

  /// The purchase failed or was rejected ("Der Kauf hat nicht geklappt").
  failed,
}

/// How often [SubscriptionController.refresh] reads the server unless forced
/// (app resumes are frequent; purchases arrive as events anyway).
const Duration kPlanRefreshInterval = Duration(minutes: 5);

/// Window in which a Google subscription's expiry makes the controller ask
/// the server to re-check it with Google (no webhook needed for renewals).
/// A row on hold or paused has no lower bound: it can outlast the window,
/// and only the re-check closes it once Google ends it.
const Duration kStoreRecheckAhead = Duration(hours: 48);
const Duration kStoreRecheckBehind = Duration(days: 30);

/// The plan and purchases of ONE signed-in account (docs/PREMIUM.md 4.2).
///
/// The shell creates it per account and session, binds it into the
/// app-level [SubscriptionScope] and into the [PurchaseFlow], and disposes it
/// with the account. The plan shown is the cached one until the server
/// answered, [PlanStatus.assumed] before anything is known. The server
/// decides the tier: a purchase counts only once [PurchaseVerified] brought
/// the server's plan, and a failed read keeps what was known.
class SubscriptionController extends ChangeNotifier implements PurchaseAccount {
  SubscriptionController({
    required this.userId,
    required PlanStatusCache cache,
    required SubscriptionLog log,
    this.flow = const NoPurchaseFlow(),
  }) : _cache = cache,
       _log = log,
       canPurchase = true;

  /// Preview and tests without a sync layer (debug builds only): the assumed
  /// plan, no store, no upgrade hints.
  SubscriptionController.preview()
    : userId = '',
      _cache = const _NoPlanCache(),
      _log = const _NoSubscriptionLog(),
      flow = const NoPurchaseFlow(),
      canPurchase = false;

  @override
  final String userId;
  final PlanStatusCache _cache;
  final SubscriptionLog _log;

  /// The app's purchase pipeline.
  final PurchaseFlow flow;

  /// False only for [SubscriptionController.preview].
  final bool canPurchase;

  PlanStatus _plan = PlanStatus.assumed();
  bool _loaded = false;
  bool _disposed = false;

  /// Bumped by every verified purchase, so a server read that started
  /// before it cannot overwrite it when it lands.
  int _revision = 0;

  Future<void>? _loading;
  Future<void>? _refreshing;
  DateTime? _lastRefreshAt;

  List<PremiumOffer> _offers = const <PremiumOffer>[];
  BillingAvailability? _availability;
  Future<void>? _offersLoading;

  PurchaseState _purchaseState = PurchaseState.idle;

  /// What a user restore met before it ended, to pick its final state.
  final Set<PurchaseState> _restoreFindings = <PurchaseState>{};

  /// The UTC day each upgrade hint was last offered.
  final Map<PlanFeature, DateTime> _upsellDays = <PlanFeature, DateTime>{};

  final StreamController<PlanStatus> _tierChanges =
      StreamController<PlanStatus>.broadcast();
  int _tierRevision = 0;

  @override
  SubscriptionLog get log => _log;

  /// The latest known plan; [PlanStatus.assumed] until the cache or the
  /// server answered.
  PlanStatus get plan => _plan;

  bool get isPremium => _plan.isPremium;

  /// Whether the cached plan has been read.
  bool get loaded => _loaded;

  /// The store's plans; empty until [loadOffers] found some.
  List<PremiumOffer> get offers => _offers;

  /// Null until [loadOffers] asked the store.
  BillingAvailability? get availability => _availability;

  /// The store can sell now: available and with both prices known.
  bool get storeReady =>
      _availability == BillingAvailability.available && _offers.isNotEmpty;

  PurchaseState get purchaseState => _purchaseState;

  /// The store's offer for [period], null when it has none.
  PremiumOffer? offerFor(PremiumPeriod period) {
    for (final offer in _offers) {
      if (offer.period == period) return offer;
    }
    return null;
  }

  /// Fires with the new plan whenever the tier or the current limits change
  /// (an upgrade, an expiry, the legacy window closing). The Coach resets
  /// its remembered daily limit here, so an upgrade unlocks the composer at
  /// once (4.5).
  Stream<PlanStatus> get tierChanges => _tierChanges.stream;

  /// Counts the [tierChanges] so far; for widgets that compare instead of
  /// listening.
  int get tierRevision => _tierRevision;

  /// Reads the cache, then the server. Idempotent.
  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    final revision = _revision;
    final upsellDays = _readUpsellDays();
    PlanStatus? cached;
    try {
      cached = await _cache.readPlanStatus();
    } catch (e) {
      _logFailure('cache read', e);
    }
    final shown = await upsellDays;
    if (_disposed) return;
    // Offered today by an earlier process (killed in the background, an
    // account switch): still at most once per UTC day.
    final today = utcDay(clock.now());
    for (final MapEntry(key: feature, value: day) in shown.entries) {
      if (day.isAtSameMomentAs(today)) _upsellDays[feature] = day;
    }
    // A server plan that arrived meanwhile (a resume refresh, a limit hit)
    // is newer; only a server plan clears `assumed`.
    if (cached != null && revision == _revision && _plan.assumed) {
      _setPlan(cached);
    }
    _loaded = true;
    notifyListeners();
    await refresh(force: true);
  }

  /// Reads the plan from the server, at most once per
  /// [kPlanRefreshInterval] unless [force]d; concurrent calls share one read.
  /// A failure keeps the known plan. A Google subscription close to or just
  /// past its expiry is re-checked with the store on the way.
  Future<void> refresh({bool force = false}) {
    if (_disposed || !canPurchase) return Future<void>.value();
    final running = _refreshing;
    if (running != null) return running;
    final now = clock.now();
    final last = _lastRefreshAt;
    if (!force &&
        last != null &&
        now.difference(last).abs() < kPlanRefreshInterval) {
      return Future<void>.value();
    }
    _lastRefreshAt = now;
    final refreshing = _refresh().whenComplete(() => _refreshing = null);
    _refreshing = refreshing;
    return refreshing;
  }

  Future<void> _refresh() async {
    final revision = _revision;
    final PlanStatus fetched;
    try {
      fetched = await _log.fetchPlan();
    } catch (e) {
      // Offline or off the contract: the known plan stands, the next resume
      // asks again.
      _lastRefreshAt = null;
      _logFailure('plan read', e);
      return;
    }
    if (_disposed || revision != _revision) return;
    _adoptServerPlan(fetched);
    if (!_needsStoreRecheck(fetched)) return;
    final result = await _log.refresh();
    final rechecked = result.plan;
    if (_disposed || revision != _revision || rechecked == null) return;
    _adoptServerPlan(rechecked);
  }

  bool _needsStoreRecheck(PlanStatus plan) {
    final subscription = plan.subscription;
    if (subscription == null ||
        subscription.platform != StorePlatform.google ||
        subscription.state == SubscriptionState.revoked ||
        subscription.state == SubscriptionState.expired) {
      return false;
    }
    final now = clock.now();
    return subscription.expiresAt.isBefore(now.add(kStoreRecheckAhead)) &&
        (subscription.state == SubscriptionState.onHold ||
            subscription.state == SubscriptionState.paused ||
            subscription.expiresAt.isAfter(now.subtract(kStoreRecheckBehind)));
  }

  /// A server plan, keeping today's higher local counts ([noteUsage]) that a
  /// read started earlier may not have seen yet.
  void _adoptServerPlan(PlanStatus server) {
    var next = server;
    if (_plan.usage.day.isAtSameMomentAs(server.usage.day)) {
      var usage = server.usage;
      for (final feature in PlanFeature.values) {
        final local = _plan.usage.usedFor(feature);
        if (local > usage.usedFor(feature)) {
          usage = usage.withUsed(feature, local);
        }
      }
      if (usage != server.usage) next = server.withUsage(usage);
    }
    if (next == _plan) return;
    _setPlan(next);
    notifyListeners();
    unawaited(_writeCache(next));
  }

  void _setPlan(PlanStatus next) {
    final previous = _plan;
    _plan = next;
    if (previous.tier != next.tier || previous.current != next.current) {
      _tierRevision++;
      _tierChanges.add(next);
    }
  }

  Future<void> _writeCache(PlanStatus status) async {
    if (status.assumed) return;
    try {
      await _cache.writePlanStatus(status);
    } catch (e) {
      _logFailure('cache write', e);
    }
  }

  Future<Map<PlanFeature, DateTime>> _readUpsellDays() async {
    try {
      return await _cache.readUpsellDays();
    } catch (e) {
      _logFailure('upsell read', e);
      return const <PlanFeature, DateTime>{};
    }
  }

  Future<void> _writeUpsellDays(Map<PlanFeature, DateTime> days) async {
    try {
      await _cache.writeUpsellDays(days);
    } catch (e) {
      _logFailure('upsell write', e);
    }
  }

  /// Asks the store for availability and both plans. Shares a running
  /// request; with offers known it only asks again when [force]d.
  Future<void> loadOffers({bool force = false}) {
    if (_disposed) return Future<void>.value();
    final running = _offersLoading;
    if (running != null) return running;
    if (!force && _offers.isNotEmpty) return Future<void>.value();
    final loading = _loadOffers().whenComplete(() => _offersLoading = null);
    _offersLoading = loading;
    return loading;
  }

  Future<void> _loadOffers() async {
    final showsLoading = _purchaseState == PurchaseState.idle;
    if (showsLoading) _setPurchaseState(PurchaseState.loadingOffers);
    BillingAvailability availability;
    var offers = const <PremiumOffer>[];
    try {
      availability = await flow.availability();
      if (availability == BillingAvailability.available) {
        offers = List<PremiumOffer>.unmodifiable(await flow.offers());
      }
    } catch (e) {
      _logFailure('offers', e);
      availability = BillingAvailability.unavailable;
    }
    if (_disposed) return;
    _availability = availability;
    _offers = offers;
    if (_purchaseState == PurchaseState.loadingOffers) {
      _purchaseState = PurchaseState.idle;
    }
    notifyListeners();
  }

  bool get _busy =>
      _purchaseState == PurchaseState.purchasing ||
      _purchaseState == PurchaseState.restoring;

  /// Buys the plan for [period]: the account token from the server, then
  /// the store's sheet. The outcome arrives as a [PurchaseEvent].
  Future<void> buy(PremiumPeriod period) async {
    if (_disposed || _busy) return;
    if (_offers.isEmpty) await loadOffers();
    final offer = offerFor(period);
    if (_disposed || _busy) return;
    if (!canPurchase || offer == null) {
      _setPurchaseState(PurchaseState.failed);
      return;
    }
    _setPurchaseState(PurchaseState.purchasing);
    final String token;
    try {
      token = await _log.accountToken();
    } catch (e) {
      _logFailure('account token', e);
      if (!_disposed && _purchaseState == PurchaseState.purchasing) {
        _setPurchaseState(PurchaseState.failed);
      }
      return;
    }
    if (_disposed || _purchaseState != PurchaseState.purchasing) return;
    try {
      await flow.buy(offer, accountToken: token, current: _plan.subscription);
    } catch (e) {
      _logFailure('buy', e);
      if (!_disposed && _purchaseState == PurchaseState.purchasing) {
        _setPurchaseState(PurchaseState.failed);
      }
    }
  }

  /// "Käufe wiederherstellen": ends in [PurchaseState.restored] as soon as an
  /// active purchase verified, otherwise once the flow finished.
  Future<void> restore() async {
    if (_disposed || _busy) return;
    _restoreFindings.clear();
    _setPurchaseState(PurchaseState.restoring);
    try {
      await flow.restore();
    } catch (e) {
      _logFailure('restore', e);
      _restoreFindings.add(PurchaseState.failed);
    }
    if (!_disposed && _purchaseState == PurchaseState.restoring) {
      _finishRestore();
    }
  }

  void _finishRestore() {
    const precedence = <PurchaseState>[
      PurchaseState.pending,
      PurchaseState.verifyDeferred,
      PurchaseState.ownedByOther,
      PurchaseState.failed,
    ];
    final found = precedence.where(_restoreFindings.contains).toList();
    _restoreFindings.clear();
    _setPurchaseState(
      found.isEmpty ? PurchaseState.restoredNothing : found.first,
    );
  }

  /// The store's subscription management for the account's subscription.
  Future<void> openManageSubscriptions() async {
    final subscription = _plan.subscription;
    try {
      await flow.openManageSubscriptions(
        productId: subscription?.productId,
        platform: subscription?.isStorePurchase == true
            ? subscription!.platform
            : null,
      );
    } catch (e) {
      _logFailure('manage subscriptions', e);
    }
  }

  /// Back to [PurchaseState.idle] after the UI showed a result (or gave up
  /// waiting for one). A running restore ends by itself.
  void clearPurchaseState() {
    if (_disposed ||
        _purchaseState == PurchaseState.restoring ||
        _purchaseState == PurchaseState.loadingOffers ||
        _purchaseState == PurchaseState.idle) {
      return;
    }
    _setPurchaseState(PurchaseState.idle);
  }

  @override
  void onPurchaseEvent(PurchaseEvent event) {
    if (_disposed) return;
    final restoring = _purchaseState == PurchaseState.restoring;
    // A silent result (a restore of an older purchase) never changes the
    // state of a running purchase: it can land during the account-token
    // request, while the sheet is open or after it closed pending or
    // deferred. The account's own purchase always reports in full.
    final waiting =
        _purchaseState == PurchaseState.purchasing ||
        _purchaseState == PurchaseState.pending ||
        _purchaseState == PurchaseState.verifyDeferred;
    switch (event) {
      case PurchaseVerified(:final active, :final plan, :final silent):
        // Newer than any read in flight, which must not land over it.
        _revision++;
        if (plan != null) {
          _adoptServerPlan(plan);
        } else {
          _readAgain();
        }
        if (restoring) {
          if (active) {
            _restoreFindings.clear();
            _setPurchaseState(PurchaseState.restored);
          }
        } else if (waiting && !silent) {
          _setPurchaseState(
            active ? PurchaseState.success : PurchaseState.failed,
          );
        }
      case PurchasePending(:final silent):
        if (restoring) {
          _restoreFindings.add(PurchaseState.pending);
        } else if ((waiting && !silent) ||
            _purchaseState == PurchaseState.idle) {
          _setPurchaseState(PurchaseState.pending);
        }
      case PurchaseOwnedByOther():
        _settle(restoring, waiting, PurchaseState.ownedByOther);
      case PurchaseVerifyDeferred():
        _settle(restoring, waiting, PurchaseState.verifyDeferred);
      case PurchaseInvalid(reason: 'account'):
        // Carries another Eatova account's token: retrying cannot help.
        _settle(restoring, waiting, PurchaseState.ownedByOther);
      case PurchaseInvalid() || PurchaseFailed():
        _settle(restoring, waiting, PurchaseState.failed);
      case PurchaseCanceled():
        if (_purchaseState == PurchaseState.purchasing) {
          _setPurchaseState(PurchaseState.idle);
        }
      case PurchaseRestoredNothing():
        if (restoring) _finishRestore();
    }
  }

  /// A fresh server read, after the one in flight (whose answer predates
  /// the event that asked for this).
  void _readAgain() {
    final running = _refreshing;
    if (running == null) {
      unawaited(refresh(force: true));
    } else {
      unawaited(running.whenComplete(() => refresh(force: true)));
    }
  }

  void _settle(bool restoring, bool waiting, PurchaseState outcome) {
    if (restoring) {
      _restoreFindings.add(outcome);
    } else if (waiting) {
      _setPurchaseState(outcome);
    }
  }

  void _setPurchaseState(PurchaseState state) {
    if (_disposed || _purchaseState == state) return;
    _purchaseState = state;
    notifyListeners();
  }

  /// Whether the "Mehr mit Premium" action may show for [feature] now: true
  /// at most once per feature and UTC day, also across app starts (the
  /// account's `upsell_shown` slot), so call it once per limit hit, not per
  /// build. Always false in preview.
  bool takeUpsell(PlanFeature feature) {
    if (!canPurchase || _disposed) return false;
    final today = utcDay(clock.now());
    final last = _upsellDays[feature];
    if (last != null && last.isAtSameMomentAs(today)) return false;
    _upsellDays[feature] = today;
    unawaited(_writeUpsellDays(Map.of(_upsellDays)));
    return true;
  }

  /// Today's use of [feature] as an AI response reported it (a counter or
  /// `rateLimit.userDay`), so counters and "Heute noch n" follow without a
  /// server read. Only raises the count.
  void noteUsage(PlanFeature feature, int used) {
    if (_disposed || used < 0) return;
    final today = utcDay(clock.now());
    final usage = _plan.usage.day.isAtSameMomentAs(today)
        ? _plan.usage
        : PlanUsage.none(today);
    if (used <= usage.usedFor(feature)) return;
    final next = _plan.withUsage(usage.withUsed(feature, used));
    _plan = next;
    notifyListeners();
    unawaited(_writeCache(next));
  }

  /// A tier-quota denial: the feature is used up today, and a tier or limit
  /// that differs from the known plan means the plan changed, so it is read
  /// again.
  void noteLimitHit(PlanLimitHit hit) {
    if (_disposed) return;
    noteUsage(hit.feature, hit.limit);
    if (hit.tier != _plan.tier || hit.limit != _plan.limitFor(hit.feature)) {
      unawaited(refresh(force: true));
    }
  }

  void _logFailure(String step, Object error) => dev.log(
    'Subscription $step failed (${error.runtimeType})',
    name: 'subscription',
  );

  @override
  void dispose() {
    _disposed = true;
    unawaited(_tierChanges.close());
    super.dispose();
  }
}

class _NoPlanCache implements PlanStatusCache {
  const _NoPlanCache();

  @override
  Future<PlanStatus?> readPlanStatus() => Future<PlanStatus?>.value();

  @override
  Future<void> writePlanStatus(PlanStatus status) => Future<void>.value();

  @override
  Future<Map<PlanFeature, DateTime>> readUpsellDays() =>
      Future<Map<PlanFeature, DateTime>>.value(const <PlanFeature, DateTime>{});

  @override
  Future<void> writeUpsellDays(Map<PlanFeature, DateTime> days) =>
      Future<void>.value();
}

class _NoSubscriptionLog implements SubscriptionLog {
  const _NoSubscriptionLog();

  @override
  Future<PlanStatus> fetchPlan() =>
      Future<PlanStatus>.error(StateError('No server in preview'));

  @override
  Future<String> accountToken() =>
      Future<String>.error(StateError('No server in preview'));

  @override
  Future<VerifyResult> verify(PurchaseProof proof) =>
      Future<VerifyResult>.value(const VerifyResult(VerifyOutcome.unavailable));

  @override
  Future<VerifyResult> refresh() =>
      Future<VerifyResult>.value(const VerifyResult(VerifyOutcome.unavailable));
}

/// Opens the Premium screen; registered by the shell (the screen lives
/// there, on the root Navigator).
typedef PremiumOpener =
    Future<void> Function(BuildContext context, PremiumSource source);

/// The app-level slot the signed-in shell binds its account's
/// [SubscriptionController] into, plus the [PremiumOpener] it registers.
/// Plain holder like `AiTrustBinding`: every reader looks it up when it acts.
/// A new account's shell binds before the old one disposes, so unbinding
/// only removes its own controller or opener.
class SubscriptionBinding {
  SubscriptionController? _controller;
  PremiumOpener? _opener;

  SubscriptionController? get controller => _controller;
  PremiumOpener? get opener => _opener;

  void bind(SubscriptionController controller) => _controller = controller;

  void unbind(SubscriptionController controller) {
    if (identical(_controller, controller)) _controller = null;
  }

  void registerOpener(PremiumOpener opener) => _opener = opener;

  /// By equality: a method tear-off is equal, not identical, to itself.
  void unregisterOpener(PremiumOpener opener) {
    if (_opener == opener) _opener = null;
  }
}

/// Provides the [SubscriptionBinding] above the app's Navigator, so sheets
/// and pushed routes (Coach, add meal, recipe import, Profile, Settings)
/// reach the account's plan like the tabs do.
class SubscriptionScope extends InheritedWidget {
  const SubscriptionScope({
    super.key,
    required this.binding,
    required super.child,
  });

  final SubscriptionBinding binding;

  /// The binding, or null outside the app shell (widget tests, previews).
  static SubscriptionBinding? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<SubscriptionScope>()?.binding;

  /// The bound account's controller, or null. Listen to it for changes.
  static SubscriptionController? controllerOf(BuildContext context) =>
      maybeOf(context)?.controller;

  @override
  bool updateShouldNotify(SubscriptionScope oldWidget) =>
      !identical(binding, oldWidget.binding);
}

/// Opens the Premium screen from [source]; a no-op without a bound shell.
Future<void> openPremium(
  BuildContext context, {
  required PremiumSource source,
}) {
  final opener = SubscriptionScope.maybeOf(context)?.opener;
  if (opener == null) return Future<void>.value();
  return opener(context, source);
}

/// Opens the store's subscription management for the bound account; a no-op
/// without one.
Future<void> openManageSubscription(BuildContext context) {
  final controller = SubscriptionScope.controllerOf(context);
  if (controller == null) return Future<void>.value();
  return controller.openManageSubscriptions();
}
