import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../app/subscription.dart' show PurchaseState, SubscriptionController;
import '../../l10n/l10n.dart';
import '../../models/plan_status.dart';
import '../../theme/app_tokens.dart';
import '../common/app_snack.dart';
import '../common/motion.dart';
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
/// Depth and light (2026-10-25): one lit surface on its own shadow, no rim
/// and no divider. The tier is a word with the lit dot when Premium is on;
/// today's use reads as three meters that fill once on first sight. One
/// action leads (lit "Mehr mit Premium" on Free, the tonal "Abo verwalten"
/// for a live store subscription); restore stays a quiet capsule under it.
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
    // Bought on the other platform: only a note, managed there.
    final elsewhere = manageHere ? null : liveStore;
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

    return LitSurface(
      key: const ValueKey('profile-subscription-card'),
      radius: rCard,
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Wrap(
            spacing: 10,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              _TierMark(premium: plan.isPremium),
              if (subscription?.isTestPurchase ?? false)
                const _TestPurchaseBadge(),
            ],
          ),
          if (details.isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              details.join(' · '),
              key: const ValueKey('profile-subscription-details'),
              style: AppType.ui(
                13.5,
                weight: FontWeight.w600,
                color: t.inkMuted,
                height: 1.35,
              ),
            ),
          ],
          if (status != null) ...<Widget>[
            const SizedBox(height: 3),
            _StatusLine(text: status, color: statusColor),
          ],
          const SizedBox(height: 22),
          Text(
            l10n.subscriptionUsageTitle.toUpperCase(),
            semanticsLabel: l10n.subscriptionUsageTitle,
            style: AppType.sectionEyebrow(t.ink3, size: 11),
          ),
          const SizedBox(height: 12),
          for (final (index, (feature, label)) in <(PlanFeature, String)>[
            (PlanFeature.coach, l10n.subscriptionUsageCoach),
            (PlanFeature.mealAnalysis, l10n.subscriptionUsageAnalyses),
            (PlanFeature.recipeImport, l10n.subscriptionUsageImports),
          ].indexed) ...<Widget>[
            if (index > 0) const SizedBox(height: 14),
            _UsageRow(
              key: ValueKey('profile-subscription-usage-${feature.wire}'),
              index: index,
              label: label,
              used: plan.usedToday(feature, now),
              limit: plan.limitFor(feature),
              premium: plan.isPremium,
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
          const SizedBox(height: 22),
          if (legacyNote != null) ...<Widget>[
            _CardNote(
              key: const ValueKey('profile-subscription-legacy'),
              text: legacyNote,
              icon: Icons.history_rounded,
            ),
            const SizedBox(height: 16),
          ],
          if (upgrade != null) ...<Widget>[
            Text(
              l10n.subscriptionFreeBody(
                plan.premium.coachDaily,
                plan.premium.mealAnalysisDaily,
              ),
              style: AppType.ui(14, color: t.ink2, height: 1.45),
            ),
            const SizedBox(height: 12),
            PrimaryActionButton(
              key: const ValueKey('profile-subscription-upgrade'),
              label: l10n.planLimitUpgrade,
              icon: Icons.arrow_forward_rounded,
              height: 50,
              onTap: upgrade,
            ),
          ] else if (manage != null)
            SoftPillButton(
              key: const ValueKey('profile-subscription-manage'),
              label: l10n.premiumManage,
              icon: Icons.open_in_new_rounded,
              expand: true,
              onTap: manage,
            )
          else if (elsewhere != null)
            _CardNote(
              key: const ValueKey('profile-subscription-elsewhere'),
              text: l10n.subscriptionManagedElsewhere(elsewhere.wire),
              icon: Icons.info_outline_rounded,
            ),
          if (restore != null) ...<Widget>[
            if (upgrade != null || manage != null || elsewhere != null)
              const SizedBox(height: 8),
            // Restoring is for the few who bought elsewhere: visibly second,
            // a capsule only under a finger or keyboard focus.
            Center(
              child: SoftPillButton(
                key: const ValueKey('profile-subscription-restore'),
                label: l10n.premiumRestore,
                icon: Icons.restore_rounded,
                tone: SoftPillTone.quiet,
                onTap: _restoring ? null : () => _restore(restore),
              ),
            ),
          ],
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

/// The tier as a word: "Premium" with the lit dot, "Free" with an unlit
/// one. Carries the tier key the Profile tests read.
class _TierMark extends StatelessWidget {
  const _TierMark({required this.premium});

  final bool premium;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return Row(
      key: ValueKey(
        premium ? 'profile-subscription-premium' : 'profile-subscription-free',
      ),
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        LitDot(lit: premium, size: 9),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            premium ? l10n.subscriptionTierPremium : l10n.subscriptionTierFree,
            style: AppType.display(28, color: t.ink, height: 1.1),
          ),
        ),
      ],
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

/// The status sentence in its state's colour. No dot of its own: the tier's
/// lit dot above already marks "on", a second one only repeated it.
class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Row(
    key: const ValueKey('profile-subscription-status'),
    children: <Widget>[
      Flexible(
        child: Text(
          text,
          style: AppType.ui(
            13.5,
            weight: FontWeight.w600,
            color: color,
            height: 1.35,
          ),
        ),
      ),
    ],
  );
}

/// A quiet note in the card: glyph and sentence on the card itself, no box,
/// in the card's text column.
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

/// One usage line: the feature at the start, "used/limit" in tabular
/// figures at the end (at large text the value drops under the label), and
/// a meter under both. The meter fills from empty on first sight, one row
/// after the other, and turns to `warning` once the day's limit is used up.
/// It is decoration; the value's label carries the numbers.
class _UsageRow extends StatelessWidget {
  const _UsageRow({
    super.key,
    required this.index,
    required this.label,
    required this.used,
    required this.limit,
    required this.premium,
    required this.value,
    required this.valueLabel,
  });

  /// Position in the card, for the fill's stagger.
  final int index;
  final String label;
  final int used;
  final int limit;
  final bool premium;
  final String value;

  /// [value] for screen readers.
  final String valueLabel;

  static const Duration _fill = Duration(milliseconds: 520);
  static const Duration _stagger = Duration(milliseconds: 80);

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final share = limit <= 0 ? 0.0 : (used / limit).clamp(0.0, 1.0);
    final full = limit > 0 && used >= limit;
    final wait = _stagger * index;
    final total = wait + _fill;
    return MergeSemantics(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Wrap(
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
                style: AppType.display(
                  15,
                  weight: FontWeight.w700,
                  color: t.ink,
                  letterSpacing: 0,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ExcludeSemantics(
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: share),
              duration: motionDuration(context, total),
              curve: Interval(
                wait.inMicroseconds / total.inMicroseconds,
                1,
                curve: kSpringSettle,
              ),
              builder: (context, fill, _) => SizedBox(
                height: 6,
                child: CustomPaint(
                  painter: _MeterPainter(
                    track: t.arcTrack,
                    fill: full
                        ? t.warning
                        : premium
                        ? t.accentFill
                        : t.progressAccent,
                    share: fill,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A 6 px meter: the track, and the fill clipped to it, so the spring's
/// small overshoot never spills past the end.
class _MeterPainter extends CustomPainter {
  const _MeterPainter({
    required this.track,
    required this.fill,
    required this.share,
  });

  final Color track;
  final Color fill;
  final double share;

  @override
  void paint(Canvas canvas, Size size) {
    final radius = Radius.circular(size.height / 2);
    final whole = RRect.fromRectAndRadius(Offset.zero & size, radius);
    canvas.drawRRect(whole, Paint()..color = track);
    if (share <= 0) return;
    final end = size.width * share.clamp(0.0, 1.0);
    canvas
      ..save()
      ..clipRRect(whole)
      ..drawRRect(
        RRect.fromRectAndRadius(
          // A started meter shows at least its round cap.
          Rect.fromLTWH(
            0,
            0,
            end < size.height ? size.height : end,
            size.height,
          ),
          radius,
        ),
        Paint()..color = fill,
      )
      ..restore();
  }

  @override
  bool shouldRepaint(_MeterPainter old) =>
      old.share != share || old.fill != fill || old.track != track;
}
