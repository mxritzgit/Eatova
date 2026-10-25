import 'dart:async';
import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart' show DateFormat, NumberFormat;

import '../../config/legal_links.dart';
import '../../l10n/l10n.dart';
import '../../models/plan_status.dart';
import '../../services/billing/billing_client.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/common/lively.dart';
import '../../widgets/common/motion.dart';
import '../../widgets/design/design.dart';
import '../settings/settings_controls.dart' show openLegalLink;

// ---------------------------------------------------------------------------
// The sections of the Premium screen (docs/PREMIUM.md 4.3), top to bottom.
//
// Depth and light (polish 2026-10-25): no hairlines, no glow blobs. The page
// itself carries the words; only the surfaces the decision rests on float,
// lit from above with their own shadow:
//
//   top bar     the lit dot and the eyebrow, the close button (pinned)
//   hero        the promise as the screen's level-1 title, on the page
//   ledger      Free against Premium: labels and Free numbers flat on the
//               page, the Premium column one lit pillar whose numbers count
//               up from the Free ones
//   footnotes   the picture stays on the device, nothing is lost at the end
//   plan picker ONE floating decision surface: two plan rows with a lit
//               selection well, the trial timeline inside the yearly one
//   fine print  renewal, cancellation, Terms, Privacy, restore
//
// Plus the states that replace the plans: loading (the picker's skeleton),
// store unavailable, pending, already Premium, and the success view.
// Every number comes from the plan, every price from the store's offer.
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

/// Prices and limits in running text keep their digits in columns.
const List<FontFeature> _kTabular = <FontFeature>[
  FontFeature.tabularFigures(),
];

/// The pinned head of the screen: the lit dot and "EATOVA PREMIUM" at the
/// start, the close button at the end, in one row.
class PaywallTopBar extends StatelessWidget {
  const PaywallTopBar({super.key, required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(20, 6, 12, 0),
      child: Row(
        children: <Widget>[
          const LitDot(),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              l10n.premiumEyebrow,
              semanticsLabel: l10n.premiumScreenLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppType.sectionEyebrow(t.inkMuted),
            ),
          ),
          SheetCloseButton(
            buttonKey: const ValueKey('paywall-close'),
            tooltip: l10n.premiumClose,
            onTap: onClose,
          ),
        ],
      ),
    );
  }
}

/// [scaler], lowered just enough that the widest unbreakable run of [text]
/// still fits [maxWidth] on one line, never below 1x. Like
/// [AppType.wholeWordScaler], except that a no-break space joins its words
/// into one run: "Jeden Tag." must move to the next line whole, never
/// be split inside a word.
TextScaler _runScaler(
  BuildContext context, {
  required String text,
  required TextStyle style,
  required TextScaler scaler,
  required double maxWidth,
}) {
  if (!maxWidth.isFinite || maxWidth <= 0) return scaler;
  var widest = 0.0;
  for (final run in text.split(RegExp('[ \t\n]+'))) {
    if (run.isEmpty) continue;
    final painter = TextPainter(
      text: TextSpan(text: run, style: style),
      textDirection: Directionality.of(context),
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    widest = math.max(widest, painter.width);
    painter.dispose();
  }
  if (widest <= maxWidth) return scaler;
  final size = style.fontSize ?? 14;
  final base = scaler.scale(size) / size;
  return TextScaler.linear(
    math.max(base * maxWidth / widest, math.min(base, 1.0)),
  );
}

/// The promise as the screen's level-1 title and what Premium changes,
/// set on the page itself: no card, no glow.
class PaywallHero extends StatelessWidget {
  const PaywallHero({super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final size = MediaQuery.sizeOf(context).width < 360 ? 36.0 : 44.0;
    final titleStyle = AppType.display(
      size,
      color: t.ink,
      height: 1.0,
      letterSpacing: -size * 0.035,
    );
    // A 44 px title is large text already; past 1.5x it adds height, not
    // legibility.
    final titleScaler = MediaQuery.textScalerOf(
      context,
    ).clamp(maxScaleFactor: 1.5);
    return Column(
      key: const ValueKey('paywall-hero'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        HeadingSemantics(
          level: 1,
          child: LayoutBuilder(
            builder: (context, constraints) => Text(
              l10n.premiumTitle,
              key: const ValueKey('paywall-title'),
              style: titleStyle,
              textScaler: _runScaler(
                context,
                text: l10n.premiumTitle,
                style: titleStyle,
                scaler: titleScaler,
                maxWidth: constraints.maxWidth,
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),
        Text(
          l10n.premiumSubtitle,
          style: AppType.ui(15, color: t.ink2, height: 1.5),
        ),
      ],
    );
  }
}

/// A figure that counts once from [from] to [value] when it first shows,
/// [delay] after it mounted, then rests as exactly `Text('$value')`. A later
/// change of [value] shows at once. Under reduced motion it is the final
/// text from the first frame.
class _CountUp extends StatelessWidget {
  const _CountUp({
    required this.from,
    required this.value,
    required this.style,
    required this.duration,
    this.delay = Duration.zero,
  });

  final int from;
  final int value;
  final TextStyle style;
  final Duration duration;
  final Duration delay;

  @override
  Widget build(BuildContext context) {
    final total = delay + duration;
    final start = delay.inMicroseconds / total.inMicroseconds;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: motionDuration(context, total),
      curve: Interval(start, 1, curve: kMotionCurve),
      builder: (context, progress, _) => Text(
        '${(from + (value - from) * progress).round()}',
        maxLines: 1,
        style: style,
      ),
    );
  }
}

/// One line of the ledger: the visible name and detail, the spoken label,
/// and the two values (a daily number, or included / not included).
typedef _LedgerLine = ({
  String spoken,
  String name,
  String detail,
  int? free,
  int? premium,
  bool? freeIncluded,
  bool? premiumIncluded,
});

/// Free against Premium, from the plan's `limits.free` and `limits.premium`
/// (the assumed defaults until the server answered). Labels and the Free
/// column sit flat on the page; the Premium column is one lit pillar that
/// rises once beside them while its numbers count up from the Free ones.
/// Each row is one semantics node that names both columns.
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
    final lines = <_LedgerLine>[
      (
        spoken: l10n.premiumRowCoach,
        name: l10n.premiumRowCoachShort,
        detail: l10n.premiumRowPerDay,
        free: free.coachDaily,
        premium: premium.coachDaily,
        freeIncluded: null,
        premiumIncluded: null,
      ),
      (
        spoken: l10n.premiumRowMealAnalysis,
        name: l10n.premiumRowMealAnalysisShort,
        detail: l10n.premiumRowMealAnalysisDetail,
        free: free.mealAnalysisDaily,
        premium: premium.mealAnalysisDaily,
        freeIncluded: null,
        premiumIncluded: null,
      ),
      (
        spoken: l10n.premiumRowRecipeImport,
        name: l10n.premiumRowRecipeImportShort,
        detail: l10n.premiumRowPerDay,
        free: free.recipeImportDaily,
        premium: premium.recipeImportDaily,
        freeIncluded: null,
        premiumIncluded: null,
      ),
      (
        spoken: l10n.premiumRowRecipePicture,
        name: l10n.premiumRowRecipePictureShort,
        detail: l10n.premiumRowRecipePictureDetail,
        free: null,
        premium: null,
        freeIncluded: free.recipePicture,
        premiumIncluded: premium.recipePicture,
      ),
    ];
    return Column(
      key: const ValueKey('paywall-compare'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        HeadingSemantics(
          level: 2,
          child: Text(
            l10n.premiumCompareTitle,
            style: AppType.display(20, color: t.ink, height: 1.15),
          ),
        ),
        const SizedBox(height: 14),
        LayoutBuilder(
          builder: (context, constraints) {
            final scaler = MediaQuery.textScalerOf(context);
            final columns = (
              free: scaler.scale(58).clamp(58.0, 116.0),
              premium: scaler.scale(92).clamp(92.0, 170.0),
            );
            // Two value columns leave the label too little room at large
            // text on a narrow phone: each line then stacks.
            final stacked =
                constraints.maxWidth - columns.free - columns.premium <
                scaler.scale(118);
            return stacked
                ? _StackedLedger(lines: lines)
                : _Ledger(lines: lines, columns: columns);
          },
        ),
      ],
    );
  }
}

/// The widths of the Free and the Premium column.
typedef _Columns = ({double free, double premium});

/// A column header: the tier's name as a small uppercase caption, spoken as
/// the name itself.
Widget _columnCaption(String name, Color color) => Text(
  name.toUpperCase(),
  semanticsLabel: name,
  textAlign: TextAlign.center,
  maxLines: 1,
  style: AppType.sectionEyebrow(color, size: 11),
);

class _Ledger extends StatelessWidget {
  const _Ledger({required this.lines, required this.columns});

  final List<_LedgerLine> lines;
  final _Columns columns;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return Stack(
      children: <Widget>[
        // The pillar: the Premium column lifted off the page.
        PositionedDirectional(
          top: 0,
          bottom: 0,
          end: 0,
          width: columns.premium,
          child: const _PillarRise(
            child: LitSurface(radius: rTile, child: SizedBox.expand()),
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.only(top: 16, bottom: 4),
              child: Row(
                children: <Widget>[
                  const Spacer(),
                  SizedBox(
                    width: columns.free,
                    child: _columnCaption(l10n.premiumCompareFree, t.ink3),
                  ),
                  SizedBox(
                    width: columns.premium,
                    child: _columnCaption(
                      l10n.premiumComparePremium,
                      t.accentText,
                    ),
                  ),
                ],
              ),
            ),
            for (final (index, line) in lines.indexed)
              _LedgerRow(
                line: line,
                child: Row(
                  children: <Widget>[
                    Expanded(child: _LedgerLabel(line: line)),
                    SizedBox(
                      width: columns.free,
                      child: Center(child: _value(context, line, index, false)),
                    ),
                    SizedBox(
                      width: columns.premium,
                      child: Center(child: _value(context, line, index, true)),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 10),
          ],
        ),
      ],
    );
  }
}

/// The pillar arriving: it rises 12 px and fades in once, settling on a
/// soft spring. At rest (and under reduced motion) it is [child] as is.
class _PillarRise extends StatelessWidget {
  const _PillarRise({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween<double>(begin: 0, end: 1),
    duration: motionDuration(context, const Duration(milliseconds: 420)),
    curve: kSpringSettle,
    builder: (context, rise, child) => Opacity(
      opacity: rise.clamp(0.0, 1.0),
      child: Transform.translate(
        offset: Offset(0, 12 * (1 - rise)),
        child: child,
      ),
    ),
    child: child,
  );
}

/// Narrow phone, large text: each line stacks, the label above the two
/// values; the Premium value sits on its own small lit slab.
class _StackedLedger extends StatelessWidget {
  const _StackedLedger({required this.lines});

  final List<_LedgerLine> lines;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final (index, line) in lines.indexed)
          _LedgerRow(
            line: line,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _LedgerLabel(line: line),
                const SizedBox(height: 8),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Column(
                        children: <Widget>[
                          _columnCaption(l10n.premiumCompareFree, t.ink3),
                          const SizedBox(height: 4),
                          _value(context, line, index, false),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: LitSurface(
                        radius: rControl,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Column(
                          children: <Widget>[
                            _columnCaption(
                              l10n.premiumComparePremium,
                              t.accentText,
                            ),
                            const SizedBox(height: 4),
                            _value(context, line, index, true),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// One ledger row as one semantics node: "Coach-Fragen pro Tag: Free 2,
/// Premium 20".
class _LedgerRow extends StatelessWidget {
  const _LedgerRow({required this.line, required this.child});

  final _LedgerLine line;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    String spoken(int? number, bool? included) =>
        number?.toString() ??
        (included == true ? l10n.premiumIncluded : l10n.premiumNotIncluded);
    return Semantics(
      container: true,
      excludeSemantics: true,
      label:
          '${line.spoken}: ${l10n.premiumCompareFree} '
          '${spoken(line.free, line.freeIncluded)}, '
          '${l10n.premiumComparePremium} '
          '${spoken(line.premium, line.premiumIncluded)}',
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 11),
        child: child,
      ),
    );
  }
}

class _LedgerLabel extends StatelessWidget {
  const _LedgerLabel({required this.line});

  final _LedgerLine line;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          line.name,
          style: AppType.ui(15, weight: FontWeight.w700, color: t.ink),
        ),
        const SizedBox(height: 2),
        Text(
          line.detail,
          style: AppType.ui(12.5, color: t.ink2, height: 1.3),
        ),
      ],
    );
  }
}

/// A ledger value: Premium numbers large in `ink` on the pillar, counting up
/// from the Free number one row after the other; Free ones a size smaller in
/// `ink2`; the yes/no row as a check or an en dash.
Widget _value(
  BuildContext context,
  _LedgerLine line,
  int index,
  bool premium,
) {
  final t = context.t;
  final number = premium ? line.premium : line.free;
  if (number != null) {
    final style = AppType.display(
      premium ? 26 : 19,
      weight: premium ? FontWeight.w800 : FontWeight.w600,
      color: premium ? t.ink : t.ink2,
      height: 1.1,
    );
    if (!premium) return Text('$number', maxLines: 1, style: style);
    return _CountUp(
      from: line.free ?? 0,
      value: number,
      style: style,
      duration: const Duration(milliseconds: 640),
      delay: Duration(milliseconds: 70 * index),
    );
  }
  final included = premium ? line.premiumIncluded : line.freeIncluded;
  return included == true
      ? Icon(
          Icons.check_rounded,
          size: premium ? 24 : 20,
          color: premium ? t.accentText : t.ink2,
        )
      : Text(
          '–',
          style: AppType.display(19, weight: FontWeight.w600, color: t.ink3),
        );
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

/// The two reassurances under the ledger as quiet footnotes: a small accent
/// glyph without a disc, the sentence in `ink2`.
class PaywallBenefits extends StatelessWidget {
  const PaywallBenefits({super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    Widget line(IconData icon, String text) => Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: ExcludeSemantics(
            child: Icon(icon, size: 18, color: t.accentText),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            text,
            style: AppType.ui(13.5, color: t.ink2, height: 1.5),
          ),
        ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        line(Icons.phone_android_rounded, l10n.premiumBenefitPicture),
        const SizedBox(height: 10),
        line(Icons.bookmark_added_outlined, l10n.premiumBenefitKeep),
      ],
    );
  }
}

/// Inner radius of a plan row: concentric with the plan picker around it.
const double _kPlanCardInset = 6;
const double _kPlanRowRadius = rHero - _kPlanCardInset;

/// Width of the leading column of a plan row (the pip) and of the trial
/// timeline's nodes, so the timeline hangs from the pips.
const double _kPipColumn = 24;

/// The plan choice: ONE floating decision surface (lit top, contact and
/// ambient shadow, no edge) holding the plans, yearly first. The selected
/// row lights its well; with a trial the timeline hangs inside that well
/// and folds away for a plan without one.
class PaywallPlanPicker extends StatelessWidget {
  const PaywallPlanPicker({
    super.key,
    required this.offers,
    required this.selected,
    required this.savingsPercent,
    required this.onChoose,
  });

  /// The store's offers, yearly first.
  final List<PremiumOffer> offers;
  final PremiumOffer? selected;

  /// The yearly plan's saving over twelve monthly payments.
  final int? savingsPercent;
  final ValueChanged<PremiumPeriod> onChoose;

  @override
  Widget build(BuildContext context) {
    final chosen = selected;
    final trial =
        chosen != null &&
        chosen.period == PremiumPeriod.yearly &&
        chosen.hasTrial;
    return LitSurface(
      decision: true,
      padding: const EdgeInsets.all(_kPlanCardInset),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (final (index, offer) in offers.indexed) ...<Widget>[
            if (index > 0) const SizedBox(height: 2),
            PaywallPlanCard(
              offer: offer,
              selected: identical(offer, chosen),
              savingsPercent: offer.period == PremiumPeriod.yearly
                  ? savingsPercent
                  : null,
              onTap: () => onChoose(offer.period),
              // The trial belongs to the plan that has it: its timeline
              // hangs inside that plan's lit well and folds away with it.
              footer: trial && identical(offer, chosen)
                  ? PaywallTrialTimeline(offer: chosen)
                  : null,
            ),
          ],
        ],
      ),
    );
  }
}

/// One plan as a row of the [PaywallPlanPicker]: the billed amount as the
/// largest number, the monthly equivalent and the trial in one quiet line
/// under it, the saving next to the name. Selected, its well lights up and
/// the pip turns into a lit check; a switch to it ticks once.
class PaywallPlanCard extends StatelessWidget {
  const PaywallPlanCard({
    super.key,
    required this.offer,
    required this.selected,
    required this.onTap,
    this.savingsPercent,
    this.footer,
  });

  final PremiumOffer offer;
  final bool selected;
  final VoidCallback onTap;

  /// The yearly plan's saving over twelve monthly payments.
  final int? savingsPercent;

  /// Shown inside the lit well under the row, aligned with the pip column
  /// (the trial timeline); outside the row's tap target and its semantics
  /// node. It unfolds and folds with the selection.
  final Widget? footer;

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
    final radius = BorderRadius.circular(_kPlanRowRadius);
    final meta = <Widget>[
      if (yearly)
        Text(
          l10n.premiumPlanPerMonth(paywallMonthlyPrice(context, offer)),
          style: AppType.ui(
            13,
            color: t.ink2,
          ).copyWith(fontFeatures: _kTabular),
        ),
      if (offer.hasTrial)
        Text(
          l10n.premiumPlanTrialBadge(offer.trialDays!),
          key: const ValueKey('paywall-trial-badge'),
          style: AppType.ui(13, weight: FontWeight.w700, color: t.accentText),
        ),
    ];
    final row = MergeSemantics(
      child: Semantics(
        button: true,
        selected: selected,
        inMutuallyExclusiveGroup: true,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            key: ValueKey('paywall-plan-${offer.period.name}'),
            onTap: () {
              // Only a real change ticks; the chosen plan stays silent.
              if (!selected) unawaited(HapticFeedback.selectionClick());
              onTap();
            },
            borderRadius: radius,
            splashFactory: NoSplash.splashFactory,
            highlightColor: t.accentTint,
            focusColor: t.accentTintStrong,
            child: Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(14, 16, 16, 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: _PlanPip(selected: selected),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Wrap(
                          alignment: WrapAlignment.spaceBetween,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 8,
                          runSpacing: 2,
                          children: <Widget>[
                            Text(
                              yearly
                                  ? l10n.premiumPlanYearly
                                  : l10n.premiumPlanMonthly,
                              style: AppType.ui(
                                15,
                                weight: FontWeight.w700,
                                color: t.ink,
                              ),
                            ),
                            if (savingsPercent != null)
                              Text(
                                l10n.premiumPlanSavings(savingsPercent!),
                                style: AppType.display(
                                  13,
                                  color: t.accentText,
                                  letterSpacing: 0,
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          price,
                          key: ValueKey('paywall-price-${offer.period.name}'),
                          textScaler: priceScaler,
                          style: AppType.display(
                            25,
                            color: t.ink,
                            height: 1.1,
                          ),
                        ),
                        if (meta.isNotEmpty) ...<Widget>[
                          const SizedBox(height: 6),
                          Wrap(spacing: 10, runSpacing: 2, children: meta),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    final extra = footer;
    return PressScale(
      scale: kPressScaleCard,
      child: AnimatedContainer(
        duration: motionDuration(context, kMotionEnter),
        curve: kMotionCurve,
        decoration: BoxDecoration(
          color: selected ? t.accentTint : t.accentTint.withValues(alpha: 0),
          borderRadius: radius,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            row,
            maybeAnimatedSize(
              context,
              duration: kMotionEnter,
              curve: kMotionCurve,
              alignment: Alignment.topCenter,
              child: extra == null
                  ? const SizedBox(width: double.infinity)
                  : Padding(
                      padding: const EdgeInsetsDirectional.fromSTEB(
                        14,
                        0,
                        16,
                        18,
                      ),
                      child: extra,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The radio of a plan row without a ring: a flush neutral disc that turns
/// into a lit accent check (it casts its light) when chosen; the check pops.
class _PlanPip extends StatelessWidget {
  const _PlanPip({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final duration = motionDuration(context, kMotionEnter);
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: _kPipColumn,
        child: Center(
          child: AnimatedContainer(
            duration: duration,
            curve: kMotionCurve,
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              // Unselected: the faint idle mark, which reads on the lit
              // surface in both palettes where `softFill` vanished in dark.
              color: selected ? t.accentFill : t.inkFaint,
              boxShadow: selected
                  ? castLight(t, t.accentGlow)
                  : const <BoxShadow>[],
            ),
            child: AnimatedScale(
              duration: motionDuration(context, _kPopDuration),
              curve: kSpringPop,
              scale: selected ? 1 : 0.4,
              child: AnimatedOpacity(
                duration: duration,
                opacity: selected ? 1 : 0,
                child: Icon(
                  Icons.check_rounded,
                  size: 15,
                  color: t.onAccentFill,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A pip's check landing: long enough for the spring to show.
const Duration _kPopDuration = Duration(milliseconds: 320);

/// The trial in two steps hanging from the plan rows' pips: today lit
/// (unlocked now), the first charge with its date and price unlit (a trial
/// is never shown without them, 1.2). One continuous track joins them,
/// falling off from the light of today into the neutral of later; once the
/// well has opened, the light runs down it.
class PaywallTrialTimeline extends StatelessWidget {
  const PaywallTrialTimeline({super.key, required this.offer});

  final PremiumOffer offer;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final chargeOn = paywallTrialChargeDate(offer);
    final lineHeight = MediaQuery.textScalerOf(context).scale(14) * 1.4;
    // The dots sit on the first line of their text; each draws the half of
    // the track on its side of the gap between the steps.
    Widget node({required bool lit}) => SizedBox(
      width: _kPipColumn,
      height: lineHeight,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          Positioned(
            top: lit ? lineHeight / 2 : 0,
            bottom: lit ? 0 : lineHeight / 2,
            width: 2,
            child: ColoredBox(color: lit ? t.accentFill : t.inkFaint),
          ),
          LitDot(lit: lit, size: 10),
        ],
      ),
    );
    return Column(
      key: const ValueKey('paywall-trial-timeline'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Column(
                children: <Widget>[
                  node(lit: true),
                  const Expanded(child: _TrialTrack()),
                ],
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Text(
                    l10n.premiumTrialToday,
                    key: const ValueKey('paywall-trial-today'),
                    style: AppType.ui(
                      14,
                      weight: FontWeight.w700,
                      color: t.ink,
                      height: 1.4,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            node(lit: false),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                l10n.premiumTrialCharge(
                  paywallDate(context, chargeOn),
                  offer.priceLabel,
                ),
                key: const ValueKey('paywall-trial-charge'),
                style: AppType.ui(
                  14,
                  weight: FontWeight.w500,
                  color: t.ink2,
                  height: 1.4,
                ).copyWith(fontFeatures: _kTabular),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// The middle of the trial track: the idle tone, with the light of today
/// running down it once after the well has unfolded (220 ms), over 600 ms.
class _TrialTrack extends StatelessWidget {
  const _TrialTrack();

  static const Duration _wait = Duration(milliseconds: 220);
  static const Duration _run = Duration(milliseconds: 600);

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final total = _wait + _run;
    // Painted, not sized: the track adds no intrinsic height of its own, so
    // the timeline's IntrinsicHeight measures the text alone.
    return SizedBox(
      width: 2,
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 0, end: 1),
        duration: motionDuration(context, total),
        curve: Interval(
          _wait.inMicroseconds / total.inMicroseconds,
          1,
          curve: Curves.easeOutCubic,
        ),
        builder: (context, grow, _) => CustomPaint(
          painter: _TrackPainter(
            idle: t.inkFaint,
            lit: t.accentFill,
            grow: grow,
          ),
        ),
      ),
    );
  }
}

/// The idle track, and over its top [grow] share the light falling off into
/// the idle tone.
class _TrackPainter extends CustomPainter {
  const _TrackPainter({
    required this.idle,
    required this.lit,
    required this.grow,
  });

  final Color idle;
  final Color lit;
  final double grow;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = idle);
    final reach = size.height * grow.clamp(0.0, 1.0);
    if (reach <= 0) return;
    final shown = Rect.fromLTWH(0, 0, size.width, reach);
    canvas.drawRect(
      shown,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[lit, idle],
        ).createShader(shown),
    );
  }

  @override
  bool shouldRepaint(_TrackPainter old) =>
      old.grow != grow || old.idle != idle || old.lit != lit;
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
      style: AppType.ui(
        13,
        weight: FontWeight.w500,
        color: context.t.ink2,
        height: 1.35,
      ).copyWith(fontFeatures: _kTabular),
    );
  }
}

/// Renewal and cancellation for the selected plan, the legal links and the
/// restore action: left-aligned with the page, the links as quiet text
/// actions with the full 48 px target, their words flush with the sentence
/// above.
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

  /// The horizontal inset of an [EatovaTextAction]'s label.
  static const double _linkInset = 12;

  /// The restore link's glyph and the gap after it.
  static const double _glyph = 16;
  static const double _glyphGap = 8;

  /// The spinner after the restore link while the store answers.
  static const double _spinner = 14;

  static const double _linkSize = 13;
  static TextStyle get _linkStyle =>
      AppType.ui(_linkSize, weight: FontWeight.w700);

  /// How a link label fits [room]: the reader's text scale where it stays on
  /// one line, lowered just enough where it would not, but never below 1.3x
  /// (the pinned foot's cap); below that it wraps between words. With the
  /// label's width at that scale.
  static ({double scale, double width}) _fit(
    BuildContext context,
    String label,
    double room,
  ) {
    double width(double scale) {
      final painter = TextPainter(
        text: TextSpan(text: label, style: _linkStyle),
        textDirection: Directionality.of(context),
        textScaler: TextScaler.linear(scale),
        maxLines: 1,
      )..layout();
      final width = painter.width;
      painter.dispose();
      return width;
    }

    final own = MediaQuery.textScalerOf(context).scale(_linkSize) / _linkSize;
    final natural = width(own);
    if (natural <= room) return (scale: own, width: natural);
    final scale = math.max(own * room / natural, math.min(own, 1.3));
    return (scale: scale, width: width(scale));
  }

  /// A fine-print link whose label takes at most [scale].
  Widget _link({
    required double scale,
    required Key key,
    required String label,
    required VoidCallback? onTap,
    IconData? icon,
    EatovaTextTone tone = EatovaTextTone.accent,
  }) => MediaQuery.withClampedTextScaling(
    maxScaleFactor: scale,
    child: EatovaTextAction(
      buttonKey: key,
      label: label,
      icon: icon,
      iconSize: _glyph,
      tone: tone,
      textStyle: _linkStyle,
      onTap: onTap,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final offer = selected;
    final restore = onRestore;
    // Pulls the links back by their own inset, so the first word lines up
    // with the renewal sentence instead of sitting 12 px in.
    final flush = Offset(
      Directionality.of(context) == TextDirection.rtl
          ? _linkInset
          : -_linkInset,
      0,
    );
    final dot = ExcludeSemantics(
      child: Container(
        width: 3,
        height: 3,
        decoration: BoxDecoration(color: t.inkFaint, shape: BoxShape.circle),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (offer != null) ...<Widget>[
          Text(
            '${offer.period == PremiumPeriod.yearly ? l10n.premiumRenewalYearly(offer.priceLabel) : l10n.premiumRenewalMonthly(offer.priceLabel)} '
            '${l10n.premiumCancelAnytime(paywallStoreKey(context))}',
            key: const ValueKey('paywall-renewal'),
            style: AppType.ui(
              12.5,
              color: t.ink2,
              height: 1.55,
            ).copyWith(fontFeatures: _kTabular),
          ),
          const SizedBox(height: 4),
        ],
        Transform.translate(
          offset: flush,
          child: LayoutBuilder(
            builder: (context, constraints) {
              // Each label on one line, never split inside a word. The two
              // documents share a line with a dot between them while they
              // fit; otherwise the second moves under the first, without
              // a dot left over at either end.
              final room = constraints.maxWidth - 2 * _linkInset;
              final terms = _fit(context, l10n.premiumTermsLink, room);
              final privacy = _fit(context, l10n.premiumPrivacyLink, room);
              final links = <Widget>[
                _link(
                  scale: terms.scale,
                  key: const ValueKey('paywall-terms'),
                  label: l10n.premiumTermsLink,
                  onTap: () => openLegalLink(context, kTermsUrl),
                ),
                _link(
                  scale: privacy.scale,
                  key: const ValueKey('paywall-privacy'),
                  label: l10n.premiumPrivacyLink,
                  onTap: () => openLegalLink(context, kPrivacyUrl),
                ),
              ];
              final oneLine =
                  terms.width + privacy.width + 4 * _linkInset + 3 <=
                  constraints.maxWidth;
              return oneLine
                  ? Row(children: <Widget>[links[0], dot, links[1]])
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: links,
                    );
            },
          ),
        ),
        // Restore is an action, not a document: its own line, its glyph,
        // and a spinner after it while the store answers.
        if (restore != null)
          Transform.translate(
            offset: flush,
            child: LayoutBuilder(
              builder: (context, constraints) {
                // Room for the spinner is kept, so the label never jumps.
                final fit = _fit(
                  context,
                  l10n.premiumRestore,
                  constraints.maxWidth -
                      2 * _linkInset -
                      _glyph -
                      _glyphGap -
                      _spinner,
                );
                return Row(
                  children: <Widget>[
                    Flexible(
                      child: _link(
                        scale: fit.scale,
                        key: const ValueKey('paywall-restore'),
                        label: l10n.premiumRestore,
                        icon: Icons.restore_rounded,
                        tone: EatovaTextTone.neutral,
                        onTap: restoring ? null : restore,
                      ),
                    ),
                    if (restoring)
                      const ExcludeSemantics(
                        child: AppSpinner(size: _spinner, strokeWidth: 2),
                      ),
                  ],
                );
              },
            ),
          ),
      ],
    );
  }
}

/// While the store answers: the plan picker's own surface with its rows as
/// calm placeholders and one live line, so the price arrives in place
/// instead of into an empty box.
class PaywallLoadingPlans extends StatelessWidget {
  const PaywallLoadingPlans({super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    Widget bar(double width, double height) => Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: t.softFill,
        borderRadius: BorderRadius.circular(height / 2),
      ),
    );
    Widget row() => Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(14, 16, 16, 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox.square(
            dimension: _kPipColumn,
            child: Center(
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: t.softFill,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
          const SizedBox(width: 14),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              bar(72, 12),
              const SizedBox(height: 10),
              bar(150, 20),
            ],
          ),
        ],
      ),
    );
    return LitSurface(
      key: const ValueKey('paywall-loading'),
      decision: true,
      padding: const EdgeInsets.all(_kPlanCardInset),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          ExcludeSemantics(child: row()),
          ExcludeSemantics(child: row()),
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(14, 4, 16, 14),
            child: Semantics(
              liveRegion: true,
              child: Row(
                children: <Widget>[
                  const SizedBox(
                    width: _kPipColumn,
                    child: Center(
                      child: ExcludeSemantics(
                        child: AppSpinner(size: 16, strokeWidth: 2),
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      context.l10n.premiumLoadingOffers,
                      style: AppType.ui(13.5, color: t.ink2),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
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
      child: _QuietState(
        icon: Icons.storefront_outlined,
        title: l10n.premiumStoreUnavailableTitle,
        text: l10n.premiumStoreUnavailableBody,
        radius: rHero,
        action: SoftPillButton(
          key: const ValueKey('paywall-retry'),
          label: l10n.premiumRetry,
          icon: Icons.refresh_rounded,
          onTap: onRetry,
        ),
      ),
    );
  }
}

/// The purchase belongs to another Eatova account (a `409`, or a `422` with
/// reason `account`); nothing was granted here.
class PaywallOwnedByOtherNote extends StatelessWidget {
  const PaywallOwnedByOtherNote({super.key});

  @override
  Widget build(BuildContext context) => Semantics(
    key: const ValueKey('paywall-owned-by-other'),
    liveRegion: true,
    child: _QuietState(
      icon: Icons.manage_accounts_outlined,
      tone: context.t.warning,
      text: context.l10n.premiumOwnedByOther,
    ),
  );
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
      child: _QuietState(
        icon: Icons.hourglass_top_rounded,
        tone: context.t.warning,
        title: l10n.premiumPendingTitle,
        text: l10n.premiumPendingBody(paywallStoreKey(context)),
      ),
    );
  }
}

/// A calm state in or under the plan picker's place: a lit surface with the
/// glyph in a small disc (neutral, or [tone] at 14 % for a wait or a
/// conflict), the title, the sentence and an optional action under it.
class _QuietState extends StatelessWidget {
  const _QuietState({
    required this.icon,
    required this.text,
    this.title,
    this.tone,
    this.action,
    this.radius = rCard,
  });

  final IconData icon;
  final String? title;
  final String text;
  final Color? tone;
  final Widget? action;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final glyph = tone ?? t.ink2;
    final heading = title;
    return LitSurface(
      radius: radius,
      padding: const EdgeInsets.all(20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          ExcludeSemantics(
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: tone == null
                    ? Color.alphaBlend(t.tile, t.surfLit)
                    : glyph.withValues(alpha: 0.14),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 18, color: glyph),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Padding(
              // The first line sits on the disc's centre.
              padding: const EdgeInsets.only(top: 7),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  if (heading != null) ...<Widget>[
                    Text(
                      heading,
                      style: AppType.ui(
                        16,
                        weight: FontWeight.w700,
                        color: t.ink,
                        height: 1.3,
                      ),
                    ),
                    const SizedBox(height: 4),
                  ],
                  Text(text, style: AppType.ui(14, color: t.ink2, height: 1.5)),
                  if (action != null) ...<Widget>[
                    const SizedBox(height: 14),
                    action!,
                  ],
                ],
              ),
            ),
          ),
        ],
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
    final titleStyle = AppType.display(24, color: t.ink, height: 1.12);
    final details = <String>[
      if (premium && info != null) _statusLine(context, info),
      if (info != null && info.isStorePurchase)
        l10n.subscriptionVia(paywallStoreKey(context, info)),
    ];
    return LitSurface(
      key: const ValueKey('paywall-premium-status'),
      decision: true,
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          LayoutBuilder(
            builder: (context, constraints) {
              // A status sentence as the heading: whole words only
              // ("fehlgeschlagen" at 2x on 320 px), the hero's cap.
              final scaler = AppType.wholeWordScaler(
                context,
                text: title,
                style: titleStyle,
                scaler: MediaQuery.textScalerOf(
                  context,
                ).clamp(maxScaleFactor: 1.6),
                maxWidth: constraints.maxWidth - 20,
                minScaleFactor: 1,
              );
              final firstLine = scaler.scale(24) * 1.12;
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  // Lit for Premium; a held, paused or pending subscription
                  // waits on its store in the warning tone.
                  Padding(
                    padding: EdgeInsets.only(top: (firstLine - 10) / 2),
                    child: LitDot(
                      size: 10,
                      color: premium ? null : t.warning,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Semantics(
                      liveRegion: true,
                      child: HeadingSemantics(
                        level: 2,
                        child: Text(
                          title,
                          style: titleStyle,
                          textScaler: scaler,
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
          for (final line in details) ...<Widget>[
            const SizedBox(height: 6),
            Text(line, style: AppType.ui(14, color: t.ink2, height: 1.4)),
          ],
          if (info != null && info.isStorePurchase) ...<Widget>[
            const SizedBox(height: 18),
            SoftPillButton(
              key: const ValueKey('paywall-manage'),
              label: l10n.premiumManage,
              icon: Icons.open_in_new_rounded,
              onTap: onManage,
            ),
          ],
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

/// The whole arrival of the success view.
const Duration _kSuccessDuration = Duration(milliseconds: 1200);

/// "Willkommen bei Premium": the verified purchase, announced once. A lit
/// disc lands on a spring and its check draws itself, then the words rise
/// and the new daily limits count up from zero. No halo, no sparkle.
class PaywallSuccessView extends StatefulWidget {
  const PaywallSuccessView({super.key, this.limits});

  /// The new daily limits (`plan.premium`), counted up once under the
  /// words; null shows none.
  final TierLimits? limits;

  @override
  State<PaywallSuccessView> createState() => _PaywallSuccessViewState();
}

class _PaywallSuccessViewState extends State<PaywallSuccessView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _kSuccessDuration,
  );
  // 0–600 ms: the disc lands from 0.8.
  late final CurvedAnimation _disc = CurvedAnimation(
    parent: _controller,
    curve: const Interval(0, 0.5, curve: kSpringPop),
  );
  late final CurvedAnimation _draw = CurvedAnimation(
    parent: _controller,
    curve: const Interval(0.22, 0.62, curve: Curves.easeOutCubic),
  );
  late final CurvedAnimation _wordsRise = CurvedAnimation(
    parent: _controller,
    curve: const Interval(0.35, 0.9, curve: kSpringSettle),
  );
  late final CurvedAnimation _wordsFade = CurvedAnimation(
    parent: _controller,
    curve: const Interval(0.35, 0.6, curve: Curves.easeOut),
  );
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (reducedMotion(context)) {
      _controller.value = 1;
    } else {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _disc.dispose();
    _draw.dispose();
    _wordsRise.dispose();
    _wordsFade.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(28, 12, 28, 20),
        child: Column(
          key: const ValueKey('paywall-success'),
          children: <Widget>[
            ExcludeSemantics(
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, _) {
                  final land = _disc.value;
                  return Transform.scale(
                    scale: 0.8 + 0.2 * land,
                    child: Container(
                      width: 88,
                      height: 88,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: t.accentFill,
                        boxShadow: castLight(
                          t,
                          t.accentGlow,
                          strength: land.clamp(0.0, 1.0),
                        ),
                      ),
                      child: CustomPaint(
                        painter: _CheckPainter(
                          color: t.onAccentFill,
                          progress: _draw.value,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 28),
            FadeTransition(
              opacity: _wordsFade,
              child: AnimatedBuilder(
                animation: _wordsRise,
                builder: (context, child) => Transform.translate(
                  offset: Offset(0, 14 * (1 - _wordsRise.value)),
                  child: child,
                ),
                child: Column(
                  children: <Widget>[
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
                          style: AppType.display(34, color: t.ink, height: 1.1),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      l10n.premiumSuccessBody,
                      textAlign: TextAlign.center,
                      style: AppType.ui(15, color: t.ink2, height: 1.5),
                    ),
                    if (widget.limits case final limits?) ...<Widget>[
                      const SizedBox(height: 32),
                      _SuccessRecap(limits: limits),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The new daily limits: three numbers counting up from zero, one after the
/// other, with their names under them; no boxes.
class _SuccessRecap extends StatelessWidget {
  const _SuccessRecap({required this.limits});

  final TierLimits limits;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    Widget stat(int index, int value, String label) => Expanded(
      child: MergeSemantics(
        child: Column(
          children: <Widget>[
            _CountUp(
              from: 0,
              value: value,
              style: AppType.display(34, color: t.accentText, height: 1),
              duration: const Duration(milliseconds: 700),
              // Once the words have risen, 90 ms apart.
              delay: Duration(milliseconds: 400 + 90 * index),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              textAlign: TextAlign.center,
              style: AppType.ui(13, color: t.ink2),
            ),
          ],
        ),
      ),
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        stat(0, limits.coachDaily, l10n.subscriptionUsageCoach),
        stat(1, limits.mealAnalysisDaily, l10n.subscriptionUsageAnalyses),
        stat(2, limits.recipeImportDaily, l10n.subscriptionUsageImports),
      ],
    );
  }
}

/// A check stroke drawn from its short leg to the tip, round-capped.
class _CheckPainter extends CustomPainter {
  const _CheckPainter({required this.color, required this.progress});

  final Color color;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;
    final s = size.width / 88;
    final path = Path()
      ..moveTo(28 * s, 45 * s)
      ..lineTo(39 * s, 56 * s)
      ..lineTo(61 * s, 33 * s);
    final metric = path.computeMetrics().first;
    canvas.drawPath(
      metric.extractPath(0, metric.length * progress.clamp(0.0, 1.0)),
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5 * s
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_CheckPainter old) =>
      old.progress != progress || old.color != color;
}
