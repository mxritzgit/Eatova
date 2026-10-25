import 'package:clock/clock.dart';
import 'package:flutter/material.dart';

import '../../app/subscription.dart';
import '../../l10n/l10n.dart';
import '../../models/plan_limit_hit.dart';
import '../../models/plan_status.dart';
import '../../services/meal_analyzer.dart';
import '../../theme/app_tokens.dart';
import '../design/design.dart';

// At a limit (docs/PREMIUM.md 1.2, 4.5): an inline notice, never a sheet,
// that names what still works and when the quota opens again. "Mehr mit
// Premium" shows at most once per feature and UTC day. Burst, IP and global
// 429s carry no PlanLimitHit and keep their own texts.

/// [at] on the phone's clock, in its 12/24-hour setting (the German copy
/// adds "Uhr").
String planLimitClockLabel(BuildContext context, DateTime at) =>
    MaterialLocalizations.of(context).formatTimeOfDay(
      TimeOfDay.fromDateTime(at.toLocal()),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );

/// What is used up, what still works and when it opens again. With
/// [upgrade] also the Premium allowance: the `*Premium` texts appear only
/// together with the "Mehr mit Premium" action.
String planLimitMessage(
  AppLocalizations l10n,
  PlanLimitHit hit,
  String Function(DateTime at) clockLabel, {
  bool upgrade = false,
}) {
  final time = clockLabel(hit.resetAt);
  final premium = upgrade ? hit.premiumLimit : null;
  return switch (hit.feature) {
    PlanFeature.mealAnalysis =>
      premium == null
          ? l10n.planLimitMeal(hit.limit, time)
          : l10n.planLimitMealPremium(hit.limit, time, premium),
    PlanFeature.recipeImport =>
      premium == null
          ? l10n.planLimitImport(hit.limit, time)
          : l10n.planLimitImportPremium(hit.limit, time, premium),
    PlanFeature.coach =>
      premium == null
          ? l10n.planLimitCoach(hit.limit, time)
          : l10n.planLimitCoachPremium(hit.limit, time, premium),
  };
}

/// [hit] while its quota still holds, null once [PlanLimitHit.resetAt]
/// passed (a new attempt may go out then).
PlanLimitHit? planLimitInForce(PlanLimitHit? hit) =>
    hit != null && hit.resetAt.isAfter(clock.now()) ? hit : null;

/// [hit] while it still blocks a new attempt: in force, and [account] has
/// not moved to Premium with [PlanLimitHit.feature] left since the denial
/// arrived, when its [SubscriptionController.tierRevision] was [deniedAt].
/// A Premium plan the denial already contradicts (one that ended while the
/// app was open) lifts nothing. An upgrade from the notice lifts it at once;
/// listen to [account] to see that.
PlanLimitHit? planLimitHolding(
  PlanLimitHit? hit,
  SubscriptionController? account, {
  required int? deniedAt,
}) {
  final inForce = planLimitInForce(hit);
  if (inForce == null || account == null) return inForce;
  final plan = account.plan;
  final lifted =
      plan.isPremium &&
      plan.tier != inForce.tier &&
      account.tierRevision != deniedAt &&
      plan.remaining(inForce.feature) > 0;
  return lifted ? null : inForce;
}

/// Whether a notice may offer Premium: the offer was taken for this hit
/// ([notePlanLimitHit]) and [account] does not have Premium (by now).
bool planUpsellShows(bool taken, SubscriptionController? account) =>
    taken && !(account?.isPremium ?? false);

/// The tier quota behind an `analyze-meal` [error] while it holds; null for
/// every other error, the burst, IP and global 429s included.
PlanLimitHit? mealPlanLimitOf(Object? error) =>
    error is MealAnalysisRateLimited ? planLimitInForce(error.planLimit) : null;

/// The signed-in account a request starts for. Hand it back with the answer
/// ([notePlanLimitHit], [noteMealAnalysisUsage]); null outside the app shell.
SubscriptionController? planAccountOf(BuildContext context) =>
    SubscriptionScope.controllerOf(context);

/// [account] while it is still the signed-in one: an answer that lands
/// after an account switch counts for nobody.
SubscriptionController? _stillSignedIn(
  BuildContext context,
  SubscriptionController? account,
) => account != null && identical(planAccountOf(context), account)
    ? account
    : null;

/// Records [hit] with the [account] that asked and decides whether its
/// notice offers Premium. Call it once when the denial arrives, never from
/// build: the account allows the offer once per feature and UTC day. False
/// outside the app shell and for a hit without a higher Premium limit.
bool notePlanLimitHit(
  BuildContext context,
  SubscriptionController? account,
  PlanLimitHit hit,
) {
  final controller = _stillSignedIn(context, account);
  if (controller == null) return false;
  controller.noteLimitHit(hit);
  return hit.offersPremium && controller.takeUpsell(hit.feature);
}

/// Hands the usage a successful `analyze-meal` [answer] reported to the
/// [account] that asked, so [PlanRemainingAnalysesHint] follows without a
/// server read.
void noteMealAnalysisUsage(
  BuildContext context,
  SubscriptionController? account,
  Object answer,
) {
  final usage = mealAnalysisUsageOf(answer);
  if (usage == null) return;
  _stillSignedIn(
    context,
    account,
  )?.noteUsage(PlanFeature.mealAnalysis, usage.used);
}

/// The Premium screen, opened from the limit notice of [feature].
Future<void> openPremiumAtLimit(BuildContext context, PlanFeature feature) =>
    openPremium(
      context,
      source: switch (feature) {
        PlanFeature.coach => PremiumSource.coach,
        PlanFeature.mealAnalysis => PremiumSource.mealAnalysis,
        PlanFeature.recipeImport => PremiumSource.recipeImport,
      },
    );

/// A tier-quota denial in place of a failure: title, [planLimitMessage],
/// "Mehr mit Premium" when [onUpgrade] is given and [hit] offers Premium,
/// then [secondary], the surface's own way on. Carries no card; the surface
/// wraps it.
class PlanLimitNotice extends StatelessWidget {
  const PlanLimitNotice({
    super.key,
    required this.hit,
    this.onUpgrade,
    this.secondary,
  });

  final PlanLimitHit hit;

  /// Null: the wait text only (Premium, or the offer was made today).
  final VoidCallback? onUpgrade;
  final Widget? secondary;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final upgrade = onUpgrade != null && hit.offersPremium;
    final secondary = this.secondary;
    return Column(
      key: const ValueKey('plan-limit-notice'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.schedule_rounded, color: t.accentText, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                l10n.planLimitTitle,
                style: AppType.ui(14, weight: FontWeight.w700, color: t.ink),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Semantics(
          liveRegion: true,
          child: Text(
            planLimitMessage(
              l10n,
              hit,
              (at) => planLimitClockLabel(context, at),
              upgrade: upgrade,
            ),
            key: const ValueKey('plan-limit-message'),
            style: AppType.ui(13, color: t.ink2, height: 1.4),
          ),
        ),
        if (upgrade || secondary != null) const SizedBox(height: 14),
        if (upgrade)
          PrimaryActionButton(
            key: const ValueKey('plan-limit-upgrade'),
            label: l10n.planLimitUpgrade,
            icon: Icons.auto_awesome_rounded,
            onTap: onUpgrade,
            height: 48,
          ),
        if (upgrade && secondary != null) const SizedBox(height: 8),
        ?secondary,
      ],
    );
  }
}

/// "Heute noch n KI-Analysen" at the scan and Describe entries when
/// [showFrom] or fewer analyses are left today (1.2). Nothing while the plan
/// is still assumed or outside the app shell.
class PlanRemainingAnalysesHint extends StatelessWidget {
  const PlanRemainingAnalysesHint({
    super.key,
    this.padding = EdgeInsets.zero,
    this.alignment = MainAxisAlignment.start,
    this.capsule = false,
  });

  static const int showFrom = 2;

  /// Around the line, only while it shows.
  final EdgeInsetsGeometry padding;
  final MainAxisAlignment alignment;

  /// On its own soft capsule, for a line above scrolling content (the Food
  /// tab's dock).
  final bool capsule;

  @override
  Widget build(BuildContext context) {
    final controller = SubscriptionScope.controllerOf(context);
    if (controller == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final plan = controller.plan;
        final left = plan.remaining(PlanFeature.mealAnalysis);
        if (plan.assumed || left > showFrom) return const SizedBox.shrink();
        final t = context.t;
        Widget line = Row(
          key: const ValueKey('plan-remaining-analyses'),
          mainAxisSize: capsule ? MainAxisSize.min : MainAxisSize.max,
          mainAxisAlignment: alignment,
          children: [
            Icon(Icons.auto_awesome_rounded, size: 15, color: t.accentText),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                context.l10n.planRemainingAnalyses(left),
                style: AppType.ui(12.5, weight: FontWeight.w600, color: t.ink2),
              ),
            ),
          ],
        );
        if (capsule) {
          line = Row(
            mainAxisAlignment: alignment,
            children: [
              Flexible(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: t.surfRaised,
                    borderRadius: BorderRadius.circular(rPill),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 6, 12, 6),
                    child: line,
                  ),
                ),
              ),
            ],
          );
        }
        return Padding(padding: padding, child: line);
      },
    );
  }
}
