// The Premium screen (docs/PREMIUM.md 1.2, 4.3): every state of 4.3 from
// one table, the numbers from the plan and the prices from the store, and
// the onboarding's ways out all meaning Free.

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart' show DateFormat;

import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/app/subscription.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/plan_status.dart';
import 'package:eatova/src/screens/premium/paywall_screen.dart';
import 'package:eatova/src/services/billing/purchase_flow.dart';
import 'package:eatova/src/widgets/design/design.dart';

import '../support/harness.dart';
import '../support/subscription_fakes.dart';

/// A store that has not answered yet.
class _SlowStore extends FakePurchaseFlow {
  final Completer<void> answer = Completer<void>();

  @override
  Future<BillingAvailability> availability() async {
    await answer.future;
    return super.availability();
  }
}

/// Free with limits no default has, so a shown number can only come from
/// the plan.
final PlanStatus _freeOwnNumbers = PlanStatus(
  tier: PlanTier.free,
  current: const TierLimits(
    coachDaily: 6,
    mealAnalysisDaily: 7,
    recipeImportDaily: 2,
    recipePicture: false,
  ),
  free: const TierLimits(
    coachDaily: 6,
    mealAnalysisDaily: 7,
    recipeImportDaily: 2,
    recipePicture: false,
  ),
  premium: const TierLimits(
    coachDaily: 41,
    mealAnalysisDaily: 37,
    recipeImportDaily: 11,
    recipePicture: true,
  ),
  usage: PlanUsage.none(kPlanDay),
  resetAt: nextUtcMidnight(kPlanDay),
);

/// An account from before the launch, its old limits until December.
final PlanStatus _legacy = PlanStatus(
  tier: PlanTier.free,
  current: const TierLimits(
    coachDaily: 5,
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
  legacy: LegacyPlan(until: DateTime.utc(2026, 12, 1)),
  usage: PlanUsage.none(kPlanDay),
  resetAt: nextUtcMidnight(kPlanDay),
);

/// That account after buying Premium: the current limits merge both.
final PlanStatus _legacyPremium = PlanStatus(
  tier: PlanTier.premium,
  subscription: planOf(PlanTier.premium).subscription,
  current: _legacy.premium,
  free: kAssumedFreeLimits,
  premium: _legacy.premium,
  legacy: _legacy.legacy,
  usage: PlanUsage.none(kPlanDay),
  resetAt: nextUtcMidnight(kPlanDay),
);

/// Free again: the Google subscription is on hold after a failed payment,
/// since [days] days.
PlanStatus _onHoldFor(int days) => planOf(
  PlanTier.free,
  subscription: SubscriptionInfo(
    platform: StorePlatform.google,
    productId: 'eatova_premium',
    basePlanId: 'yearly',
    state: SubscriptionState.onHold,
    expiresAt: kPlanDay.subtract(Duration(days: days)),
    autoRenewing: true,
  ),
);

Finder _key(String key) => find.byKey(ValueKey<String>(key));

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// The screen over [plan] and [flow], on the fakes' day.
Future<(SubscriptionController, BuildContext)> _pump(
  WidgetTester tester, {
  PlanStatus? plan,
  FakePurchaseFlow? flow,
  PaywallMode mode = PaywallMode.onboarding,
  Future<void> Function()? onAnswered,
  Size surfaceSize = const Size(390, 844),
  double textScale = 1.0,
}) async {
  final controller = await subscriptionController(
    log: FakeSubscriptionLog(plan: plan ?? planOf(PlanTier.free)),
    flow: flow ?? FakePurchaseFlow(),
  );
  addTearDown(controller.dispose);
  final context = await pumpLocalizedContext(
    tester,
    PaywallScreen(
      mode: mode,
      controller: controller,
      onAnswered: mode == PaywallMode.onboarding
          ? (onAnswered ?? () async {})
          : null,
    ),
    surfaceSize: surfaceSize,
    textScale: textScale,
    scaffold: false,
    safeArea: false,
  );
  await _settle(tester);
  return (controller, context);
}

Future<void> _tapKey(WidgetTester tester, String key) async {
  await tester.ensureVisible(_key(key));
  await _settle(tester);
  await tester.tap(_key(key));
  await _settle(tester);
}

bool _selected(WidgetTester tester, String key) => tester
    .widget<OptionCard>(
      find.ancestor(of: _key(key), matching: find.byType(OptionCard)),
    )
    .selected;

String _text(WidgetTester tester, String key) =>
    tester.widget<Text>(_key(key)).data!;

void main() {
  final rows =
      <
        ({
          String name,
          PlanStatus? plan,
          FakePurchaseFlow Function() flow,
          String? tap,
          List<String> shown,
          List<String> hidden,
          void Function(WidgetTester, BuildContext)? check,
        })
      >[
        (
          name: 'Preise laden',
          plan: null,
          flow: _SlowStore.new,
          tap: null,
          shown: [
            'paywall-loading',
            'paywall-compare',
            'paywall-continue-free',
          ],
          hidden: ['paywall-plans'],
          check: (tester, _) => expect(
            tester.widget<PrimaryActionButton>(_key('paywall-buy')).onTap,
            isNull,
            reason: 'ohne Preis kein Kauf',
          ),
        ),
        (
          name: 'Angebote: Jahr vorgewaehlt, mit Probezeit',
          plan: _freeOwnNumbers,
          flow: FakePurchaseFlow.new,
          tap: null,
          shown: [
            'paywall-plans',
            'paywall-trial-badge',
            'paywall-trial-timeline',
            'paywall-continue-free',
          ],
          hidden: ['paywall-loading'],
          check: (tester, context) {
            final l10n = context.l10n;
            expect(_selected(tester, 'paywall-plan-yearly'), isTrue);
            expect(_selected(tester, 'paywall-plan-monthly'), isFalse);
            expect(find.text(l10n.premiumCtaTrial(7)), findsOneWidget);
            expect(find.text(l10n.premiumPlanSavings(48)), findsOneWidget);
            expect(
              _text(tester, 'paywall-price-yearly'),
              l10n.premiumPlanYearlyPrice('49,99 €'),
            );
            // The first charge: today plus the store's trial, its price.
            final charge = MaterialLocalizations.of(
              context,
            ).formatMediumDate(kPlanDay.add(const Duration(days: 7)).toLocal());
            expect(
              _text(tester, 'paywall-trial-charge'),
              l10n.premiumTrialCharge(charge, '49,99 €'),
            );
            // The table shows the plan's numbers, not the decided defaults.
            for (final number in ['6', '41', '7', '37', '11']) {
              expect(find.text(number), findsOneWidget, reason: number);
            }
          },
        ),
        (
          name: 'Store nicht erreichbar, Free bleibt',
          plan: null,
          flow: () =>
              FakePurchaseFlow()
                ..availabilityAnswer = BillingAvailability.unavailable,
          tap: null,
          shown: [
            'paywall-store-unavailable',
            'paywall-retry',
            'paywall-compare',
            'paywall-continue-free',
          ],
          hidden: ['paywall-plans', 'paywall-buy', 'paywall-restore'],
          check: null,
        ),
        (
          name: 'Kauf laeuft',
          plan: null,
          flow: FakePurchaseFlow.new,
          tap: 'paywall-buy',
          shown: ['paywall-plans'],
          hidden: ['paywall-success'],
          check: (tester, _) => expect(
            tester.widget<PrimaryActionButton>(_key('paywall-buy')).busy,
            isTrue,
          ),
        ),
        (
          name: 'Zahlung ausstehend',
          plan: null,
          flow: () => FakePurchaseFlow()..onBuy = const [PurchasePending()],
          tap: 'paywall-buy',
          shown: ['paywall-pending', 'paywall-plans'],
          hidden: ['paywall-success'],
          check: null,
        ),
        (
          name: 'Erfolg',
          plan: null,
          flow: () => FakePurchaseFlow()
            ..onBuy = [
              PurchaseVerified(active: true, plan: planOf(PlanTier.premium)),
            ],
          tap: 'paywall-buy',
          shown: ['paywall-success', 'paywall-continue'],
          hidden: ['paywall-buy', 'paywall-continue-free', 'paywall-plans'],
          check: null,
        ),
        (
          name: 'Abo eines anderen Kontos',
          plan: null,
          flow: () =>
              FakePurchaseFlow()..onBuy = const [PurchaseOwnedByOther()],
          tap: 'paywall-buy',
          shown: ['paywall-owned-by-other', 'paywall-plans'],
          hidden: ['paywall-success'],
          check: null,
        ),
        (
          name: 'Kauf gescheitert',
          plan: null,
          flow: () => FakePurchaseFlow()..onBuy = const [PurchaseFailed()],
          tap: 'paywall-buy',
          shown: ['paywall-plans'],
          hidden: ['paywall-success'],
          check: (tester, context) {
            expect(
              find.text(context.l10n.premiumPurchaseFailed),
              findsOneWidget,
            );
            final buy = tester.widget<PrimaryActionButton>(_key('paywall-buy'));
            expect(buy.busy, isFalse, reason: 'wieder kaufbar');
          },
        ),
        (
          name: 'Wiederherstellen findet nichts',
          plan: null,
          flow: () =>
              FakePurchaseFlow()..onRestore = const [PurchaseRestoredNothing()],
          tap: 'paywall-restore',
          shown: ['paywall-plans'],
          hidden: [],
          check: (tester, context) => expect(
            find.text(context.l10n.premiumRestoreNothing),
            findsOneWidget,
          ),
        ),
        (
          name: 'schon Premium',
          plan: planOf(PlanTier.premium),
          flow: FakePurchaseFlow.new,
          tap: null,
          shown: [
            'paywall-premium-status',
            'paywall-manage',
            'paywall-continue',
          ],
          hidden: ['paywall-plans', 'paywall-buy', 'paywall-continue-free'],
          check: (tester, context) {
            // A renewal next year names its year.
            final renews = DateFormat.yMMMEd(
              context.l10n.localeName,
            ).format(kPlanDay.add(const Duration(days: 365)).toLocal());
            expect(
              find.text(context.l10n.subscriptionRenewsOn(renews)),
              findsOneWidget,
            );
          },
        ),
        (
          name: 'Bestandskonto mit alten Limits',
          plan: _legacy,
          flow: FakePurchaseFlow.new,
          tap: null,
          shown: ['paywall-legacy-note', 'paywall-plans'],
          hidden: [],
          check: (tester, context) {
            final date = MaterialLocalizations.of(
              context,
            ).formatMediumDate(DateTime.utc(2026, 12, 1).toLocal());
            expect(
              find.text(context.l10n.premiumLegacyNoteUntil(date, 5, 100, 20)),
              findsOneWidget,
            );
          },
        ),
        (
          // Premium merges into its limits: they are not "the previous ones".
          name: 'Bestandskonto mit Premium',
          plan: _legacyPremium,
          flow: FakePurchaseFlow.new,
          tap: null,
          shown: ['paywall-premium-status'],
          hidden: ['paywall-legacy-note'],
          check: null,
        ),
        (
          // Fixed in the store, never bought a second time.
          name: 'Abo zurueckgehalten, Zahlung fehlgeschlagen',
          plan: _onHoldFor(2),
          flow: FakePurchaseFlow.new,
          tap: null,
          shown: [
            'paywall-premium-status',
            'paywall-manage',
            'paywall-continue-free',
          ],
          hidden: ['paywall-plans', 'paywall-buy', 'paywall-foot-charge'],
          check: (tester, context) {
            final l10n = context.l10n;
            expect(
              find.text(l10n.subscriptionOnHold('google')),
              findsOneWidget,
            );
            expect(find.text(l10n.premiumAlreadyActiveTitle), findsNothing);
          },
        ),
        (
          // Longer than any Google hold: the row was never closed, and the
          // account can buy again.
          name: 'Abo seit 61 Tagen zurueckgehalten',
          plan: _onHoldFor(61),
          flow: FakePurchaseFlow.new,
          tap: null,
          shown: ['paywall-plans', 'paywall-buy'],
          hidden: ['paywall-premium-status', 'paywall-manage'],
          check: null,
        ),
      ];

  for (final row in rows) {
    testWidgets('Zustand: ${row.name}', (tester) async {
      await withClock(Clock.fixed(kPlanDay), () async {
        final (_, context) = await _pump(
          tester,
          plan: row.plan,
          flow: row.flow(),
        );
        if (row.tap case final key?) await _tapKey(tester, key);
        for (final key in row.shown) {
          expect(_key(key), findsOneWidget, reason: key);
        }
        for (final key in row.hidden) {
          expect(_key(key), findsNothing, reason: key);
        }
        row.check?.call(tester, context);
        expect(tester.takeException(), isNull);
      });
    });
  }

  testWidgets('der Probezeit-Knopf zeigt Preis und erste Abbuchung direkt '
      'darueber, ohne zu scrollen', (tester) async {
    await withClock(Clock.fixed(kPlanDay), () async {
      final (_, context) = await _pump(tester);
      final l10n = context.l10n;
      final charge = MaterialLocalizations.of(
        context,
      ).formatMediumDate(kPlanDay.add(const Duration(days: 7)).toLocal());

      expect(find.text(l10n.premiumCtaTrial(7)), findsOneWidget);
      expect(
        _text(tester, 'paywall-foot-charge'),
        l10n.premiumTrialCharge(charge, '49,99 €'),
      );
      final line = tester.getRect(_key('paywall-foot-charge'));
      expect(line.top, greaterThanOrEqualTo(0));
      expect(line.bottom, lessThanOrEqualTo(844));
      expect(
        line.bottom,
        lessThanOrEqualTo(tester.getRect(_key('paywall-buy')).top),
      );
    });
  });

  testWidgets('an 320 px und 2.0x: Kauf und Free gleich hoch, der Fuss '
      'waechst hoechstens bis 1.3x', (tester) async {
    await withClock(Clock.fixed(kPlanDay), () async {
      await _pump(tester, surfaceSize: const Size(320, 568), textScale: 2);
      expect(
        tester.getSize(_key('paywall-buy')).height,
        tester.getSize(_key('paywall-continue-free')).height,
      );
      // The pinned foot takes the screen from the content past this scale.
      for (final key in <String>[
        'paywall-foot-charge',
        'paywall-buy',
        'paywall-continue-free',
      ]) {
        final label = find
            .descendant(
              of: _key(key),
              matching: find.byType(Text),
              matchRoot: true,
            )
            .first;
        expect(
          MediaQuery.textScalerOf(tester.element(label)).scale(10),
          13,
          reason: key,
        );
      }
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('der Monatsplan kauft ohne Probezeit und nennt seinen Preis', (
    tester,
  ) async {
    await withClock(Clock.fixed(kPlanDay), () async {
      final flow = FakePurchaseFlow();
      final (_, context) = await _pump(tester, flow: flow);
      final l10n = context.l10n;

      await _tapKey(tester, 'paywall-plan-monthly');
      expect(_selected(tester, 'paywall-plan-monthly'), isTrue);
      expect(_key('paywall-trial-timeline'), findsNothing);
      expect(find.text(l10n.premiumCtaSubscribe), findsOneWidget);
      expect(
        _text(tester, 'paywall-foot-charge'),
        l10n.premiumPlanMonthlyPrice('7,99 €'),
      );
      expect(
        _text(tester, 'paywall-renewal'),
        startsWith(l10n.premiumRenewalMonthly('7,99 €')),
      );

      await _tapKey(tester, 'paywall-buy');
      expect(flow.buys.single.offer.period, PremiumPeriod.monthly);
    });
  });

  testWidgets('im Onboarding heissen Schliessen, Zurueck und Free: Free', (
    tester,
  ) async {
    await withClock(Clock.fixed(kPlanDay), () async {
      for (final way in ['close', 'back', 'free']) {
        var answers = 0;
        await _pump(tester, onAnswered: () async => answers++);
        switch (way) {
          case 'close':
            await _tapKey(tester, 'paywall-close');
          case 'back':
            await tester.binding.handlePopRoute();
            await _settle(tester);
          case 'free':
            await _tapKey(tester, 'paywall-continue-free');
        }
        expect(answers, 1, reason: way);
        expect(_key('screen-paywall'), findsOneWidget, reason: way);
      }
    });
  });

  testWidgets('die Schale oeffnet Premium als Route, einmal zur Zeit', (
    tester,
  ) async {
    final binding = SubscriptionBinding();
    await tester.pumpWidget(
      SubscriptionScope(
        binding: binding,
        child: localizedApp(EatovaHomePage(), safeArea: false, scaffold: false),
      ),
    );
    await _settle(tester);
    final shell = tester.element(find.byType(EatovaHomePage));
    final paywalls = find.byKey(
      const ValueKey('screen-paywall'),
      skipOffstage: false,
    );

    // A second tap while the first route opens stacks nothing.
    unawaited(openPremium(shell, source: PremiumSource.coach));
    unawaited(openPremium(shell, source: PremiumSource.coach));
    await _settle(tester);
    expect(paywalls, findsOneWidget);
    final screen = tester.widget<PaywallScreen>(find.byType(PaywallScreen));
    expect(screen.mode, PaywallMode.upsell);
    expect(screen.source, PremiumSource.coach);

    await _tapKey(tester, 'paywall-close');
    expect(paywalls, findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(binding.opener, isNull, reason: 'unregistered with the shell');
  });
}
