/// Eatova Premium (docs/PREMIUM.md 4.2): the account's tier, its daily
/// limits, today's usage and its store subscription, as `get_my_plan`
/// reports them (2.4). The server decides the tier and enforces the limits;
/// the app only shows them, and every number in the copy comes from here.
library;

import 'package:clock/clock.dart';

/// Upper bound of every daily limit (`plan_tiers` check constraints).
const int kMaxPlanDailyLimit = 10000;

enum PlanTier {
  free('free'),
  premium('premium');

  const PlanTier(this.wire);

  final String wire;

  static PlanTier? fromWire(Object? value) {
    for (final tier in values) {
      if (tier.wire == value) return tier;
    }
    return null;
  }
}

/// The AI features with a per-account daily quota. `/meal` in the Coach and
/// everything without AI have none.
enum PlanFeature {
  coach('coach'),
  mealAnalysis('meal_analysis'),
  recipeImport('recipe_import');

  const PlanFeature(this.wire);

  final String wire;

  static PlanFeature? fromWire(Object? value) {
    for (final feature in values) {
      if (feature.wire == value) return feature;
    }
    return null;
  }
}

/// The two Premium plans (1.1).
enum PremiumPeriod { monthly, yearly }

/// Where a subscription is billed. Store purchases are `google` or `apple`;
/// `manual` is an operator grant by SQL (1.3.7) and never sold in the app.
enum StorePlatform {
  google('google'),
  apple('apple'),
  manual('manual');

  const StorePlatform(this.wire);

  final String wire;

  static StorePlatform? fromWire(Object? value) {
    for (final platform in values) {
      if (platform.wire == value) return platform;
    }
    return null;
  }
}

/// `store_subscriptions.status`.
enum SubscriptionState {
  active('active'),
  grace('grace'),

  /// Auto-renew off, still paid until `expires_at`.
  canceled('canceled'),
  onHold('on_hold'),
  paused('paused'),
  pending('pending'),
  expired('expired'),
  revoked('revoked');

  const SubscriptionState(this.wire);

  final String wire;

  /// The server's entitlement rule (2.1), before the expiry check.
  bool get entitles => this == active || this == grace || this == canceled;

  static SubscriptionState? fromWire(Object? value) {
    for (final state in values) {
      if (state.wire == value) return state;
    }
    return null;
  }
}

/// `store_subscriptions.environment`; anything but production is a test
/// purchase (sandbox, license tester).
enum SubscriptionEnvironment {
  production('production'),
  sandbox('sandbox'),
  test('test');

  const SubscriptionEnvironment(this.wire);

  final String wire;

  static SubscriptionEnvironment? fromWire(Object? value) {
    for (final environment in values) {
      if (environment.wire == value) return environment;
    }
    return null;
  }
}

/// Which status sentence the Profile card shows (4.4); the date is
/// [SubscriptionInfo.expiresAt] where the sentence has one.
enum SubscriptionLine {
  renewsOn,
  endsOn,
  grace,
  onHold,
  paused,
  pending,
  expiredOn,
  revoked,
  manualUntil,
}

/// Lines under which the store still holds a live subscription: managing it
/// there fits, buying a second one does not.
const Set<SubscriptionLine> _liveStoreLines = <SubscriptionLine>{
  SubscriptionLine.renewsOn,
  SubscriptionLine.endsOn,
  SubscriptionLine.grace,
  SubscriptionLine.onHold,
  SubscriptionLine.paused,
  SubscriptionLine.pending,
};

/// The longest a store keeps a subscription on hold or paused past its
/// `expires_at`: Google's grace and hold together 60 days (Apple's billing
/// retry too), a Google pause 3 months. A row still in that state later was
/// never closed (no notification, no re-check) and counts as expired, so the
/// account can buy again.
const Duration _storeHoldSpan = Duration(days: 60);
const Duration _storePauseSpan = Duration(days: 92);

/// The UTC calendar day of [moment], as UTC midnight. All limits reset at
/// 00:00 UTC (1.1).
DateTime utcDay(DateTime moment) {
  final utc = moment.toUtc();
  return DateTime.utc(utc.year, utc.month, utc.day);
}

/// The next 00:00 UTC after [moment].
DateTime nextUtcMidnight(DateTime moment) =>
    utcDay(moment).add(const Duration(days: 1));

int? _dailyLimit(Object? value) =>
    value is int && value >= 1 && value <= kMaxPlanDailyLimit ? value : null;

int? _count(Object? value) => value is int && value >= 0 ? value : null;

DateTime? _instant(Object? value) =>
    value is String ? DateTime.tryParse(value)?.toUtc() : null;

String _iso(DateTime moment) => moment.toUtc().toIso8601String();

final RegExp _dayPattern = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');

DateTime? _day(Object? value) {
  if (value is! String) return null;
  final match = _dayPattern.firstMatch(value);
  if (match == null) return null;
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  final parsed = DateTime.utc(year, month, day);
  // DateTime rolls 2026-02-30 over into March; that is not a day.
  if (parsed.year != year || parsed.month != month || parsed.day != day) {
    return null;
  }
  return parsed;
}

String _dayKey(DateTime day) =>
    '${day.year.toString().padLeft(4, '0')}-'
    '${day.month.toString().padLeft(2, '0')}-'
    '${day.day.toString().padLeft(2, '0')}';

/// The daily limits of one tier (`limits.current|free|premium`).
class TierLimits {
  const TierLimits({
    required this.coachDaily,
    required this.mealAnalysisDaily,
    required this.recipeImportDaily,
    required this.recipePicture,
  });

  final int coachDaily;
  final int mealAnalysisDaily;
  final int recipeImportDaily;

  /// Whether a Coach `/recipe` comes with an AI picture.
  final bool recipePicture;

  int limitFor(PlanFeature feature) => switch (feature) {
    PlanFeature.coach => coachDaily,
    PlanFeature.mealAnalysis => mealAnalysisDaily,
    PlanFeature.recipeImport => recipeImportDaily,
  };

  Map<String, dynamic> toJson() => <String, dynamic>{
    'coach_daily': coachDaily,
    'meal_analysis_daily': mealAnalysisDaily,
    'recipe_import_daily': recipeImportDaily,
    'recipe_picture': recipePicture,
  };

  /// Null unless every limit is a whole number in the server's range.
  static TierLimits? fromJson(Object? json) {
    if (json is! Map) return null;
    final coach = _dailyLimit(json['coach_daily']);
    final meal = _dailyLimit(json['meal_analysis_daily']);
    final imports = _dailyLimit(json['recipe_import_daily']);
    final picture = json['recipe_picture'];
    if (coach == null || meal == null || imports == null || picture is! bool) {
      return null;
    }
    return TierLimits(
      coachDaily: coach,
      mealAnalysisDaily: meal,
      recipeImportDaily: imports,
      recipePicture: picture,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TierLimits &&
      other.coachDaily == coachDaily &&
      other.mealAnalysisDaily == mealAnalysisDaily &&
      other.recipeImportDaily == recipeImportDaily &&
      other.recipePicture == recipePicture;

  @override
  int get hashCode => Object.hash(
    coachDaily,
    mealAnalysisDaily,
    recipeImportDaily,
    recipePicture,
  );
}

/// The decided Free limits (1.1), used until the server answered.
const TierLimits kAssumedFreeLimits = TierLimits(
  coachDaily: 3,
  mealAnalysisDaily: 4,
  recipeImportDaily: 2,
  recipePicture: false,
);

/// The decided Premium limits (1.1), used until the server answered.
const TierLimits kAssumedPremiumLimits = TierLimits(
  coachDaily: 20,
  mealAnalysisDaily: 30,
  recipeImportDaily: 10,
  recipePicture: true,
);

/// What the account used on one UTC [day] (`usage`).
class PlanUsage {
  const PlanUsage({
    required this.day,
    required this.coach,
    required this.mealAnalysis,
    required this.recipeImport,
  });

  /// Nothing used on [day] yet.
  PlanUsage.none(DateTime day)
    : this(day: utcDay(day), coach: 0, mealAnalysis: 0, recipeImport: 0);

  /// UTC midnight of the counted day.
  final DateTime day;
  final int coach;
  final int mealAnalysis;
  final int recipeImport;

  int usedFor(PlanFeature feature) => switch (feature) {
    PlanFeature.coach => coach,
    PlanFeature.mealAnalysis => mealAnalysis,
    PlanFeature.recipeImport => recipeImport,
  };

  /// This usage with [feature] at [used].
  PlanUsage withUsed(PlanFeature feature, int used) => PlanUsage(
    day: day,
    coach: feature == PlanFeature.coach ? used : coach,
    mealAnalysis: feature == PlanFeature.mealAnalysis ? used : mealAnalysis,
    recipeImport: feature == PlanFeature.recipeImport ? used : recipeImport,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'day': _dayKey(day),
    'coach': coach,
    'meal_analysis': mealAnalysis,
    'recipe_import': recipeImport,
  };

  static PlanUsage? fromJson(Object? json) {
    if (json is! Map) return null;
    final day = _day(json['day']);
    final coach = _count(json['coach']);
    final meal = _count(json['meal_analysis']);
    final imports = _count(json['recipe_import']);
    if (day == null || coach == null || meal == null || imports == null) {
      return null;
    }
    return PlanUsage(
      day: day,
      coach: coach,
      mealAnalysis: meal,
      recipeImport: imports,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PlanUsage &&
      other.day.isAtSameMomentAs(day) &&
      other.coach == coach &&
      other.mealAnalysis == mealAnalysis &&
      other.recipeImport == recipeImport;

  @override
  int get hashCode => Object.hash(
    day.microsecondsSinceEpoch,
    coach,
    mealAnalysis,
    recipeImport,
  );
}

/// The account's subscription row as the snapshot shows it: the entitled row
/// with the latest expiry, otherwise the most recently updated one. Never
/// carries a store key, token or transaction id.
class SubscriptionInfo {
  const SubscriptionInfo({
    required this.platform,
    required this.productId,
    this.basePlanId,
    required this.state,
    required this.expiresAt,
    this.autoRenewing,
    this.environment = SubscriptionEnvironment.production,
  });

  final StorePlatform platform;
  final String productId;

  /// Google's base plan (`monthly`, `yearly`); null on Apple and manual rows.
  final String? basePlanId;
  final SubscriptionState state;
  final DateTime expiresAt;

  /// Null while unknown (Apple, until a store notification brought it).
  final bool? autoRenewing;
  final SubscriptionEnvironment environment;

  /// The plan, from Google's base plan or the product id; null for a manual
  /// grant or an unknown product.
  PremiumPeriod? get period {
    final plan = basePlanId ?? '';
    if (plan == 'yearly' || productId.endsWith('_yearly')) {
      return PremiumPeriod.yearly;
    }
    if (plan == 'monthly' || productId.endsWith('_monthly')) {
      return PremiumPeriod.monthly;
    }
    return null;
  }

  /// A sandbox or license-tester purchase (the "Testkauf" badge).
  bool get isTestPurchase => environment != SubscriptionEnvironment.production;

  /// Bought through a store (managed there), not granted by the operator.
  bool get isStorePurchase => platform != StorePlatform.manual;

  /// The server's entitlement rule (2.1) at [now].
  bool entitledAt(DateTime now) => state.entitles && expiresAt.isAfter(now);

  /// Still live in its store at [now]: paid, in grace, on hold or paused
  /// within the store's longest span, or pending. Not a manual grant.
  bool liveInStoreAt(DateTime now) =>
      isStorePurchase && _liveStoreLines.contains(lineAt(now));

  /// The Profile status sentence at [now] (default: the clock).
  SubscriptionLine lineAt([DateTime? now]) {
    final at = now ?? clock.now();
    final expired = !expiresAt.isAfter(at);
    if (platform == StorePlatform.manual) {
      return expired
          ? SubscriptionLine.expiredOn
          : SubscriptionLine.manualUntil;
    }
    bool heldFor(Duration span) => expiresAt.add(span).isAfter(at);
    return switch (state) {
      SubscriptionState.revoked => SubscriptionLine.revoked,
      SubscriptionState.onHold when heldFor(_storeHoldSpan) =>
        SubscriptionLine.onHold,
      SubscriptionState.paused when heldFor(_storePauseSpan) =>
        SubscriptionLine.paused,
      SubscriptionState.pending => SubscriptionLine.pending,
      _ when expired || state == SubscriptionState.expired =>
        SubscriptionLine.expiredOn,
      SubscriptionState.grace => SubscriptionLine.grace,
      SubscriptionState.canceled => SubscriptionLine.endsOn,
      _ =>
        autoRenewing == false
            ? SubscriptionLine.endsOn
            : SubscriptionLine.renewsOn,
    };
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'platform': platform.wire,
    'product_id': productId,
    'base_plan_id': basePlanId,
    'status': state.wire,
    'expires_at': _iso(expiresAt),
    'auto_renewing': autoRenewing,
    'environment': environment.wire,
  };

  static SubscriptionInfo? fromJson(Object? json) {
    if (json is! Map) return null;
    final platform = StorePlatform.fromWire(json['platform']);
    final productId = json['product_id'];
    final basePlanId = json['base_plan_id'];
    final state = SubscriptionState.fromWire(json['status']);
    final expiresAt = _instant(json['expires_at']);
    final autoRenewing = json['auto_renewing'];
    final environment = SubscriptionEnvironment.fromWire(json['environment']);
    if (platform == null ||
        productId is! String ||
        productId.isEmpty ||
        (basePlanId != null && (basePlanId is! String || basePlanId.isEmpty)) ||
        state == null ||
        expiresAt == null ||
        (autoRenewing != null && autoRenewing is! bool) ||
        environment == null) {
      return null;
    }
    return SubscriptionInfo(
      platform: platform,
      productId: productId,
      basePlanId: basePlanId as String?,
      state: state,
      expiresAt: expiresAt,
      autoRenewing: autoRenewing as bool?,
      environment: environment,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SubscriptionInfo &&
      other.platform == platform &&
      other.productId == productId &&
      other.basePlanId == basePlanId &&
      other.state == state &&
      other.expiresAt.isAtSameMomentAs(expiresAt) &&
      other.autoRenewing == autoRenewing &&
      other.environment == environment;

  @override
  int get hashCode => Object.hash(
    platform,
    productId,
    basePlanId,
    state,
    expiresAt.microsecondsSinceEpoch,
    autoRenewing,
    environment,
  );
}

/// The regular Premium tier's daily limits (`legacy.premium`).
typedef BasePremiumLimits = ({
  int coachDaily,
  int mealAnalysisDaily,
  int recipeImportDaily,
});

/// `legacy.premium`, added after the first snapshot shape: missing or
/// malformed, it is left out instead of failing the snapshot.
BasePremiumLimits? _basePremium(Object? json) {
  if (json is! Map) return null;
  final coach = _dailyLimit(json['coach_daily']);
  final meal = _dailyLimit(json['meal_analysis_daily']);
  final imports = _dailyLimit(json['recipe_import_daily']);
  if (coach == null || meal == null || imports == null) return null;
  return (
    coachDaily: coach,
    mealAnalysisDaily: meal,
    recipeImportDaily: imports,
  );
}

/// An account created before the Premium launch keeps the old limits until
/// [until] (null: no end set yet).
class LegacyPlan {
  const LegacyPlan({this.until, this.premium});

  final DateTime? until;

  /// The regular Premium limits a Premium subscription keeps after [until]
  /// (its [PlanStatus.premium] is merged with the old limits until then);
  /// null when the server did not send them.
  final BasePremiumLimits? premium;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'until': until == null ? null : _iso(until!),
    if (premium case final premium?)
      'premium': <String, dynamic>{
        'coach_daily': premium.coachDaily,
        'meal_analysis_daily': premium.mealAnalysisDaily,
        'recipe_import_daily': premium.recipeImportDaily,
      },
  };

  @override
  bool operator ==(Object other) =>
      other is LegacyPlan &&
      other.premium == premium &&
      (other.until == null
          ? until == null
          : until != null && other.until!.isAtSameMomentAs(until!));

  @override
  int get hashCode => Object.hash(until?.microsecondsSinceEpoch, premium);
}

/// The account's plan (`get_my_plan`, 2.4).
class PlanStatus {
  const PlanStatus({
    required this.tier,
    this.subscription,
    required this.current,
    required this.free,
    required this.premium,
    this.legacy,
    required this.usage,
    required this.resetAt,
    this.assumed = false,
  });

  /// The decided defaults (1.1) before the server answered: Free, nothing
  /// used today, [assumed] set. Never cached.
  factory PlanStatus.assumed([DateTime? now]) {
    final at = now ?? clock.now();
    return PlanStatus(
      tier: PlanTier.free,
      current: kAssumedFreeLimits,
      free: kAssumedFreeLimits,
      premium: kAssumedPremiumLimits,
      usage: PlanUsage.none(at),
      resetAt: nextUtcMidnight(at),
      assumed: true,
    );
  }

  final PlanTier tier;
  final SubscriptionInfo? subscription;

  /// The limits that apply to this account now (legacy and Premium merged).
  final TierLimits current;

  /// The Free and the (for this account effective) Premium limits, for the
  /// comparison table and the upgrade sentences.
  final TierLimits free;
  final TierLimits premium;

  /// Non-null for an account that still keeps the pre-launch limits.
  final LegacyPlan? legacy;
  final PlanUsage usage;

  /// The server's next reset (00:00 UTC) when the snapshot was taken; see
  /// [nextReset] for a cached snapshot.
  final DateTime resetAt;

  /// True for [PlanStatus.assumed]: nothing known from the server yet.
  final bool assumed;

  bool get isPremium => tier == PlanTier.premium;
  bool get isLegacy => legacy != null;

  /// The store subscription still live at [now] (default: the clock), also
  /// on Free (on hold, paused, pending): it is managed in its store, never
  /// bought a second time.
  SubscriptionInfo? liveStoreSubscription([DateTime? now]) {
    final info = subscription;
    return info != null && info.liveInStoreAt(now ?? clock.now()) ? info : null;
  }

  int limitFor(PlanFeature feature) => current.limitFor(feature);

  /// Today's (UTC) use of [feature]; a snapshot of an earlier day counts 0.
  int usedToday(PlanFeature feature, [DateTime? now]) {
    if (!usage.day.isAtSameMomentAs(utcDay(now ?? clock.now()))) return 0;
    final used = usage.usedFor(feature);
    final limit = limitFor(feature);
    return used > limit ? limit : used;
  }

  /// What is left of [feature] today (UTC).
  int remaining(PlanFeature feature, [DateTime? now]) =>
      limitFor(feature) - usedToday(feature, now);

  /// The Premium limit for "mit Premium {n} pro Tag": only on Free, and only
  /// when Premium gives more.
  int? premiumLimitFor(PlanFeature feature) {
    if (isPremium) return null;
    final more = premium.limitFor(feature);
    return more > limitFor(feature) ? more : null;
  }

  /// The next reset as seen at [now]: [resetAt] while it is ahead, otherwise
  /// the next 00:00 UTC (a cached snapshot of an earlier day).
  DateTime nextReset([DateTime? now]) {
    final at = now ?? clock.now();
    return resetAt.isAfter(at) ? resetAt : nextUtcMidnight(at);
  }

  PlanStatus withUsage(PlanUsage next) => PlanStatus(
    tier: tier,
    subscription: subscription,
    current: current,
    free: free,
    premium: premium,
    legacy: legacy,
    usage: next,
    resetAt: resetAt,
    assumed: assumed,
  );

  /// The wire shape of 2.4, also the cache slot `plan_status`.
  Map<String, dynamic> toJson() => <String, dynamic>{
    'tier': tier.wire,
    'subscription': subscription?.toJson(),
    'limits': <String, dynamic>{
      'current': current.toJson(),
      'free': free.toJson(),
      'premium': premium.toJson(),
    },
    'legacy': legacy?.toJson(),
    'usage': usage.toJson(),
    'reset_at': _iso(resetAt),
  };

  /// Null for anything that is not a complete snapshot; unknown extra fields
  /// are ignored (the server only adds fields).
  static PlanStatus? fromJson(Object? json) {
    if (json is! Map) return null;
    final tier = PlanTier.fromWire(json['tier']);
    final limits = json['limits'];
    if (tier == null || limits is! Map) return null;
    final current = TierLimits.fromJson(limits['current']);
    final free = TierLimits.fromJson(limits['free']);
    final premium = TierLimits.fromJson(limits['premium']);
    final usage = PlanUsage.fromJson(json['usage']);
    final resetAt = _instant(json['reset_at']);
    if (current == null ||
        free == null ||
        premium == null ||
        usage == null ||
        resetAt == null) {
      return null;
    }
    final rawSubscription = json['subscription'];
    final subscription = SubscriptionInfo.fromJson(rawSubscription);
    if (rawSubscription != null && subscription == null) return null;
    final rawLegacy = json['legacy'];
    LegacyPlan? legacy;
    if (rawLegacy != null) {
      if (rawLegacy is! Map || !rawLegacy.containsKey('until')) return null;
      final until = rawLegacy['until'];
      final premium = _basePremium(rawLegacy['premium']);
      if (until == null) {
        legacy = LegacyPlan(premium: premium);
      } else {
        final at = _instant(until);
        if (at == null) return null;
        legacy = LegacyPlan(until: at, premium: premium);
      }
    }
    return PlanStatus(
      tier: tier,
      subscription: subscription,
      current: current,
      free: free,
      premium: premium,
      legacy: legacy,
      usage: usage,
      resetAt: resetAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PlanStatus &&
      other.tier == tier &&
      other.subscription == subscription &&
      other.current == current &&
      other.free == free &&
      other.premium == premium &&
      other.legacy == legacy &&
      other.usage == usage &&
      other.resetAt.isAtSameMomentAs(resetAt) &&
      other.assumed == assumed;

  @override
  int get hashCode => Object.hash(
    tier,
    subscription,
    current,
    free,
    premium,
    legacy,
    usage,
    resetAt.microsecondsSinceEpoch,
    assumed,
  );
}
