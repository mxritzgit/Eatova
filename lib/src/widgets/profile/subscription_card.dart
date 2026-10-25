import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../app/subscription.dart' show PurchaseState, SubscriptionController;
import '../../l10n/l10n.dart';
import '../../models/plan_status.dart';
import '../../theme/app_tokens.dart';
import '../common/app_snack.dart';
import '../design/design.dart';

/// The store this device sells through: Google Play on Android, the App
/// Store on iOS, none elsewhere.
StorePlatform? deviceStorePlatform() {
  if (kIsWeb) return null;
  return switch (defaultTargetPlatform) {
    TargetPlatform.android => StorePlatform.google,
    TargetPlatform.iOS => StorePlatform.apple,
    _ => null,
  };
}

/// "Käufe wiederherstellen" for the Profile: runs [controller]'s restore and
/// returns where it ended, then hands the state back to idle. Does nothing
/// while a purchase or restore is already running.
Future<PurchaseState> restorePurchasesFor(
  SubscriptionController controller,
) async {
  final before = controller.purchaseState;
  if (before == PurchaseState.purchasing || before == PurchaseState.restoring) {
    return PurchaseState.idle;
  }
  await controller.restore();
  final outcome = controller.purchaseState;
  controller.clearPurchaseState();
  return outcome;
}

/// The Profile's "Abo" card (docs/PREMIUM.md 4.4): tier, the subscription's
/// status, today's AI usage against the current limits and the actions that
/// fit the account.
///
/// Every number and date comes from [plan] (the server's snapshot); the
/// status follows [SubscriptionInfo.lineAt] at the clock. A Free account
/// gets "Mehr mit Premium", a live store subscription "Abo verwalten" (or
/// the note that it is managed in the other platform's store), every
/// account "Käufe wiederherstellen". Null callbacks hide their action.
class SubscriptionCard extends StatefulWidget {
  const SubscriptionCard({
    super.key,
    required this.plan,
    this.onUpgrade,
    this.onManage,
    this.onRestore,
  });

  final PlanStatus plan;

  /// Opens the paywall (`openPremium`, source profile).
  final VoidCallback? onUpgrade;

  /// The store's subscription management on this device.
  final VoidCallback? onManage;

  /// Restores purchases and reports where it ended ([restorePurchasesFor]);
  /// the card names the outcome in a toast.
  final Future<PurchaseState> Function()? onRestore;

  @override
  State<SubscriptionCard> createState() => _SubscriptionCardState();
}

class _SubscriptionCardState extends State<SubscriptionCard> {
  bool _restoring = false;

  Future<void> _restore(Future<PurchaseState> Function() restore) async {
    if (_restoring) return;
    setState(() => _restoring = true);
    var outcome = PurchaseState.failed;
    try {
      outcome = await restore();
    } catch (_) {
      outcome = PurchaseState.failed;
    }
    if (!mounted) return;
    setState(() => _restoring = false);
    final l10n = context.l10n;
    final store = (deviceStorePlatform() ?? StorePlatform.google).wire;
    final (String? message, SnackTone tone) = switch (outcome) {
      PurchaseState.restored => (l10n.premiumRestoreDone, SnackTone.positive),
      PurchaseState.restoredNothing => (
        l10n.premiumRestoreNothing,
        SnackTone.neutral,
      ),
      PurchaseState.pending => (
        l10n.premiumPendingBody(store),
        SnackTone.neutral,
      ),
      PurchaseState.verifyDeferred => (
        l10n.premiumVerifyLater,
        SnackTone.neutral,
      ),
      PurchaseState.ownedByOther => (
        l10n.premiumOwnedByOther,
        SnackTone.warning,
      ),
      PurchaseState.failed => (l10n.premiumPurchaseFailed, SnackTone.error),
      _ => (null, SnackTone.neutral),
    };
    if (message == null) return;
    showAppSnack(
      context,
      message,
      tone: tone,
      duration: tone == SnackTone.positive ? null : kSnackError,
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final now = clock.now();
    final plan = widget.plan;
    final subscription = plan.subscription;
    final line = subscription?.lineAt(now);
    // The store that still holds a live subscription, if any.
    final liveStore = plan.liveStoreSubscription(now)?.platform;
    final manageHere = liveStore != null && liveStore == deviceStorePlatform();
    final upgrade = !plan.isPremium && liveStore == null
        ? widget.onUpgrade
        : null;
    final manage = manageHere ? widget.onManage : null;
    final restore = widget.onRestore;
    // With the year: a yearly plan renews a year out.
    final dateFormat = DateFormat.yMMMd(l10n.localeName);
    String date(DateTime moment) => dateFormat.format(moment.toLocal());

    final details = <String>[
      if (subscription?.period case final period?)
        period == PremiumPeriod.yearly
            ? l10n.subscriptionPlanYearly
            : l10n.subscriptionPlanMonthly,
      if (subscription != null && subscription.isStorePurchase)
        l10n.subscriptionVia(subscription.platform.wire),
    ];
    final status = subscription == null || line == null
        ? null
        : _statusText(l10n, line, subscription, date(subscription.expiresAt));
    final statusColor = switch (line) {
      SubscriptionLine.grace || SubscriptionLine.onHold => t.warning,
      SubscriptionLine.renewsOn || SubscriptionLine.manualUntil => t.accentText,
      _ => t.ink2,
    };
    // A Premium account's current limits merge Premium in: they are not
    // "the previous limits". Once `until` is set it names the date the
    // regular Premium limits apply from, which stays here after Today's
    // one-time notice was dismissed.
    final legacyNote = switch ((plan.isPremium, plan.legacy)) {
      (_, null) => null,
      (true, LegacyPlan(until: final until?, premium: final base?)) =>
        l10n.legacyNoticeBodyPremium(
          date(until),
          base.coachDaily,
          base.mealAnalysisDaily,
          base.recipeImportDaily,
        ),
      (true, LegacyPlan(until: final until?)) =>
        l10n.legacyNoticeBodyPremiumPlain(date(until)),
      (true, LegacyPlan()) => null,
      (false, LegacyPlan(until: final until?)) => l10n.premiumLegacyNoteUntil(
        date(until),
        plan.current.coachDaily,
        plan.current.mealAnalysisDaily,
        plan.current.recipeImportDaily,
      ),
      (false, LegacyPlan()) => l10n.premiumLegacyNote(
        plan.current.coachDaily,
        plan.current.mealAnalysisDaily,
        plan.current.recipeImportDaily,
      ),
    };

    return AppCard(
      key: const ValueKey('profile-subscription-card'),
      clip: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                ExcludeSemantics(
                  child: IconTile.custom(
                    color: plan.isPremium ? t.accent : null,
                    size: 40,
                    child: const Icon(
                      Icons.workspace_premium_outlined,
                      size: 20,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: <Widget>[
                          _TierPill(premium: plan.isPremium),
                          if (subscription?.isTestPurchase ?? false)
                            const _TestPurchaseBadge(),
                        ],
                      ),
                      if (details.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 8),
                        Text(
                          details.join(' · '),
                          key: const ValueKey('profile-subscription-details'),
                          style: AppType.ui(
                            13.5,
                            weight: FontWeight.w600,
                            color: t.ink,
                            height: 1.35,
                          ),
                        ),
                      ],
                      if (status != null) ...<Widget>[
                        const SizedBox(height: 4),
                        _StatusLine(text: status, color: statusColor),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, thickness: 1, color: t.line),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  l10n.subscriptionUsageTitle,
                  style: AppType.ui(
                    12.5,
                    weight: FontWeight.w600,
                    color: t.ink2,
                  ),
                ),
                const SizedBox(height: 4),
                for (final (feature, label) in <(PlanFeature, String)>[
                  (PlanFeature.coach, l10n.subscriptionUsageCoach),
                  (PlanFeature.mealAnalysis, l10n.subscriptionUsageAnalyses),
                  (PlanFeature.recipeImport, l10n.subscriptionUsageImports),
                ])
                  _UsageRow(
                    key: ValueKey('profile-subscription-usage-${feature.wire}'),
                    label: label,
                    value: l10n.subscriptionUsageValue(
                      plan.usedToday(feature, now),
                      plan.limitFor(feature),
                    ),
                    valueLabel: l10n.subscriptionUsageValueLabel(
                      plan.usedToday(feature, now),
                      plan.limitFor(feature),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (legacyNote != null) ...<Widget>[
                  _CardNote(
                    key: const ValueKey('profile-subscription-legacy'),
                    text: legacyNote,
                    icon: Icons.history_rounded,
                  ),
                  const SizedBox(height: 12),
                ],
                if (upgrade != null) ...<Widget>[
                  Text(
                    l10n.subscriptionFreeBody(
                      plan.premium.coachDaily,
                      plan.premium.mealAnalysisDaily,
                    ),
                    style: AppType.ui(13, color: t.ink2, height: 1.4),
                  ),
                  const SizedBox(height: 12),
                  SoftPillButton(
                    key: const ValueKey('profile-subscription-upgrade'),
                    label: l10n.planLimitUpgrade,
                    icon: Icons.auto_awesome_rounded,
                    expand: true,
                    onTap: upgrade,
                  ),
                  const SizedBox(height: 8),
                ],
                if (manage != null) ...<Widget>[
                  SoftPillButton(
                    key: const ValueKey('profile-subscription-manage'),
                    label: l10n.premiumManage,
                    icon: Icons.open_in_new_rounded,
                    expand: true,
                    onTap: manage,
                  ),
                  const SizedBox(height: 8),
                ] else if (liveStore != null && !manageHere) ...<Widget>[
                  _CardNote(
                    key: const ValueKey('profile-subscription-elsewhere'),
                    text: l10n.subscriptionManagedElsewhere(liveStore.wire),
                    icon: Icons.info_outline_rounded,
                  ),
                  const SizedBox(height: 12),
                ],
                if (restore != null)
                  SoftPillButton(
                    key: const ValueKey('profile-subscription-restore'),
                    label: l10n.premiumRestore,
                    icon: Icons.restore_rounded,
                    tone: SoftPillTone.neutral,
                    expand: true,
                    onTap: _restoring ? null : () => _restore(restore),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _statusText(
    AppLocalizations l10n,
    SubscriptionLine line,
    SubscriptionInfo subscription,
    String date,
  ) => switch (line) {
    SubscriptionLine.renewsOn => l10n.subscriptionRenewsOn(date),
    SubscriptionLine.endsOn => l10n.subscriptionEndsOn(date),
    SubscriptionLine.grace => l10n.subscriptionGrace(date),
    SubscriptionLine.onHold => l10n.subscriptionOnHold(
      subscription.platform.wire,
    ),
    SubscriptionLine.paused => l10n.subscriptionPaused,
    SubscriptionLine.pending => l10n.premiumPendingTitle,
    SubscriptionLine.expiredOn => l10n.subscriptionExpiredOn(date),
    SubscriptionLine.revoked => l10n.subscriptionRevoked,
    SubscriptionLine.manualUntil => l10n.subscriptionManualUntil(date),
  };
}

/// Free in the neutral fill, Premium in the accent.
class _TierPill extends StatelessWidget {
  const _TierPill({required this.premium});

  final bool premium;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return Container(
      key: ValueKey(
        premium ? 'profile-subscription-premium' : 'profile-subscription-free',
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: premium ? t.accentTint : t.softFill,
        borderRadius: BorderRadius.circular(rPill),
      ),
      child: Text(
        premium ? l10n.subscriptionTierPremium : l10n.subscriptionTierFree,
        style: AppType.ui(
          14,
          weight: FontWeight.w800,
          color: premium ? t.accentText : t.inkMuted,
        ),
      ),
    );
  }
}

/// "Testkauf": a sandbox or license-tester purchase.
class _TestPurchaseBadge extends StatelessWidget {
  const _TestPurchaseBadge();

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Container(
      key: const ValueKey('profile-subscription-test-purchase'),
      padding: const EdgeInsets.fromLTRB(8, 4, 10, 4),
      decoration: BoxDecoration(
        color: t.warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(rPill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.science_outlined, size: 14, color: t.warning),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              context.l10n.subscriptionTestPurchase,
              style: AppType.ui(12, weight: FontWeight.w700, color: t.ink),
            ),
          ),
        ],
      ),
    );
  }
}

/// A status dot and its sentence; the dot sits on the first line's centre.
class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final lineHeight = MediaQuery.textScalerOf(context).scale(13) * 1.35;
    return Row(
      key: const ValueKey('profile-subscription-status'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        ExcludeSemantics(
          child: Padding(
            padding: EdgeInsets.only(top: (lineHeight - 7) / 2, right: 7),
            child: Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
          ),
        ),
        Flexible(
          child: Text(
            text,
            style: AppType.ui(
              13,
              weight: FontWeight.w500,
              color: color,
              height: 1.35,
            ),
          ),
        ),
      ],
    );
  }
}

/// A quiet note in the card: glyph and sentence, in the card's text column.
class _CardNote extends StatelessWidget {
  const _CardNote({super.key, required this.text, required this.icon});

  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        ExcludeSemantics(child: Icon(icon, size: 17, color: t.ink2)),
        const SizedBox(width: 10),
        Expanded(
          child: Text(text, style: AppType.ui(13, color: t.ink2, height: 1.4)),
        ),
      ],
    );
  }
}

/// One usage line: the feature at the start, "used/limit" at the end; at
/// large text the value drops under the label.
class _UsageRow extends StatelessWidget {
  const _UsageRow({
    super.key,
    required this.label,
    required this.value,
    required this.valueLabel,
  });

  final String label;
  final String value;

  /// [value] for screen readers.
  final String valueLabel;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return MergeSemantics(
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 32),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 2,
            children: <Widget>[
              Text(
                label,
                style: AppType.ui(14, weight: FontWeight.w600, color: t.ink),
              ),
              Text(
                value,
                // "1/3" reads as a fraction; the label says it.
                semanticsLabel: valueLabel,
                style: AppType.ui(14, weight: FontWeight.w700, color: t.ink),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
