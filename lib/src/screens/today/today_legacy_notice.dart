import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../app/subscription.dart' show SubscriptionController;
import '../../config/legal_links.dart';
import '../../l10n/l10n.dart';
import '../../models/plan_status.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/design/design.dart';
import '../settings/settings_controls.dart' show openLegalLink;

/// Today's one-time notice for an account that still keeps the pre-Premium
/// limits (docs/PREMIUM.md 1.2, 4.4): once the operator set `legacy_until`,
/// it names that date and the new Free limits, or for a Premium account the
/// regular Premium limits, without offering Premium again.
///
/// It decides itself whether it shows: the plan carries `legacy.until` and
/// the account's `legacy_notice` slot ([readDismissed]) does not hold that
/// date yet. "Verstanden" stores the date ([writeDismissed]); a later date
/// shows the notice again. Nothing shows until the slot was read, so a
/// dismissed notice never flashes up.
class TodayLegacyNotice extends StatefulWidget {
  const TodayLegacyNotice({
    super.key,
    required this.controller,
    required this.readDismissed,
    required this.writeDismissed,
    this.onUpgrade,
    this.onOpenTerms,
  });

  final SubscriptionController controller;

  /// The `legacy_until` whose notice was dismissed (`HomeStore`).
  final Future<DateTime?> Function() readDismissed;
  final Future<void> Function(DateTime until) writeDismissed;

  /// "Mehr mit Premium"; null hides it.
  final VoidCallback? onUpgrade;

  /// "Geänderte AGB lesen"; null opens [kTermsUrl] in the browser.
  final VoidCallback? onOpenTerms;

  @override
  State<TodayLegacyNotice> createState() => _TodayLegacyNoticeState();
}

class _TodayLegacyNoticeState extends State<TodayLegacyNotice> {
  bool _read = false;
  DateTime? _dismissed;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onPlan);
    unawaited(_readSlot());
  }

  @override
  void didUpdateWidget(TodayLegacyNotice oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_onPlan);
      widget.controller.addListener(_onPlan);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onPlan);
    super.dispose();
  }

  Future<void> _readSlot() async {
    DateTime? dismissed;
    try {
      dismissed = await widget.readDismissed();
    } catch (_) {
      // Unreadable slot: the notice shows rather than being lost.
      dismissed = null;
    }
    if (!mounted) return;
    setState(() {
      _read = true;
      _dismissed = dismissed;
    });
  }

  void _onPlan() {
    if (mounted) setState(() {});
  }

  Future<void> _dismiss(DateTime until) async {
    setState(() => _dismissed = until);
    try {
      await widget.writeDismissed(until);
    } catch (_) {
      // Gone for this session; the next start asks the slot again.
    }
  }

  @override
  Widget build(BuildContext context) {
    final plan = widget.controller.plan;
    final until = plan.legacy?.until;
    final dismissed = _dismissed;
    if (!_read ||
        until == null ||
        (dismissed != null && dismissed.isAtSameMomentAs(until))) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: TodayLegacyNoticeCard(
        until: until,
        free: plan.free,
        premium: plan.isPremium,
        basePremium: plan.legacy?.premium,
        onDismiss: () => _dismiss(until),
        onUpgrade: plan.isPremium ? null : widget.onUpgrade,
        onOpenTerms:
            widget.onOpenTerms ?? () => openLegalLink(context, kTermsUrl),
      ),
    );
  }
}

/// The notice itself: the date the new Free limits apply from, those
/// limits, the changed terms, and "Verstanden" as the one filled answer.
/// With [premium] it names the regular Premium limits instead.
class TodayLegacyNoticeCard extends StatelessWidget {
  const TodayLegacyNoticeCard({
    super.key,
    required this.until,
    required this.free,
    this.premium = false,
    this.basePremium,
    required this.onDismiss,
    this.onUpgrade,
    this.onOpenTerms,
  });

  /// `legacy_until`: from then on the account has the Free limits, or with
  /// Premium the regular Premium ones.
  final DateTime until;

  /// The Free limits named in the body (`limits.free`).
  final TierLimits free;

  /// The account has Premium: its limits change, not Free's.
  final bool premium;

  /// The regular Premium limits (`legacy.premium`); without them the
  /// Premium body names no numbers.
  final BasePremiumLimits? basePremium;
  final Future<void> Function() onDismiss;
  final VoidCallback? onUpgrade;
  final VoidCallback? onOpenTerms;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final date = DateFormat.yMMMd(l10n.localeName).format(until.toLocal());
    final body = switch ((premium, basePremium)) {
      (false, _) => <String>[
        l10n.legacyNoticeBody(
          date,
          free.coachDaily,
          free.mealAnalysisDaily,
          free.recipeImportDaily,
        ),
        l10n.legacyNoticeMorePremium,
      ].join(' '),
      (true, final limits?) => l10n.legacyNoticeBodyPremium(
        date,
        limits.coachDaily,
        limits.mealAnalysisDaily,
        limits.recipeImportDaily,
      ),
      (true, null) => l10n.legacyNoticeBodyPremiumPlain(date),
    };
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: l10n.legacyNoticeTitle,
      child: Container(
        key: const ValueKey('today-legacy-notice'),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: t.surf,
          borderRadius: BorderRadius.circular(rCard),
          border: Border.all(color: t.cardBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                IconTile(icon: Icons.auto_awesome_rounded, color: t.accent),
                const SizedBox(width: 12),
                Expanded(
                  child: HeadingSemantics(
                    level: 2,
                    child: Text(
                      l10n.legacyNoticeTitle,
                      style: AppType.ui(
                        15,
                        weight: FontWeight.w700,
                        color: t.ink,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              body,
              key: const ValueKey('today-legacy-notice-body'),
              style: AppType.ui(13.5, color: t.ink2, height: 1.4),
            ),
            if (onOpenTerms case final openTerms?) ...<Widget>[
              const SizedBox(height: 4),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  key: const ValueKey('today-legacy-notice-terms'),
                  onPressed: openTerms,
                  icon: const Icon(Icons.open_in_new_rounded, size: 16),
                  label: Text(l10n.legacyNoticeTerms),
                  style: TextButton.styleFrom(
                    foregroundColor: t.accentText,
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(0, 44),
                    textStyle: AppType.ui(14, weight: FontWeight.w700),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 10),
            PrimaryActionButton(
              key: const ValueKey('today-legacy-notice-dismiss'),
              label: l10n.legacyNoticeDismiss,
              icon: Icons.check_rounded,
              // The touch floor the other in-card primaries use.
              height: kButtonMinHeight,
              onTap: () => unawaited(onDismiss()),
            ),
            if (onUpgrade case final upgrade?) ...<Widget>[
              const SizedBox(height: 8),
              SoftPillButton(
                key: const ValueKey('today-legacy-notice-upgrade'),
                label: l10n.planLimitUpgrade,
                icon: Icons.auto_awesome_rounded,
                expand: true,
                onTap: upgrade,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
