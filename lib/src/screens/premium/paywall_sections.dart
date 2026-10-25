import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat, NumberFormat;

import '../../config/legal_links.dart';
import '../../l10n/l10n.dart';
import '../../models/plan_status.dart';
import '../../services/billing/billing_client.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/design/design.dart';
import '../settings/settings_controls.dart' show openLegalLink;

// ---------------------------------------------------------------------------
// The sections of the Premium screen (docs/PREMIUM.md 4.3), top to bottom:
//
//   hero        eyebrow, the promise, what stays free (the IdentityCard
//               recipe: `surf`, rHero, the violet glow)
//   compare     Free vs Premium with the plan's numbers, never literals
//   benefits    the picture stays on the device, nothing is lost at the end
//   plans       two OptionCards, prices only as the store formats them
//   timeline    a trial never without its price and first charge date
//   fine print  renewal, cancellation, Terms, Privacy, restore
//
// Plus the states that replace the plans: loading, store unavailable,
// pending, already Premium, and the success view.
// ---------------------------------------------------------------------------

/// The `{store}` select value of the copy: the store this subscription runs
/// through, or this device's store.
String paywallStoreKey(BuildContext context, [SubscriptionInfo? info]) {
  final platform = info?.platform;
  if (platform == StorePlatform.apple) return 'apple';
  if (platform == StorePlatform.google) return 'google';
  return switch (Theme.of(context).platform) {
    TargetPlatform.iOS || TargetPlatform.macOS => 'apple',
    _ => 'google',
  };
}

/// [date] as the app writes dates in running text, with the year once it is
/// not this one: a renewal next October must not read as this October.
String paywallDate(BuildContext context, DateTime date) {
  final local = date.toLocal();
  if (local.year == clock.now().year) {
    return MaterialLocalizations.of(context).formatMediumDate(local);
  }
  return DateFormat.yMMMEd(context.l10n.localeName).format(local);
}

/// The first charge after [offer]'s trial, counted from now. The timeline
/// and the line above the button both read it, so their dates cannot drift.
DateTime paywallTrialChargeDate(PremiumOffer offer) =>
    clock.now().add(Duration(days: offer.trialDays ?? 0));

/// The monthly equivalent of [offer], formatted in the store's currency.
String paywallMonthlyPrice(BuildContext context, PremiumOffer offer) =>
    NumberFormat.simpleCurrency(
      locale: context.l10n.localeName,
      name: offer.currencyCode,
    ).format(offer.monthlyEquivalent);

/// The violet glow of the hero cards, anchored outside a corner.
class _Glow extends StatelessWidget {
  const _Glow({required this.color, required this.alpha});

  final Color color;
  final double alpha;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: DecoratedBox(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          colors: <Color>[
            color.withValues(alpha: alpha * context.t.glowStrength),
            color.withValues(alpha: 0),
          ],
        ),
      ),
    ),
  );
}

/// The accent disc behind a glyph, as on the onboarding plan hero.
class _AccentDisc extends StatelessWidget {
  const _AccentDisc({required this.icon, this.size = 34});

  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: t.accentTint, shape: BoxShape.circle),
        child: Icon(icon, size: size / 2, color: t.accentText),
      ),
    );
  }
}

/// Eyebrow, the promise as the screen's level-1 title, and what stays free.
class PaywallHero extends StatelessWidget {
  const PaywallHero({super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final titleStyle = AppType.display(36, color: t.ink, height: 1.06);
    // A 36 px title is large text already; past 1.6x (the onboarding
    // titles' cap) it adds height, not legibility.
    final titleScaler = MediaQuery.textScalerOf(
      context,
    ).clamp(maxScaleFactor: 1.6);
    return Container(
      key: const ValueKey('paywall-hero'),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: t.surf,
        borderRadius: BorderRadius.circular(rHero),
        border: Border.all(color: t.cardBorder),
      ),
      child: Stack(
        children: <Widget>[
          Positioned(
            top: -90,
            right: -70,
            width: 300,
            height: 260,
            child: _Glow(color: t.arcStart, alpha: 0.28),
          ),
          Positioned(
            bottom: -120,
            left: -90,
            width: 280,
            height: 240,
            child: _Glow(color: t.accentGlow, alpha: 0.5),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        l10n.premiumEyebrow,
                        semanticsLabel: l10n.premiumScreenLabel,
                        style: AppType.sectionEyebrow(t.accentText),
                      ),
                    ),
                    const SizedBox(width: 10),
                    const _AccentDisc(icon: Icons.auto_awesome_rounded),
                  ],
                ),
                const SizedBox(height: 14),
                HeadingSemantics(
                  level: 1,
                  child: LayoutBuilder(
                    builder: (context, constraints) => Text(
                      l10n.premiumTitle,
                      key: const ValueKey('paywall-title'),
                      style: titleStyle,
                      textScaler: AppType.wholeWordScaler(
                        context,
                        text: l10n.premiumTitle,
                        style: titleStyle,
                        scaler: titleScaler,
                        maxWidth: constraints.maxWidth,
                        minScaleFactor: 1,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  l10n.premiumSubtitle,
                  style: AppType.ui(14.5, color: t.ink2, height: 1.45),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Free against Premium, from the plan's `limits.free` and `limits.premium`
/// (the assumed defaults until the server answered). Each row is one
/// semantics node that names both columns.
class PaywallCompareCard extends StatelessWidget {
  const PaywallCompareCard({
    super.key,
    required this.free,
    required this.premium,
  });

  final TierLimits free;
  final TierLimits premium;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final rows = <(String, int?, int?)>[
      (l10n.premiumRowCoach, free.coachDaily, premium.coachDaily),
      (
        l10n.premiumRowMealAnalysis,
        free.mealAnalysisDaily,
        premium.mealAnalysisDaily,
      ),
      (
        l10n.premiumRowRecipeImport,
        free.recipeImportDaily,
        premium.recipeImportDaily,
      ),
    ];
    return Container(
      key: const ValueKey('paywall-compare'),
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 8),
      decoration: BoxDecoration(
        color: t.surf,
        borderRadius: BorderRadius.circular(rCard),
        border: Border.all(color: t.line),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final scaler = MediaQuery.textScalerOf(context);
          // The Premium column carries the captioned pill, so it is wider.
          final columns = (
            free: scaler.scale(60).clamp(60.0, 120.0),
            premium: scaler.scale(84).clamp(84.0, 160.0),
          );
          // Two value columns leave the label too little room at large text
          // on a narrow phone: the label then takes its own line.
          final stacked =
              constraints.maxWidth - columns.free - columns.premium <
              scaler.scale(110);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              HeadingSemantics(
                level: 2,
                child: Text(
                  l10n.premiumCompareTitle,
                  style: AppType.display(
                    18,
                    weight: FontWeight.w700,
                    color: t.ink,
                  ),
                ),
              ),
              const SizedBox(height: 14),
              ExcludeSemantics(
                child: _CompareLine(
                  stacked: stacked,
                  columns: columns,
                  label: null,
                  free: Text(
                    l10n.premiumCompareFree,
                    textAlign: TextAlign.center,
                    style: AppType.sectionEyebrow(t.inkMuted),
                  ),
                  premium: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: t.accentTint,
                      borderRadius: BorderRadius.circular(rPill),
                    ),
                    child: Text(
                      l10n.premiumComparePremium,
                      textAlign: TextAlign.center,
                      style: AppType.sectionEyebrow(t.accentText),
                    ),
                  ),
                ),
              ),
              for (final (label, freeValue, premiumValue) in rows) ...<Widget>[
                Divider(height: 1, thickness: 1, color: t.line),
                _CompareRow(
                  stacked: stacked,
                  columns: columns,
                  label: label,
                  freeText: '$freeValue',
                  premiumText: '$premiumValue',
                ),
              ],
              Divider(height: 1, thickness: 1, color: t.line),
              _CompareRow(
                stacked: stacked,
                columns: columns,
                label: l10n.premiumRowRecipePicture,
                freeIncluded: free.recipePicture,
                premiumIncluded: premium.recipePicture,
              ),
            ],
          );
        },
      ),
    );
  }
}

/// The widths of the Free and the Premium column.
typedef _Columns = ({double free, double premium});

/// One line of the table: the label and the two value cells, side by side
/// or (stacked) the label above two equal halves.
class _CompareLine extends StatelessWidget {
  const _CompareLine({
    required this.stacked,
    required this.columns,
    required this.label,
    required this.free,
    required this.premium,
  });

  final bool stacked;
  final _Columns columns;
  final Widget? label;
  final Widget free;
  final Widget premium;

  @override
  Widget build(BuildContext context) {
    if (stacked) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (label != null) ...<Widget>[label!, const SizedBox(height: 8)],
          Row(
            children: <Widget>[
              Expanded(child: Center(child: free)),
              Expanded(child: Center(child: premium)),
            ],
          ),
        ],
      );
    }
    return Row(
      children: <Widget>[
        Expanded(child: label ?? const SizedBox.shrink()),
        SizedBox(
          width: columns.free,
          child: Center(child: free),
        ),
        SizedBox(
          width: columns.premium,
          child: Center(child: premium),
        ),
      ],
    );
  }
}

class _CompareRow extends StatelessWidget {
  const _CompareRow({
    required this.stacked,
    required this.columns,
    required this.label,
    this.freeText,
    this.premiumText,
    this.freeIncluded,
    this.premiumIncluded,
  });

  final bool stacked;
  final _Columns columns;
  final String label;

  /// A daily limit, or null for the yes/no row ([freeIncluded]).
  final String? freeText;
  final String? premiumText;
  final bool? freeIncluded;
  final bool? premiumIncluded;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    String spoken(String? text, bool? included) =>
        text ??
        (included == true ? l10n.premiumIncluded : l10n.premiumNotIncluded);
    Widget cell(String? text, bool? included, {required bool premium}) {
      if (text != null) {
        return Text(
          text,
          maxLines: 1,
          style: AppType.display(
            premium ? 22 : 19,
            weight: premium ? FontWeight.w800 : FontWeight.w700,
            color: premium ? t.accentText : t.inkMuted,
          ),
        );
      }
      return included == true
          ? Icon(
              Icons.check_circle_rounded,
              size: 22,
              color: premium ? t.accentText : t.inkMuted,
            )
          : Icon(Icons.remove_rounded, size: 22, color: t.ink3);
    }

    return Semantics(
      container: true,
      excludeSemantics: true,
      label:
          '$label: ${l10n.premiumCompareFree} ${spoken(freeText, freeIncluded)}, '
          '${l10n.premiumComparePremium} '
          '${spoken(premiumText, premiumIncluded)}',
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 13),
        child: _CompareLine(
          stacked: stacked,
          columns: columns,
          label: Text(
            label,
            style: AppType.ui(
              14,
              weight: FontWeight.w600,
              color: t.ink,
              height: 1.3,
            ),
          ),
          free: cell(freeText, freeIncluded, premium: false),
          premium: cell(premiumText, premiumIncluded, premium: true),
        ),
      ),
    );
  }
}

/// A legacy account keeps its current limits for now (1.1); the note names
/// them and the end date once the operator set one.
class PaywallLegacyNote extends StatelessWidget {
  const PaywallLegacyNote({super.key, required this.plan});

  final PlanStatus plan;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final current = plan.current;
    final until = plan.legacy?.until;
    final text = until == null
        ? l10n.premiumLegacyNote(
            current.coachDaily,
            current.mealAnalysisDaily,
            current.recipeImportDaily,
          )
        : l10n.premiumLegacyNoteUntil(
            paywallDate(context, until),
            current.coachDaily,
            current.mealAnalysisDaily,
            current.recipeImportDaily,
          );
    return SignalNote(
      text,
      key: const ValueKey('paywall-legacy-note'),
      icon: Icons.history_rounded,
      boxed: true,
    );
  }
}

/// The two reassurance lines under the table.
class PaywallBenefits extends StatelessWidget {
  const PaywallBenefits({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _Benefit(icon: Icons.photo_outlined, text: l10n.premiumBenefitPicture),
        const SizedBox(height: 12),
        _Benefit(
          icon: Icons.bookmark_added_outlined,
          text: l10n.premiumBenefitKeep,
        ),
      ],
    );
  }
}

class _Benefit extends StatelessWidget {
  const _Benefit({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _AccentDisc(icon: icon, size: 32),
        const SizedBox(width: 12),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              text,
              style: AppType.ui(14, color: t.ink, height: 1.45),
            ),
          ),
        ),
      ],
    );
  }
}

/// One plan as an [OptionCard]: the billed amount large, the monthly
/// equivalent and the savings secondary, the trial when the store offers
/// one to this account.
class PaywallPlanCard extends StatelessWidget {
  const PaywallPlanCard({
    super.key,
    required this.offer,
    required this.selected,
    required this.onTap,
    this.savingsPercent,
  });

  final PremiumOffer offer;
  final bool selected;
  final VoidCallback onTap;

  /// The yearly plan's saving over twelve monthly payments.
  final int? savingsPercent;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final yearly = offer.period == PremiumPeriod.yearly;
    final price = yearly
        ? l10n.premiumPlanYearlyPrice(offer.priceLabel)
        : l10n.premiumPlanMonthlyPrice(offer.priceLabel);
    final priceScaler = MediaQuery.textScalerOf(
      context,
    ).clamp(maxScaleFactor: 1.6);
    return OptionCard(
      actionKey: ValueKey('paywall-plan-${offer.period.name}'),
      selected: selected,
      onTap: onTap,
      title: yearly ? l10n.premiumPlanYearly : l10n.premiumPlanMonthly,
      badge: savingsPercent == null
          ? null
          : l10n.premiumPlanSavings(savingsPercent!),
      detail: Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          Text(
            price,
            key: ValueKey('paywall-price-${offer.period.name}'),
            textScaler: priceScaler,
            style: AppType.display(22, color: t.ink, height: 1.15),
          ),
          if (offer.hasTrial)
            Container(
              key: const ValueKey('paywall-trial-badge'),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              decoration: BoxDecoration(
                color: t.accentTint,
                borderRadius: BorderRadius.circular(rPill),
              ),
              child: Text(
                l10n.premiumPlanTrialBadge(offer.trialDays!),
                style: AppType.ui(
                  12.5,
                  weight: FontWeight.w700,
                  color: t.accentText,
                ),
              ),
            ),
        ],
      ),
      subtitle: yearly
          ? l10n.premiumPlanPerMonth(paywallMonthlyPrice(context, offer))
          : null,
    );
  }
}

/// The trial in two steps: unlocked today, the first charge with its date
/// and price (a trial is never shown without them, 1.2).
class PaywallTrialTimeline extends StatelessWidget {
  const PaywallTrialTimeline({super.key, required this.offer});

  final PremiumOffer offer;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final chargeOn = paywallTrialChargeDate(offer);
    Widget step(String text, {required bool now, required Key key}) => Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        ExcludeSemantics(
          child: Container(
            width: 22,
            height: 22,
            margin: const EdgeInsets.only(top: 1),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: now ? t.selectedFill : Colors.transparent,
              border: Border.all(
                color: now ? t.selectedFill : t.ink3,
                width: kSelectionEdge,
              ),
            ),
            child: now
                ? Icon(Icons.check_rounded, size: 14, color: t.onSelected)
                : null,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            text,
            key: key,
            style: AppType.ui(
              14,
              weight: now ? FontWeight.w700 : FontWeight.w500,
              color: t.ink,
              height: 1.4,
            ),
          ),
        ),
      ],
    );
    return Container(
      key: const ValueKey('paywall-trial-timeline'),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      decoration: BoxDecoration(
        color: t.surfWell,
        borderRadius: BorderRadius.circular(rTile),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          step(
            l10n.premiumTrialToday,
            now: true,
            key: const ValueKey('paywall-trial-today'),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 10),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Container(width: 2, height: 14, color: t.lineStrong),
            ),
          ),
          step(
            l10n.premiumTrialCharge(
              paywallDate(context, chargeOn),
              offer.priceLabel,
            ),
            now: false,
            key: const ValueKey('paywall-trial-charge'),
          ),
        ],
      ),
    );
  }
}

/// What the purchase button charges, pinned right above it: with a trial the
/// first charge's date and price, otherwise the billed amount. The button
/// never shows without it (1.2), wherever the plans have scrolled to.
class PaywallChargeLine extends StatelessWidget {
  const PaywallChargeLine({super.key, required this.offer});

  final PremiumOffer offer;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final yearly = offer.period == PremiumPeriod.yearly;
    final text = yearly && offer.hasTrial
        ? l10n.premiumTrialCharge(
            paywallDate(context, paywallTrialChargeDate(offer)),
            offer.priceLabel,
          )
        : yearly
        ? l10n.premiumPlanYearlyPrice(offer.priceLabel)
        : l10n.premiumPlanMonthlyPrice(offer.priceLabel);
    return Text(
      text,
      key: const ValueKey('paywall-foot-charge'),
      textAlign: TextAlign.center,
      style: AppType.ui(13.5, color: context.t.ink2, height: 1.35),
    );
  }
}

/// Renewal and cancellation for the selected plan, the legal links and the
/// restore action.
class PaywallFinePrint extends StatelessWidget {
  const PaywallFinePrint({
    super.key,
    required this.selected,
    required this.onRestore,
    required this.restoring,
  });

  /// The plan the button buys; null hides the renewal sentences (no store).
  final PremiumOffer? selected;

  /// Null hides "Käufe wiederherstellen" (no store to ask).
  final VoidCallback? onRestore;
  final bool restoring;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final offer = selected;
    final style = AppType.ui(12.5, color: t.ink2, height: 1.5);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (offer != null)
          Text(
            '${offer.period == PremiumPeriod.yearly ? l10n.premiumRenewalYearly(offer.priceLabel) : l10n.premiumRenewalMonthly(offer.priceLabel)} '
            '${l10n.premiumCancelAnytime(paywallStoreKey(context))}',
            key: const ValueKey('paywall-renewal'),
            textAlign: TextAlign.center,
            style: style,
          ),
        const SizedBox(height: 6),
        Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            _FinePrintLink(
              key: const ValueKey('paywall-terms'),
              label: l10n.premiumTermsLink,
              onTap: () => openLegalLink(context, kTermsUrl),
            ),
            _FinePrintLink(
              key: const ValueKey('paywall-privacy'),
              label: l10n.premiumPrivacyLink,
              onTap: () => openLegalLink(context, kPrivacyUrl),
            ),
            if (onRestore != null)
              _FinePrintLink(
                key: const ValueKey('paywall-restore'),
                label: l10n.premiumRestore,
                onTap: restoring ? null : onRestore,
                busy: restoring,
              ),
          ],
        ),
      ],
    );
  }
}

class _FinePrintLink extends StatelessWidget {
  const _FinePrintLink({
    super.key,
    required this.label,
    required this.onTap,
    this.busy = false,
  });

  final String label;
  final VoidCallback? onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    // Small text, the full 48 px target of every control.
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        foregroundColor: t.accentText,
        disabledForegroundColor: t.inkDisabled,
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (busy) ...<Widget>[
            const AppSpinner(size: 14, strokeWidth: 2),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: AppType.ui(13, weight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

/// While the store answers: the space of the plans with one calm line.
class PaywallLoadingPlans extends StatelessWidget {
  const PaywallLoadingPlans({super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Container(
      key: const ValueKey('paywall-loading'),
      constraints: const BoxConstraints(minHeight: 148),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: t.surf,
        borderRadius: BorderRadius.circular(rCard),
        border: Border.all(color: t.line),
      ),
      child: Semantics(
        liveRegion: true,
        child: Wrap(
          spacing: 12,
          runSpacing: 8,
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            const ExcludeSemantics(child: AppSpinner(size: 18, strokeWidth: 2)),
            Text(
              context.l10n.premiumLoadingOffers,
              style: AppType.ui(14, color: t.ink2),
            ),
          ],
        ),
      ),
    );
  }
}

/// No store on this device right now: say so calmly and offer a retry; the
/// table and the Free choice stay.
class PaywallStoreUnavailable extends StatelessWidget {
  const PaywallStoreUnavailable({super.key, required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Semantics(
      key: const ValueKey('paywall-store-unavailable'),
      liveRegion: true,
      child: CalmState(
        card: true,
        icon: Icons.storefront_outlined,
        title: l10n.premiumStoreUnavailableTitle,
        text: l10n.premiumStoreUnavailableBody,
        actions: <Widget>[
          SoftPillButton(
            key: const ValueKey('paywall-retry'),
            label: l10n.premiumRetry,
            icon: Icons.refresh_rounded,
            onTap: onRetry,
          ),
        ],
      ),
    );
  }
}

/// The store reports a pending payment; nothing is granted yet.
class PaywallPendingNote extends StatelessWidget {
  const PaywallPendingNote({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Semantics(
      key: const ValueKey('paywall-pending'),
      liveRegion: true,
      child: CalmState(
        card: true,
        icon: Icons.hourglass_top_rounded,
        title: l10n.premiumPendingTitle,
        text: l10n.premiumPendingBody(paywallStoreKey(context)),
      ),
    );
  }
}

/// The account already has Premium, or a store subscription that is still
/// live without it (on hold, paused, pending): its status and the store's
/// management instead of the plan choice, never a second purchase.
class PaywallStatusCard extends StatelessWidget {
  const PaywallStatusCard({
    super.key,
    required this.plan,
    required this.onManage,
  });

  final PlanStatus plan;
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final info = plan.subscription;
    final premium = plan.isPremium;
    // Without Premium the status itself is the heading ("Zahlung
    // fehlgeschlagen …"); "Du hast Premium" would be false.
    final title = premium || info == null
        ? l10n.premiumAlreadyActiveTitle
        : _statusLine(context, info);
    final titleStyle = AppType.display(22, color: t.ink, height: 1.15);
    final details = <String>[
      if (premium && info != null) _statusLine(context, info),
      if (info != null && info.isStorePurchase)
        l10n.subscriptionVia(paywallStoreKey(context, info)),
    ];
    return Container(
      key: const ValueKey('paywall-premium-status'),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: t.surf,
        borderRadius: BorderRadius.circular(rCard),
        border: Border.all(color: t.cardBorder),
      ),
      child: Stack(
        children: <Widget>[
          Positioned(
            top: -100,
            left: -80,
            width: 280,
            height: 240,
            child: _Glow(color: t.arcStart, alpha: 0.2),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _AccentDisc(
                  icon: premium
                      ? Icons.verified_rounded
                      : Icons.info_outline_rounded,
                  size: 40,
                ),
                const SizedBox(height: 14),
                Semantics(
                  liveRegion: true,
                  child: HeadingSemantics(
                    level: 2,
                    // A status sentence as the heading: whole words only
                    // ("fehlgeschlagen" at 2x on 320 px), the hero's cap.
                    child: LayoutBuilder(
                      builder: (context, constraints) => Text(
                        title,
                        style: titleStyle,
                        textScaler: AppType.wholeWordScaler(
                          context,
                          text: title,
                          style: titleStyle,
                          scaler: MediaQuery.textScalerOf(
                            context,
                          ).clamp(maxScaleFactor: 1.6),
                          maxWidth: constraints.maxWidth,
                          minScaleFactor: 1,
                        ),
                      ),
                    ),
                  ),
                ),
                for (final line in details) ...<Widget>[
                  const SizedBox(height: 6),
                  Text(line, style: AppType.ui(14, color: t.ink2, height: 1.4)),
                ],
                if (info != null && info.isStorePurchase) ...<Widget>[
                  const SizedBox(height: 16),
                  SoftPillButton(
                    key: const ValueKey('paywall-manage'),
                    label: l10n.premiumManage,
                    icon: Icons.open_in_new_rounded,
                    onTap: onManage,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _statusLine(BuildContext context, SubscriptionInfo info) {
    final l10n = context.l10n;
    final date = paywallDate(context, info.expiresAt);
    return switch (info.lineAt()) {
      SubscriptionLine.renewsOn => l10n.subscriptionRenewsOn(date),
      SubscriptionLine.endsOn => l10n.subscriptionEndsOn(date),
      SubscriptionLine.grace => l10n.subscriptionGrace(date),
      SubscriptionLine.onHold => l10n.subscriptionOnHold(
        paywallStoreKey(context, info),
      ),
      SubscriptionLine.paused => l10n.subscriptionPaused,
      SubscriptionLine.pending => l10n.premiumPendingTitle,
      SubscriptionLine.expiredOn => l10n.subscriptionExpiredOn(date),
      SubscriptionLine.revoked => l10n.subscriptionRevoked,
      SubscriptionLine.manualUntil => l10n.subscriptionManualUntil(date),
    };
  }
}

/// "Willkommen bei Premium": the verified purchase, announced once.
class PaywallSuccessView extends StatelessWidget {
  const PaywallSuccessView({super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          key: const ValueKey('paywall-success'),
          children: <Widget>[
            SizedBox(
              width: 220,
              height: 160,
              child: Stack(
                alignment: Alignment.center,
                children: <Widget>[
                  Positioned.fill(child: _Glow(color: t.arcStart, alpha: 0.4)),
                  const _AccentDisc(icon: Icons.auto_awesome_rounded, size: 76),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Semantics(
              liveRegion: true,
              child: HeadingSemantics(
                level: 1,
                child: Text(
                  l10n.premiumSuccessTitle,
                  textAlign: TextAlign.center,
                  textScaler: MediaQuery.textScalerOf(
                    context,
                  ).clamp(maxScaleFactor: 1.6),
                  style: AppType.display(32, color: t.ink, height: 1.1),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              l10n.premiumSuccessBody,
              textAlign: TextAlign.center,
              style: AppType.ui(15, color: t.ink2, height: 1.45),
            ),
          ],
        ),
      ),
    );
  }
}
