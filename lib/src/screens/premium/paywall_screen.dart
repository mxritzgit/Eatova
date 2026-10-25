import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/subscription.dart';
import '../../l10n/l10n.dart';
import '../../services/billing/billing_client.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/common/app_snack.dart';
import '../../widgets/common/lively.dart';
import '../../widgets/common/motion.dart';
import '../../widgets/design/design.dart';
import 'paywall_sections.dart';

// ---------------------------------------------------------------------------
// The Premium screen (docs/PREMIUM.md 1.2, 4.3): one screen, two modes.
//
// The store sells, the server grants: the screen only starts a purchase
// through the account's [SubscriptionController] and shows what comes back.
// Every number comes from the plan, every price from the store's offer.
// ---------------------------------------------------------------------------

enum PaywallMode {
  /// The root gate after a fresh onboarding: close, system Back and "Weiter
  /// mit Free" answer it with Free.
  onboarding,

  /// A pushed route from an upgrade hint, the Profile or the Settings.
  upsell,
}

class PaywallScreen extends StatefulWidget {
  const PaywallScreen({
    super.key,
    required this.mode,
    required this.controller,
    this.source,
    this.onAnswered,
  });

  final PaywallMode mode;

  /// The signed-in account's plan and purchases.
  final SubscriptionController controller;

  /// Where an upsell was opened from; stays on the device.
  final PremiumSource? source;

  /// The onboarding answer: "Weiter mit Free", close, Back or a finished
  /// purchase. Without it (upsell) the screen pops its route instead.
  final Future<void> Function()? onAnswered;

  @override
  State<PaywallScreen> createState() => _PaywallScreenState();
}

class _PaywallScreenState extends State<PaywallScreen> {
  PremiumPeriod _period = PremiumPeriod.yearly;
  late PurchaseState _seenState;
  bool _leaving = false;

  bool get _onboarding => widget.mode == PaywallMode.onboarding;

  @override
  void initState() {
    super.initState();
    _seenState = widget.controller.purchaseState;
    widget.controller.addListener(_onControllerChanged);
    // After the frame that mounts the screen: both calls notify at once, and
    // the gate is built inside the shell's own rebuild.
    scheduleMicrotask(_start);
  }

  void _start() {
    if (!mounted) return;
    unawaited(widget.controller.load());
    unawaited(widget.controller.loadOffers());
  }

  @override
  void didUpdateWidget(PaywallScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.controller, widget.controller)) return;
    oldWidget.controller.removeListener(_onControllerChanged);
    widget.controller.addListener(_onControllerChanged);
    _seenState = widget.controller.purchaseState;
    scheduleMicrotask(_start);
  }

  @override
  void dispose() {
    final controller = widget.controller;
    controller.removeListener(_onControllerChanged);
    // A result this screen showed is done with it; a purchase still on its
    // way keeps its state for the next opening. Later, not inside the
    // unmount, where a notify must not rebuild anything.
    if (controller.purchaseState == PurchaseState.success ||
        controller.purchaseState == PurchaseState.ownedByOther) {
      scheduleMicrotask(controller.clearPurchaseState);
    }
    super.dispose();
  }

  /// Results without a place on the screen go out as a snack, once.
  void _onControllerChanged() {
    final controller = widget.controller;
    final state = controller.purchaseState;
    if (state == _seenState) return;
    _seenState = state;
    if (!mounted) return;
    final l10n = context.l10n;
    final (String, SnackTone, IconData)? snack = switch (state) {
      PurchaseState.failed => (
        l10n.premiumPurchaseFailed,
        SnackTone.error,
        Icons.error_outline_rounded,
      ),
      PurchaseState.verifyDeferred => (
        l10n.premiumVerifyLater,
        SnackTone.neutral,
        Icons.schedule_rounded,
      ),
      PurchaseState.restored => (
        l10n.premiumRestoreDone,
        SnackTone.positive,
        Icons.check_circle_outline_rounded,
      ),
      PurchaseState.restoredNothing => (
        l10n.premiumRestoreNothing,
        SnackTone.neutral,
        Icons.info_outline_rounded,
      ),
      _ => null,
    };
    if (snack == null) return;
    final (message, tone, icon) = snack;
    showAppSnack(context, message, tone: tone, icon: icon);
    scheduleMicrotask(controller.clearPurchaseState);
  }

  /// The plan the button buys: the chosen one, or the one the store has.
  PremiumOffer? _selectedOffer() {
    final controller = widget.controller;
    return controller.offerFor(_period) ??
        controller.offerFor(
          _period == PremiumPeriod.yearly
              ? PremiumPeriod.monthly
              : PremiumPeriod.yearly,
        );
  }

  void _buy(PremiumOffer offer) {
    unawaited(widget.controller.buy(offer.period));
  }

  void _restore() => unawaited(widget.controller.restore());

  void _retry() => unawaited(widget.controller.loadOffers(force: true));

  /// Leaves the screen: the onboarding answer, or the route's pop.
  Future<void> _leave() async {
    if (_leaving) return;
    final answer = widget.onAnswered;
    if (answer == null) {
      await Navigator.of(context).maybePop();
      return;
    }
    _leaving = true;
    try {
      await answer();
    } finally {
      if (mounted) _leaving = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return PopScope<Object?>(
      // The gate is the root route: Back means Free, never "close the app".
      canPop: !_onboarding,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _onboarding) unawaited(_leave());
      },
      child: Semantics(
        scopesRoute: true,
        namesRoute: true,
        explicitChildNodes: true,
        label: context.l10n.premiumScreenLabel,
        child: Scaffold(
          key: const ValueKey('screen-paywall'),
          backgroundColor: t.bg,
          body: SafeArea(
            child: ReadableWidth(
              child: ListenableBuilder(
                listenable: widget.controller,
                builder: (context, _) => _content(context),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _content(BuildContext context) {
    final l10n = context.l10n;
    final controller = widget.controller;
    final state = controller.purchaseState;
    final success = state == PurchaseState.success;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
          child: Align(
            alignment: AlignmentDirectional.centerEnd,
            child: SheetCloseButton(
              buttonKey: const ValueKey('paywall-close'),
              tooltip: l10n.premiumClose,
              onTap: () => unawaited(_leave()),
            ),
          ),
        ),
        Expanded(
          child: AnimatedSwitcher(
            duration: motionDuration(context, kMotionValue),
            switchInCurve: kMotionCurve,
            switchOutCurve: kMotionCurve,
            child: success
                ? const PaywallSuccessView(
                    key: ValueKey('paywall-success-view'),
                  )
                : KeyedSubtree(
                    key: const ValueKey('paywall-offer-view'),
                    child: _offerScroll(context),
                  ),
          ),
        ),
        _foot(context, success: success),
      ],
    );
  }

  Widget _offerScroll(BuildContext context) {
    final controller = widget.controller;
    final plan = controller.plan;
    final state = controller.purchaseState;
    final premium = controller.isPremium;
    // A subscription on hold, paused or pending is fixed in its store, not
    // bought again.
    final managed = premium || plan.liveStoreSubscription() != null;
    final storeKnown =
        controller.availability != null && state != PurchaseState.loadingOffers;
    final offer = managed || !controller.storeReady ? null : _selectedOffer();
    return _EdgeFade(
      child: LivelyStaggerScope(
        child: SingleChildScrollView(
          key: const ValueKey('paywall-scroll'),
          padding: const EdgeInsets.fromLTRB(
            20,
            _kEdgeFade,
            20,
            _kEdgeFade + 8,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: livelyStagger(<Widget>[
              const PaywallHero(),
              const SizedBox(height: 16),
              PaywallCompareCard(free: plan.free, premium: plan.premium),
              // With Premium the current limits are not "the previous ones".
              if (plan.isLegacy && !premium) ...<Widget>[
                const SizedBox(height: 12),
                PaywallLegacyNote(plan: plan),
              ],
              const SizedBox(height: 20),
              const PaywallBenefits(),
              const SizedBox(height: 26),
              if (managed)
                PaywallStatusCard(
                  plan: plan,
                  onManage: () =>
                      unawaited(controller.openManageSubscriptions()),
                )
              else if (!storeKnown)
                const PaywallLoadingPlans()
              else if (!controller.storeReady)
                PaywallStoreUnavailable(onRetry: _retry)
              else
                _plans(context, offer),
              const SizedBox(height: 16),
              PaywallFinePrint(
                selected: offer,
                onRestore: controller.storeReady || premium ? _restore : null,
                restoring: state == PurchaseState.restoring,
              ),
            ]),
          ),
        ),
      ),
    );
  }

  /// Yearly first and preselected, then monthly; the state notes and the
  /// trial timeline above the button.
  Widget _plans(BuildContext context, PremiumOffer? selected) {
    final t = context.t;
    final l10n = context.l10n;
    final controller = widget.controller;
    final state = controller.purchaseState;
    final yearly = controller.offerFor(PremiumPeriod.yearly);
    final monthly = controller.offerFor(PremiumPeriod.monthly);
    final savings = yearly == null || monthly == null
        ? null
        : yearlySavingsPercent(yearly: yearly, monthly: monthly);
    void choose(PremiumPeriod period) {
      if (_period != period) setState(() => _period = period);
    }

    return Column(
      key: const ValueKey('paywall-plans'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final offer in <PremiumOffer?>[yearly, monthly])
          if (offer != null) ...<Widget>[
            PaywallPlanCard(
              offer: offer,
              selected: identical(offer, selected),
              savingsPercent: offer.period == PremiumPeriod.yearly
                  ? savings
                  : null,
              onTap: () => choose(offer.period),
            ),
            const SizedBox(height: 10),
          ],
        if (state == PurchaseState.ownedByOther) ...<Widget>[
          const SizedBox(height: 4),
          SignalNote(
            l10n.premiumOwnedByOther,
            key: const ValueKey('paywall-owned-by-other'),
            tone: t.warning,
            icon: Icons.manage_accounts_outlined,
            boxed: true,
            liveRegion: true,
          ),
          const SizedBox(height: 10),
        ],
        if (state == PurchaseState.pending) ...<Widget>[
          const SizedBox(height: 4),
          const PaywallPendingNote(),
          const SizedBox(height: 10),
        ],
        if (selected != null &&
            selected.period == PremiumPeriod.yearly &&
            selected.hasTrial) ...<Widget>[
          const SizedBox(height: 6),
          PaywallTrialTimeline(offer: selected),
        ],
      ],
    );
  }

  /// One filled action at the foot, with what it charges right above it; in
  /// the onboarding the Free choice under it, as tall as the purchase button.
  Widget _foot(BuildContext context, {required bool success}) {
    final l10n = context.l10n;
    final controller = widget.controller;
    final state = controller.purchaseState;
    final premium = controller.isPremium;
    final sells = !premium && controller.plan.liveStoreSubscription() == null;
    final storeKnown =
        controller.availability != null && state != PurchaseState.loadingOffers;
    final offer = controller.storeReady ? _selectedOffer() : null;

    Widget? charge;
    Widget? primary;
    if (success || (premium && _onboarding)) {
      primary = PrimaryActionButton(
        key: const ValueKey('paywall-continue'),
        label: l10n.premiumSuccessContinue,
        // The shown success is cleared once the screen is gone.
        onTap: () => unawaited(_leave()),
      );
    } else if (sells && offer != null) {
      final trial = offer.period == PremiumPeriod.yearly && offer.hasTrial;
      charge = PaywallChargeLine(offer: offer);
      primary = PrimaryActionButton(
        key: const ValueKey('paywall-buy'),
        label: trial
            ? l10n.premiumCtaTrial(offer.trialDays!)
            : l10n.premiumCtaSubscribe,
        busy: state == PurchaseState.purchasing,
        onTap: state == PurchaseState.restoring ? null : () => _buy(offer),
      );
    } else if (sells && !storeKnown) {
      // The prices are on their way: the button's place stays, locked.
      primary = PrimaryActionButton(
        key: const ValueKey('paywall-buy'),
        label: l10n.premiumCtaSubscribe,
      );
    }
    final free = _onboarding && !premium && !success
        ? ConstrainedBox(
            constraints: const BoxConstraints(minHeight: kPrimaryButtonHeight),
            child: SoftPillButton(
              key: const ValueKey('paywall-continue-free'),
              label: l10n.premiumContinueFree,
              tone: SoftPillTone.neutral,
              expand: true,
              onTap: () => unawaited(_leave()),
            ),
          )
        : null;
    final Widget actions;
    if (primary != null && free != null) {
      // Both as tall as the taller one, also when the purchase label wraps
      // at large text (1.2).
      actions = IntrinsicHeight(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(child: primary),
            const SizedBox(height: 10),
            Expanded(child: free),
          ],
        ),
      );
    } else if (primary ?? free case final only?) {
      actions = only;
    } else {
      return const SizedBox(height: 8);
    }
    // The foot never scrolls: past this scale it takes the screen from the
    // content instead of reading any better.
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: _kFootMaxTextScale,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (charge != null) ...<Widget>[charge, const SizedBox(height: 8)],
            actions,
          ],
        ),
      ),
    );
  }
}

/// The text-scale cap of the pinned foot: its labels stay large, but a foot
/// at 2.0x left a small phone a strip of content.
const double _kFootMaxTextScale = 1.3;

/// Height of the fades at the scroll view's top and bottom edge.
const double _kEdgeFade = 16;

/// Content scrolling under the close button or toward the foot fades out
/// instead of being cut mid-glyph (the onboarding's edge, 2026-10-04); the
/// scroll padding keeps the resting content clear of both fades.
class _EdgeFade extends StatelessWidget {
  const _EdgeFade({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (bounds) {
        final edge = bounds.height <= 0
            ? 0.0
            : (_kEdgeFade / bounds.height).clamp(0.0, 0.5);
        return LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          // Only the alpha matters for dstIn; any opaque token works.
          colors: <Color>[
            t.bg.withValues(alpha: 0),
            t.bg,
            t.bg,
            t.bg.withValues(alpha: 0),
          ],
          stops: <double>[0, edge, 1 - edge, 1],
        ).createShader(bounds);
      },
      child: child,
    );
  }
}
