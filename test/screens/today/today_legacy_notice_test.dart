// Today's one-time notice for legacy accounts (docs/PREMIUM.md 4.4): it
// appears once the operator set `legacy_until`, names that date and the new
// Free limits, stays away after "Verstanden" for that date and returns for a
// later one.

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/plan_status.dart';
import 'package:eatova/src/screens/today/today_legacy_notice.dart';

import '../../support/harness.dart';
import '../../support/subscription_fakes.dart';

/// A legacy account's plan; [until] is the operator's `legacy_until`.
PlanStatus _legacy(DateTime? until) => PlanStatus(
  tier: PlanTier.free,
  current: const TierLimits(
    coachDaily: 5,
    mealAnalysisDaily: 100,
    recipeImportDaily: 20,
    recipePicture: true,
  ),
  free: kAssumedFreeLimits,
  premium: kAssumedPremiumLimits,
  legacy: LegacyPlan(until: until),
  usage: PlanUsage.none(kPlanDay),
  resetAt: nextUtcMidnight(kPlanDay),
);

final Finder _card = find.byKey(const ValueKey('today-legacy-notice'));

void main() {
  testWidgets('der Hinweis erscheint einmal je legacy_until', (tester) async {
    final l10n = lookupAppLocalizations(const Locale('de'));
    await withClock(Clock.fixed(kPlanDay), () async {
      final log = FakeSubscriptionLog(plan: _legacy(null));
      final controller = await subscriptionController(log: log);
      addTearDown(controller.dispose);
      DateTime? slot;
      Future<void> mount() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await pumpLocalized(
          tester,
          TodayLegacyNotice(
            controller: controller,
            readDismissed: () async => slot,
            writeDismissed: (until) async => slot = until,
            onOpenTerms: () {},
          ),
          scrollable: true,
        );
        // The slot read lands a frame later.
        await tester.pump();
      }

      // No end date yet: nothing to announce.
      await mount();
      expect(_card, findsNothing);

      // The operator sets it: the date and the new Free limits.
      final first = DateTime.utc(2026, 12, 1, 12);
      log.plan = _legacy(first);
      await controller.refresh(force: true);
      await tester.pump();
      expect(_card, findsOneWidget);
      expect(
        find.text(
          '${l10n.legacyNoticeBody('1. Dez. 2026', 3, 4, 2)} '
          '${l10n.legacyNoticeMorePremium}',
        ),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey('today-legacy-notice-dismiss')),
      );
      await tester.pump();
      expect(_card, findsNothing);
      expect(slot, first);

      // The next start remembers it.
      await mount();
      expect(_card, findsNothing);

      // A later date is news again.
      log.plan = _legacy(DateTime.utc(2027, 1, 15, 12));
      await controller.refresh(force: true);
      await tester.pump();
      expect(_card, findsOneWidget);
    });
  });

  testWidgets('mit Premium: die regulaeren Premium-Limits, kein Angebot', (
    tester,
  ) async {
    final l10n = lookupAppLocalizations(const Locale('de'));
    await withClock(Clock.fixed(kPlanDay), () async {
      final controller = await subscriptionController(
        log: FakeSubscriptionLog(
          plan: PlanStatus(
            tier: PlanTier.premium,
            subscription: planOf(PlanTier.premium).subscription,
            current: const TierLimits(
              coachDaily: 20,
              mealAnalysisDaily: 100,
              recipeImportDaily: 20,
              recipePicture: true,
            ),
            free: kAssumedFreeLimits,
            premium: const TierLimits(
              coachDaily: 20,
              mealAnalysisDaily: 100,
              recipeImportDaily: 20,
              recipePicture: true,
            ),
            legacy: LegacyPlan(
              until: DateTime.utc(2026, 12, 1, 12),
              premium: (
                coachDaily: 20,
                mealAnalysisDaily: 30,
                recipeImportDaily: 10,
              ),
            ),
            usage: PlanUsage.none(kPlanDay),
            resetAt: nextUtcMidnight(kPlanDay),
          ),
        ),
      );
      addTearDown(controller.dispose);
      await pumpLocalized(
        tester,
        TodayLegacyNotice(
          controller: controller,
          readDismissed: () async => null,
          writeDismissed: (_) async {},
          onUpgrade: () {},
          onOpenTerms: () {},
        ),
        scrollable: true,
      );
      await tester.pump();

      final body = find.byKey(const ValueKey('today-legacy-notice-body'));
      expect(
        tester.widget<Text>(body).data,
        l10n.legacyNoticeBodyPremium('1. Dez. 2026', 20, 30, 10),
      );
      expect(
        find.byKey(const ValueKey('today-legacy-notice-upgrade')),
        findsNothing,
      );
    });
  });

  testWidgets('Premium und die geaenderten AGB oeffnen sich aus dem Hinweis', (
    tester,
  ) async {
    var upgrades = 0;
    var terms = 0;
    await withClock(Clock.fixed(kPlanDay), () async {
      await pumpLocalized(
        tester,
        TodayLegacyNoticeCard(
          until: DateTime.utc(2026, 12, 1, 12),
          free: kAssumedFreeLimits,
          onDismiss: () async {},
          onUpgrade: () => upgrades++,
          onOpenTerms: () => terms++,
        ),
        scrollable: true,
      );
      for (final key in const <String>[
        'today-legacy-notice-upgrade',
        'today-legacy-notice-terms',
      ]) {
        final button = find.byKey(ValueKey(key));
        await tester.ensureVisible(button);
        await tester.tap(button);
      }
    });

    expect((upgrades, terms), (1, 1));
  });
}
