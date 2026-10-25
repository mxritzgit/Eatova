/// The per-account daily quota an AI request ran into (docs/PREMIUM.md 3.1):
/// the `planLimit` object of a tier-quota denial in coach-chat, analyze-meal
/// and recipe-import. Burst, IP, auth-fail and global gates never carry it,
/// so only this object may lead to an upgrade hint.
library;

import 'plan_status.dart';

class PlanLimitHit {
  const PlanLimitHit({
    required this.feature,
    required this.tier,
    required this.limit,
    required this.resetAt,
    this.premiumLimit,
  });

  final PlanFeature feature;

  /// The tier the server applied to this request.
  final PlanTier tier;

  /// The daily limit that is used up.
  final int limit;

  /// The next 00:00 UTC, when the quota opens again.
  final DateTime resetAt;

  /// The Premium limit for the upgrade sentence; only for a Free account and
  /// only when Premium gives more.
  final int? premiumLimit;

  /// Whether the hint may offer Premium at all (the controller still decides
  /// whether to show it today, `SubscriptionController.takeUpsell`).
  bool get offersPremium => premiumLimit != null;

  /// Null for anything malformed: the caller then shows its plain rate-limit
  /// text, never an upgrade.
  static PlanLimitHit? fromJson(Object? json) {
    if (json is! Map) return null;
    final feature = PlanFeature.fromWire(json['feature']);
    final tier = PlanTier.fromWire(json['tier']);
    final limit = json['limit'];
    final reset = json['resetAt'];
    final premium = json['premiumLimit'];
    if (feature == null ||
        tier == null ||
        limit is! int ||
        limit < 1 ||
        limit > kMaxPlanDailyLimit ||
        reset is! String ||
        (premium != null &&
            (premium is! int || premium < 1 || premium > kMaxPlanDailyLimit))) {
      return null;
    }
    final resetAt = DateTime.tryParse(reset)?.toUtc();
    if (resetAt == null) return null;
    // Off the server rule (Free only, and higher): no upgrade to offer.
    final upgrade = premium is int && tier == PlanTier.free && premium > limit
        ? premium
        : null;
    return PlanLimitHit(
      feature: feature,
      tier: tier,
      limit: limit,
      resetAt: resetAt,
      premiumLimit: upgrade,
    );
  }

  /// The `planLimit` member of a decoded 429 body.
  static PlanLimitHit? fromBody(Object? body) =>
      body is Map ? fromJson(body['planLimit']) : null;

  @override
  bool operator ==(Object other) =>
      other is PlanLimitHit &&
      other.feature == feature &&
      other.tier == tier &&
      other.limit == limit &&
      other.resetAt.isAtSameMomentAs(resetAt) &&
      other.premiumLimit == premiumLimit;

  @override
  int get hashCode => Object.hash(
    feature,
    tier,
    limit,
    resetAt.microsecondsSinceEpoch,
    premiumLimit,
  );
}
