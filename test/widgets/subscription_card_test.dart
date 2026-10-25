// The Profile's "Abo" card (docs/PREMIUM.md 4.4): one table row per account
// state at a frozen clock, with the tier, the status sentence and its date,
// today's usage against the current limits and the actions that fit. Every
// number and date comes from the plan. The test device is Android, so a
// Google subscription is managed here and an Apple one "there".

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/subscription.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/plan_status.dart';
import 'package:eatova/src/services/billing/purchase_flow.dart';
import 'package:eatova/src/widgets/profile/subscription_card.dart';

import '../support/harness.dart';
import '../support/subscription_fakes.dart';

/// The fakes' day, noon UTC: every date below is the same day everywhere.
final DateTime _now = kPlanDay;

SubscriptionInfo _store({
  StorePlatform platform = StorePlatform.google,
  String productId = 'eatova_premium',
  String? basePlanId = 'yearly',
  SubscriptionState state = SubscriptionState.active,
  Duration expiresIn = const Duration(days: 365),
  bool? autoRenewing = true,
  SubscriptionEnvironment environment = SubscriptionEnvironment.production,
}) => SubscriptionInfo(
  platform: platform,
  productId: productId,
  basePlanId: basePlanId,
  state: state,
  expiresAt: _now.add(expiresIn),
  autoRenewing: autoRenewing,
  environment: environment,
);

/// A legacy account: the old limits apply now, Premium would add Coach; with
/// a [subscription] it has Premium, merged with the old limits, and [base]
/// are the regular Premium limits it keeps after [until].
PlanStatus _legacy(
  DateTime? until, {
  SubscriptionInfo? subscription,
  BasePremiumLimits? base,
}) => PlanStatus(
  tier: subscription == null ? PlanTier.free : PlanTier.premium,
  subscription: subscription,
  current: TierLimits(
    coachDaily: subscription == null ? 5 : 20,
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
  legacy: LegacyPlan(until: until, premium: base),
  usage: PlanUsage(
    day: utcDay(_now),
    coach: 1,
    mealAnalysis: 7,
    recipeImport: 0,
  ),
  resetAt: nextUtcMidnight(_now),
);

Widget _card(
  PlanStatus plan, {
  VoidCallback? onUpgrade,
  VoidCallback? onManage,
  Future<PurchaseState> Function()? onRestore,
}) => SubscriptionCard(
  plan: plan,
  onUpgrade: onUpgrade ?? () {},
  onManage: onManage ?? () {},
  onRestore: onRestore ?? () async => PurchaseState.idle,
);

Finder _part(String suffix) =>
    find.byKey(ValueKey<String>('profile-subscription-$suffix'));

/// The card's optional actions and notes.
const List<String> _optional = <String>[
  'upgrade',
  'manage',
  'elsewhere',
  'test-purchase',
  'legacy',
];

void main() {
  testWidgets('die Karte zeigt jeden Abo-Zustand mit seinen Daten', (
    tester,
  ) async {
    final l10n = lookupAppLocalizations(const Locale('de'));
    final rows =
        <
          ({
            String name,
            PlanStatus plan,
            bool premium,
            List<String> details,
            String? status,
            List<String> usage,
            Set<String> shows,
            String? note,
          })
        >[
          (
            name: 'Free ohne Abo',
            plan: planOf(PlanTier.free, coachUsed: 1, analysesUsed: 2),
            premium: false,
            details: const <String>[],
            status: null,
            usage: const <String>['1/3', '2/4', '0/2'],
            shows: const <String>{'upgrade'},
            note: l10n.subscriptionFreeBody(20, 30),
          ),
          (
            name: 'Premium verlaengert sich',
            plan: planOf(PlanTier.premium, coachUsed: 4),
            premium: true,
            details: <String>[
              l10n.subscriptionPlanYearly,
              l10n.subscriptionVia('google'),
            ],
            status: l10n.subscriptionRenewsOn('25. Okt. 2027'),
            usage: const <String>['4/20', '0/30', '0/10'],
            shows: const <String>{'manage'},
            note: null,
          ),
          (
            name: 'gekuendigter Testkauf endet',
            plan: planOf(
              PlanTier.premium,
              subscription: _store(
                state: SubscriptionState.canceled,
                autoRenewing: false,
                environment: SubscriptionEnvironment.test,
              ),
            ),
            premium: true,
            details: <String>[l10n.subscriptionVia('google')],
            status: l10n.subscriptionEndsOn('25. Okt. 2027'),
            usage: const <String>['0/20', '0/30', '0/10'],
            shows: const <String>{'manage', 'test-purchase'},
            note: null,
          ),
          (
            name: 'Zahlung fehlgeschlagen, noch Zugang',
            plan: planOf(
              PlanTier.premium,
              subscription: _store(
                state: SubscriptionState.grace,
                expiresIn: const Duration(days: 3),
              ),
            ),
            premium: true,
            details: const <String>[],
            status: l10n.subscriptionGrace('28. Okt. 2026'),
            usage: const <String>['0/20', '0/30', '0/10'],
            shows: const <String>{'manage'},
            note: null,
          ),
          (
            name: 'Zahlung fehlgeschlagen, kein Zugang',
            plan: planOf(
              PlanTier.free,
              subscription: _store(
                state: SubscriptionState.onHold,
                expiresIn: const Duration(days: -2),
              ),
            ),
            premium: false,
            details: const <String>[],
            status: l10n.subscriptionOnHold('google'),
            usage: const <String>['0/3', '0/4', '0/2'],
            shows: const <String>{'manage'},
            note: null,
          ),
          (
            name: 'pausiert',
            plan: planOf(
              PlanTier.free,
              subscription: _store(
                basePlanId: 'monthly',
                state: SubscriptionState.paused,
                expiresIn: const Duration(days: -1),
              ),
            ),
            premium: false,
            details: <String>[l10n.subscriptionPlanMonthly],
            status: l10n.subscriptionPaused,
            usage: const <String>['0/3', '0/4', '0/2'],
            shows: const <String>{'manage'},
            note: null,
          ),
          (
            name: 'abgelaufen',
            plan: planOf(
              PlanTier.free,
              subscription: _store(
                state: SubscriptionState.expired,
                expiresIn: const Duration(days: -10),
              ),
            ),
            premium: false,
            details: const <String>[],
            status: l10n.subscriptionExpiredOn('15. Okt. 2026'),
            usage: const <String>['0/3', '0/4', '0/2'],
            shows: const <String>{'upgrade'},
            note: null,
          ),
          (
            name: 'erstattet',
            plan: planOf(
              PlanTier.free,
              subscription: _store(state: SubscriptionState.revoked),
            ),
            premium: false,
            details: const <String>[],
            status: l10n.subscriptionRevoked,
            usage: const <String>['0/3', '0/4', '0/2'],
            shows: const <String>{'upgrade'},
            note: null,
          ),
          (
            name: 'vom Betreiber freigeschaltet',
            plan: planOf(
              PlanTier.premium,
              subscription: _store(
                platform: StorePlatform.manual,
                basePlanId: null,
                expiresIn: const Duration(days: 30),
                autoRenewing: null,
              ),
            ),
            premium: true,
            details: const <String>[],
            status: l10n.subscriptionManualUntil('24. Nov. 2026'),
            usage: const <String>['0/20', '0/30', '0/10'],
            shows: const <String>{},
            note: null,
          ),
          (
            name: 'im App Store gekauft, hier Android',
            plan: _legacy(
              null,
              subscription: _store(
                platform: StorePlatform.apple,
                productId: 'eatova_premium_monthly',
                basePlanId: null,
                expiresIn: const Duration(days: 20),
                autoRenewing: null,
                environment: SubscriptionEnvironment.sandbox,
              ),
            ),
            premium: true,
            details: <String>[
              l10n.subscriptionPlanMonthly,
              l10n.subscriptionVia('apple'),
            ],
            status: l10n.subscriptionRenewsOn('14. Nov. 2026'),
            usage: const <String>['1/20', '7/100', '0/20'],
            // Premium merges into the current limits: no "previous limits".
            shows: const <String>{'elsewhere', 'test-purchase'},
            note: l10n.subscriptionManagedElsewhere('apple'),
          ),
          (
            // Stays after Today's one-time notice was dismissed.
            name: 'Bestandskonto mit Premium und Enddatum',
            plan: _legacy(
              DateTime.utc(2026, 12, 1, 12),
              subscription: _store(),
              base: (
                coachDaily: 20,
                mealAnalysisDaily: 30,
                recipeImportDaily: 10,
              ),
            ),
            premium: true,
            details: <String>[
              l10n.subscriptionPlanYearly,
              l10n.subscriptionVia('google'),
            ],
            status: l10n.subscriptionRenewsOn('25. Okt. 2027'),
            usage: const <String>['1/20', '7/100', '0/20'],
            shows: const <String>{'manage', 'legacy'},
            note: l10n.legacyNoticeBodyPremium('1. Dez. 2026', 20, 30, 10),
          ),
          (
            name: 'Bestandskonto mit Enddatum',
            plan: _legacy(DateTime.utc(2026, 12, 1, 12)),
            premium: false,
            details: const <String>[],
            status: null,
            usage: const <String>['1/5', '7/100', '0/20'],
            shows: const <String>{'legacy', 'upgrade'},
            note: l10n.premiumLegacyNoteUntil('1. Dez. 2026', 5, 100, 20),
          ),
          (
            name: 'Bestandskonto ohne Enddatum',
            plan: _legacy(null),
            premium: false,
            details: const <String>[],
            status: null,
            usage: const <String>['1/5', '7/100', '0/20'],
            shows: const <String>{'legacy', 'upgrade'},
            note: l10n.premiumLegacyNote(5, 100, 20),
          ),
        ];

    for (final row in rows) {
      await withClock(Clock.fixed(_now), () async {
        await pumpLocalized(tester, _card(row.plan), scrollable: true);
      });
      final why = row.name;

      expect(
        _part(row.premium ? 'premium' : 'free'),
        findsOneWidget,
        reason: why,
      );
      final details = row.details.isEmpty
          ? ''
          : tester.widget<Text>(_part('details')).data!;
      for (final fragment in row.details) {
        expect(details, contains(fragment), reason: why);
      }
      expect(
        _part('status'),
        row.status == null ? findsNothing : findsOneWidget,
        reason: why,
      );
      if (row.status case final status?) {
        expect(find.text(status), findsOneWidget, reason: why);
      }
      for (final (index, feature) in PlanFeature.values.indexed) {
        expect(
          find.descendant(
            of: _part('usage-${feature.wire}'),
            matching: find.text(row.usage[index]),
          ),
          findsOneWidget,
          reason: '$why: ${feature.wire}',
        );
      }
      for (final part in _optional) {
        expect(
          _part(part),
          row.shows.contains(part) ? findsOneWidget : findsNothing,
          reason: '$why: $part',
        );
      }
      if (row.note case final note?) {
        expect(find.text(note), findsOneWidget, reason: why);
      }
      expect(_part('restore'), findsOneWidget, reason: why);
    }
  });

  testWidgets('Vorleser hoeren "1 von 3 genutzt", keinen Bruch', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final l10n = lookupAppLocalizations(const Locale('de'));
    await withClock(Clock.fixed(_now), () async {
      await pumpLocalized(
        tester,
        _card(planOf(PlanTier.free, coachUsed: 1)),
        scrollable: true,
      );
    });
    final label = tester.getSemantics(_part('usage-coach')).label;
    expect(label, contains(l10n.subscriptionUsageValueLabel(1, 3)));
    expect(label, isNot(contains('1/3')));
    semantics.dispose();
  });

  testWidgets('die Aktionen erreichen ihre Callbacks', (tester) async {
    var upgrades = 0;
    var manages = 0;
    await withClock(Clock.fixed(_now), () async {
      for (final (plan, action) in <(PlanStatus, String)>[
        (planOf(PlanTier.free), 'upgrade'),
        (planOf(PlanTier.premium), 'manage'),
      ]) {
        await pumpLocalized(
          tester,
          _card(plan, onUpgrade: () => upgrades++, onManage: () => manages++),
          scrollable: true,
        );
        await tester.ensureVisible(_part(action));
        await tester.tap(_part(action));
      }
    });

    expect((upgrades, manages), (1, 1));
  });

  testWidgets('Wiederherstellen nennt das Ergebnis und gibt den Zustand frei', (
    tester,
  ) async {
    await withClock(Clock.fixed(_now), () async {
      final flow = FakePurchaseFlow()
        ..onRestore = const <PurchaseEvent>[PurchaseRestoredNothing()];
      final controller = await subscriptionController(
        log: FakeSubscriptionLog(plan: planOf(PlanTier.free)),
        flow: flow,
      );
      addTearDown(controller.dispose);
      await pumpLocalized(
        tester,
        _card(
          controller.plan,
          onRestore: () => restorePurchasesFor(controller),
        ),
        scrollable: true,
      );

      await tester.tap(_part('restore'));
      // Frames, not pumpAndSettle: settling would let the toast expire.
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(flow.restores, 1);
      expect(
        find.text(
          lookupAppLocalizations(const Locale('de')).premiumRestoreNothing,
        ),
        findsOneWidget,
      );
      expect(controller.purchaseState, PurchaseState.idle);
    });
  });

  renderMatrix('die vollste Karte passt auf 320 px', (tester, c) async {
    await withClock(Clock.fixed(_now), () async {
      await c.pump(
        tester,
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: _card(
            _legacy(
              DateTime.utc(2026, 12, 1, 12),
              subscription: _store(
                platform: StorePlatform.apple,
                productId: 'eatova_premium_yearly',
                basePlanId: null,
                environment: SubscriptionEnvironment.sandbox,
              ),
            ),
          ),
        ),
        surfaceSize: const Size(320, 568),
        scrollable: true,
      );
    });
    expect(_part('elsewhere'), findsOneWidget);
  }, textScales: const <double>[2.0]);
}
